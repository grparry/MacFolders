import AppKit

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

    /// The workspace of the window this sidebar lives in.
    private var windowWorkspaceID: UUID {
        AppDelegate.shared.workspaceID(for: view.window)
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
        entries = [.group("Favorites")] + favorites.map(Entry.location)
        if !recentFolders.isEmpty {
            entries += [.group("Recent Folders")] + recentFolders.map(Entry.location)
        }
        if !recentDocuments.isEmpty {
            entries += [.group("Recent Documents")] + recentDocuments.map(Entry.location)
        }
        entries += [.group("Locations")] + volumes.map(Entry.location)
        outlineView.reloadData()
    }

    @objc private func rowClicked() {
        let row = outlineView.clickedRow
        guard entries.indices.contains(row),
              case .location(let url) = entries[row] else { return }
        onSelect?(url)
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

    /// Root children: row 0 is the "Favorites" group header, favorites follow.
    /// Clamp any proposed drop into that range. A drop ON the header means
    /// "front"; ON a favorite row means "right after it"; elsewhere, append.
    private func clampedDropIndex(_ proposed: Int, item: Any?) -> Int {
        if proposed < 0 {
            if let index = item as? Int {
                if index == 0 { return 1 }
                if (1...favorites.count).contains(index) { return index + 1 }
            }
            return favorites.count + 1
        }
        return min(max(proposed, 1), favorites.count + 1)
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
                    path: path, toIndex: clampedDropIndex(index, item: item) - 1,
                    in: windowWorkspaceID)
                return true
            } catch {
                NSAlert(error: error).runModal()
                return false
            }
        }
        let folders = droppableFolders(from: info)
        guard !folders.isEmpty else { return false }
        let favoritesIndex = clampedDropIndex(index, item: item) - 1
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
            let values = try? url.resourceValues(forKeys: [.isVolumeKey, .volumeNameKey])
            let name = (values?.isVolume == true ? values?.volumeName : nil)
                ?? url.lastPathComponent
            let text = NSTextField(labelWithString: name.isEmpty ? url.path : name)
            text.lineBreakMode = .byTruncatingMiddle
            let image = NSImageView()
            let icon = NSWorkspace.shared.icon(forFile: url.path)
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

    @objc private func removeFavorite(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        do { try AppDelegate.shared.workspaceManager.removeFavorite(
            path: url.path, in: windowWorkspaceID) }
        catch { NSAlert(error: error).runModal() }
    }
}
