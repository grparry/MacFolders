import XCTest
@testable import MacFolders

final class WorkspaceManagerTests: XCTestCase {
    private var tempDir: URL!
    private var store: WorkspaceStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FoldersManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = WorkspaceStore(fileURL: tempDir.appendingPathComponent("workspaces.json"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDir)
    }

    private func window(_ path: String) -> WindowState {
        WindowState(frame: CGRect(x: 0, y: 0, width: 900, height: 600),
                    tabs: [TabState(path: path, viewMode: .list)], selectedTab: 0)
    }

    func testFirstRunCreatesDefaultWorkspace() throws {
        let manager = try WorkspaceManager(store: store)
        XCTAssertEqual(manager.state.workspaces.count, 1)
        XCTAssertEqual(manager.state.workspaces[0].name, "Default")
        XCTAssertEqual(manager.state.activeWorkspaceID, manager.state.workspaces[0].id)
        XCTAssertFalse(manager.activeWorkspace.favorites.isEmpty)
        // and it persisted
        XCTAssertNotNil(try store.load())
    }

    func testSecondInitLoadsExistingState() throws {
        let first = try WorkspaceManager(store: store)
        try first.captureLive([window("/tmp")])
        let second = try WorkspaceManager(store: store)
        XCTAssertEqual(second.activeWorkspace.live, [window("/tmp")])
    }

    func testCaptureLiveUpdatesOnlyActiveWorkspace() throws {
        let manager = try WorkspaceManager(store: store)
        try manager.addWorkspace(name: "Other")
        try manager.captureLive([window("/tmp")])
        let active = manager.activeWorkspace
        let other = manager.state.workspaces.first { $0.id != active.id }!
        XCTAssertEqual(active.live, [window("/tmp")])
        XCTAssertTrue(other.live.isEmpty)
    }

    func testSwitchChangesActiveAndReturnsTargetLive() throws {
        let manager = try WorkspaceManager(store: store)
        try manager.addWorkspace(name: "Work")
        let workID = manager.state.workspaces.first { $0.name == "Work" }!.id
        try manager.captureLive([window("/tmp")])          // into Default
        let toOpen = try manager.switchTo(id: workID)
        XCTAssertEqual(manager.state.activeWorkspaceID, workID)
        XCTAssertTrue(toOpen.isEmpty)                       // Work has no state yet
        let back = try manager.switchTo(id: manager.state.workspaces[0].id)
        XCTAssertEqual(back, [window("/tmp")])              // Default kept its live state
    }

    func testSaveSnapshotAndRevert() throws {
        let manager = try WorkspaceManager(store: store)
        try manager.captureLive([window("/tmp")])
        try manager.saveSnapshot()
        try manager.captureLive([window("/Users")])
        XCTAssertEqual(manager.activeWorkspace.live, [window("/Users")])
        let reverted = try manager.revertToSaved()
        XCTAssertEqual(reverted, [window("/tmp")])
        XCTAssertEqual(manager.activeWorkspace.live, [window("/tmp")])
    }

    func testUniqueNamesIncrement() throws {
        let manager = try WorkspaceManager(store: store)
        try manager.addWorkspace(name: "Default")       // collides with first-run
        try manager.addWorkspace(name: "Default")
        XCTAssertEqual(manager.state.workspaces.map(\.name),
                       ["Default", "Default 2", "Default 3"])
        // Rename into a collision also increments; renaming to self is a no-op.
        let last = manager.state.workspaces.last!.id
        try manager.renameWorkspace(last, to: "Default")
        // Own old name ("Default 3") still counts as taken during the rename.
        XCTAssertEqual(manager.state.workspaces.last!.name, "Default 4")
        try manager.renameWorkspace(last, to: "Default 2")
        XCTAssertEqual(manager.state.workspaces.last!.name, "Default 2 2")
    }

    func testFavoritesExcludedFromRecentFolders() throws {
        let manager = try WorkspaceManager(store: store)
        let id = manager.state.activeWorkspaceID
        try manager.addFavorite(path: "/Applications", in: id)
        try manager.noteRecentFolder(path: "/Applications", in: id)
        XCTAssertEqual(manager.state.workspaces[0].recentFolders, [])
        try manager.noteRecentFolder(path: "/Users", in: id)
        XCTAssertEqual(manager.state.workspaces[0].recentFolders, ["/Users"])
        // Favoriting a folder already in recents removes it from recents.
        try manager.addFavorite(path: "/Users", in: id)
        XCTAssertEqual(manager.state.workspaces[0].recentFolders, [])
    }

    func testRenameWorkspace() throws {
        let manager = try WorkspaceManager(store: store)
        try manager.renameActiveWorkspace(to: "Renamed")
        XCTAssertEqual(manager.activeWorkspace.name, "Renamed")
    }

