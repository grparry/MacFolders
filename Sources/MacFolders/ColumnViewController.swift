import AppKit

/// Flipped container so columns lay out top-left in the horizontal scroller.
final class ColumnsContainerView: NSView {
    override var isFlipped: Bool { true }
}

/// One Miller column's table. Right-click selects the clicked row (like the
/// other views); left/right arrows navigate between columns.
final class ColumnTableView: NSTableView {
    var onNavigateLeft: (() -> Void)?
    var onNavigateRight: (() -> Void)?
    var onMenuOpen: (() -> Void)?
    var onPlainClick: (() -> Void)?
    /// True while a fresh press is being disambiguated (drag vs click) —
    /// the controller must not react to the transient selection.
    private(set) var suppressChainSync = false
    /// Set by the data source when a dragging session actually begins.
    var dragBegan = false

    /// Press-drag is not press-select: a drag from an unselected row must not
    /// change selection or navigate. Selection commits only when the press
    /// resolves as a click (release without drag).
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        let freshPress = row >= 0 && !selectedRowIndexes.contains(row)
            && event.modifierFlags.intersection([.command, .shift]).isEmpty
        guard freshPress else {
            super.mouseDown(with: event)
            return
        }
        let previousSelection = selectedRowIndexes
        dragBegan = false
        suppressChainSync = true
        super.mouseDown(with: event)  // returns once the press resolves
        if dragBegan {
            // Drag: put selection back the way it was; nothing navigates.
            selectRowIndexes(previousSelection, byExtendingSelection: false)
            suppressChainSync = false
        } else {
            // Click: keep the new selection and let the chain react now.
            suppressChainSync = false
            onPlainClick?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        if clicked >= 0, !selectedRowIndexes.contains(clicked) {
            selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }
        onMenuOpen?()
        return super.menu(for: event)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onNavigateLeft?()   // ←
        case 124: onNavigateRight?()  // →
        default: super.keyDown(with: event)
        }
    }
}

