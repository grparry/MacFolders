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

    static func isInICloudContainer(_ url: URL) -> Bool {
        url.path.contains("/Library/Mobile Documents/")
    }

    /// The on-disk flag Finder's "Keep Downloaded" writes. There is no
    /// public API for iCloud pinning; this is the one non-public mechanism
    /// in the codebase. The "#P" suffix marks the xattr for File Provider
    /// propagation.
    private static let pinnedXattr = "com.apple.fileprovider.pinned#P"

    static func isPinned(_ url: URL) -> Bool {
        getxattr(url.path, pinnedXattr, nil, 0, 0, 0) > 0
    }

    static func setPinned(_ pinned: Bool, itemAt url: URL) throws {
        if pinned {
            let value: [UInt8] = Array("1".utf8)
            guard setxattr(url.path, pinnedXattr, value, value.count, 0, 0) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                              userInfo: [NSLocalizedDescriptionKey:
                                "Could not pin \(url.lastPathComponent): "
                                + String(cString: strerror(errno))])
            }
            // Keeping downloaded implies being downloaded.
            if needsDownload(url) { try startDownload(itemAt: url) }
        } else {
            guard removexattr(url.path, pinnedXattr, 0) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                              userInfo: [NSLocalizedDescriptionKey:
                                "Could not unpin \(url.lastPathComponent): "
                                + String(cString: strerror(errno))])
            }
        }
    }

    static func isInICloud(_ url: URL) -> Bool {
        isPlaceholder(url) || FileManager.default.isUbiquitousItem(at: url)
    }

    static func startDownload(itemAt url: URL) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    static func evict(itemAt url: URL) throws {
        try FileManager.default.evictUbiquitousItem(at: url)
    }

    /// iCloud item not resident on disk (legacy placeholder or modern
    /// File Provider dataless file).
    static func needsDownload(_ url: URL) -> Bool {
        if isPlaceholder(url) { return true }
        let values = try? url.resourceValues(
            forKeys: [.ubiquitousItemDownloadingStatusKey])
        return values?.ubiquitousItemDownloadingStatus == .notDownloaded
    }

    /// Resident iCloud item (eviction candidate).
    static func isEvictable(_ url: URL) -> Bool {
        guard !isPlaceholder(url),
              FileManager.default.isUbiquitousItem(at: url) else { return false }
        let values = try? url.resourceValues(
            forKeys: [.ubiquitousItemDownloadingStatusKey])
        return values?.ubiquitousItemDownloadingStatus != .notDownloaded
    }
}

extension FileItem {
    /// Legacy placeholders have no real file to derive an icon from; use the
    /// type the materialized name implies. Dataless items have real paths.
    var icon: NSImage {
        guard isLegacyCloudPlaceholder else {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        let ext = (name as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }
}
