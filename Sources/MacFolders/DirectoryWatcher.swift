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

    /// Posted after MacFolders itself changes the filesystem. userInfo
    /// carries the touched item URLs (created, removed, and moved-from/to).
    /// Every running watcher matches them and fires directly, so in-app
    /// operations never wait on FSEvents delivery — which is asynchronous
    /// and stalls entirely when fseventsd is unhealthy. External changes
    /// still arrive via FSEvents.
    static let localChange = Notification.Name("MacFoldersLocalChange")
    static let touchedItemsKey = "items"

    /// Announce items this process just created, removed, or moved.
    /// Safe from any thread; delivery is on the main queue.
    static func noteLocalChange(_ items: [URL]) {
        guard !items.isEmpty else { return }
        let post = {
            NotificationCenter.default.post(name: localChange, object: nil,
                                            userInfo: [touchedItemsKey: items])
        }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }

    let directoryURL: URL
    /// Recursive watchers fire for changes anywhere below the directory
    /// (flat view); non-recursive ones filter to direct children.
    let recursive: Bool
    /// Fired on the main queue.
    var onChange: (() -> Void)?
    private var stream: FSEventStreamRef?
    private var localObserver: NSObjectProtocol?

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
        localObserver = NotificationCenter.default.addObserver(
            // queue nil = run synchronously on the posting thread, which
            // noteLocalChange guarantees is main.
            forName: Self.localChange, object: nil, queue: nil) { [weak self] note in
            guard let self,
                  let items = note.userInfo?[Self.touchedItemsKey] as? [URL],
                  self.isAffected(byLocalChangeTo: items) else { return }
            self.onChange?()
        }
    }

    func stop() {
        if let localObserver {
            NotificationCenter.default.removeObserver(localObserver)
            self.localObserver = nil
        }
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

    /// Whether an in-app change to `items` alters this watcher's listing:
    /// an item directly inside the directory (anywhere below it, when
    /// recursive), or the directory itself / an ancestor moved or removed
    /// (so the owner notices the vanish). Parents are resolved rather than
    /// the items, which may no longer exist.
    func isAffected(byLocalChangeTo items: [URL]) -> Bool {
        let dir = directoryURL.resolvingSymlinksInPath().path
        return items.contains { item in
            let parent = item.deletingLastPathComponent().resolvingSymlinksInPath().path
            let path = (parent as NSString).appendingPathComponent(item.lastPathComponent)
            return parent == dir || path == dir || dir.hasPrefix(path + "/")
                || (recursive && parent.hasPrefix(dir + "/"))
        }
    }
}
