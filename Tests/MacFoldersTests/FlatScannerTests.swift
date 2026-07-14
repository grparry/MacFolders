import XCTest
@testable import MacFolders

final class FlatScannerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub/.git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub/deep"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("node_modules/pkg"),
            withIntermediateDirectories: true)
        try Data(count: 50).write(
            to: dir.appendingPathComponent("node_modules/pkg/index.js"))
        try Data(count: 10).write(to: dir.appendingPathComponent("small.txt"))
        try Data(count: 5000).write(to: dir.appendingPathComponent("big.bin"))
        try Data(count: 100).write(to: dir.appendingPathComponent("sub/deep/nested.txt"))
        try Data(count: 100).write(to: dir.appendingPathComponent("sub/.git/config"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dir)
    }

    private func scan(_ config: FlatViewConfig) -> [String] {
        let scanner = FlatScanner()
        let done = expectation(description: "finished")
        var names: [String] = []
        scanner.onEvent = { event in
            switch event {
            case .batch(let items): names += items.map(\.name)
            case .finished: done.fulfill()
            case .paused: XCTFail("unexpected pause")
            }
        }
        scanner.scan(root: dir, config: config)
        wait(for: [done], timeout: 5)
        return names.sorted()
    }

    func testSkipsDotTreesWhenConfigured() {
        XCTAssertEqual(scan(FlatViewConfig()),
                       ["big.bin", "nested.txt", "small.txt"])
    }

    func testIncludesDotTreesWhenAllowed() {
        var config = FlatViewConfig()
        config.skipDotTrees = false
        XCTAssertEqual(scan(config),
                       ["big.bin", "config", "index.js", "nested.txt", "small.txt"])
    }

    func testMinSizeFilter() {
        var config = FlatViewConfig()
        config.minSizeBytes = 1000
        XCTAssertEqual(scan(config), ["big.bin"])
    }

    func testModifiedWithinIncludesFreshFiles() {
        var config = FlatViewConfig()
        config.modifiedWithinDays = 1
        XCTAssertEqual(scan(config), ["big.bin", "nested.txt", "small.txt"])
    }

    func testSkipPatternMatching() {
        let saved = UserDefaults.standard.stringArray(forKey: "flatSkipPatterns")
        defer { UserDefaults.standard.set(saved, forKey: "flatSkipPatterns") }
        UserDefaults.standard.removeObject(forKey: "flatSkipPatterns")
        // Seeded defaults: every dot-directory plus node_modules.
        XCTAssertTrue(FlatScanner.shouldSkip(directoryName: ".git"))
        XCTAssertTrue(FlatScanner.shouldSkip(directoryName: ".venv"))
        XCTAssertTrue(FlatScanner.shouldSkip(directoryName: "node_modules"))
        XCTAssertFalse(FlatScanner.shouldSkip(directoryName: "Sources"))
        XCTAssertFalse(FlatScanner.shouldSkip(directoryName: "node_modules_backup"))
        // User globs.
        FlatScanner.skipPatterns = ["build*", "dist"]
        XCTAssertTrue(FlatScanner.shouldSkip(directoryName: "build"))
        XCTAssertTrue(FlatScanner.shouldSkip(directoryName: "build-output"))
        XCTAssertTrue(FlatScanner.shouldSkip(directoryName: "dist"))
        XCTAssertFalse(FlatScanner.shouldSkip(directoryName: ".git"))
    }

    func testFlatConfigRoundTripAndDefault() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = try WorkspaceManager(store: WorkspaceStore(fileURL: url))
        XCTAssertEqual(manager.flatConfig(forPath: "/tmp"), FlatViewConfig())
        var config = FlatViewConfig()
        config.sortKey = .dateModified
        config.minSizeBytes = 1_000_000
        try manager.setFlatConfig(config, forPath: "/tmp")
        XCTAssertEqual(manager.flatConfig(forPath: "/tmp"), config)
        // Other folders are untouched — per-folder, never inherited.
        XCTAssertEqual(manager.flatConfig(forPath: "/Users"), FlatViewConfig())
    }
}
