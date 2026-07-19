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

    static func urls(from info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}