    func testDeleteActiveWorkspaceActivatesAnother() throws {
        let manager = try WorkspaceManager(store: store)
        try manager.addWorkspace(name: "Second")
        let firstID = manager.state.workspaces[0].id
        _ = try manager.switchTo(id: firstID)
        _ = try manager.deleteWorkspace(id: firstID)
        XCTAssertEqual(manager.state.workspaces.count, 1)
        XCTAssertEqual(manager.state.activeWorkspaceID, manager.state.workspaces[0].id)
    }

    func testDeleteLastWorkspaceThrows() throws {
        let manager = try WorkspaceManager(store: store)
        XCTAssertThrowsError(
            try manager.deleteWorkspace(id: manager.state.activeWorkspaceID))
    }

    func testInsertFavoriteAtPosition() throws {
        let manager = try WorkspaceManager(store: store)
        let count = manager.activeWorkspace.favorites.count
        try manager.insertFavorite(path: "/opt", at: 1)
        XCTAssertEqual(manager.activeWorkspace.favorites[1], "/opt")
        try manager.insertFavorite(path: "/opt", at: 0)   // duplicate is a no-op
        XCTAssertEqual(manager.activeWorkspace.favorites.count, count + 1)
        try manager.insertFavorite(path: "/tmp", at: 999) // out-of-range clamps to end
        XCTAssertEqual(manager.activeWorkspace.favorites.last, "/tmp")
    }

    func testFavoritesAddRemove() throws {
        let manager = try WorkspaceManager(store: store)
        let count = manager.activeWorkspace.favorites.count
        try manager.addFavorite(path: "/opt")
        XCTAssertEqual(manager.activeWorkspace.favorites.count, count + 1)
        try manager.addFavorite(path: "/opt")   // duplicate is a no-op
        XCTAssertEqual(manager.activeWorkspace.favorites.count, count + 1)
        try manager.removeFavorite(path: "/opt")
        XCTAssertEqual(manager.activeWorkspace.favorites.count, count)
    }

    func testConcurrentInstancesDoNotClobber() throws {
        let m1 = try WorkspaceManager(store: store)
        try m1.addWorkspace(name: "B")
        let bID = m1.state.workspaces.first { $0.name == "B" }!.id

        // Second manager over the same file simulates a second app instance.
        let m2 = try WorkspaceManager(store: WorkspaceStore(fileURL: store.fileURL))
        _ = try m2.switchTo(id: bID)

        try m2.captureLive([window("/tmp")])     // instance 2 works in B
        try m1.captureLive([window("/Users")])   // instance 1 works in Default
        let disk = try store.load()!
        XCTAssertEqual(disk.workspaces.first { $0.name == "Default" }!.live,
                       [window("/Users")])
        XCTAssertEqual(disk.workspaces.first { $0.name == "B" }!.live,
                       [window("/tmp")])

        // Structural change by one instance becomes visible to the other.
        try m2.addWorkspace(name: "C")
        try m1.refreshFromDisk()
        XCTAssertTrue(m1.state.workspaces.contains { $0.name == "C" })
        // And the refresh keeps instance 1's own active workspace authoritative.
        XCTAssertEqual(m1.activeWorkspace.live, [window("/Users")])
    }

    func testRecentsTrackOrderDedupeAndCap() throws {
        // Real paths: dead ones would be auto-pruned.
        let paths = ["/usr", "/bin", "/sbin", "/etc", "/var", "/opt",
                     "/tmp", "/Library", "/System", "/Users", "/private", "/dev"]
        let manager = try WorkspaceManager(store: store)
        for path in paths {
            try manager.noteRecentFolder(path: path)
        }
        XCTAssertEqual(manager.activeWorkspace.recentFolders.count,
                       WorkspaceManager.maxRecents)
        XCTAssertEqual(manager.activeWorkspace.recentFolders.first, "/dev")
        try manager.noteRecentFolder(path: "/opt")   // revisit moves to front
        XCTAssertEqual(manager.activeWorkspace.recentFolders.first, "/opt")
        XCTAssertEqual(manager.activeWorkspace.recentFolders.count,
                       WorkspaceManager.maxRecents)
        try manager.noteRecentDocument(path: "/etc/hosts")
        XCTAssertEqual(manager.activeWorkspace.recentDocuments, ["/etc/hosts"])
    }

    func testRecentsArePerWorkspaceAndNotInherited() throws {
        let manager = try WorkspaceManager(store: store)
        try manager.noteRecentFolder(path: "/usr")
        try manager.addWorkspace(name: "W")
        let wID = manager.state.workspaces.first { $0.name == "W" }!.id
        _ = try manager.switchTo(id: wID)
        XCTAssertTrue(manager.activeWorkspace.recentFolders.isEmpty)
        try manager.noteRecentFolder(path: "/bin")
        _ = try manager.switchTo(id: manager.state.workspaces[0].id)
        XCTAssertEqual(manager.activeWorkspace.recentFolders, ["/usr"])
    }

