import AppKit

protocol DirectoryView: NSViewController {
    var model: DirectoryModel { get set }
    var onOpen: ((URL) -> Void)? { get set }
    var selectedURLs: [URL] { get }
    var contextMenu: NSMenu? { get set }
    /// Where directory-level actions (New Folder, Paste, Get Info fallback)
    /// apply. The column view overrides this with the clicked column.
    var activeDirectory: URL { get }
    /// Model contents changed (reload or directory event); re-render.
    func modelDidChange()
}

extension DirectoryView {
    var activeDirectory: URL { model.directoryURL }
}
