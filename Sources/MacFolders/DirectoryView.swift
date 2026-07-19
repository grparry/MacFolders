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
    /// Scroll position captured into / restored from workspace state.
    /// Vertical for list and icon views; horizontal for columns.
    var persistedScrollOffset: CGFloat { get set }
    /// Re-select these items on restore. Views that can't (columns, where
    /// selection IS the navigation chain) use the no-op default.
    func applySelection(_ urls: Set<URL>)
    /// Put the item's name into inline edit (New Folder flow). Views
    /// without inline editing use the no-op default.
    func beginRenaming(_ url: URL)
}

extension DirectoryView {
    func applySelection(_ urls: Set<URL>) {}
    func beginRenaming(_ url: URL) {}
}

extension DirectoryView {
    var activeDirectory: URL { model.directoryURL }
}
