import AppKit

extension NSToolbarItem.Identifier {
    static let navigation = NSToolbarItem.Identifier("Navigation")
    static let pathMenu = NSToolbarItem.Identifier("PathMenu")
    static let viewMode = NSToolbarItem.Identifier("ViewMode")
}

final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    private(set) var workspaceID: UUID
    /// The tab group this window was last seen in; a mismatch means the user
    /// dragged this tab into another group (see reconcileTabGroupWorkspaces).
    var lastTabGroupID: ObjectIdentifier?
    let contentVC: ContentViewController
    let sidebarVC = SidebarViewController()
    private let splitVC: NSSplitViewController
    private(set) var currentURL: URL
    private var backHistory: [URL] = []
    private var forwardHistory: [URL] = []
    private var viewModeControl: NSSegmentedControl?
    private let pathMenu = NSMenu()

    init(url: URL, viewMode: ViewMode, workspaceID: UUID) {
        self.workspaceID = workspaceID
        currentURL = url
        contentVC = ContentViewController(url: url, viewMode: viewMode)

        let split = NSSplitViewController()
        splitVC = split
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 140
        sidebarItem.maximumThickness = 300
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: contentVC))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = split
        window.tabbingMode = .preferred
        // One global identifier so tabs can be dragged between ANY windows,
        // including across workspaces; workspace membership is reconciled
        // after drags instead of being enforced by the group.
        window.tabbingIdentifier = "MacFoldersBrowser"
        window.toolbarStyle = .unified
        super.init(window: window)

        window.delegate = self
        setupToolbar()
        NotificationCenter.default.addObserver(
            self, selector: #selector(splitDidResize(_:)),
            name: NSSplitView.didResizeSubviewsNotification, object: split.splitView)
        sidebarVC.onSelect = { [weak self] url in self?.open(url) }
        sidebarVC.onOpenInNewTab = { [weak self] url in self?.openNewTab(at: url) }
        contentVC.onOpen = { [weak self] url in self?.open(url) }
        contentVC.onOpenInNewTab = { [weak self] url in self?.openNewTab(at: url) }
        contentVC.onDirectoryVanished = { [weak self] in
            guard let self else { return }
            // Land on the closest surviving ancestor, like Finder.
            self.navigate(to: PathRecovery.nearestExistingAncestor(of: self.currentURL),
                          recordHistory: false)
        }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Navigation

    func navigate(to url: URL, recordHistory: Bool = true) {
        // Stale destinations (dead recents, restored tabs whose folder moved)
        // resolve to the nearest surviving ancestor instead of erroring.
        let url = FileManager.default.fileExists(atPath: url.path)
            ? url : PathRecovery.nearestExistingAncestor(of: url)
        do {
            try contentVC.show(url: url)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        if recordHistory, url != currentURL {
            backHistory.append(currentURL)
            forwardHistory.removeAll()
        }
        currentURL = url
        updateTitle()
        if recordHistory {
            AppDelegate.shared.noteRecentFolder(url, workspaceID: workspaceID)
        }
        AppDelegate.shared.noteWindowStateChanged()
    }

    func open(_ url: URL) {
        // Follow symlinks so a link to a folder navigates in-app (like Finder)
        // instead of handing off to the system.
        let resolved = url.resolvingSymlinksInPath()
        let isDirectory = (try? resolved.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if isDirectory {
            // Cmd+double-click (or Cmd+click in the sidebar): new tab, like Finder.
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                openNewTab(at: resolved)
                return
            }
            navigate(to: resolved)
        } else {
            NSWorkspace.shared.open(url)
            AppDelegate.shared.noteRecentDocument(url, workspaceID: workspaceID)
        }
    }

    @objc func goBack(_ sender: Any?) {
        guard let previous = backHistory.popLast() else { return }
        forwardHistory.append(currentURL)
        currentURL = previous
        navigate(to: previous, recordHistory: false)
    }

    @objc func goForward(_ sender: Any?) {
        guard let next = forwardHistory.popLast() else { return }
        backHistory.append(currentURL)
        currentURL = next
        navigate(to: next, recordHistory: false)
    }

    @objc func goToEnclosingFolder(_ sender: Any?) {
        let parent = currentURL.deletingLastPathComponent()
        guard parent.path != currentURL.path else { return }
        navigate(to: parent)
    }

    private func updateTitle() {
        let folder = currentURL.lastPathComponent.isEmpty
            ? currentURL.path : currentURL.lastPathComponent
        // Title bar: "workspace — folder" so the Dock's window list
        // disambiguates. Tab label: just the folder — the workspace prefix is
        // redundant inside one group's tab bar.
        let workspaceName = AppDelegate.shared.workspaceManager?
            .workspace(id: workspaceID)?.name
        window?.title = workspaceName.map { "\($0) — \(folder)" } ?? folder
        window?.tab.title = folder
        window?.representedURL = currentURL
    }

    // MARK: Tabs

    @objc override func newWindowForTab(_ sender: Any?) {
        openNewTab(at: currentURL)
    }

    func openNewTab(at url: URL) {
        let controller = BrowserWindowController(url: url, viewMode: contentVC.viewMode,
                                                 workspaceID: workspaceID)
        AppDelegate.shared.register(controller)
        window?.addTabbedWindow(controller.window!, ordered: .above)
        controller.navigate(to: url, recordHistory: false)
        controller.window?.makeKeyAndOrderFront(nil)
        AppDelegate.shared.noteWindowStateChanged()
    }

    /// A tab dragged into another workspace's window joins that workspace:
    /// retitle, and the caller refreshes the sidebar + persists.
    func adopt(workspaceID newID: UUID) {
        guard newID != workspaceID else { return }
        workspaceID = newID
        updateTitle()
    }

    /// Single-tab windows hide the tab bar by default, which makes tabs feel
    /// absent; keep it visible so Cmd+T and drag targets are discoverable.
    func ensureTabBarVisible() {
        guard let window, let group = window.tabGroup,
              !group.isTabBarVisible else { return }
        window.toggleTabBar(nil)
    }

    func windowWillClose(_ notification: Notification) {
        contentVC.model.stopWatching()
        AppDelegate.shared.unregister(self)
    }

    func windowDidMove(_ notification: Notification) {
        AppDelegate.shared.noteWindowStateChanged()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        AppDelegate.shared.noteWindowStateChanged()
    }

    // MARK: Sidebar width (part of workspace state)

    var sidebarWidth: CGFloat {
        // The first arranged split pane (the sidebar's container) — the same
        // coordinate setPosition(_:ofDividerAt:) uses, so capture/restore
        // round-trips exactly. (`subviews` is layering order, not arrangement;
        // the VC's view is inset inside the pane's effect wrapper.)
        splitVC.splitView.arrangedSubviews.first?.frame.width ?? sidebarVC.view.frame.width
    }

    func applySidebarWidth(_ width: CGFloat) {
        splitVC.splitView.setPosition(width, ofDividerAt: 0)
    }

    @objc private func splitDidResize(_ notification: Notification) {
        AppDelegate.shared.noteWindowStateChanged()
    }

    // MARK: Toolbar

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: "BrowserToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }

    @objc private func navigationClicked(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { goBack(sender) } else { goForward(sender) }
    }

    @objc private func viewModeClicked(_ sender: NSSegmentedControl) {
        let modes: [ViewMode] = [.icon, .list, .column]
        contentVC.setViewMode(modes[sender.selectedSegment])
        AppDelegate.shared.noteWindowStateChanged()
    }

    func selectViewModeControl(_ mode: ViewMode) {
        let index = [ViewMode.icon, .list, .column].firstIndex(of: mode) ?? 1
        viewModeControl?.selectedSegment = index
    }

    @objc func viewAsIcons(_ sender: Any?) {
        contentVC.setViewMode(.icon)
        selectViewModeControl(.icon)
        AppDelegate.shared.noteWindowStateChanged()
    }

    @objc func viewAsList(_ sender: Any?) {
        contentVC.setViewMode(.list)
        selectViewModeControl(.list)
        AppDelegate.shared.noteWindowStateChanged()
    }

    @objc func viewAsColumns(_ sender: Any?) {
        contentVC.setViewMode(.column)
        selectViewModeControl(.column)
        AppDelegate.shared.noteWindowStateChanged()
    }

    @objc func goToFolder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        navigate(to: URL(fileURLWithPath: path))
    }

}

