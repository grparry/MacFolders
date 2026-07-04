import Foundation

enum SearchMode: Int {
    case name, contents
}

enum SearchScope: Int {
    case folder, computer
}

/// Two strategies behind one interface: folder-scoped name search walks the
/// filesystem directly (finds dotfiles and unindexed trees Spotlight never
/// sees); everything else — content search, whole-computer scope — uses the
/// Spotlight index via NSMetadataQuery, the only sane way to search text or
/// a whole disk.
final class SearchEngine {
    /// Batches accumulate in the caller; isComplete true on the final batch.
    /// Always called on the main queue.
    var onResults: (([URL], _ isComplete: Bool) -> Void)?
    static let resultCap = 2000

    private var generation = 0
    private var metadataQuery: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []

    func search(term: String, mode: SearchMode, scope: SearchScope, folder: URL) {
        cancel()
        guard !term.isEmpty else {
            onResults?([], true)
            return
        }
        if mode == .name, scope == .folder {
            walk(folder: folder, term: term)
        } else {
            spotlight(term: term, mode: mode, scope: scope, folder: folder)
        }
    }

    func cancel() {
        generation += 1
        metadataQuery?.stop()
        metadataQuery = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private func walk(folder: URL, term: String) {
        let expected = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var batch: [URL] = []
            var total = 0
            var lastFlush = Date()
            let enumerator = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [],
                options: [.skipsPackageDescendants])
            while let url = enumerator?.nextObject() as? URL {
                guard let self, self.generation == expected else { return }
                if url.lastPathComponent.localizedCaseInsensitiveContains(term) {
                    batch.append(url)
                    total += 1
                    if total >= Self.resultCap {
                        self.flush(batch, complete: true, expected: expected)
                        return
                    }
                }
                if batch.count >= 50
                    || (!batch.isEmpty && Date().timeIntervalSince(lastFlush) > 0.25) {
                    self.flush(batch, complete: false, expected: expected)
                    batch = []
                    lastFlush = Date()
                }
            }
            self?.flush(batch, complete: true, expected: expected)
        }
    }

    private func flush(_ urls: [URL], complete: Bool, expected: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == expected else { return }
            self.onResults?(urls, complete)
        }
    }

    private func spotlight(term: String, mode: SearchMode,
                           scope: SearchScope, folder: URL) {
        let query = NSMetadataQuery()
        query.searchScopes = scope == .computer
            ? [NSMetadataQueryLocalComputerScope] : [folder]
        switch mode {
        case .name:
            query.predicate = NSPredicate(
                format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*\(term)*")
        case .contents:
            query.predicate = NSPredicate(
                format: "kMDItemTextContent CONTAINS[cd] %@", term)
        }
        query.operationQueue = .main
        let expected = generation
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query, queue: .main) { [weak self] _ in
            guard let self, self.generation == expected else { return }
            query.disableUpdates()
            query.stop()
            var urls: [URL] = []
            for index in 0..<min(query.resultCount, Self.resultCap) {
                if let item = query.result(at: index) as? NSMetadataItem,
                   let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                    urls.append(URL(fileURLWithPath: path))
                }
            }
            self.onResults?(urls, true)
        })
        metadataQuery = query
        query.start()
    }
}
