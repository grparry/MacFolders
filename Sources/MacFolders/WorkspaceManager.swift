import Foundation

/// Owns workspace state and persistence. Pure logic — window enumeration and
/// creation live in WindowSession; AppDelegate glues the two together.
///
/// Multi-instance safe: every mutation is a lock-protected read-merge-write.
/// The instance re-reads the file, overlays its own active workspace (which it
/// is the source of truth for), applies the change, and writes back — so two
/// app instances on different workspaces never clobber each other. Two
/// instances on the SAME workspace are last-writer-wins for that workspace.
final class WorkspaceManager {
    enum WorkspaceError: LocalizedError {
        case unknownWorkspace(UUID)
        case cannotDeleteLastWorkspace
        var errorDescription: String? {
            switch self {
            case .unknownWorkspace(let id): return "Unknown workspace: \(id)"
            case .cannotDeleteLastWorkspace: return "Cannot delete the last workspace."
            }
        }
    }

    static let maxRecents = 10

    private(set) var state: AppState
    private let store: WorkspaceStore
    /// Fired after any state mutation; UI (menu, sidebar) refreshes from this.
    var onStateChanged: (() -> Void)?
    /// Which workspaces THIS instance is authoritative for when merging with
    /// disk (its open workspaces). Defaults to just the active one.
    var authoritativeWorkspaceIDs: (() -> [UUID])?

    init(store: WorkspaceStore,
         defaultFavorites: [String] = SidebarDefaults.favoritePaths()) throws {
        self.store = store
        state = try store.withLock {
            if var existing = try store.load() {
                if Self.prune(&existing) {
                    try store.save(existing)
                }
                return existing
            }
            let workspace = Workspace(id: UUID(), name: "Default", live: [], saved: [],
                                      favorites: defaultFavorites)
            let fresh = AppState(workspaces: [workspace], activeWorkspaceID: workspace.id,
                                 openWorkspaceIDs: [workspace.id])
            try store.save(fresh)
            return fresh
        }
    }

    var activeWorkspace: Workspace {
        guard let workspace = state.workspaces.first(where: { $0.id == state.activeWorkspaceID })
        else {
            // Persisted state must always contain the active id; anything else is corrupt.
            fatalError("Active workspace \(state.activeWorkspaceID) missing from state")
        }
        return workspace
    }

    /// Lock, re-read disk, overlay this instance's active workspace, apply the
    /// change to the merged state, persist, adopt as in-memory state.
    private func mutate(_ change: (inout AppState) throws -> Void) throws {
        state = try store.withLock {
            var fresh = try store.load() ?? state
            let authoritative = authoritativeWorkspaceIDs?() ?? [state.activeWorkspaceID]
            for id in authoritative {
                guard let mine = state.workspaces.first(where: { $0.id == id }) else { continue }
                if let i = fresh.workspaces.firstIndex(where: { $0.id == id }) {
                    fresh.workspaces[i] = mine
                } else {
                    // Another instance deleted a workspace this one has open;
                    // the running instance resurrects it.
                    fresh.workspaces.append(mine)
                }
            }
            if fresh.workspaces.contains(where: { $0.id == state.activeWorkspaceID }) {
                fresh.activeWorkspaceID = state.activeWorkspaceID
            }
            try change(&fresh)
            _ = Self.prune(&fresh)
            try store.save(fresh)
            return fresh
        }
        onStateChanged?()
    }

    private func mutateActive(_ change: (inout Workspace) throws -> Void) throws {
        try mutate { state in
            guard let i = state.workspaces.firstIndex(where: { $0.id == state.activeWorkspaceID })
            else { throw WorkspaceError.unknownWorkspace(state.activeWorkspaceID) }
            try change(&state.workspaces[i])
        }
    }

    /// Adopt other instances' changes (new/renamed workspaces etc.) without
    /// writing. This instance's open workspaces stay authoritative in memory.
    func refreshFromDisk() throws {
        let merged: AppState = try store.withLock {
            guard var fresh = try store.load() else { return state }
            let authoritative = authoritativeWorkspaceIDs?() ?? [state.activeWorkspaceID]
            for id in authoritative {
                guard let mine = state.workspaces.first(where: { $0.id == id }) else { continue }
                if let i = fresh.workspaces.firstIndex(where: { $0.id == id }) {
                    fresh.workspaces[i] = mine
                } else {
                    fresh.workspaces.append(mine)
                }
            }
            if fresh.workspaces.contains(where: { $0.id == state.activeWorkspaceID }) {
                fresh.activeWorkspaceID = state.activeWorkspaceID
            }
            return fresh
        }
        guard merged != state else { return }
        state = merged
        onStateChanged?()
    }

    func workspace(id: UUID) -> Workspace? {
        state.workspaces.first { $0.id == id }
    }

    private func mutateWorkspace(_ id: UUID,
                                 _ change: (inout Workspace) throws -> Void) throws {
        try mutate { state in
            guard let i = state.workspaces.firstIndex(where: { $0.id == id })
            else { throw WorkspaceError.unknownWorkspace(id) }
            try change(&state.workspaces[i])
        }
    }

