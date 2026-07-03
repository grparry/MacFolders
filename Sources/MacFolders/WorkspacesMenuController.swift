import AppKit

final class WorkspacesMenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu(title: "Workspaces")
    private let manager: WorkspaceManager

    init(manager: WorkspaceManager) {
        self.manager = manager
        super.init()
        menu.delegate = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Adopt workspaces created/renamed by other running instances.
        do { try manager.refreshFromDisk() } catch { NSAlert(error: error).runModal() }
        menu.removeAllItems()
        let currentID = AppDelegate.shared.currentWorkspaceID
        for (index, workspace) in manager.state.workspaces.enumerated() {
            let item = NSMenuItem(title: workspace.name,
                                  action: #selector(openWorkspace(_:)),
                                  keyEquivalent: index < 9 ? "\(index + 1)" : "")
            item.keyEquivalentModifierMask = [.command, .control]
            item.target = self
            item.representedObject = workspace.id
            item.state = workspace.id == currentID ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        addItem(to: menu, title: "New Workspace…", action: #selector(newWorkspace(_:)))
        addItem(to: menu, title: "Rename Workspace…", action: #selector(renameWorkspace(_:)))
        addItem(to: menu, title: "Close Workspace", action: #selector(closeWorkspace(_:)))
        addItem(to: menu, title: "Delete Workspace…", action: #selector(deleteWorkspace(_:)))
        menu.addItem(.separator())
        addItem(to: menu, title: "Save Workspace", action: #selector(saveWorkspace(_:)))
        addItem(to: menu, title: "Revert to Saved", action: #selector(revertToSaved(_:)))
    }

    private func addItem(to menu: NSMenu, title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func promptForName(title: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              !field.stringValue.isEmpty else { return nil }
        return field.stringValue
    }

    /// Launcher semantics: open alongside whatever is already open, or bring
    /// forward if it already has windows.
    @objc private func openWorkspace(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        AppDelegate.shared.openWorkspace(id)
    }

    @objc private func newWorkspace(_ sender: Any?) {
        guard let name = promptForName(title: "New Workspace", initial: "") else { return }
        do {
            try manager.addWorkspace(name: name)
            guard let id = manager.state.workspaces.last?.id else { return }
            AppDelegate.shared.openWorkspace(id)
        } catch { NSAlert(error: error).runModal() }
    }

    @objc private func renameWorkspace(_ sender: Any?) {
        let currentID = AppDelegate.shared.currentWorkspaceID
        guard let workspace = manager.workspace(id: currentID),
              let name = promptForName(title: "Rename Workspace",
                                       initial: workspace.name) else { return }
        do { try manager.renameWorkspace(currentID, to: name) }
        catch { NSAlert(error: error).runModal() }
    }

    /// Close the current workspace's windows; the workspace itself stays.
    @objc private func closeWorkspace(_ sender: Any?) {
        AppDelegate.shared.closeWorkspaceWindows(AppDelegate.shared.currentWorkspaceID)
    }

    @objc private func deleteWorkspace(_ sender: Any?) {
        let currentID = AppDelegate.shared.currentWorkspaceID
        guard let workspace = manager.workspace(id: currentID) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete workspace “\(workspace.name)”?"
        alert.informativeText = "Its saved windows and tabs will be forgotten. Files are not affected."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            AppDelegate.shared.closeWorkspaceWindows(currentID)
            _ = try manager.deleteWorkspace(id: currentID)
            // If nothing is open anymore, open the new active workspace.
            if AppDelegate.shared.session.openWorkspaceIDs().isEmpty {
                AppDelegate.shared.openWorkspace(manager.state.activeWorkspaceID)
            }
        } catch { NSAlert(error: error).runModal() }
    }

    @objc private func saveWorkspace(_ sender: Any?) {
        let currentID = AppDelegate.shared.currentWorkspaceID
        do {
            try manager.syncOpenState(
                captures: [currentID: AppDelegate.shared.session.snapshot(for: currentID)],
                activeID: currentID,
                openIDs: AppDelegate.shared.session.openWorkspaceIDs())
            try manager.saveSnapshot(of: currentID)
        } catch { NSAlert(error: error).runModal() }
    }

    @objc private func revertToSaved(_ sender: Any?) {
        AppDelegate.shared.performRevertToSaved(of: AppDelegate.shared.currentWorkspaceID)
    }
}
