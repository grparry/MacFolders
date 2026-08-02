import AppKit

/// Shared Trash operations, used by both the sidebar Trash location and the
/// content view when a Trash tab is open.
enum Trash {
    static let homeURL = FileManager.default.urls(
        for: .trashDirectory, in: .userDomainMask)[0]

    /// Finder's Trash is several trashes merged: the home trash, iCloud
    /// Drive's ".Trash" (Recently Deleted), and each volume's ".Trashes/uid".
    static func directories() -> [URL] {
        var dirs = [homeURL]
        if let icloud = CloudFiles.iCloudDriveURL() {
            let cloudTrash = icloud.appendingPathComponent(".Trash")
            if FileManager.default.fileExists(atPath: cloudTrash.path) {
                dirs.append(cloudTrash)
            }
        }
        let uid = getuid()
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: [.skipHiddenVolumes]) ?? []
        for volume in volumes where volume.path != "/" {
            let volumeTrash = volume.appendingPathComponent(".Trashes/\(uid)")
            if FileManager.default.fileExists(atPath: volumeTrash.path) {
                dirs.append(volumeTrash)
            }
        }
        return dirs
    }

    /// True when `url` is the browsable home Trash (what a Trash tab shows).
    static func isTrashLocation(_ url: URL) -> Bool {
        url.standardizedFileURL.path == homeURL.standardizedFileURL.path
    }

    /// Confirmed empty-trash flow (presents its own alerts). Returns true if
    /// items were erased, so the caller can refresh its UI. Read errors
    /// surface — a permission failure must never masquerade as an empty trash.
    @discardableResult
    static func empty() -> Bool {
        var items: [URL] = []
        for dir in directories() {
            do {
                items += try FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil)
            } catch {
                NSAlert(error: error).runModal()
                return false
            }
        }
        guard !items.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "The Trash is already empty."
            alert.runModal()
            return false
        }
        let alert = NSAlert()
        alert.messageText = "Empty the Trash?"
        alert.informativeText = items.count == 1
            ? "1 item will be permanently erased. This cannot be undone."
            : "\(items.count) items will be permanently erased. This cannot be undone."
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        do {
            for item in items {
                try FileManager.default.removeItem(at: item)
            }
        } catch {
            NSAlert(error: error).runModal()
        }
        return true
    }
}
