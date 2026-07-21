import AppKit

enum DropBehavior {

    /// Finder semantics: same volume → move; different volume → copy; Option always copies.
    private static func desired(for sources: [URL], destination: URL) -> NSDragOperation {
        if NSEvent.modifierFlags.contains(.option) { return .copy }
        guard let sourceVolume = try? sources.first?
                .resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
              let destVolume = try? destination
                .resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier else {
            return .copy
        }
        return sourceVolume.isEqual(destVolume) ? .move : .copy
    }

    /// Hover-time check that file URLs are on the drag pasteboard WITHOUT
    /// reading them — cross-app drag content is privacy-restricted until the
    /// actual drop, and a content read during hover comes back empty, which
    /// made every external drag validate as refusable.
    static func canAcceptFileDrop(_ info: NSDraggingInfo) -> Bool {
        info.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || hasPromises(info)
    }

    /// Hover-time operation from the source's mask alone (no content reads).
    /// .generic defers Finder semantics to drop time.
    static func hoverOperation(_ info: NSDraggingInfo) -> NSDragOperation {
        let mask = info.draggingSourceOperationMask
        if NSEvent.modifierFlags.contains(.option), mask.contains(.copy) { return .copy }
        if mask.contains(.generic) { return .generic }
        if mask.contains(.move) { return .move }
        if mask.contains(.copy) { return .copy }
        return []
    }

    /// The Finder-semantic operation clamped to what the DRAG SOURCE allows.
    /// Our own drags offer move+copy, but external sources (Finder, Mail,
    /// browsers) each offer their own mask — returning an operation outside
    /// it makes AppKit refuse the drop entirely, which is why inter-app
    /// drags dead-ended.
    static func operation(for sources: [URL], destination: URL,
                          info: NSDraggingInfo) -> NSDragOperation {
        let wanted = desired(for: sources, destination: destination)
        let mask = info.draggingSourceOperationMask
        if mask.contains(wanted) { return wanted }
        if mask.contains(.copy) { return .copy }
        if mask.contains(.generic) { return .generic }
        if mask.contains(.move) { return .move }
        return []
    }

    static func perform(_ operation: NSDragOperation, sources: [URL], destination: URL) -> Bool {
        // .generic carries Finder semantics: the source deferred the choice.
        let moves = operation.contains(.move)
            || (operation.contains(.generic)
                && desired(for: sources, destination: destination) == .move)
        do {
            if moves {
                try FileOperations.move(sources, to: destination)
            } else {
                try FileOperations.copy(sources, to: destination)
            }
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    /// Types every drop surface should register: real file URLs plus file
    /// promises (browsers, Mail, Photos — the file exists only on request).
    /// The legacy promise type (kPasteboardTypeFileURLPromise) is NOT in
    /// NSFilePromiseReceiver.readableDraggedTypes, but Mail still vends it —
    /// without registering it, Mail drags never reach our views at all.
    static let legacyPromiseType =
        NSPasteboard.PasteboardType(kPasteboardTypeFileURLPromise as String)

    static var registeredTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, legacyPromiseType] + NSFilePromiseReceiver.readableDraggedTypes
            .map { NSPasteboard.PasteboardType($0) }
    }

    static func hasPromises(_ info: NSDraggingInfo) -> Bool {
        info.draggingPasteboard.canReadObject(
            forClasses: [NSFilePromiseReceiver.self], options: nil)
            || info.draggingPasteboard.types?.contains(legacyPromiseType) == true
    }

    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// Materialize promised files into the destination (always a copy-in —
    /// the promiser writes fresh files). Errors surface per file.
    static func receivePromises(from info: NSDraggingInfo,
                                destination: URL) -> Bool {
        let receivers = (info.draggingPasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self], options: nil)
            as? [NSFilePromiseReceiver]) ?? []
        guard !receivers.isEmpty else {
            // Legacy-only source (Mail): the old receive API is the only
            // door such sources answer — it directs them to write into the
            // destination and returns the promised names.
            guard info.draggingPasteboard.types?.contains(legacyPromiseType) == true
            else { return false }
            let names = info.namesOfPromisedFilesDropped(atDestination: destination) ?? []
            return !names.isEmpty
        }
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: destination, options: [:],
                                          operationQueue: promiseQueue) { _, error in
                if let error {
                    DispatchQueue.main.async {
                        NSAlert(error: error).runModal()
                    }
                }
            }
        }
        return true
    }

    static func urls(from info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}
