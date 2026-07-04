import XCTest
@testable import MacFolders

final class SearchEngineTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub/.git"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("Report-Final.txt"))
        try Data().write(to: dir.appendingPathComponent(".hidden-report.txt"))
        try Data().write(to: dir.appendingPathComponent("sub/.git/report-config"))
        try Data().write(to: dir.appendingPathComponent("other.txt"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dir)
    }

    private func nameSearch(_ term: String) -> [String] {
        let engine = SearchEngine()
        let done = expectation(description: "complete")
        var found: [URL] = []
        engine.onResults = { batch, complete in
            found += batch
            if complete { done.fulfill() }
        }
        engine.search(term: term, mode: .name, scope: .folder, folder: dir)
        wait(for: [done], timeout: 5)
        return found.map(\.lastPathComponent).sorted()
    }

    func testWalkFindsDotfilesAndNestedHiddenDirs() {
        XCTAssertEqual(nameSearch("report"),
                       [".hidden-report.txt", "Report-Final.txt", "report-config"])
    }

    func testWalkIsCaseInsensitive() {
        XCTAssertEqual(nameSearch("REPORT-FINAL"), ["Report-Final.txt"])
    }

    func testEmptyTermCompletesEmpty() {
        XCTAssertEqual(nameSearch(""), [])
    }
}
