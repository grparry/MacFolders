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

    /// A human, actionable reason a trashed item couldn't be deleted. An app
    /// bundle whose executables are still mapped by a running process can't be
    /// removed — common when an app is trashed while running, or when it left
    /// a login-item / SMAppService helper running from inside the bundle.
    private static func reason(for url: URL, error: Error) -> String {
        guard url.pathExtension == "app" else { return error.localizedDescription }
        let path = url.standardizedFileURL.path
        let running = NSWorkspace.shared.runningApplications.contains {
            guard let b = $0.bundleURL?.standardizedFileURL.path else { return false }
            return b == path || b.hasPrefix(path + "/")
        }
        return running
            ? "still running — quit it, then empty the Trash again"
            : "still in use — quit the app and any background helper it left "
                + "running, then empty the Trash again"
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
        // Delete every item; a failure on one (e.g. a permission error on a
        // System-managed item) must not abort the rest. Failures are still
        // surfaced — collected and reported, never swallowed.
        var failures: [(name: String, reason: String)] = []
        for item in items {
            do {
                try FileManager.default.removeItem(at: item)
            } catch {
                failures.append((item.lastPathComponent, reason(for: item, error: error)))
            }
        }
        if !failures.isEmpty {
            let report = NSAlert()
            report.messageText = failures.count == 1
                ? "1 item couldn't be deleted; the rest of the Trash was emptied."
                : "\(failures.count) items couldn't be deleted; the rest of the Trash was emptied."
            report.informativeText = failures.prefix(8)
                .map { "\($0.name): \($0.reason)" }
                .joined(separator: "\n")
            report.runModal()
        }
        return true
    }
}
