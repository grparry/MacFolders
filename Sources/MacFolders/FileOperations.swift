import Foundation

enum FileOperations {
    @discardableResult
    static func copy(_ sources: [URL], to directory: URL) throws -> [URL] {
        var results: [URL] = []
        for source in sources {
            // Name collision → Finder-style " copy" suffix instead of failing.
            let dest = nonCollidingURL(named: source.lastPathComponent, in: directory)
            try FileManager.default.copyItem(at: source, to: dest)
            results.append(dest)
        }
        return results
    }

    @discardableResult
    static func move(_ sources: [URL], to directory: URL) throws -> [URL] {
        var results: [URL] = []
        for source in sources {
            // Moving into the folder it's already in is a no-op, not a rename.
            if source.deletingLastPathComponent().standardizedFileURL
                == directory.standardizedFileURL {
                results.append(source)
                continue
            }
            // Name collision → keep both via a " copy" suffix instead of failing.
            let dest = nonCollidingURL(named: source.lastPathComponent, in: directory)
            try FileManager.default.moveItem(at: source, to: dest)
            results.append(dest)
        }
        return results
    }

    /// A destination URL in `directory` for an item named `name`: the name
    /// as-is when free, otherwise Finder's " copy", " copy 2", … suffix.
    static func nonCollidingURL(named name: String, in directory: URL) -> URL {
        let asIs = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: asIs.path) else { return asIs }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        func candidate(_ suffix: String) -> URL {
            let n = ext.isEmpty ? "\(base)\(suffix)" : "\(base)\(suffix).\(ext)"
            return directory.appendingPathComponent(n)
        }
        var dest = candidate(" copy")
        var counter = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = candidate(" copy \(counter)")
            counter += 1
        }
        return dest
    }

    @discardableResult
    static func rename(_ url: URL, to newName: String) throws -> URL {
        let dest = url.deletingLastPathComponent().appendingPathComponent(newName)
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }

    @discardableResult
    static func duplicate(_ url: URL) throws -> URL {
        // The original name is always taken (same folder), so nonCollidingURL
        // yields "<name> copy", "<name> copy 2", … just like Finder's Duplicate.
        let dest = nonCollidingURL(named: url.lastPathComponent,
                                   in: url.deletingLastPathComponent())
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    /// Finder-parity compress: a single item → "<name>.zip", multiple items
    /// → "Archive.zip", created beside the originals with numeric-suffix
    /// collision handling. Uses ditto (Archive Utility's engine) so macOS
    /// metadata and resource forks survive. Runs synchronously — callers
    /// dispatch it off the main thread. Returns the archive URL.
    @discardableResult
    static func compress(_ items: [URL]) throws -> URL {
        guard let first = items.first else {
            throw error("Nothing to compress.")
        }
        let directory = first.deletingLastPathComponent()
        let baseName = items.count == 1
            ? first.deletingPathExtension().lastPathComponent
            : "Archive"
        let dest = uniqueURL(in: directory, base: baseName, ext: "zip")

        let process = Process()
        if items.count == 1 {
            // ditto is Archive Utility's engine; --keepParent nests the item
            // under its own name, matching Finder's single-item layout, and
            // --sequesterRsrc preserves macOS metadata/resource forks.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent",
                                 first.path, dest.path]
        } else {
            // ditto archives a single source; for several items, zip run from
            // the shared parent with relative names holds each at top level
            // (Finder's Archive.zip layout) without a staging copy.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = directory
            process.arguments = ["-r", "-y", dest.path]
                + items.map { $0.lastPathComponent }
        }
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? "ditto failed"
            try? FileManager.default.removeItem(at: dest)
            throw error("Could not compress: \(message)")
        }
        return dest
    }

    private static func uniqueURL(in directory: URL, base: String, ext: String) -> URL {
        var candidate = directory.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "MacFolders", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    @discardableResult
    static func createFolder(named name: String, in directory: URL) throws -> URL {
        let dest = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
        return dest
    }

    static func trash(_ urls: [URL]) throws {
        for url in urls {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    /// Permanent removal, bypassing the Trash. Callers confirm first —
    /// there is no undo.
    static func deleteImmediately(_ urls: [URL]) throws {
        for url in urls {
            try FileManager.default.removeItem(at: url)
        }
    }
}
