import XCTest
@testable import MacFolders

final class WorkspaceStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: WorkspaceStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FoldersTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = WorkspaceStore(fileURL: tempDir.appendingPathComponent("workspaces.json"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDir)
    }

    private func sampleState() -> AppState {
        let workspace = Workspace(
            id: UUID(), name: "Work",
            live: [WindowState(
                frame: CGRect(x: 10, y: 20, width: 900, height: 600),
                tabs: [TabState(path: "/tmp", viewMode: .list, sidebarWidth: 180),
                       TabState(path: "/Users", viewMode: .icon)],
                selectedTab: 1)],
            saved: [],
            favorites: ["/Users"])
        return AppState(workspaces: [workspace], activeWorkspaceID: workspace.id)
    }

    func testRoundTrip() throws {
        let state = sampleState()
        try store.save(state)
        let loaded = try store.load()
        XCTAssertEqual(loaded, state)
    }

    func testLoadReturnsNilWhenFileMissing() throws {
        XCTAssertNil(try store.load())
    }

    func testLoadThrowsOnCorruptFile() throws {
        try Data("not json {".utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
    }

    func testLoadMigratesLegacyGlobalFavorites() throws {
        let id1 = UUID().uuidString, id2 = UUID().uuidString
        let legacy = """
        {"activeWorkspaceID":"\(id1)",
         "favorites":["/opt","/tmp"],
         "workspaces":[
           {"id":"\(id1)","name":"Default","live":[],"saved":[]},
           {"id":"\(id2)","name":"Work","live":[],"saved":[]}]}
        """
        try Data(legacy.utf8).write(to: store.fileURL)
        let loaded = try store.load()
        XCTAssertEqual(loaded?.workspaces.map(\.favorites),
                       [["/opt", "/tmp"], ["/opt", "/tmp"]])
        XCTAssertEqual(loaded?.workspaces.map(\.name), ["Default", "Work"])
    }

    func testLoadMigratesV2WithoutRecents() throws {
        let id = UUID().uuidString
        let v2 = """
        {"activeWorkspaceID":"\(id)",
         "workspaces":[
           {"id":"\(id)","name":"Default","live":[],"saved":[],
            "favorites":["/opt"]}]}
        """
        try Data(v2.utf8).write(to: store.fileURL)
        let loaded = try store.load()
        XCTAssertEqual(loaded?.workspaces[0].favorites, ["/opt"])
        XCTAssertEqual(loaded?.workspaces[0].recentFolders, [])
        XCTAssertEqual(loaded?.workspaces[0].recentDocuments, [])
    }

    func testSaveCreatesParentDirectory() throws {
        let nested = WorkspaceStore(
            fileURL: tempDir.appendingPathComponent("a/b/workspaces.json"))
        try nested.save(sampleState())
        XCTAssertNotNil(try nested.load())
    }
}
