import AppKit

/// Translates between live NSWindows and [WindowState], per workspace.
/// No persistence here.
final class WindowSession {
    /// True while programmatically opening/closing windows, so close/change
    /// events during a restore don't get captured as user actions.
    private(set) var isRestoring = false

    private func controllers(for workspaceID: UUID) -> [BrowserWindowController] {
        AppDelegate.shared.controllers.filter { $0.workspaceID == workspaceID }
    }

    /// Workspaces that currently have windows, in controller creation order.
    func openWorkspaceIDs() -> [UUID] {
        var seen: [UUID] = []
        for controller in AppDelegate.shared.controllers
        where !seen.contains(controller.workspaceID) {
            seen.append(controller.workspaceID)
        }
        return seen
    }

    func snapshot(for workspaceID: UUID) -> [WindowState] {
        var seenGroups: [NSWindowTabGroup] = []
        var result: [WindowState] = []
        for window in NSApp.windows {
            guard let controller = window.windowController as? BrowserWindowController,
                  controller.workspaceID == workspaceID else { continue }
            if let group = window.tabGroup {
                guard !seenGroups.contains(where: { $0 === group }) else { continue }
                seenGroups.append(group)
                let tabControllers = group.windows.compactMap {
                    $0.windowController as? BrowserWindowController
                }
                let tabs = tabControllers.map {
                    TabState(path: $0.currentURL.path, viewMode: $0.contentVC.viewMode,
                             sidebarWidth: $0.sidebarWidth,
                             expandedPaths: $0.contentVC.persistedExpandedPaths,
                             scrollOffset: $0.contentVC.persistedScrollOffset)
                }
                let selected = group.windows.firstIndex { $0 === group.selectedWindow } ?? 0
                result.append(WindowState(frame: group.windows[0].frame,
                                          tabs: tabs, selectedTab: selected))
            } else {
                result.append(WindowState(
                    frame: window.frame,
                    tabs: [TabState(path: controller.currentURL.path,
                                    viewMode: controller.contentVC.viewMode,
                                    sidebarWidth: controller.sidebarWidth,
                                    expandedPaths: controller.contentVC.persistedExpandedPaths,
                                    scrollOffset: controller.contentVC.persistedScrollOffset)],
                    selectedTab: 0))
            }
        }
        return result
    }

    func closeAll(workspaceID: UUID) {
        isRestoring = true
        defer { isRestoring = false }
        for controller in controllers(for: workspaceID) {
            controller.window?.close()
        }
    }

    /// Bring an already-open workspace's windows forward. False if none.
    /// Fronts one window per tab GROUP — ordering front a non-selected tab
    /// would switch the group's selection to it.
    func bringToFront(workspaceID: UUID) -> Bool {
        let list = controllers(for: workspaceID)
        guard !list.isEmpty else { return false }
        var seenGroups: [NSWindowTabGroup] = []
        var frontTargets: [NSWindow] = []
        for controller in list {
            guard let window = controller.window else { continue }
            if let group = window.tabGroup {
                guard !seenGroups.contains(where: { $0 === group }) else { continue }
                seenGroups.append(group)
                frontTargets.append(group.selectedWindow ?? window)
            } else {
                frontTargets.append(window)
            }
        }
        for window in frontTargets {
            window.orderFront(nil)
        }
        frontTargets.first?.makeKeyAndOrderFront(nil)
        return true
    }

    func open(_ states: [WindowState], workspaceID: UUID) {
        isRestoring = true
        defer { isRestoring = false }
        for windowState in states {
            var anchor: BrowserWindowController?
            for tab in windowState.tabs {
                let url = URL(fileURLWithPath: tab.path)
                let controller = BrowserWindowController(url: url, viewMode: tab.viewMode,
                                                         workspaceID: workspaceID)
                AppDelegate.shared.register(controller)
                if let anchor {
                    // Called on the previously added tab each iteration so tabs
                    // restore in saved order.
                    anchor.window?.addTabbedWindow(controller.window!, ordered: .above)
                    controller.window?.orderFront(nil)
                } else {
                    controller.window?.setFrame(windowState.frame, display: false)
                    // Anchor windows are standalone; don't auto-tab them into
                    // whatever group happens to be key.
                    controller.window?.tabbingMode = .disallowed
                    controller.showWindow(nil)
                    controller.window?.tabbingMode = .preferred
                }
                controller.navigate(to: url, recordHistory: false)
                if let width = tab.sidebarWidth {
                    controller.applySidebarWidth(width)
                }
                controller.contentVC.restorePersistedViewState(
                    expandedPaths: tab.expandedPaths, scrollOffset: tab.scrollOffset)
                anchor = controller
            }
            if let group = anchor?.window?.tabGroup,
               windowState.tabs.count == group.windows.count,
               group.windows.indices.contains(windowState.selectedTab) {
                group.selectedWindow = group.windows[windowState.selectedTab]
            }
            // Without an explicit key window after restore, the responder
            // chain is empty and nil-target menu actions silently no-op.
            (anchor?.window?.tabGroup?.selectedWindow ?? anchor?.window)?
                .makeKeyAndOrderFront(nil)
            anchor?.ensureTabBarVisible()
        }
        if states.isEmpty {
            // Explicit default: an empty workspace opens one window on Home.
            AppDelegate.shared.openBrowserWindow(
                at: FileManager.default.homeDirectoryForCurrentUser,
                workspaceID: workspaceID)
        }
    }
}
