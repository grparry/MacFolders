import AppKit
import UniformTypeIdentifiers

/// iCloud Drive integration. Files not downloaded locally exist on disk as
/// hidden ".name.icloud" placeholder plists; these helpers surface them as
/// real entries and trigger download/eviction.
enum CloudFiles {
    static func iCloudDriveURL() -> URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// ".Report.pdf.icloud" → "Report.pdf"; nil for anything else.
    static func materializedName(fromPlaceholder name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return nil }
        let stripped = String(name.dropFirst().dropLast(".icloud".count))
        return stripped.isEmpty ? nil : stripped
    }

    static func isPlaceholder(_ url: URL) -> Bool {
        materializedName(fromPlaceholder: url.lastPathComponent) != nil
    }

    /// The eventual file's size, recorded inside the placeholder plist.
    static func placeholderSize(at url: URL) -> Int64? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, format: nil) as? [String: Any] else { return nil }
        return (plist["NSURLFileSizeKey"] as? NSNumber)?.int64Value
    }

    static func startDownload(itemAt url: URL) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    static func evict(itemAt url: URL) throws {
        try FileManager.default.evictUbiquitousItem(at: url)
    }

    /// Downloaded item stored in iCloud (eviction candidate).
    static func isEvictable(_ url: URL) -> Bool {
        !isPlaceholder(url) && FileManager.default.isUbiquitousItem(at: url)
    }
}

extension FileItem {
    /// Placeholders have no real file to derive an icon from; use the type
    /// the materialized name implies.
    var icon: NSImage {
        guard isCloudPlaceholder else {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        let ext = (name as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }
}
