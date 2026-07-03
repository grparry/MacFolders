import XCTest
@testable import MacFolders

final class DirectoryModelTests: XCTestCase {
    private var tempDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("FoldersModelTests-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tempDir)
    }

    private func makeFile(_ name: String, bytes: Int = 1) throws {
        try Data(repeating: 0, count: bytes)
            .write(to: tempDir.appendingPathComponent(name))
    }

    func testListsContents() throws {
        try makeFile("b.txt")
        try makeFile("a.txt")
        try fm.createDirectory(at: tempDir.appendingPathComponent("sub"),
                               withIntermediateDirectories: false)
        let model = DirectoryModel(directoryURL: tempDir)
        try model.reload()
        XCTAssertEqual(model.items.map(\.name), ["a.txt", "b.txt", "sub"])
        XCTAssertTrue(model.items[2].isDirectory)
    }

    func testHiddenFilesExcludedByDefault() throws {
        try makeFile(".hidden")
        try makeFile("visible.txt")
        let model = DirectoryModel(directoryURL: tempDir)
        try model.reload()
        XCTAssertEqual(model.items.map(\.name), ["visible.txt"])
        model.showHidden = true
        try model.reload()
        XCTAssertEqual(model.items.map(\.name), [".hidden", "visible.txt"])
    }

    func testSortBySizeDescending() throws {
        try makeFile("small.txt", bytes: 1)
        try makeFile("big.txt", bytes: 1000)
        let model = DirectoryModel(directoryURL: tempDir)
        model.sortKey = .size
        model.ascending = false
        try model.reload()
        XCTAssertEqual(model.items.map(\.name), ["big.txt", "small.txt"])
    }

    func testSortByNameIsFinderLike() throws {
        try makeFile("file10.txt")
        try makeFile("file2.txt")
        let model = DirectoryModel(directoryURL: tempDir)
        try model.reload()
        // localizedStandardCompare: numeric-aware, like Finder
        XCTAssertEqual(model.items.map(\.name), ["file2.txt", "file10.txt"])
    }

    func testItemsOfSubdirectoryRespectsSettings() throws {
        let sub = tempDir.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: sub.appendingPathComponent(".hidden"))
        try Data("x".utf8).write(to: sub.appendingPathComponent("b.txt"))
        try Data("x".utf8).write(to: sub.appendingPathComponent("a.txt"))
        let model = DirectoryModel(directoryURL: tempDir)
        XCTAssertEqual(try model.items(of: sub).map(\.name), ["a.txt", "b.txt"])
        model.showHidden = true
        model.ascending = false
        XCTAssertEqual(try model.items(of: sub).map(\.name), ["b.txt", "a.txt", ".hidden"])
    }

    func testWatcherEventFilter() throws {
        // FSEvents delivery timing can't be asserted deterministically (it may
        // coalesce and over-report an ancestor), so test the filter directly:
        // the watched dir and its direct children are relevant, deeper is not.
        let watcher = DirectoryWatcher(directoryURL: tempDir)
        XCTAssertTrue(watcher.isRelevant(paths: [tempDir.path]))
        XCTAssertTrue(watcher.isRelevant(paths: [tempDir.appendingPathComponent("a.txt").path]))
        XCTAssertFalse(watcher.isRelevant(
            paths: [tempDir.appendingPathComponent("sub/deep.txt").path]))
        XCTAssertFalse(watcher.isRelevant(
            paths: [tempDir.appendingPathComponent("sub/subsub/deeper.txt").path]))
        XCTAssertTrue(watcher.isRelevant(
            paths: [tempDir.appendingPathComponent("sub/deep.txt").path, tempDir.path]))
    }

    func testWatcherFiresOnChange() throws {
        let model = DirectoryModel(directoryURL: tempDir)
        try model.reload()
        let changed = expectation(description: "directory change observed")
        changed.assertForOverFulfill = false
        model.onDirectoryChanged = { changed.fulfill() }
        try model.startWatching()
        try makeFile("new.txt")
        wait(for: [changed], timeout: 5.0)
        model.stopWatching()
    }
}
