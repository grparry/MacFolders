import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate!
    private(set) var controllers: [BrowserWindowController] = []
    private(set) var workspaceManager: WorkspaceManager!
    let session = WindowSession()
    private var workspacesMenuController: WorkspacesMenuController!
    private var pendingAutosave: DispatchWorkItem?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests host this app; don't spawn UI during test runs.
        guard NSClassFromString("XCTestCase") == nil else { return }
        do {
            workspaceManager = try WorkspaceManager(
                store: WorkspaceStore(fileURL: WorkspaceStore.defaultURL()))
        } catch {
            // Corrupt state file: surface it, ask before starting fresh. Never silent-reset.
            let alert = NSAlert()
            alert.messageText = "MacFolders could not read its saved workspaces."
            alert.informativeText =
                "\(WorkspaceStore.defaultURL().path)\n\n\(error.localizedDescription)"
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Start Fresh (discards saved workspaces)")
            if alert.runModal() == .alertFirstButtonReturn {
                NSApp.terminate(nil)
                return
            }
            try? FileManager.default.removeItem(at: WorkspaceStore.defaultURL())
            workspaceManager = try! WorkspaceManager(
                store: WorkspaceStore(fileURL: WorkspaceStore.defaultURL()))
        }
        workspaceManager.authoritativeWorkspaceIDs = { [weak self] in
            self?.session.openWorkspaceIDs()
                ?? [self?.workspaceManager.state.activeWorkspaceID].compactMap { $0 }
        }
        workspacesMenuController = WorkspacesMenuController(manager: workspaceManager)
        NSApp.mainMenu = MainMenu.build(workspacesMenu: workspacesMenuController.menu)
        workspaceManager.onStateChanged = { [weak self] in self?.refreshSidebars() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowBecameKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil)

        // Restore every workspace that was open, keying the last-active one.
        let state = workspaceManager.state
        let known = state.openWorkspaceIDs.filter { id in
            state.workspaces.contains { $0.id == id }
        }
        let toOpen = known.isEmpty ? [state.activeWorkspaceID] : known
        for id in toOpen {
            session.open(workspaceManager.workspace(id: id)?.live ?? [], workspaceID: id)
        }
        _ = session.bringToFront(workspaceID: state.activeWorkspaceID)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        pendingAutosave?.cancel()
        persistLiveStateNow()
    }

    // MARK: Current workspace (the key window's)

    var currentWorkspaceID: UUID {
        (NSApp.keyWindow?.windowController as? BrowserWindowController)?.workspaceID
            ?? workspaceManager.state.activeWorkspaceID
    }

    func workspaceID(for window: NSWindow?) -> UUID {
        (window?.windowController as? BrowserWindowController)?.workspaceID
            ?? currentWorkspaceID
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        guard let controller = (notification.object as? NSWindow)?.windowController
                as? BrowserWindowController else { return }
        // The tab bar is always visible — no hide-on-single-tab complexity.
        controller.ensureTabBarVisible()
        reconcileTabGroupWorkspaces()
        noteWindowStateChanged()   // persists the new active workspace
    }

    /// After a tab is dragged between windows, its group contains mixed
    /// workspaces. The members that were already in the group define the
    /// host workspace; migrants adopt it. A tab torn out into its own window
    /// keeps its workspace.
    private var isReconciling = false

    private func reconcileTabGroupWorkspaces() {
        guard !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }
        var groups: [ObjectIdentifier: [BrowserWindowController]] = [:]
        for controller in controllers {
            guard let group = controller.window?.tabGroup else { continue }
            groups[ObjectIdentifier(group), default: []].append(controller)
        }
        var vacatedWorkspaceIDs: Set<UUID> = []
        for (groupID, members) in groups {
            let stayed = members.filter {
                $0.lastTabGroupID == groupID || $0.lastTabGroupID == nil
            }
            if let host = stayed.first {
                for member in members where member.workspaceID != host.workspaceID {
                    vacatedWorkspaceIDs.insert(member.workspaceID)
                    member.adopt(workspaceID: host.workspaceID)
                    applySidebarState(to: member)
                }
            } else if members.count == 1, let migrant = members.first,
                      let originID = migrant.lastTabGroupID,
                      let originHost = controllers.first(where: {
                          $0 !== migrant && $0.window?.tabGroup
                              .map(ObjectIdentifier.init) == originID
                      }) {
                // Torn out of a live group into a standalone window: that's
                // a new auto-named workspace (rename any time).
                _ = originHost  // origin confirmed alive = real tear-out
                vacatedWorkspaceIDs.insert(migrant.workspaceID)
                do {
                    try workspaceManager.addWorkspace(name: "Workspace")
                    if let id = workspaceManager.state.workspaces.last?.id {
                        migrant.adopt(workspaceID: id)
                        applySidebarState(to: migrant)
                    }
                } catch { NSAlert(error: error).runModal() }
            }
        }
        for controller in controllers {
            controller.lastTabGroupID = controller.window?.tabGroup
                .map(ObjectIdentifier.init)
        }
        // Dragging a workspace's LAST tab away deletes the workspace.
        // (Merely closing tabs never does — only drag-out.)
        for id in vacatedWorkspaceIDs
        where !controllers.contains(where: { $0.workspaceID == id }) {
            do {
                _ = try workspaceManager.deleteWorkspace(id: id)
            } catch WorkspaceManager.WorkspaceError.cannotDeleteLastWorkspace {
                // The sole remaining workspace stays even if emptied.
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    // MARK: Live-state autosave (debounced 1s)

    func noteWindowStateChanged() {
        guard workspaceManager != nil, !session.isRestoring else { return }
        pendingAutosave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistLiveStateNow() }
        pendingAutosave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func persistLiveStateNow() {
        guard workspaceManager != nil else { return }
        reconcileTabGroupWorkspaces()
        let openIDs = session.openWorkspaceIDs()
        var captures: [UUID: [WindowState]] = [:]
        for id in openIDs {
            let windows = session.snapshot(for: id)
            // A workspace whose last window was closed keeps its stored live
            // state, so relaunching it later restores something useful.
            if !windows.isEmpty { captures[id] = windows }
        }
        do {
            try workspaceManager.syncOpenState(captures: captures,
                                               activeID: currentWorkspaceID,
                                               openIDs: openIDs)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: Workspace launching (menu bar, dock — never repurposes windows)

    func openWorkspace(_ id: UUID) {
        guard let workspace = workspaceManager.workspace(id: id) else { return }
        if session.bringToFront(workspaceID: id) {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        session.open(workspace.live, workspaceID: id)
        NSApp.activate(ignoringOtherApps: true)
        noteWindowStateChanged()
    }

    func closeWorkspaceWindows(_ id: UUID) {
        session.closeAll(workspaceID: id)
        noteWindowStateChanged()
    }

    func performRevertToSaved(of id: UUID) {
        pendingAutosave?.cancel()
        do {
            let toOpen = try workspaceManager.revertToSaved(of: id)
            session.closeAll(workspaceID: id)
            session.open(toOpen, workspaceID: id)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: Dock menu (workspace launcher; macOS adds the window switcher)

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        guard workspaceManager != nil else { return menu }
        // Pick up other instances' workspaces; errors here just mean the list
        // may be a moment stale — no alert from a dock right-click.
        try? workspaceManager.refreshFromDisk()
        for workspace in workspaceManager.state.workspaces {
            let item = NSMenuItem(title: workspace.name,
                                  action: #selector(dockOpenWorkspace(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = workspace.id
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let newWindowItem = NSMenuItem(title: "New Window",
                                       action: #selector(newWindow(_:)), keyEquivalent: "")
        newWindowItem.target = self
        menu.addItem(newWindowItem)
        return menu
    }

    @objc private func dockOpenWorkspace(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        openWorkspace(id)
    }

    // MARK: Windows

    @discardableResult
    func openBrowserWindow(at url: URL, viewMode: ViewMode = .list,
                           workspaceID: UUID) -> BrowserWindowController {
        let controller = BrowserWindowController(url: url, viewMode: viewMode,
                                                 workspaceID: workspaceID)
        register(controller)
        controller.window?.center()
        // Standalone by intent: don't let macOS auto-tab it into the key
        // window's group (identifier is global now).
        controller.window?.tabbingMode = .disallowed
        controller.showWindow(nil)
        controller.window?.tabbingMode = .preferred
        controller.navigate(to: url, recordHistory: false)
        controller.ensureTabBarVisible()
        return controller
    }

    func register(_ controller: BrowserWindowController) {
        controllers.append(controller)
        if workspaceManager != nil {
            applySidebarState(to: controller)
        }
    }

    func unregister(_ controller: BrowserWindowController) {
        controllers.removeAll { $0 === controller }
        noteWindowStateChanged()
    }

    private func applySidebarState(to controller: BrowserWindowController) {
        guard let workspace = workspaceManager.workspace(id: controller.workspaceID)
        else { return }
        controller.sidebarVC.favorites = workspace.favorites.map(URL.init(fileURLWithPath:))
        controller.sidebarVC.recentFolders = workspace.recentFolders.map(URL.init(fileURLWithPath:))
        controller.sidebarVC.recentDocuments = workspace.recentDocuments.map(URL.init(fileURLWithPath:))
    }

    private func refreshSidebars() {
        for controller in controllers {
            applySidebarState(to: controller)
        }
    }

    // MARK: Recents

    func noteRecentFolder(_ url: URL, workspaceID: UUID) {
        guard workspaceManager != nil, !session.isRestoring else { return }
        do { try workspaceManager.noteRecentFolder(path: url.path, in: workspaceID) }
        catch { NSAlert(error: error).runModal() }
    }

    func noteRecentDocument(_ url: URL, workspaceID: UUID) {
        guard workspaceManager != nil, !session.isRestoring else { return }
        do { try workspaceManager.noteRecentDocument(path: url.path, in: workspaceID) }
        catch { NSAlert(error: error).runModal() }
    }

    /// File > Get Info (explicit target — reliable from any focus state).
    @objc func showItemInfo(_ sender: Any?) {
        let controller = (NSApp.keyWindow ?? NSApp.mainWindow)?.windowController
            as? BrowserWindowController ?? controllers.first
        controller?.contentVC.showItemInfo(sender)
    }

    /// Window = workspace: a new window IS a new workspace (auto-named,
    /// rename any time). Cmd+T adds tabs within the current one.
    @objc func newWindow(_ sender: Any?) {
        do {
            try workspaceManager.addWorkspace(name: "Workspace")
            guard let id = workspaceManager.state.workspaces.last?.id else { return }
            openBrowserWindow(at: FileManager.default.homeDirectoryForCurrentUser,
                              workspaceID: id)
            noteWindowStateChanged()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