    /// One transaction persisting everything the window session knows: each
    /// open workspace's live windows, which workspaces are open, and which
    /// one is current.
    func syncOpenState(captures: [UUID: [WindowState]],
                       activeID: UUID, openIDs: [UUID]) throws {
        try mutate { state in
            for (id, windows) in captures {
                if let i = state.workspaces.firstIndex(where: { $0.id == id }) {
                    state.workspaces[i].live = windows
                }
            }
            if state.workspaces.contains(where: { $0.id == activeID }) {
                state.activeWorkspaceID = activeID
            }
            state.openWorkspaceIDs = openIDs.filter { id in
                state.workspaces.contains { $0.id == id }
            }
        }
    }

    // MARK: Workspace ops

    func captureLive(_ windows: [WindowState]) throws {
        try mutateActive { workspace in
            workspace.live = windows
        }
    }

    /// Returns the window states the caller should now open.
    func switchTo(id: UUID) throws -> [WindowState] {
        try mutate { state in
            guard state.workspaces.contains(where: { $0.id == id }) else {
                throw WorkspaceError.unknownWorkspace(id)
            }
            state.activeWorkspaceID = id
        }
        return activeWorkspace.live
    }

    func saveSnapshot() throws {
        try saveSnapshot(of: state.activeWorkspaceID)
    }

    func saveSnapshot(of id: UUID) throws {
        try mutateWorkspace(id) { workspace in
            workspace.saved = workspace.live
        }
    }

    /// Returns the window states the caller should now open.
    func revertToSaved() throws -> [WindowState] {
        try revertToSaved(of: state.activeWorkspaceID)
    }

    @discardableResult
    func revertToSaved(of id: UUID) throws -> [WindowState] {
        try mutateWorkspace(id) { workspace in
            workspace.live = workspace.saved
        }
        return workspace(id: id)?.live ?? []
    }

    /// "Name", "Name 2", "Name 3"… — never a duplicate of an existing
    /// workspace name.
    func uniqueName(from base: String) -> String {
        let existing = Set(state.workspaces.map(\.name))
        guard existing.contains(base) else { return base }
        var counter = 2
        while existing.contains("\(base) \(counter)") { counter += 1 }
        return "\(base) \(counter)"
    }

    func addWorkspace(name: String) throws {
        // A new workspace starts with a copy of the active one's favorites.
        let inherited = activeWorkspace.favorites
        let unique = uniqueName(from: name)
        try mutate { state in
            state.workspaces.append(Workspace(id: UUID(), name: unique, live: [], saved: [],
                                              favorites: inherited))
        }
    }

    func renameActiveWorkspace(to name: String) throws {
        try renameWorkspace(state.activeWorkspaceID, to: name)
    }

    func renameWorkspace(_ id: UUID, to name: String) throws {
        guard workspace(id: id)?.name != name else { return }
        let unique = uniqueName(from: name)
        try mutateWorkspace(id) { workspace in
            workspace.name = unique
        }
    }

    /// Returns the window states to open if the active workspace was deleted
    /// (the new active workspace's live state), else nil.
    func deleteWorkspace(id: UUID) throws -> [WindowState]? {
        let wasActive = state.activeWorkspaceID == id
        try mutate { state in
            guard state.workspaces.count > 1 else {
                throw WorkspaceError.cannotDeleteLastWorkspace
            }
            guard state.workspaces.contains(where: { $0.id == id }) else {
                throw WorkspaceError.unknownWorkspace(id)
            }
            state.workspaces.removeAll { $0.id == id }
            state.openWorkspaceIDs.removeAll { $0 == id }
            if state.activeWorkspaceID == id {
                state.activeWorkspaceID = state.workspaces[0].id
            }
        }
        return wasActive ? activeWorkspace.live : nil
    }

    // MARK: Auto-pruning of dead sidebar entries

    /// Remove favorites/recents whose target no longer exists. Paths on
    /// unmounted volumes are kept — the volume may come back. Returns whether
    /// anything was removed.
    @discardableResult
    static func prune(_ state: inout AppState) -> Bool {
        var pruned = false
        for i in state.workspaces.indices {
            let before = state.workspaces[i].favorites.count
                + state.workspaces[i].recentFolders.count
                + state.workspaces[i].recentDocuments.count
            state.workspaces[i].favorites.removeAll(where: Self.isPrunablyDead)
            state.workspaces[i].recentFolders.removeAll(where: Self.isPrunablyDead)
            state.workspaces[i].recentDocuments.removeAll(where: Self.isPrunablyDead)
            let after = state.workspaces[i].favorites.count
                + state.workspaces[i].recentFolders.count
                + state.workspaces[i].recentDocuments.count
            pruned = pruned || after != before
        }
        return pruned
    }

