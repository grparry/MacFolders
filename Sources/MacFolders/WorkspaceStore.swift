import Foundation

final class WorkspaceStore {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static func defaultURL() -> URL {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacFolders/workspaces.json")
        migrateLegacyState(to: url)
        return url
    }

    /// The app was previously named "Folders"; adopt its state once.
    private static func migrateLegacyState(to url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let legacy = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Folders/workspaces.json")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: legacy, to: url)
    }

    /// nil means "no file yet" — first run. The caller decides what to create.
    /// Older schemas migrate explicitly; a genuinely corrupt file fails every
    /// decode and the final error surfaces.
    func load() throws -> AppState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        if let state = try? decoder.decode(AppState.self, from: data) {
            return state
        }
        // V3: per-workspace favorites+recents, before openWorkspaceIDs.
        if let v3 = try? decoder.decode(AppStateV3.self, from: data) {
            return AppState(workspaces: v3.workspaces,
                            activeWorkspaceID: v3.activeWorkspaceID,
                            openWorkspaceIDs: [v3.activeWorkspaceID])
        }
        // V2: per-workspace favorites, no recents.
        if let v2 = try? decoder.decode(AppStateV2.self, from: data) {
            return AppState(
                workspaces: v2.workspaces.map {
                    Workspace(id: $0.id, name: $0.name, live: $0.live, saved: $0.saved,
                              favorites: $0.favorites)
                },
                activeWorkspaceID: v2.activeWorkspaceID,
                openWorkspaceIDs: [v2.activeWorkspaceID])
        }
        // V1: app-global favorites — copy into every workspace.
        let v1 = try decoder.decode(AppStateV1.self, from: data)
        return AppState(
            workspaces: v1.workspaces.map {
                Workspace(id: $0.id, name: $0.name, live: $0.live, saved: $0.saved,
                          favorites: v1.favorites)
            },
            activeWorkspaceID: v1.activeWorkspaceID,
            openWorkspaceIDs: [v1.activeWorkspaceID])
    }

    /// Serializes read-modify-write cycles across processes so concurrent
    /// app instances don't clobber each other's workspaces.
    func withLock<T>(_ body: () throws -> T) throws -> T {
        let lockURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".workspaces.lock")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw LockError.cannotOpenLockFile(lockURL.path) }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw LockError.cannotAcquire(lockURL.path) }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    enum LockError: LocalizedError {
        case cannotOpenLockFile(String)
        case cannotAcquire(String)
        var errorDescription: String? {
            switch self {
            case .cannotOpenLockFile(let path): return "Cannot open lock file: \(path)"
            case .cannotAcquire(let path): return "Cannot acquire lock: \(path)"
            }
        }
    }

    private struct AppStateV3: Codable {
        let workspaces: [Workspace]   // same shape as current
        let activeWorkspaceID: UUID
    }

    private struct WorkspaceV2: Codable {
        let id: UUID
        let name: String
        let live: [WindowState]
        let saved: [WindowState]
        let favorites: [String]
    }

    private struct AppStateV2: Codable {
        let workspaces: [WorkspaceV2]
        let activeWorkspaceID: UUID
    }

    private struct WorkspaceV1: Codable {
        let id: UUID
        let name: String
        let live: [WindowState]
        let saved: [WindowState]
    }

    private struct AppStateV1: Codable {
        let workspaces: [WorkspaceV1]
        let activeWorkspaceID: UUID
        let favorites: [String]
    }

    func save(_ state: AppState) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: .atomic)
    }
}
