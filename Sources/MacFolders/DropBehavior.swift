import AppKit

enum DropBehavior {
    /// Finder semantics: same volume → move; different volume → copy; Option always copies.
    static func operation(for sources: [URL], destination: URL) -> NSDragOperation {
        if NSEvent.modifierFlags.contains(.option) { return .copy }
        guard let sourceVolume = try? sources.first?
                .resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
              let destVolume = try? destination
                .resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier else {
            return .copy
        }
        return sourceVolume.isEqual(destVolume) ? .move : .copy
    }

    static func perform(_ operation: NSDragOperation, sources: [URL], destination: URL) -> Bool {
        do {
            if operation == .move {
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
