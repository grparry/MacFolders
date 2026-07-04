import CoreServices
import Foundation

enum FileMetadata {
    /// Finder comment via Spotlight. Queried lazily per visible cell — a
    /// per-item query at directory-load time would penalize large folders.
    static func finderComment(for url: URL) -> String {
        guard let item = MDItemCreateWithURL(nil, url as CFURL),
              let comment = MDItemCopyAttribute(item, kMDItemFinderComment) as? String
        else { return "" }
        return comment
    }
}
