import XCTest
@testable import MacFolders

final class FileOperationsTests: XCTestCase {
    private var tempDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("FoldersOpsTests-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tempDir)
    }

    private func makeFile(_ name: String, in dir: URL? = nil) throws -> URL {
        let url = (dir ?? tempDir).appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    private func makeDir(_ name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    func testCopyIntoDirectory() throws {
        let file = try makeFile("a.txt")
        let dest = try makeDir("dest")
        let results = try FileOperations.copy([file], to: dest)
        XCTAssertEqual(results, [dest.appendingPathComponent("a.txt")])
        XCTAssertTrue(fm.fileExists(atPath: results[0].path))
        XCTAssertTrue(fm.fileExists(atPath: file.path)) // original remains
    }

    func testMoveIntoDirectory() throws {
        let file = try makeFile("a.txt")
        let dest = try makeDir("dest")
        let results = try FileOperations.move([file], to: dest)
        XCTAssertTrue(fm.fileExists(atPath: results[0].path))
        XCTAssertFalse(fm.fileExists(atPath: file.path)) // original gone
    }

    func testCopyCollisionThrows() throws {
        let file = try makeFile("a.txt")
        let dest = try makeDir("dest")
        _ = try makeFile("a.txt", in: dest)
        XCTAssertThrowsError(try FileOperations.copy([file], to: dest))
    }

    func testRename() throws {
        let file = try makeFile("a.txt")
        let renamed = try FileOperations.rename(file, to: "b.txt")
        XCTAssertEqual(renamed.lastPathComponent, "b.txt")
        XCTAssertTrue(fm.fileExists(atPath: renamed.path))
        XCTAssertFalse(fm.fileExists(atPath: file.path))
    }

    func testRenameCollisionThrows() throws {
        let file = try makeFile("a.txt")
        _ = try makeFile("b.txt")
        XCTAssertThrowsError(try FileOperations.rename(file, to: "b.txt"))
    }

    func testDuplicateNamesLikeFinder() throws {
        let file = try makeFile("a.txt")
        let first = try FileOperations.duplicate(file)
        XCTAssertEqual(first.lastPathComponent, "a copy.txt")
        let second = try FileOperations.duplicate(file)
        XCTAssertEqual(second.lastPathComponent, "a copy 2.txt")
    }

    func testDuplicateFolderWithoutExtension() throws {
        let dir = try makeDir("stuff")
        let dup = try FileOperations.duplicate(dir)
        XCTAssertEqual(dup.lastPathComponent, "stuff copy")
        var isDir: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: dup.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testNewFolderNaming() throws {
        let first = try FileOperations.newFolder(in: tempDir)
        XCTAssertEqual(first.lastPathComponent, "untitled folder")
        let second = try FileOperations.newFolder(in: tempDir)
        XCTAssertEqual(second.lastPathComponent, "untitled folder 2")
    }

    func testTrashRemovesFromDirectory() throws {
        let file = try makeFile("a.txt")
        try FileOperations.trash([file])
        XCTAssertFalse(fm.fileExists(atPath: file.path))
    }
}