    static func isPrunablyDead(_ path: String) -> Bool {
        guard !FileManager.default.fileExists(atPath: path) else { return false }
        if path.hasPrefix("/Volumes/") {
            let rest = path.dropFirst("/Volumes/".count)
            guard let volumeName = rest.split(separator: "/").first else { return false }
            let volumeRoot = "/Volumes/\(volumeName)"
            if !FileManager.default.fileExists(atPath: volumeRoot) {
                return false  // volume unmounted, not gone
            }
        }
        return true
    }

    // MARK: Favorites (per-workspace, always the active one's)

    func addFavorite(path: String) throws {
        try addFavorite(path: path, in: state.activeWorkspaceID)
    }

    func addFavorite(path: String, in id: UUID) throws {
        try insertFavorite(path: path, at: workspace(id: id)?.favorites.count ?? 0, in: id)
    }

    func insertFavorite(path: String, at index: Int) throws {
        try insertFavorite(path: path, at: index, in: state.activeWorkspaceID)
    }

    func insertFavorite(path: String, at index: Int, in id: UUID) throws {
        guard workspace(id: id)?.favorites.contains(path) != true else { return }
        try mutateWorkspace(id) { workspace in
            let count = workspace.favorites.count
            workspace.favorites.insert(path, at: min(max(index, 0), count))
        }
    }

    /// Option-drop: insert at the drop position in the originating workspace,
    /// append to every other workspace that doesn't already have it.
    func insertFavoriteInAllWorkspaces(path: String, activeAt index: Int,
                                       in originID: UUID? = nil) throws {
        let origin = originID ?? state.activeWorkspaceID
        try mutate { state in
            for i in state.workspaces.indices {
                guard !state.workspaces[i].favorites.contains(path) else { continue }
                if state.workspaces[i].id == origin {
                    let count = state.workspaces[i].favorites.count
                    state.workspaces[i].favorites.insert(path, at: min(max(index, 0), count))
                } else {
                    state.workspaces[i].favorites.append(path)
                }
            }
        }
    }

    func removeFavorite(path: String) throws {
        try removeFavorite(path: path, in: state.activeWorkspaceID)
    }

    func removeFavorite(path: String, in id: UUID) throws {
        try mutateWorkspace(id) { workspace in
            workspace.favorites.removeAll { $0 == path }
        }
    }

    /// Reorder. `index` is the insertion position as seen before removal
    /// (i.e. the drop indicator's position).
    func moveFavorite(path: String, toIndex index: Int) throws {
        try moveFavorite(path: path, toIndex: index, in: state.activeWorkspaceID)
    }

    func moveFavorite(path: String, toIndex index: Int, in id: UUID) throws {
        try mutateWorkspace(id) { workspace in
            guard let from = workspace.favorites.firstIndex(of: path) else { return }
            workspace.favorites.remove(at: from)
            let adjusted = from < index ? index - 1 : index
            let clamped = min(max(adjusted, 0), workspace.favorites.count)
            workspace.favorites.insert(path, at: clamped)
        }
    }

    func isFavoriteInAllWorkspaces(path: String) -> Bool {
        state.workspaces.allSatisfy { $0.favorites.contains(path) }
    }

    func showFavoriteInAllWorkspaces(path: String) throws {
        try mutate { state in
            for i in state.workspaces.indices
            where !state.workspaces[i].favorites.contains(path) {
                state.workspaces[i].favorites.append(path)
            }
        }
    }

    func showFavoriteOnlyInActiveWorkspace(path: String) throws {
        try showFavoriteOnly(in: state.activeWorkspaceID, path: path)
    }

    func showFavoriteOnly(in id: UUID, path: String) throws {
        try mutate { state in
            for i in state.workspaces.indices where state.workspaces[i].id != id {
                state.workspaces[i].favorites.removeAll { $0 == path }
            }
        }
    }

    // MARK: Recents (per-workspace, always the active one's)

    func noteRecentFolder(path: String) throws {
        try noteRecentFolder(path: path, in: state.activeWorkspaceID)
    }

    func noteRecentFolder(path: String, in id: UUID) throws {
        try mutateWorkspace(id) { workspace in
            workspace.recentFolders.removeAll { $0 == path }
            workspace.recentFolders.insert(path, at: 0)
            workspace.recentFolders = Array(workspace.recentFolders.prefix(Self.maxRecents))
        }
    }

    func noteRecentDocument(path: String) throws {
        try noteRecentDocument(path: path, in: state.activeWorkspaceID)
    }

    func noteRecentDocument(path: String, in id: UUID) throws {
        try mutateWorkspace(id) { workspace in
            workspace.recentDocuments.removeAll { $0 == path }
            workspace.recentDocuments.insert(path, at: 0)
            workspace.recentDocuments = Array(workspace.recentDocuments.prefix(Self.maxRecents))
        }
    }
}

/// Default favorites, shared between first-run state and the sidebar.
enum SidebarDefaults {
    static func favoritePaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.path,
                home.appendingPathComponent("Desktop").path,
                home.appendingPathComponent("Documents").path,
                home.appendingPathComponent("Downloads").path,
                "/Applications"]
            .filter { FileManager.default.fileExists(atPath: $0) }
    }
}
