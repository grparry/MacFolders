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
        // Owned by another user (commonly root, for anything installed with
        // admin rights) — a user-level delete can't remove it no matter what,
        // and no process is involved. Checked first: it's the real cause even
        // when nothing holds the item.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let owner = attrs[.ownerAccountID] as? NSNumber,
           owner.uint32Value != getuid() {
            let who = attrs[.ownerAccountName] as? String ?? "user \(owner.uint32Value)"
            return "owned by \(who) — needs administrator privileges to delete "
                + "(quit any running copy, then in Terminal: "
                + "sudo rm -rf \"\(url.path)\")"
        }
        guard url.pathExtension == "app" else { return error.localizedDescription }
        let holders = holdingProcesses(of: url)
        if !holders.isEmpty {
            var list = holders.prefix(6)
                .map { "\($0.name) (pid \($0.pid))" }
                .joined(separator: ", ")
            if holders.count > 6 { list += ", and \(holders.count - 6) more" }
            return "still in use by \(list) — quit it, then empty the Trash again"
        }
        return "still in use — quit the app and any background helper it left "
            + "running, then empty the Trash again"
    }

    /// Processes holding files open inside `url` (via lsof), so the report can
    /// name the exact pid — including background helpers that aren't listed as
    /// running applications.
    private static func holdingProcesses(of url: URL) -> [(pid: Int32, name: String)] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        // +c0: full command names (default truncates to 9 chars).
        // -F: machine-readable pid (p) + command (c) fields.
        task.arguments = ["+c0", "-Fpc", "+D", url.path]
        let out = Pipe()
        task.standardOutput = out
        // nullDevice, not an undrained Pipe: lsof's permission warnings could
        // otherwise fill the stderr buffer and deadlock waitUntilExit.
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var result: [(pid: Int32, name: String)] = []
        var pid: Int32?
        for line in text.split(separator: "\n") {
            let value = line.dropFirst()
            switch line.first {
            case "p": pid = Int32(value)
            case "c":
                if let pid, !result.contains(where: { $0.pid == pid }) {
                    result.append((pid, String(value)))
                }
            default: break
            }
        }
        return result
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
