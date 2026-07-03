import Foundation

enum PathRecovery {
    /// Walk up from `url` to the closest path that still exists — where a
    /// view should land when its displayed directory is moved or deleted.
    static func nearestExistingAncestor(of url: URL) -> URL {
        var candidate = url
        while candidate.path != "/",
              !FileManager.default.fileExists(atPath: candidate.path) {
            candidate = candidate.deletingLastPathComponent()
        }
        return candidate
    }
}
