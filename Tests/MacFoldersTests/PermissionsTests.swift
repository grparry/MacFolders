import XCTest
@testable import MacFolders

final class PermissionsTests: XCTestCase {
    func testDirectoryReadImpliesExecute() {
        // 0o700 dir, grant everyone Read only → r-x for everyone.
        let updated = GetInfoPanelController.updatedPermissions(
            current: 0o700, shift: 0, newReadWrite: 0b100, isDirectory: true)
        XCTAssertEqual(updated, 0o705)
    }

    func testDirectoryNoAccessClearsAllBits() {
        let updated = GetInfoPanelController.updatedPermissions(
            current: 0o755, shift: 0, newReadWrite: 0, isDirectory: true)
        XCTAssertEqual(updated, 0o750)
    }

    func testFilePreservesExecuteBit() {
        // Executable script: changing group to Read only keeps group x.
        let updated = GetInfoPanelController.updatedPermissions(
            current: 0o755, shift: 3, newReadWrite: 0b100, isDirectory: false)
        XCTAssertEqual(updated, 0o755)
        // And a non-executable file stays non-executable.
        let plain = GetInfoPanelController.updatedPermissions(
            current: 0o644, shift: 3, newReadWrite: 0b110, isDirectory: false)
        XCTAssertEqual(plain, 0o664)
    }

    func testOwnerShiftTargetsOwnerBits() {
        let updated = GetInfoPanelController.updatedPermissions(
            current: 0o644, shift: 6, newReadWrite: 0b110, isDirectory: false)
        XCTAssertEqual(updated, 0o644)  // rw already
        let readOnly = GetInfoPanelController.updatedPermissions(
            current: 0o644, shift: 6, newReadWrite: 0b100, isDirectory: false)
        XCTAssertEqual(readOnly, 0o444)
    }
}
