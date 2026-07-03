import XCTest
@testable import MacFolders

final class PathRecoveryTests: XCTestCase {
    func testExistingPathReturnsItself() throws {
        let tempDir = FileManager.default.temporaryDirectory
        XCTAssertEqual(PathRecovery.nearestExistingAncestor(of: tempDir).resolvingSymlinksInPath(),
                       tempDir.resolvingSymlinksInPath())
    }

    func testWalksUpPastMissingComponents() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PathRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let dead = base.appendingPathComponent("gone/deeper/deepest")
        XCTAssertEqual(PathRecovery.nearestExistingAncestor(of: dead).path, base.path)
    }

    func testTotalLossFallsBackToRoot() {
        let dead = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/a/b")
        XCTAssertEqual(PathRecovery.nearestExistingAncestor(of: dead).path, "/")
    }
}
