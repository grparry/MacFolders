import Foundation
import UniformTypeIdentifiers

enum CloudStatus: Equatable {
    case notCloud       // ordinary local file
    case inCloudOnly    // iCloud file not downloaded (a ".name.icloud" placeholder)
    case downloaded     // iCloud file resident on disk
}

struct FileItem: Equatable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let dateModified: Date
    let kind: String
    var cloudStatus = CloudStatus.notCloud
    /// url points at the ".name.icloud" placeholder; name is the real file's.
    var isCloudPlaceholder: Bool { cloudStatus == .inCloudOnly }
}

enum SortKey: String, Codable {
    case name, dateModified, size, kind
}

final class DirectoryModel {
    let directoryURL: URL
    var showHidden = false
    var sortKey: SortKey = .name
    var ascending = true
    private(set) var items: [FileItem] = []
    /// Fired on the main queue when the watched directory changes.
    /// The owner reloads and re-renders.
    var onDirectoryChanged: (() -> Void)?
    private var watcher: DirectoryWatcher?

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    func reload() throws {
        items = try items(of: directoryURL)
    }

    /// Lists any directory with this model's hidden-files and sort settings.
    /// Used for the root (reload) and for expanded subfolders in list view.
    func items(of url: URL) throws -> [FileItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey,
                                      .contentModificationDateKey, .contentTypeKey,
                                      .isHiddenKey]
        // Hidden files are filtered manually (not via .skipsHiddenFiles)
        // because undownloaded iCloud files are hidden ".name.icloud"
        // placeholders that must surface as visible entries.
        let urls = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [])
        var loaded: [FileItem] = []
        for url in urls {
            let values = try url.resourceValues(forKeys: Set(keys))
            if let realName = CloudFiles.materializedName(
                fromPlaceholder: url.lastPathComponent) {
                let ext = (realName as NSString).pathExtension
                loaded.append(FileItem(
                    url: url,
                    name: realName,
                    isDirectory: false,
                    size: CloudFiles.placeholderSize(at: url) ?? 0,
                    dateModified: values.contentModificationDate ?? .distantPast,
                    kind: UTType(filenameExtension: ext)?.localizedDescription
                        ?? "Document",
                    cloudStatus: .inCloudOnly))
                continue
            }
            if !showHidden, values.isHidden == true { continue }
            let isDirectory = values.isDirectory ?? false
            // Only iCloud locations pay for the per-item ubiquity check.
            let cloudStatus: CloudStatus = CloudFiles.isInICloudContainer(url)
                && FileManager.default.isUbiquitousItem(at: url)
                ? .downloaded : .notCloud
            loaded.append(FileItem(
                url: url,
                name: url.lastPathComponent,
                isDirectory: isDirectory,
                size: Int64(values.fileSize ?? 0),
                dateModified: values.contentModificationDate ?? .distantPast,
                kind: values.contentType?.localizedDescription
                    ?? (isDirectory ? "Folder" : "Document"),
                cloudStatus: cloudStatus))
        }
        return sorted(loaded)
    }

    private func sorted(_ items: [FileItem]) -> [FileItem] {
        let result: [FileItem]
        switch sortKey {
        case .name:
            result = items.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case .dateModified:
            result = items.sorted { $0.dateModified < $1.dateModified }
        case .size:
            result = items.sorted { $0.size < $1.size }
        case .kind:
            result = items.sorted {
                $0.kind.localizedStandardCompare($1.kind) == .orderedAscending
            }
        }
        return ascending ? result : result.reversed()
    }

    func startWatching() throws {
        guard watcher == nil else { return }
        let created = DirectoryWatcher(directoryURL: directoryURL)
        created.onChange = { [weak self] in self?.onDirectoryChanged?() }
        try created.start()
        watcher = created
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
    }
}
