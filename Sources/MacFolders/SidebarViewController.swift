import AppKit
import NetFS

extension NSPasteboard.PasteboardType {
    /// Private type for reordering favorites — deliberately NOT a fileURL so a
    /// sidebar drag can't be dropped into file views as a real file operation.
    static let foldersFavorite = NSPasteboard.PasteboardType("ai.grovestack.macfolders.favorite")
}

final class SidebarViewController: NSViewController,
    NSOutlineViewDataSource, NSOutlineViewDelegate {

    enum Entry {
        case group(String)
        case location(URL)
        case server(String)   // discovered SMB server; click to connect
    }

    var onSelect: ((URL) -> Void)?
    var onOpenInNewTab: ((URL) -> Void)?
    var favorites: [URL] = SidebarViewController.defaultFavorites() {
        didSet { rebuildEntries() }
    }
    var recentFolders: [URL] = [] {
        didSet { rebuildEntries() }
    }
    var recentDocuments: [URL] = [] {
        didSet { rebuildEntries() }
    }
    private var volumes: [URL] = []
    private var entries: [Entry] = []
    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()

    static func defaultFavorites() -> [URL] {
        SidebarDefaults.favoritePaths().map(URL.init(fileURLWithPath:))
    }

    static let trashURL = FileManager.default.urls(
        for: .trashDirectory, in: .userDomainMask)[0]

    /// Finder's Trash is several trashes merged: the home trash, iCloud
    /// Drive's ".Trash" (Recently Deleted), and each volume's ".Trashes/uid".
    static func trashDirectories() -> [URL] {
        var dirs = [trashURL]
        if let icloud = CloudFiles.iCloudDriveURL() {
            let cloudTrash = icloud.appendingPathComponent(".Trash")
            if FileManager.default.fileExists(atPath: cloudTrash.path) {
                dirs.append(cloudTrash)
            }
        }
        let uid = getuid()
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: [.skipHiddenVolumes]) ?? []
        for volume in volumes where volume.path != "/" {
            let volumeTrash = volume.appendingPathComponent(".Trashes/\(uid)")
            if FileManager.default.fileExists(atPath: volumeTrash.path) {
                dirs.append(volumeTrash)
            }
        }
        return dirs
    }

    /// The workspace of the window this sidebar lives in.
    private var windowWorkspaceID: UUID {
        AppDelegate.shared.workspaceID(for: view.window)
    }

    /// Anything Finder would put an eject button on: ejectable or removable
    /// media, disk images, and network mounts. Never the boot volume.
    static func isEjectable(_ url: URL) -> Bool {
        guard url.path != "/" else { return false }
        guard let values = try? url.resourceValues(forKeys:
            [.isVolumeKey, .volumeIsEjectableKey, .volumeIsRemovableKey,
             .volumeIsInternalKey, .volumeIsLocalKey]),
            values.isVolume == true else { return false }
        return values.volumeIsEjectable == true
            || values.volumeIsRemovable == true
            || values.volumeIsInternal == false
            || values.volumeIsLocal == false
    }

    private func eject(_ url: URL) {
        // Whole-device eject, like Finder — all partitions unmount together.
        FileManager.default.unmountVolume(
            at: url, options: [.allPartitionsAndEjectDisk]) { error in
            DispatchQueue.main.async {
                if let error { NSAlert(error: error).runModal() }
            }
        }
    }

    @objc private func ejectClicked(_ sender: NSButton) {
        guard entries.indices.contains(sender.tag),
              case .location(let url) = entries[sender.tag] else { return }
        eject(url)
    }

    @objc private func ejectFromMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        eject(url)
    }

    override func loadView() {
        view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked)
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        // The clip view only resizes the outline (and thus the column, via
        // firstColumnOnlyAutoresizingStyle) if the outline's mask tracks width.
        outlineView.autoresizingMask = [.width, .height]
        outlineView.frame = scrollView.contentView.bounds
        outlineView.sizeLastColumnToFit()

        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu
        outlineView.registerForDraggedTypes([.fileURL, .foldersFavorite])

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(volumesChanged),
                           name: NSWorkspace.didMountNotification, object: nil)
        center.addObserver(self, selector: #selector(volumesChanged),
                           name: NSWorkspace.didUnmountNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(volumesChanged),
            name: NetworkBrowser.serversChanged, object: nil)
        reloadVolumes()
    }

    @objc private func volumesChanged(_ note: Notification) {
        reloadVolumes()
    }

    private func reloadVolumes() {
        volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]) ?? []
        rebuildEntries()
    }

    private func rebuildEntries() {
        entries = [.group("Locations")] + volumes.map(Entry.location)
        // Discovered servers whose share is already mounted stay one row:
        // the mounted volume (with its eject button).
        let mountedNames = Set(volumes.compactMap {
            (try? $0.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
        })
        entries += NetworkBrowser.shared.servers
            .filter { !mountedNames.contains($0) }
            .map(Entry.server)
        entries += [.location(Self.trashURL)]
        if let icloud = CloudFiles.iCloudDriveURL() {
            entries += [.group("iCloud"), .location(icloud)]
        }
        entries += [.group("Favorites")] + favorites.map(Entry.location)
        if !recentFolders.isEmpty {
            entries += [.group("Recent Folders")] + recentFolders.map(Entry.location)
        }
        if !recentDocuments.isEmpty {
            entries += [.group("Recent Documents")] + recentDocuments.map(Entry.location)
        }
        outlineView.reloadData()
    }

    @objc private func rowClicked() {
        let row = outlineView.clickedRow
        guard entries.indices.contains(row) else { return }
        switch entries[row] {
        case .location(let url):
            onSelect?(url)
        case .server(let name):
            connectToServer(name)
        case .group:
            break
        }
    }

    /// Connect to a discovered server through the system's standard flow
    /// (Finder's connect dialog: keychain auth + share selection). Once the
    /// share mounts, the mount notification lists it here with its eject
    /// button.
    private func connectToServer(_ name: String) {
        NetworkBrowser.shared.resolveHost(of: name) { host in
            guard let host, let url = URL(string: "smb://\(host)") else {
                let alert = NSAlert()
                alert.messageText = "Could not resolve “\(name)”."
                alert.informativeText = "The server may have gone offline."
                alert.runModal()
                return
            }
            var requestID: AsyncRequestID?
            // Auth/share-picker UI and connection errors are presented by
            // the system (NetAuthAgent); on success we land in the share.
            NetFSMountURLAsync(url as CFURL, nil, nil, nil, nil, nil,
                               &requestID, DispatchQueue.main) { [weak self] _, _, mountpoints in
                if let first = (mountpoints as? [String])?.first {
                    self?.onSelect?(URL(fileURLWithPath: first))
                }
            }
        }
    }

    // MARK: Outline (flat list; groups are styling only)

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? entries.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        index  // rows are addressed by index into entries
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        guard let index = item as? Int, entries.indices.contains(index) else { return false }
        if case .group = entries[index] { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        !self.outlineView(outlineView, isGroupItem: item)
    }

    // MARK: Drop folders into Favorites

    private func droppableFolders(from info: NSDraggingInfo) -> [URL] {
        let urls = (info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let existing = favorites.map(\.path)
        return urls.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                && !existing.contains($0.path)
        }
    }

    /// Row index of the "Favorites" group header in the flat entries list.
    private var favoritesHeaderIndex: Int {
        entries.firstIndex { entry in
            if case .group("Favorites") = entry { return true }
            return false
        } ?? 0
    }

    /// Favorites occupy the rows right after their group header. Clamp any
    /// proposed drop into that range. A drop ON the header means "front"; ON
    /// a favorite row means "right after it"; elsewhere, append.
    private func clampedDropIndex(_ proposed: Int, item: Any?) -> Int {
        let header = favoritesHeaderIndex
        let first = header + 1
        let last = header + favorites.count + 1
        if proposed < 0 {
            if let index = item as? Int {
                if index == header { return first }
                if (first...(last - 1)).contains(index) { return index + 1 }
            }
            return last
        }
        return min(max(proposed, first), last)
    }

    func outlineView(_ outlineView: NSOutlineView,
                     pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let index = item as? Int, entries.indices.contains(index),
              case .location(let url) = entries[index],
              favorites.contains(url) else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(url.path, forType: .foldersFavorite)
        return pasteboardItem
    }

    /// A drop ON a sidebar folder row (favorite, recent, volume) is a real
    /// file drop into that folder — Finder semantics. Only drops BETWEEN
    /// favorites rows add a favorite.
    private func dropIntoFolder(item: Any?, index: Int,
                                info: NSDraggingInfo) -> URL? {
        guard index == NSOutlineViewDropOnItemIndex,
              let rowIndex = item as? Int, entries.indices.contains(rowIndex),
              case .location(let dest) = entries[rowIndex],
              (try? dest.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        else { return nil }
        let sources = (info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !sources.isEmpty, !sources.contains(dest),
              !sources.contains(where: { $0.deletingLastPathComponent() == dest })
        else { return nil }
        return dest
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        if info.draggingPasteboard.string(forType: .foldersFavorite) != nil {
            outlineView.setDropItem(nil, dropChildIndex: clampedDropIndex(index, item: item))
            return .move
        }
        if let dest = dropIntoFolder(item: item, index: index, info: info) {
            let sources = (info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            return DropBehavior.operation(for: sources, destination: dest)
        }
        guard !droppableFolders(from: info).isEmpty else { return [] }
        outlineView.setDropItem(nil, dropChildIndex: clampedDropIndex(index, item: item))
        return .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        if let dest = dropIntoFolder(item: item, index: index, info: info) {
            let sources = (info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            let operation = DropBehavior.operation(for: sources, destination: dest)
            return DropBehavior.perform(operation, sources: sources, destination: dest)
        }
        if let path = info.draggingPasteboard.string(forType: .foldersFavorite) {
            do {
                try AppDelegate.shared.workspaceManager.moveFavorite(
                    path: path,
                    toIndex: clampedDropIndex(index, item: item) - favoritesHeaderIndex - 1,
                    in: windowWorkspaceID)
                return true
            } catch {
                NSAlert(error: error).runModal()
                return false
            }
        }
        let folders = droppableFolders(from: info)
        guard !folders.isEmpty else { return false }
        let favoritesIndex = clampedDropIndex(index, item: item) - favoritesHeaderIndex - 1
        // Option-drop adds the favorite to every workspace, not just the active one.
        let allWorkspaces = NSEvent.modifierFlags.contains(.option)
        do {
            for (offset, url) in folders.enumerated() {
                if allWorkspaces {
                    try AppDelegate.shared.workspaceManager.insertFavoriteInAllWorkspaces(
                        path: url.path, activeAt: favoritesIndex + offset,
                        in: windowWorkspaceID)
                } else {
                    try AppDelegate.shared.workspaceManager.insertFavorite(
                        path: url.path, at: favoritesIndex + offset, in: windowWorkspaceID)
                }
            }
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        guard let index = item as? Int, entries.indices.contains(index) else { return nil }
        switch entries[index] {
        case .server(let name):
            let cell = NSTableCellView()
            let text = NSTextField(labelWithString: name)
            text.lineBreakMode = .byTruncatingMiddle
            let image = NSImageView()
            let icon = NSImage(named: NSImage.networkName) ?? NSImage()
            icon.size = NSSize(width: 16, height: 16)
            image.image = icon
            text.translatesAutoresizingMaskIntoConstraints = false
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.addSubview(text)
            cell.textField = text
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        case .group(let title):
            let cell = NSTableCellView()
            let text = NSTextField(labelWithString: title)
            text.font = .systemFont(ofSize: 11, weight: .semibold)
            text.textColor = .secondaryLabelColor
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        case .location(let url):
            let cell = NSTableCellView()
            let isICloudDrive = url == CloudFiles.iCloudDriveURL()
            let isTrash = url == Self.trashURL
            let values = try? url.resourceValues(forKeys: [.isVolumeKey, .volumeNameKey])
            let name = isICloudDrive ? "iCloud Drive"
                : isTrash ? "Trash"
                : (values?.isVolume == true ? values?.volumeName : nil)
                ?? url.lastPathComponent
            let text = NSTextField(labelWithString: name.isEmpty ? url.path : name)
            text.lineBreakMode = .byTruncatingMiddle
            let image = NSImageView()
            let trashHasItems = isTrash && Self.trashDirectories().contains {
                !((try? FileManager.default.contentsOfDirectory(
                    at: $0, includingPropertiesForKeys: nil)) ?? []).isEmpty
            }
            let icon = isICloudDrive
                ? (NSImage(systemSymbolName: "icloud",
                           accessibilityDescription: "iCloud Drive")
                    ?? NSWorkspace.shared.icon(forFile: url.path))
                : isTrash
                ? (NSImage(named: trashHasItems
                    ? NSImage.trashFullName : NSImage.trashEmptyName)
                    ?? NSWorkspace.shared.icon(forFile: url.path))
                : NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            image.image = icon
            text.translatesAutoresizingMaskIntoConstraints = false
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.addSubview(text)
            cell.textField = text
            cell.imageView = image
            var trailing = cell.trailingAnchor
            if Self.isEjectable(url) {
                let ejectButton = NSButton(
                    image: NSImage(systemSymbolName: "eject.fill",
                                   accessibilityDescription: "Eject")!,
                    target: self, action: #selector(ejectClicked(_:)))
                ejectButton.isBordered = false
                ejectButton.tag = index
                ejectButton.contentTintColor = .secondaryLabelColor
                ejectButton.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(ejectButton)
                NSLayoutConstraint.activate([
                    ejectButton.trailingAnchor.constraint(
                        equalTo: cell.trailingAnchor, constant: -4),
                    ejectButton.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    ejectButton.widthAnchor.constraint(equalToConstant: 18),
                ])
                trailing = ejectButton.leadingAnchor
            }
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                text.trailingAnchor.constraint(equalTo: trailing, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
    }
}

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard entries.indices.contains(row),
              case .location(let url) = entries[row] else { return }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let item = NSMenuItem(title: "Open in New Tab",
                                  action: #selector(openInNewTab(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            menu.addItem(item)
        }
        let infoItem = NSMenuItem(title: "Get Info",
                                  action: #selector(showItemInfo(_:)), keyEquivalent: "")
        infoItem.target = self
        infoItem.representedObject = url
        menu.addItem(infoItem)
        let pathItem = NSMenuItem(title: "Copy Pathname",
                                  action: #selector(copyPathname(_:)), keyEquivalent: "")
        pathItem.target = self
        pathItem.representedObject = url
        menu.addItem(pathItem)
        if url == Self.trashURL {
            let emptyItem = NSMenuItem(title: "Empty Trash…",
                                       action: #selector(emptyTrash(_:)),
                                       keyEquivalent: "")
            emptyItem.target = self
            menu.addItem(emptyItem)
        }
        if Self.isEjectable(url) {
            let name = (try? url.resourceValues(forKeys: [.volumeNameKey]))?
                .volumeName ?? url.lastPathComponent
            let ejectItem = NSMenuItem(title: "Eject “\(name)”",
                                       action: #selector(ejectFromMenu(_:)),
                                       keyEquivalent: "")
            ejectItem.target = self
            ejectItem.representedObject = url
            menu.addItem(ejectItem)
        }
        if recentFolders.contains(url) || recentDocuments.contains(url) {
            let item = NSMenuItem(title: "Remove from Recents",
                                  action: #selector(removeRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            menu.addItem(item)
        }
        if favorites.contains(url) {
            let manager = AppDelegate.shared.workspaceManager!
            if manager.state.workspaces.count > 1 {
                if manager.isFavoriteInAllWorkspaces(path: url.path) {
                    let item = NSMenuItem(title: "Show Only in This Workspace",
                                          action: #selector(showOnlyHere(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = url
                    menu.addItem(item)
                } else {
                    let item = NSMenuItem(title: "Show in All Workspaces",
                                          action: #selector(showEverywhere(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = url
                    menu.addItem(item)
                }
            }
            let item = NSMenuItem(title: "Remove from Sidebar",
                                  action: #selector(removeFavorite(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            menu.addItem(item)
        }
    }

    @objc private func showEverywhere(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        do { try AppDelegate.shared.workspaceManager.showFavoriteInAllWorkspaces(path: url.path) }
        catch { NSAlert(error: error).runModal() }
    }

    @objc private func showOnlyHere(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        do { try AppDelegate.shared.workspaceManager.showFavoriteOnly(
            in: windowWorkspaceID, path: url.path) }
        catch { NSAlert(error: error).runModal() }
    }

    @objc private func openInNewTab(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onOpenInNewTab?(url)
    }

    @objc private func showItemInfo(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        GetInfoPanelController.show(for: url)
    }

    @objc private func emptyTrash(_ sender: NSMenuItem) {
        // Read errors surface — a permission failure must never masquerade
        // as an empty trash.
        var items: [URL] = []
        for dir in Self.trashDirectories() {
            do {
                items += try FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil)
            } catch {
                NSAlert(error: error).runModal()
                return
            }
        }
        guard !items.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "The Trash is already empty."
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Empty the Trash?"
        alert.informativeText = items.count == 1
            ? "1 item will be permanently erased. This cannot be undone."
            : "\(items.count) items will be permanently erased. This cannot be undone."
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            for item in items {
                try FileManager.default.removeItem(at: item)
            }
        } catch { NSAlert(error: error).runModal() }
        rebuildEntries()  // trash icon back to empty
    }

    @objc private func copyPathname(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
    }

    @objc private func removeRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        do {
            if recentFolders.contains(url) {
                try AppDelegate.shared.workspaceManager.removeRecentFolder(
                    path: url.path, in: windowWorkspaceID)
            }
            if recentDocuments.contains(url) {
                try AppDelegate.shared.workspaceManager.removeRecentDocument(
                    path: url.path, in: windowWorkspaceID)
            }
        } catch { NSAlert(error: error).runModal() }
    }

    @objc private func removeFavorite(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        do { try AppDelegate.shared.workspaceManager.removeFavorite(
            path: url.path, in: windowWorkspaceID) }
        catch { NSAlert(error: error).runModal() }
    }
}