/// Miller columns built from NSTableViews. NSBrowser's drag-and-drop
/// machinery is broken (drop proposals pin to the drag origin, drops select
/// the target, matrices swallow tracking), so each column is a plain table —
/// the same native drop behavior the list view has: live hover highlighting
/// from any direction, accent drop ring distinct from selection, and moves
/// only at the release point.
final class ColumnViewController: NSViewController, DirectoryView,
    NSTableViewDataSource, NSTableViewDelegate {

    var model: DirectoryModel {
        didSet { if isViewLoaded { resetChain() } }
    }
    var onOpen: ((URL) -> Void)?
    var contextMenu: NSMenu? {
        didSet {
            for column in columns { column.table.menu = contextMenu }
        }
    }

    private struct Column {
        let url: URL
        var items: [FileItem]
        let table: ColumnTableView
        let scroll: NSScrollView
        let watcher: DirectoryWatcher?
    }

    private var columns: [Column] = []
    private let horizontalScroll = NSScrollView()
    private let columnsContainer = ColumnsContainerView()
    private var isRebuilding = false
    private var activeColumnIndex = 0
    private static let columnWidth: CGFloat = 210

    /// The directory file actions (New Folder, Paste, Get Info fallback)
    /// apply to: the column the user last interacted with.
    var activeDirectory: URL {
        columns.indices.contains(activeColumnIndex)
            ? columns[activeColumnIndex].url : model.directoryURL
    }

    init(model: DirectoryModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    var selectedURLs: [URL] {
        for column in columns.reversed() {
            let rows = column.table.selectedRowIndexes
            if !rows.isEmpty {
                return rows.compactMap {
                    column.items.indices.contains($0) ? column.items[$0].url : nil
                }
            }
        }
        return []
    }

    override func loadView() {
        view = horizontalScroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        horizontalScroll.documentView = columnsContainer
        horizontalScroll.hasHorizontalScroller = true
        horizontalScroll.hasVerticalScroller = false
        resetChain()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutColumns()
    }

    /// Deterministic frame-based layout: column 0 always starts at x = 0, so
    /// scrolling fully left always reveals it completely.
    private func layoutColumns() {
        let height = horizontalScroll.contentSize.height
        var x: CGFloat = 0
        for column in columns {
            column.scroll.frame = NSRect(x: x, y: 0, width: Self.columnWidth, height: height)
            x += Self.columnWidth + 1
        }
        columnsContainer.setFrameSize(
            NSSize(width: max(x, horizontalScroll.contentSize.width), height: height))
    }


    var persistedScrollOffset: CGFloat {
        get { horizontalScroll.contentView.bounds.origin.x }
        set {
            var origin = horizontalScroll.contentView.bounds.origin
            origin.x = newValue
            horizontalScroll.contentView.scroll(to: origin)
            horizontalScroll.reflectScrolledClipView(horizontalScroll.contentView)
        }
    }

    func modelDidChange() {
        guard isViewLoaded, !columns.isEmpty else { return }
        refreshColumn(at: 0)
    }

    // MARK: Column chain

    private func resetChain() {
        isRebuilding = true
        for column in columns {
            column.watcher?.stop()
            column.scroll.removeFromSuperview()
        }
        columns = []
        activeColumnIndex = 0
        appendColumn(for: model.directoryURL, isRoot: true)
        isRebuilding = false
    }

    private func appendColumn(for url: URL, isRoot: Bool) {
        let table = ColumnTableView()
        let tableColumn = NSTableColumn(identifier: .init("name"))
        tableColumn.width = Self.columnWidth - 18
        table.addTableColumn(tableColumn)
        table.headerView = nil
        table.rowHeight = 22
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(columnClicked(_:))
        table.doubleAction = #selector(doubleClicked(_:))
        table.menu = contextMenu
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.onNavigateLeft = { [weak self, weak table] in
            guard let self, let table else { return }
            self.focusColumn(before: table)
        }
        table.onNavigateRight = { [weak self, weak table] in
            guard let self, let table else { return }
            self.focusColumn(after: table)
        }
        table.onMenuOpen = { [weak self, weak table] in
            guard let self, let table else { return }
            self.activeColumnIndex = table.tag
        }
        table.onPlainClick = { [weak self, weak table] in
            guard let self, let table else { return }
            self.activeColumnIndex = table.tag
            self.syncChain(for: table)
        }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true

        let items: [FileItem]
        if isRoot {
            items = model.items
        } else {
            do { items = try model.items(of: url) } catch {
                NSAlert(error: error).runModal()
                return
            }
        }

        var watcher: DirectoryWatcher?
        if !isRoot {
            // The root is watched by DirectoryModel; deeper columns watch
            // themselves so every open column live-updates.
            let created = DirectoryWatcher(directoryURL: url)
            created.onChange = { [weak self] in self?.refreshColumn(url: url) }
            do {
                try created.start()
                watcher = created
            } catch {
                NSAlert(error: error).runModal()
            }
        }

        columns.append(Column(url: url, items: items, table: table,
                              scroll: scroll, watcher: watcher))
        table.tag = columns.count - 1
        columnsContainer.addSubview(scroll)
        table.reloadData()
        scrollToRightEdge()
    }

    private func truncateColumns(after depth: Int) {
        guard depth + 1 < columns.count else { return }
        for column in columns[(depth + 1)...] {
            column.watcher?.stop()
            column.scroll.removeFromSuperview()
        }
        columns.removeLast(columns.count - depth - 1)
        activeColumnIndex = min(activeColumnIndex, columns.count - 1)
        layoutColumns()
    }

    private func refreshColumn(url: URL) {
        guard let index = columns.firstIndex(where: { $0.url == url }) else { return }
        refreshColumn(at: index)
    }

    private func refreshColumn(at index: Int) {
        guard columns.indices.contains(index) else { return }
        let column = columns[index]
        // The column's own directory vanished (moved/deleted): prune it and
        // everything deeper — its parent column's refresh handles the rest.
        if index > 0, !FileManager.default.fileExists(atPath: column.url.path) {
            truncateColumns(after: index - 1)
            return
        }
        let fresh: [FileItem]
        if index == 0 {
            fresh = model.items
        } else {
            do { fresh = try model.items(of: column.url) } catch {
                NSAlert(error: error).runModal()
                return
            }
        }
        let selected = Set(column.table.selectedRowIndexes.compactMap {
            column.items.indices.contains($0) ? column.items[$0].url : nil
        })
        columns[index].items = fresh
        isRebuilding = true
        column.table.reloadData()
        let restore = IndexSet(fresh.indices.filter { selected.contains(fresh[$0].url) })
        column.table.selectRowIndexes(restore, byExtendingSelection: false)
        isRebuilding = false
        // If the folder feeding a deeper column vanished, prune it.
        if columns.indices.contains(index + 1),
           !fresh.contains(where: { $0.url == columns[index + 1].url }) {
            truncateColumns(after: index)
        }
    }

    private func focusColumn(before table: NSTableView) {
        guard table.tag > 0 else { return }
        view.window?.makeFirstResponder(columns[table.tag - 1].table)
    }

    private func focusColumn(after table: NSTableView) {
        let next = table.tag + 1
        guard columns.indices.contains(next) else { return }
        let nextTable = columns[next].table
        if nextTable.selectedRowIndexes.isEmpty, columns[next].items.isEmpty == false {
            nextTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        view.window?.makeFirstResponder(nextTable)
    }

    private func scrollToRightEdge() {
        layoutColumns()
        let x = max(0, columnsContainer.frame.width - horizontalScroll.contentSize.width)
        horizontalScroll.contentView.scroll(to: NSPoint(x: x, y: 0))
        horizontalScroll.reflectScrolledClipView(horizontalScroll.contentView)
    }

    // MARK: Table data source / delegate

    private func column(for tableView: NSTableView) -> Column? {
        columns.indices.contains(tableView.tag) ? columns[tableView.tag] : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        column(for: tableView)?.items.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard let column = column(for: tableView),
              column.items.indices.contains(row) else { return nil }
        let item = column.items[row]
        let cellID = NSUserInterfaceItemIdentifier("columnCell")
        let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView
            ?? Self.makeCell(id: cellID)
        cell.textField?.stringValue = item.name
        cell.textField?.textColor = item.cloudStatus == .inCloudOnly
            ? .secondaryLabelColor : .labelColor
        let icon = item.icon
        icon.size = NSSize(width: 16, height: 16)
        cell.imageView?.image = icon
        if let chevron = cell.subviews.first(where: { $0.identifier?.rawValue == "chevron" }) {
            chevron.isHidden = !item.isDirectory
        }
        return cell
    }

    private static func makeCell(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let image = NSImageView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        let chevron = NSImageView(image: NSImage(
            systemSymbolName: "chevron.right", accessibilityDescription: nil)!)
        chevron.identifier = NSUserInterfaceItemIdentifier("chevron")
        chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        chevron.contentTintColor = .tertiaryLabelColor
        for subview in [image, text, chevron] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(subview)
        }
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            chevron.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRebuilding,
              let table = notification.object as? ColumnTableView,
              !table.suppressChainSync else { return }
        activeColumnIndex = table.tag
        syncChain(for: table)
    }

    /// Make the column after `table` match its selection. Idempotent, so it
    /// also runs on plain clicks — re-clicking an already-selected folder
    /// (no selection change) still re-opens its column.
    @objc private func columnClicked(_ sender: Any?) {
        guard !isRebuilding, let table = sender as? ColumnTableView,
              !table.suppressChainSync else { return }
        activeColumnIndex = table.tag
        syncChain(for: table)
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        (tableView as? ColumnTableView)?.dragBegan = true
    }

    private func syncChain(for table: ColumnTableView) {
        guard let column = column(for: table) else { return }
        let rows = table.selectedRowIndexes
        if rows.count == 1, let row = rows.first,
           column.items.indices.contains(row), column.items[row].isDirectory {
            let url = column.items[row].url
            if columns.indices.contains(table.tag + 1),
               columns[table.tag + 1].url == url {
                return  // already showing this folder
            }
            truncateColumns(after: table.tag)
            appendColumn(for: url, isRoot: false)
        } else {
            truncateColumns(after: table.tag)
        }
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard let table = sender as? NSTableView,
              let column = column(for: table) else { return }
        let row = table.clickedRow
        guard column.items.indices.contains(row) else { return }
        let item = column.items[row]
        // Double-clicking a folder must NOT re-root the tab (that collapses
        // the chain to one column); its column is already open via selection.
        // Only files open.
        guard !item.isDirectory else { return }
        onOpen?(item.url)
    }

    // MARK: Drag & drop (native NSTableView behavior per column)

    func tableView(_ tableView: NSTableView,
                   pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let column = column(for: tableView),
              column.items.indices.contains(row) else { return nil }
        return column.items[row].url as NSURL
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard let column = column(for: tableView) else { return [] }
        let sources = DropBehavior.urls(from: info)
        guard !sources.isEmpty else { return [] }
        if dropOperation == .on, column.items.indices.contains(row),
           column.items[row].isDirectory {
            let dest = column.items[row].url
            guard !sources.contains(dest),
                  !sources.contains(where: { $0.deletingLastPathComponent() == dest })
            else { return [] }
            return DropBehavior.operation(for: sources, destination: dest)
        }
        tableView.setDropRow(-1, dropOperation: .on)  // whole-column drop
        guard !sources.contains(column.url),
              !sources.contains(where: { $0.deletingLastPathComponent() == column.url })
        else { return [] }
        return DropBehavior.operation(for: sources, destination: column.url)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let column = column(for: tableView) else { return false }
        let sources = DropBehavior.urls(from: info)
        let destination: URL
        if dropOperation == .on, column.items.indices.contains(row),
           column.items[row].isDirectory {
            destination = column.items[row].url
        } else {
            destination = column.url
        }
        let operation = DropBehavior.operation(for: sources, destination: destination)
        return DropBehavior.perform(operation, sources: sources, destination: destination)
        // Watchers refresh the affected columns.
    }
}
