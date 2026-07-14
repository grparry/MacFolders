import Foundation
import CoreServices

/// Watches one directory, firing on changes to the directory itself or its
/// direct children. FSEvents reports recursively; deeper changes are filtered
/// out so views don't refresh (and reset state) for irrelevant activity.
final class DirectoryWatcher {
    enum WatchError: LocalizedError {
        case streamCreationFailed(String)
        var errorDescription: String? {
            if case .streamCreationFailed(let path) = self {
                return "Could not watch directory: \(path)"
            }
            return nil
        }
    }

    let directoryURL: URL
    /// Recursive watchers fire for changes anywhere below the directory
    /// (flat view); non-recursive ones filter to direct children.
    let recursive: Bool
    /// Fired on the main queue.
    var onChange: (() -> Void)?
    private var stream: FSEventStreamRef?

    init(directoryURL: URL, recursive: Bool = false) {
        self.directoryURL = directoryURL
        self.recursive = recursive
    }

    deinit {
        stop()
    }

    func start() throws {
        guard stream == nil else { return }
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info, count > 0 else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            watcher.handleEvents(paths: paths)
        }
        guard let created = FSEventStreamCreate(
            nil, callback, &context,
            [directoryURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes)) else {
            throw WatchError.streamCreationFailed(directoryURL.path)
        }
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        FSEventStreamStart(created)
        stream = created
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func handleEvents(paths: [String]) {
        if recursive || isRelevant(paths: paths) { onChange?() }
    }

    /// Internal for testability: FSEvents timing/coalescing can't be asserted
    /// deterministically, but the filter itself can.
    func isRelevant(paths: [String]) -> Bool {
        let dir = directoryURL.resolvingSymlinksInPath().path
        return paths.contains { path in
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            return resolved.path == dir || resolved.deletingLastPathComponent().path == dir
        }
    }
}
