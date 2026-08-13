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

    func testCopyCollisionAppendsSuffix() throws {
        let file = try makeFile("a.txt")
        let dest = try makeDir("dest")
        _ = try makeFile("a.txt", in: dest)
        let out = try FileOperations.copy([file], to: dest)
        XCTAssertEqual(out.first?.lastPathComponent, "a copy.txt")
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

    func testCreateFolderNamedAndCollisionThrows() throws {
        let created = try FileOperations.createFolder(named: "Reports", in: tempDir)
        XCTAssertEqual(created.lastPathComponent, "Reports")
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))
        XCTAssertThrowsError(
            try FileOperations.createFolder(named: "Reports", in: tempDir))
    }

    func testTrashRemovesFromDirectory() throws {
        let file = try makeFile("a.txt")
        try FileOperations.trash([file])
        XCTAssertFalse(fm.fileExists(atPath: file.path))
    }

    func testDeleteImmediatelyRemovesFilesAndFolders() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("folder"), withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("file.txt")
        try Data().write(to: file)
        try FileOperations.deleteImmediately([file, dir.appendingPathComponent("folder")])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("folder").path))
        XCTAssertThrowsError(try FileOperations.deleteImmediately([file]))
        try FileManager.default.removeItem(at: dir)
    }

    func testCompressSingleItemAndCollisionSuffix() throws {
        let folder = tempDir.appendingPathComponent("Docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: folder.appendingPathComponent("a.txt"))

        let zip1 = try FileOperations.compress([folder])
        XCTAssertEqual(zip1.lastPathComponent, "Docs.zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip1.path))
        let size = (try zip1.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        XCTAssertGreaterThan(size, 0)

        let zip2 = try FileOperations.compress([folder])
        XCTAssertEqual(zip2.lastPathComponent, "Docs 2.zip")
    }

    func testCompressMultipleItemsMakesArchive() throws {
        let f1 = tempDir.appendingPathComponent("one.txt")
        let f2 = tempDir.appendingPathComponent("two.txt")
        try Data("1".utf8).write(to: f1)
        try Data("2".utf8).write(to: f2)
        let zip = try FileOperations.compress([f1, f2])
        XCTAssertEqual(zip.lastPathComponent, "Archive.zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path))
    }

    func testCopyAppendsCopySuffixOnCollision() throws {
        let dst = tempDir.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        let src = tempDir.appendingPathComponent("note.txt")
        try Data("a".utf8).write(to: src)
        try Data("b".utf8).write(to: dst.appendingPathComponent("note.txt"))  // pre-existing

        let first = try FileOperations.copy([src], to: dst)
        XCTAssertEqual(first.first?.lastPathComponent, "note copy.txt")
        let second = try FileOperations.copy([src], to: dst)
        XCTAssertEqual(second.first?.lastPathComponent, "note copy 2.txt")
    }

    func testCopyKeepsNameWhenNoCollision() throws {
        let dst = tempDir.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        let src = tempDir.appendingPathComponent("solo.txt")
        try Data("x".utf8).write(to: src)
        let out = try FileOperations.copy([src], to: dst)
        XCTAssertEqual(out.first?.lastPathComponent, "solo.txt")
    }

    func testMoveIntoSameFolderIsNoOp() throws {
        let src = tempDir.appendingPathComponent("stay.txt")
        try Data("x".utf8).write(to: src)
        let out = try FileOperations.move([src], to: tempDir)
        XCTAssertEqual(out.first?.lastPathComponent, "stay.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))
    }
}
