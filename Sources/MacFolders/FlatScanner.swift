import Foundation

/// Recursive walker behind flat view: streams every file under a root that
/// passes the folder's filters, and pauses itself at the app-wide threshold
/// instead of guessing costs up front (counting would be as expensive as
/// the scan).
final class FlatScanner {
    enum Event {
        case batch([FileItem])
        case paused(matchedSoFar: Int)
        case finished(total: Int)
    }

    /// Main-queue events.
    var onEvent: ((Event) -> Void)?

    /// Folder-name patterns the walk refuses to descend into when the
    /// folder's skip toggle is on. App-wide, user-editable, glob-matched
    /// (fnmatch) — ".*" covers every dot-directory.
    static let defaultSkipPatterns = [".*", "node_modules"]

    static var skipPatterns: [String] {
        get {
            UserDefaults.standard.stringArray(forKey: "flatSkipPatterns")
                ?? defaultSkipPatterns
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "flatSkipPatterns")
        }
    }

    static func shouldSkip(directoryName name: String) -> Bool {
        skipPatterns.contains { fnmatch($0, name, 0) == 0 }
    }

    static var pauseThreshold: Int {
        let value = UserDefaults.standard.integer(forKey: "flatPauseThreshold")
        return value > 0 ? value : 50_000
    }

    private var generation = 0
    private let resumeGate = DispatchSemaphore(value: 0)
    private var awaitingResume = false

    func scan(root: URL, config: FlatViewConfig) {
        cancel()
        let expected = generation
        let threshold = Self.pauseThreshold
        let cutoff: Date? = config.modifiedWithinDays > 0
            ? Calendar.current.date(byAdding: .day, value: -config.modifiedWithinDays,
                                    to: Date()) : nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey,
                                          .contentModificationDateKey,
                                          .contentTypeKey, .isHiddenKey]
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants])
            var batch: [FileItem] = []
            var matched = 0
            var lastFlush = Date()
            var pausesUsed = 0
            while let url = enumerator?.nextObject() as? URL {
                guard let self, self.generation == expected else { return }
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isDirectory == true {
                    if config.skipDotTrees,
                       Self.shouldSkip(directoryName: url.lastPathComponent) {
                        enumerator?.skipDescendants()
                    }
                    continue
                }
                let size = Int64(values.fileSize ?? 0)
                if size < config.minSizeBytes { continue }
                let modified = values.contentModificationDate ?? .distantPast
                if let cutoff, modified < cutoff { continue }
                batch.append(FileItem(
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: false,
                    size: size,
                    dateModified: modified,
                    kind: values.contentType?.localizedDescription ?? "Document"))
                matched += 1
                if batch.count >= 200
                    || (!batch.isEmpty && Date().timeIntervalSince(lastFlush) > 0.3) {
                    self.emit(.batch(batch), expected: expected)
                    batch = []
                    lastFlush = Date()
                }
                if matched >= threshold * (pausesUsed + 1) {
                    self.emit(.batch(batch), expected: expected)
                    batch = []
                    self.emit(.paused(matchedSoFar: matched), expected: expected)
                    self.awaitingResume = true
                    self.resumeGate.wait()
                    self.awaitingResume = false
                    guard self.generation == expected else { return }
                    pausesUsed += 1
                }
            }
            guard let self, self.generation == expected else { return }
            self.emit(.batch(batch), expected: expected)
            self.emit(.finished(total: matched), expected: expected)
        }
    }

    /// Continue past a threshold pause.
    func resume() {
        guard awaitingResume else { return }
        resumeGate.signal()
    }

    func cancel() {
        generation += 1
        if awaitingResume {
            resumeGate.signal()   // release the worker so it can observe cancellation
        }
    }

    private func emit(_ event: Event, expected: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == expected else { return }
            if case .batch(let items) = event, items.isEmpty { return }
            self.onEvent?(event)
        }
    }
}
