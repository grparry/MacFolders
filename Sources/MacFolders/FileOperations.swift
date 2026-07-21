import Foundation

enum FileOperations {
    @discardableResult
    static func copy(_ sources: [URL], to directory: URL) throws -> [URL] {
        var results: [URL] = []
        for source in sources {
            let dest = directory.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: dest)
            results.append(dest)
        }
        return results
    }

    @discardableResult
    static func move(_ sources: [URL], to directory: URL) throws -> [URL] {
        var results: [URL] = []
        for source in sources {
            let dest = directory.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: dest)
            results.append(dest)
        }
        return results
    }

    @discardableResult
    static func rename(_ url: URL, to newName: String) throws -> URL {
        let dest = url.deletingLastPathComponent().appendingPathComponent(newName)
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }

    @discardableResult
    static func duplicate(_ url: URL) throws -> URL {
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        func candidate(_ suffix: String) -> URL {
            let name = ext.isEmpty ? "\(base)\(suffix)" : "\(base)\(suffix).\(ext)"
            return dir.appendingPathComponent(name)
        }
        var dest = candidate(" copy")
        var counter = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = candidate(" copy \(counter)")
            counter += 1
        }
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
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
