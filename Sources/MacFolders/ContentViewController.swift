import AppKit

final class ContentViewController: NSViewController {
    private(set) var model: DirectoryModel
    private(set) var viewMode: ViewMode
    var onOpen: ((URL) -> Void)?
    var onOpenInNewTab: ((URL) -> Void)?
    /// The displayed directory itself was moved or deleted; the owner should
    /// navigate somewhere that still exists.
    var onDirectoryVanished: (() -> Void)?
    private(set) var currentDirectoryView: (any DirectoryView)?
    /// One controller per mode, kept alive so toggling views returns to
    /// exactly the prior state (selection, scroll, expansion, open columns).
    private var modeViewControllers: [ViewMode: any DirectoryView] = [:]

    init(url: URL, viewMode: ViewMode) {
        self.model = DirectoryModel(directoryURL: url)
        self.viewMode = viewMode
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 620))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        model.showHidden = Self.showHiddenFiles
        NotificationCenter.default.addObserver(
            self, selector: #selector(hiddenFilesSettingChanged(_:)),
            name: Self.hiddenFilesChanged, object: nil)
        installView(for: viewMode)
    }

    func show(url: URL) throws {
        let next = DirectoryModel(directoryURL: url)
        next.showHidden = model.showHidden
        next.sortKey = model.sortKey
        next.ascending = model.ascending
        try next.reload()
        model.stopWatching()
        model = next
        model.onDirectoryChanged = { [weak self] in self?.handleDirectoryChanged() }
        try model.startWatching()
        currentDirectoryView?.model = model
        currentDirectoryView?.modelDidChange()
    }

    func setViewMode(_ mode: ViewMode) {
        guard mode != viewMode else { return }
        viewMode = mode
        installView(for: mode)
    }

    private func handleDirectoryChanged() {
        do { try model.reload() } catch {
            if !FileManager.default.fileExists(atPath: model.directoryURL.path) {
                onDirectoryVanished?()
                return
            }
            NSAlert(error: error).runModal()
            return
        }
        currentDirectoryView?.modelDidChange()
    }

    private func installView(for mode: ViewMode) {
        currentDirectoryView?.view.removeFromSuperview()
        let next: any DirectoryView
        if let cached = modeViewControllers[mode] {
            next = cached
            // The model may have navigated or refreshed while this view was
            // hidden; hand it the current one and re-render.
            if cached.model !== model {
                cached.model = model
            }
            cached.modelDidChange()
        } else {
            switch mode {
            case .list:
                next = FileListViewController(model: model)
            case .icon:
                next = IconViewController(model: model)
            case .column:
                next = ColumnViewController(model: model)
            }
            next.onOpen = { [weak self] url in self?.onOpen?(url) }
            next.contextMenu = makeContextMenu()
            addChild(next)
            modeViewControllers[mode] = next
        }
        next.view.frame = view.bounds
        next.view.autoresizingMask = [.width, .height]
        view.addSubview(next.view)
        currentDirectoryView = next
    }

    // MARK: Context menu + file actions

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    private var actionTargets: [URL] {
        currentDirectoryView?.selectedURLs ?? []
    }

    /// The directory folder-level actions apply to — the clicked column in
    /// column view, the viewed directory elsewhere.
    private var actionDirectory: URL {
        currentDirectoryView?.activeDirectory ?? model.directoryURL
    }

    @objc func openSelected(_ sender: Any?) {
        for url in actionTargets { onOpen?(url) }
    }

    /// Toggle Finder-style pinning; pinning all when mixed, unpinning when
    /// every selected item is already pinned.
    @objc func toggleKeepDownloaded(_ sender: Any?) {
        let targets = actionTargets.filter(CloudFiles.isInICloud)
        let pinning = !targets.allSatisfy(CloudFiles.isPinned)
        do {
            for url in targets {
                try CloudFiles.setPinned(pinning, itemAt: url)
            }
        } catch { NSAlert(error: error).runModal() }
    }

    @objc func downloadFromCloud(_ sender: Any?) {
        do {
            for url in actionTargets where CloudFiles.needsDownload(url) {
                try CloudFiles.startDownload(itemAt: url)
            }
        } catch { NSAlert(error: error).runModal() }
    }

    /// Frees local space; the file stays in iCloud as a placeholder.
    @objc func removeDownload(_ sender: Any?) {
        do {
            for url in actionTargets where CloudFiles.isEvictable(url) {
                try CloudFiles.evict(itemAt: url)
            }
        } catch { NSAlert(error: error).runModal() }
    }

    @objc func openInNewTab(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onOpenInNewTab?(url)
    }

    /// Finder-parity Open With submenu: the common default app first and
    /// labeled, the rest alphabetical with versions disambiguating duplicate
    /// names, apps that can open EVERY selected item, and Other… at the end.
    func populateOpenWithMenu(_ submenu: NSMenu) {
        submenu.removeAllItems()
        let targets = actionTargets
        guard !targets.isEmpty else { return }
        let appSets = targets.map { Set(NSWorkspace.shared.urlsForApplications(toOpen: $0)) }
        var apps = Array(appSets.dropFirst().reduce(appSets[0]) { $0.intersection($1) })
        let defaults = Set(targets.compactMap { NSWorkspace.shared.urlForApplication(toOpen: $0) })
        let commonDefault = defaults.count == 1 ? defaults.first : nil
        apps.removeAll { $0 == commonDefault }
        let names = Dictionary(grouping: apps) { app in
            let name = FileManager.default.displayName(atPath: app.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        func title(for app: URL) -> String {
            var name = FileManager.default.displayName(atPath: app.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            guard names[name]?.count ?? 0 > 1,
                  let version = Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"]
                    as? String else { return name }
            return "\(name) (\(version))"
        }
        func addApp(_ app: URL, suffix: String = "") {
            let item = NSMenuItem(title: title(for: app) + suffix,
                                  action: #selector(openWithApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            submenu.addItem(item)
        }
        if let commonDefault {
            addApp(commonDefault, suffix: " (default)")
            submenu.addItem(.separator())
        }
        for app in apps.sorted(by: {
            title(for: $0).localizedStandardCompare(title(for: $1)) == .orderedAscending
        }) {
            addApp(app)
        }
        submenu.addItem(.separator())
        let other = NSMenuItem(title: "Other…",
                               action: #selector(openWithOther(_:)), keyEquivalent: "")
        other.target = self
        submenu.addItem(other)
    }

    /// Any-app picker with Finder's "Always Open With" option (a per-file
    /// LaunchServices binding, not a type-wide default).
    @objc func openWithOther(_ sender: Any?) {
        let targets = actionTargets
        guard !targets.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        let always = NSButton(checkboxWithTitle: "Always Open With", target: nil, action: nil)
        panel.accessoryView = always
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let appURL = panel.url else { return }
        if always.state == .on {
            Task { @MainActor in
                do {
                    for url in targets {
                        try await NSWorkspace.shared.setDefaultApplication(
                            at: appURL, toOpenFileAt: url)
                    }
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        }
        openTargets(targets, withApplicationAt: appURL)
    }

    @objc func openWithApp(_ sender: NSMenuItem) {
        guard let appURL = sender.representedObject as? URL else { return }
        openTargets(actionTargets, withApplicationAt: appURL)
    }

    private func openTargets(_ targets: [URL], withApplicationAt appURL: URL) {
        NSWorkspace.shared.open(targets, withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            DispatchQueue.main.async {
                if let error {
                    NSAlert(error: error).runModal()
                    return
                }
                for url in targets
                where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true {
                    AppDelegate.shared.noteRecentDocument(
                        url, workspaceID: AppDelegate.shared.workspaceID(for: self.view.window))
                }
            }
        }
    }

    @objc func renameSelected(_ sender: Any?) {
        guard let url = actionTargets.first else { return }
        let alert = NSAlert()
        alert.messageText = "Rename “\(url.lastPathComponent)”"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = url.lastPathComponent
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = field.stringValue
        guard !newName.isEmpty, newName != url.lastPathComponent else { return }
        do { try FileOperations.rename(url, to: newName) }
        catch { NSAlert(error: error).runModal() }
    }

    @objc func duplicateSelected(_ sender: Any?) {
        do { for url in actionTargets { try FileOperations.duplicate(url) } }
        catch { NSAlert(error: error).runModal() }
    }

    @objc func trashSelected(_ sender: Any?) {
        do { try FileOperations.trash(actionTargets) }
        catch { NSAlert(error: error).runModal() }
    }

    /// Cut marks these URLs for a MOVE on the next paste (Finder lacks this).
    /// Invalidated automatically when anything else lands on the pasteboard.
    private static var pendingCut: (urls: [URL], changeCount: Int)?

    /// POSIX path(s) of the selection — or the folder itself when nothing
    /// is selected — one per line.
    @objc func copyPathname(_ sender: Any?) {
        let urls = actionTargets.isEmpty ? [actionDirectory] : actionTargets
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"),
                             forType: .string)
    }

    @objc func copy(_ sender: Any?) {
        let urls = actionTargets
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        Self.pendingCut = nil
    }

    @objc func cut(_ sender: Any?) {
        let urls = actionTargets
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        Self.pendingCut = (urls, pasteboard.changeCount)
    }

    @objc func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        guard let urls = pasteboard.readObjects(
            forClasses: [NSURL.self]) as? [URL], !urls.isEmpty else { return }
        do {
            let destination = actionDirectory
            if let cut = Self.pendingCut, cut.changeCount == pasteboard.changeCount {
                // Items already here are a no-op, like Finder.
                let moving = cut.urls.filter {
                    $0.deletingLastPathComponent() != destination
                }
                try FileOperations.move(moving, to: destination)
                Self.pendingCut = nil
            } else {
                try FileOperations.copy(urls, to: destination)
            }
        } catch { NSAlert(error: error).runModal() }
    }

    @objc func newFolder(_ sender: Any?) {
        do { try FileOperations.newFolder(in: actionDirectory) }
        catch { NSAlert(error: error).runModal() }
    }

    @objc func revealInFinder(_ sender: Any?) {
        let urls = actionTargets.isEmpty ? [actionDirectory] : actionTargets
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc func showItemInfo(_ sender: Any?) {
        // No selection: info for the folder being viewed, like Finder.
        let urls = actionTargets.isEmpty ? [actionDirectory] : actionTargets
        for url in urls.prefix(10) {
            GetInfoPanelController.show(for: url)
        }
    }

    @objc func addToSidebar(_ sender: Any?) {
        guard let url = actionTargets.first else { return }
        do { try AppDelegate.shared.workspaceManager.addFavorite(
            path: url.path, in: AppDelegate.shared.workspaceID(for: view.window)) }
        catch { NSAlert(error: error).runModal() }
    }

    static let hiddenFilesChanged = Notification.Name("HiddenFilesChanged")
    static var showHiddenFiles: Bool {
        UserDefaults.standard.bool(forKey: "showHiddenFiles")
    }

    @objc private func hiddenFilesSettingChanged(_ note: Notification) {
        applyHiddenFilesSetting()
    }

    private func applyHiddenFilesSetting() {
        guard model.showHidden != Self.showHiddenFiles else { return }
        model.showHidden = Self.showHiddenFiles
        do { try model.reload() } catch {
            NSAlert(error: error).runModal()
            return
        }
        currentDirectoryView?.modelDidChange()
    }
}

extension ContentViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let selection = actionTargets
        if !selection.isEmpty {
            menu.addItem(withTitle: "Open",
                         action: #selector(openSelected(_:)), keyEquivalent: "").target = self
            if selection.count == 1, let url = selection.first,
               (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let newTab = NSMenuItem(title: "Open in New Tab",
                                        action: #selector(openInNewTab(_:)), keyEquivalent: "")
                newTab.target = self
                newTab.representedObject = url
                menu.addItem(newTab)
            }

            let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            populateOpenWithMenu(submenu)
            openWith.submenu = submenu
            openWith.isEnabled = !selection.isEmpty
            menu.addItem(openWith)
            menu.addItem(.separator())
            if selection.contains(where: CloudFiles.isInICloud) {
                let keep = NSMenuItem(title: "Keep Downloaded",
                                      action: #selector(toggleKeepDownloaded(_:)),
                                      keyEquivalent: "")
                keep.target = self
                keep.state = selection.allSatisfy(CloudFiles.isPinned) ? .on : .off
                menu.addItem(keep)
            }
            if selection.contains(where: CloudFiles.needsDownload) {
                menu.addItem(withTitle: "Download Now",
                             action: #selector(downloadFromCloud(_:)),
                             keyEquivalent: "").target = self
            } else if selection.contains(where: CloudFiles.isEvictable) {
                menu.addItem(withTitle: "Remove Download",
                             action: #selector(removeDownload(_:)),
                             keyEquivalent: "").target = self
            }
            menu.addItem(withTitle: "Get Info",
                         action: #selector(showItemInfo(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Rename…",
                         action: #selector(renameSelected(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Duplicate",
                         action: #selector(duplicateSelected(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Move to Trash",
                         action: #selector(trashSelected(_:)), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Cut",
                         action: #selector(cut(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Copy",
                         action: #selector(copy(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Copy Pathname",
                         action: #selector(copyPathname(_:)), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Paste",
                     action: #selector(paste(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "New Folder",
                     action: #selector(newFolder(_:)), keyEquivalent: "").target = self
        if selection.isEmpty {
            menu.addItem(withTitle: "Copy Pathname",
                         action: #selector(copyPathname(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Get Info",
                         action: #selector(showItemInfo(_:)), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reveal in Finder",
                     action: #selector(revealInFinder(_:)), keyEquivalent: "").target = self
        if selection.count == 1,
           (try? selection[0].resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            menu.addItem(.separator())
            let item = NSMenuItem(title: "Add to Sidebar",
                                  action: #selector(addToSidebar(_:)), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
    }
}