extension BrowserWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.navigation, .flexibleSpace, .pathMenu, .viewMode]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .navigation:
            let control = NSSegmentedControl(
                images: [NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!,
                         NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")!],
                trackingMode: .momentary, target: self, action: #selector(navigationClicked(_:)))
            control.segmentStyle = .separated
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = control
            item.label = "Back/Forward"
            return item
        case .pathMenu:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "folder",
                                 accessibilityDescription: "Path")
            item.label = "Path"
            item.toolTip = "Current folder hierarchy"
            pathMenu.delegate = self
            item.menu = pathMenu
            return item
        case .viewMode:
            let control = NSSegmentedControl(
                images: [NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Icons")!,
                         NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "List")!,
                         NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "Columns")!],
                trackingMode: .selectOne, target: self, action: #selector(viewModeClicked(_:)))
            control.selectedSegment = [ViewMode.icon, .list, .column]
                .firstIndex(of: contentVC.viewMode) ?? 1
            viewModeControl = control
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = control
            item.label = "View"
            return item
        default:
            return nil
        }
    }
}

extension BrowserWindowController: NSMenuDelegate {
    /// The Path toolbar dropdown: current folder first, then every ancestor
    /// up to the volume root — pick one to walk up the tree, like Finder.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === pathMenu else { return }
        menu.removeAllItems()
        // NSMenuToolbarItem swallows the menu's first item; feed it a blank.
        menu.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))
        var url = currentURL
        while true {
            let title = FileManager.default.displayName(atPath: url.path)
            let item = NSMenuItem(title: title.isEmpty ? url.path : title,
                                  action: #selector(pathMenuItemSelected(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = url
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
            if url.path == "/" { break }
            url = url.deletingLastPathComponent()
        }
    }

    @objc private func pathMenuItemSelected(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL,
              url != currentURL else { return }
        navigate(to: url)
    }
}