    func testInsertFavoriteInAllWorkspaces() throws {
        let manager = try WorkspaceManager(store: store)
        try manager.addWorkspace(name: "W")
        try manager.insertFavoriteInAllWorkspaces(path: "/opt", activeAt: 0)
        for workspace in manager.state.workspaces {
            XCTAssertTrue(workspace.favorites.contains("/opt"), workspace.name)
        }
        XCTAssertEqual(manager.activeWorkspace.favorites.first, "/opt")
        // Idempotent.
        let counts = manager.state.workspaces.map { $0.favorites.count }
        try manager.insertFavoriteInAllWorkspaces(path: "/opt", activeAt: 3)
        XCTAssertEqual(manager.state.workspaces.map { $0.favorites.count }, counts)
    }

    func testMoveFavoriteReorders() throws {
        let manager = try WorkspaceManager(store: store)
        try manager.captureLive([])  // no-op mutate to ensure persisted
        let original = manager.activeWorkspace.favorites
        guard original.count >= 3 else { return XCTFail("need 3+ default favorites") }
        // Move the first favorite to the end (drop indicator after last row).
        try manager.moveFavorite(path: original[0], toIndex: original.count)
        XCTAssertEqual(manager.activeWorkspace.favorites.last, original[0])
        XCTAssertEqual(manager.activeWorkspace.favorites.first, original[1])
        // Move it back to the front.
        try manager.moveFavorite(path: original[0], toIndex: 0)
        XCTAssertEqual(manager.activeWorkspace.favorites, original)
    }

    func testShowFavoriteInAllAndOnlyHere() throws {
        let manager = try WorkspaceManager(store: store)
        try manager.addWorkspace(name: "W")
        try manager.addFavorite(path: "/opt")   // active only
        XCTAssertFalse(manager.isFavoriteInAllWorkspaces(path: "/opt"))

        try manager.showFavoriteInAllWorkspaces(path: "/opt")
        XCTAssertTrue(manager.isFavoriteInAllWorkspaces(path: "/opt"))

        try manager.showFavoriteOnlyInActiveWorkspace(path: "/opt")
        XCTAssertFalse(manager.isFavoriteInAllWorkspaces(path: "/opt"))
        XCTAssertTrue(manager.activeWorkspace.favorites.contains("/opt"))
        let other = manager.state.workspaces.first { $0.name == "W" }!
        XCTAssertFalse(other.favorites.contains("/opt"))
    }

    func testDeadEntriesAutoPrune() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("PruneTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let manager = try WorkspaceManager(store: store)
        try manager.addFavorite(path: scratch.path)
        try manager.noteRecentFolder(path: scratch.path)
        XCTAssertTrue(manager.activeWorkspace.favorites.contains(scratch.path))

        try FileManager.default.removeItem(at: scratch)
        try manager.captureLive([])   // any mutation triggers the prune
        XCTAssertFalse(manager.activeWorkspace.favorites.contains(scratch.path))
        XCTAssertFalse(manager.activeWorkspace.recentFolders.contains(scratch.path))
    }

    func testUnmountedVolumePathsSurvivePruning() {
        // Volume absent: keep (it may remount).
        XCTAssertFalse(WorkspaceManager.isPrunablyDead(
            "/Volumes/NoSuchVolume-\(UUID().uuidString)/folder"))
        // Volume present ("/Volumes/<boot>" exists) but path gone: prune.
        let boot = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes").first
        if let boot, FileManager.default.fileExists(atPath: "/Volumes/\(boot)") {
            XCTAssertTrue(WorkspaceManager.isPrunablyDead(
                "/Volumes/\(boot)/nonexistent-\(UUID().uuidString)"))
        }
        // Ordinary dead path: prune. Ordinary live path: keep.
        XCTAssertTrue(WorkspaceManager.isPrunablyDead("/nonexistent-\(UUID().uuidString)"))
        XCTAssertFalse(WorkspaceManager.isPrunablyDead("/usr"))
    }

    func testFavoritesArePerWorkspace() throws {
        let manager = try WorkspaceManager(store: store)
        try manager.addWorkspace(name: "Work")
        let workID = manager.state.workspaces.first { $0.name == "Work" }!.id
        let defaultID = manager.state.activeWorkspaceID

        // New workspace inherits a copy of the active one's favorites.
        XCTAssertEqual(manager.state.workspaces.first { $0.id == workID }!.favorites,
                       manager.activeWorkspace.favorites)

        // A favorite added in Default stays out of Work.
        try manager.addFavorite(path: "/opt")
        _ = try manager.switchTo(id: workID)
        XCTAssertFalse(manager.activeWorkspace.favorites.contains("/opt"))

        // And one added in Work stays out of Default.
        try manager.addFavorite(path: "/tmp")
        _ = try manager.switchTo(id: defaultID)
        XCTAssertFalse(manager.activeWorkspace.favorites.contains("/tmp"))
        XCTAssertTrue(manager.activeWorkspace.favorites.contains("/opt"))
    }
}
