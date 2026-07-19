import AppKit

/// One row in the expandable list view. Children load lazily on first expand.
final class ListNode {
    let item: FileItem
    var children: [ListNode]?   // nil = not loaded yet
    init(item: FileItem) { self.item = item }
}

final class ContextOutlineListView: NSOutlineView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        if clicked >= 0, !selectedRowIndexes.contains(clicked) {
            selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }
        return super.menu(for: event)
    }
}

final class FileListViewController: NSViewController, DirectoryView,
    NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate,
    NSMenuDelegate {

    var model: DirectoryModel
    /// Option-clicking a column header: "sort EVERYTHING by this" — the
    /// owner switches to flat view with that sort.
    var onFlattenRequest: ((SortKey) -> Void)?
    var onOpen: ((URL) -> Void)?
    var contextMenu: NSMenu? {
        didSet { if isViewLoaded { outlineView.menu = contextMenu } }
    }
    let outlineView = ContextOutlineListView()
    private let scrollView = NSScrollView()
    private var rootNodes: [ListNode] = []
    /// One watcher per visible expanded folder so open folders live-update.
    /// (The tab's root is watched by DirectoryModel.)
    private var expandedWatchers: [URL: DirectoryWatcher] = [:]

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
    static let byteFormatter = ByteCountFormatter()

    init(model: DirectoryModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    var selectedURLs: [URL] {
        outlineView.selectedRowIndexes.compactMap {
            (outlineView.item(atRow: $0) as? ListNode)?.item.url
        }
    }

    // MARK: Column visibility (right-click the header to choose, like Finder)

    static let columnDefinitions: [(String, String, CGFloat)] = [
        ("name", "Name", 320),
        ("dateModified", "Date Modified", 160),
        ("dateCreated", "Date Created", 160),
        ("dateLastOpened", "Date Last Opened", 160),
        ("dateAdded", "Date Added", 160),
        ("size", "Size", 80),
        ("kind", "Kind", 140),
        ("cloudStatus", "iCloud Status", 110),
        ("tags", "Tags", 120),
        ("comments", "Comments", 160),
    ]

    /// Hidden until chosen in the header menu, like Finder's defaults.
    private static let defaultHiddenColumns: Set<String> =
        ["dateCreated", "dateLastOpened", "dateAdded", "tags", "comments"]

    /// User choices from the header menu; a column absent here uses its
    /// default (visible — except iCloud Status, which auto-shows only in
    /// iCloud locations, like Finder).
    private static func columnOverrides() -> [String: Bool] {
        UserDefaults.standard.dictionary(forKey: "listVisibleColumns")
            as? [String: Bool] ?? [:]
    }

    private func syncColumnVisibility() {
        let overrides = Self.columnOverrides()
        for column in outlineView.tableColumns {
            let id = column.identifier.rawValue
            if id == "name" { continue }  // Name is not optional
            if let manual = overrides[id] {
                column.isHidden = !manual
            } else if id == "cloudStatus" {
                column.isHidden = !CloudFiles.isInICloudContainer(model.directoryURL)
            } else {
                column.isHidden = Self.defaultHiddenColumns.contains(id)
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for (id, title, _) in Self.columnDefinitions where id != "name" {
            let item = NSMenuItem(title: title,
                                  action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = outlineView.tableColumn(withIdentifier: .init(id))?.isHidden == false
                ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let column = outlineView.tableColumn(withIdentifier: .init(id)) else { return }
        column.isHidden.toggle()
        var overrides = Self.columnOverrides()
        overrides[id] = !column.isHidden
        UserDefaults.standard.set(overrides, forKey: "listVisibleColumns")
    }


    var persistedExpandedPaths: [String] {
        expandedURLs().map(\.path)
    }

    func beginRenaming(_ url: URL) {
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? ListNode,
                  node.item.url == url else { continue }
            view.window?.makeFirstResponder(outlineView)
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
            let nameColumn = outlineView.tableColumns.firstIndex {
                $0.identifier.rawValue == "name"
            } ?? 0
            outlineView.editColumn(nameColumn, row: row, with: nil, select: true)
            return
        }
    }

    func applySelection(_ urls: Set<URL>) {
        var restore = IndexSet()
        for row in 0..<outlineView.numberOfRows {
            if let node = outlineView.item(atRow: row) as? ListNode,
               urls.contains(node.item.url) {
                restore.insert(row)
            }
        }
        outlineView.selectRowIndexes(restore, byExtendingSelection: false)
    }

    func applyPersistedExpansion(_ paths: [String]) {
        restoreExpansion(Set(paths.map(URL.init(fileURLWithPath:))))
        syncExpandedWatchers()
    }

    var persistedScrollOffset: CGFloat {
        get { scrollView.contentView.bounds.origin.y }
        set {
            var origin = scrollView.contentView.bounds.origin
            origin.y = newValue
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    func modelDidChange() {
        syncColumnVisibility()
        let expanded = expandedURLs()
        let selected = Set(selectedURLs)
        rootNodes = model.items.map(ListNode.init(item:))
        outlineView.reloadData()
        restoreExpansion(expanded)
        if !selected.isEmpty {
            var restore = IndexSet()
            for row in 0..<outlineView.numberOfRows {
                if let node = outlineView.item(atRow: row) as? ListNode,
                   selected.contains(node.item.url) {
                    restore.insert(row)
                }
            }
            outlineView.selectRowIndexes(restore, byExtendingSelection: false)
        }
        syncExpandedWatchers()
    }

    private func expandedURLs() -> Set<URL> {
        var result: Set<URL> = []
        for row in 0..<outlineView.numberOfRows {
            if let node = outlineView.item(atRow: row) as? ListNode,
               outlineView.isItemExpanded(node) {
                result.insert(node.item.url)
            }
        }
        return result
    }

    /// Child rows appear right after their parent, so a single forward pass
    /// re-expands nested folders as their parents re-open.
    private func restoreExpansion(_ urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        var row = 0
        while row < outlineView.numberOfRows {
            if let node = outlineView.item(atRow: row) as? ListNode,
               urls.contains(node.item.url), !outlineView.isItemExpanded(node) {
                outlineView.expandItem(node)
            }
            row += 1
        }
    }

    override func loadView() {
        view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        for (id, title, width) in Self.columnDefinitions {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            // Comments load lazily per cell (Spotlight query) — not sortable.
            if id != "cloudStatus", id != "comments" {
                column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            }
            outlineView.addTableColumn(column)
            if id == "name" { outlineView.outlineTableColumn = column }
        }
        let headerMenu = NSMenu()
        headerMenu.delegate = self
        outlineView.headerView?.menu = headerMenu
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.allowsMultipleSelection = true
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.rowHeight = 20
        outlineView.indentationPerLevel = 14
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClicked)
        outlineView.menu = contextMenu
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        outlineView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        modelDidChange()
    }

    // MARK: Live updates for expanded folders

    func outlineViewItemDidExpand(_ notification: Notification) {
        syncExpandedWatchers()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        syncExpandedWatchers()
    }

    private func syncExpandedWatchers() {
        let desired = expandedURLs()
        for (url, watcher) in expandedWatchers where !desired.contains(url) {
            watcher.stop()
            expandedWatchers[url] = nil
        }
        for url in desired where expandedWatchers[url] == nil {
            let watcher = DirectoryWatcher(directoryURL: url)
            watcher.onChange = { [weak self] in self?.refreshExpandedFolder(url) }
            do { try watcher.start() } catch {
                NSAlert(error: error).runModal()
                continue
            }
            expandedWatchers[url] = watcher
        }
    }

    private func refreshExpandedFolder(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path),
              let node = visibleNode(for: url) else {
            syncExpandedWatchers()
            return
        }
        let expanded = expandedURLs()
        node.children = nil
        outlineView.reloadItem(node, reloadChildren: true)
        restoreExpansion(expanded)
        syncExpandedWatchers()
    }

    private func visibleNode(for url: URL) -> ListNode? {
        for row in 0..<outlineView.numberOfRows {
            if let node = outlineView.item(atRow: row) as? ListNode, node.item.url == url {
                return node
            }
        }
        return nil
    }

    private func children(of node: ListNode) -> [ListNode] {
        if let children = node.children { return children }
        var nodes: [ListNode] = []
        do {
            nodes = try model.items(of: node.item.url).map(ListNode.init(item:))
        } catch {
            // A vanished folder is cleanup (its row disappears on the parent
            // refresh), not an error worth alerting.
            if FileManager.default.fileExists(atPath: node.item.url.path) {
                NSAlert(error: error).runModal()
            }
        }
        node.children = nodes   // cache (also after error, so the alert fires once)
        return nodes
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? ListNode else { return rootNodes.count }
        return children(of: node).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? ListNode else { return rootNodes[index] }
        return children(of: node)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? ListNode)?.item.isDirectory ?? false
    }

    // MARK: Cells

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        guard let column = tableColumn, let node = item as? ListNode else { return nil }
        let file = node.item
        let hasIcon = ["name", "cloudStatus"].contains(column.identifier.rawValue)
        let cellID = NSUserInterfaceItemIdentifier("cell-\(column.identifier.rawValue)")
        let cell = outlineView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView
            ?? Self.makeCell(id: cellID, withIcon: hasIcon)
        switch column.identifier.rawValue {
        case "name":
            cell.textField?.stringValue = file.name
            cell.textField?.isEditable = true
            cell.textField?.delegate = self
            cell.textField?.textColor = file.cloudStatus == .inCloudOnly
                ? .secondaryLabelColor : .labelColor
            let icon = file.icon
            icon.size = NSSize(width: 16, height: 16)
            cell.imageView?.image = icon
        case "dateModified":
            cell.textField?.stringValue = Self.dateFormatter.string(from: file.dateModified)
        case "size":
            cell.textField?.stringValue = file.isDirectory
                ? "--" : Self.byteFormatter.string(fromByteCount: file.size)
        case "dateCreated":
            cell.textField?.stringValue = file.dateCreated == .distantPast
                ? "--" : Self.dateFormatter.string(from: file.dateCreated)
        case "dateLastOpened":
            cell.textField?.stringValue = file.dateLastOpened == .distantPast
                ? "--" : Self.dateFormatter.string(from: file.dateLastOpened)
        case "dateAdded":
            cell.textField?.stringValue = file.dateAdded == .distantPast
                ? "--" : Self.dateFormatter.string(from: file.dateAdded)
        case "tags":
            cell.textField?.stringValue = file.tags.joined(separator: ", ")
        case "comments":
            cell.textField?.stringValue = FileMetadata.finderComment(for: file.url)
        case "cloudStatus":
            switch file.cloudStatus {
            case .notCloud:
                cell.textField?.stringValue = ""
                cell.imageView?.image = nil
            case .inCloudOnly:
                cell.textField?.stringValue = "In iCloud"
                cell.imageView?.image = NSImage(
                    systemSymbolName: "icloud.and.arrow.down",
                    accessibilityDescription: "In iCloud")
            case .downloaded:
                cell.textField?.stringValue = "Downloaded"
                cell.imageView?.image = NSImage(
                    systemSymbolName: "checkmark.icloud",
                    accessibilityDescription: "Downloaded")
            }
            cell.imageView?.contentTintColor = .secondaryLabelColor
        case "kind":
            cell.textField?.stringValue = file.kind
        default:
            break
        }
        return cell
    }

    private static func makeCell(id: NSUserInterfaceItemIdentifier,
                                 withIcon: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        var leading = cell.leadingAnchor
        if withIcon {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
            ])
            leading = image.trailingAnchor
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leading, constant: withIcon ? 6 : 2),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: Sorting

    func outlineView(_ outlineView: NSOutlineView,
                     sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        if NSEvent.modifierFlags.contains(.option),
           let key = outlineView.sortDescriptors.first?.key,
           let sortKey = SortKey(rawValue: key) {
            onFlattenRequest?(sortKey)
            return
        }
        guard let descriptor = outlineView.sortDescriptors.first,
              let key = descriptor.key, let sortKey = SortKey(rawValue: key) else { return }
        model.sortKey = sortKey
        model.ascending = descriptor.ascending
        do { try model.reload() } catch {
            NSAlert(error: error).runModal()
            return
        }
        // Rebuild; re-expanded folders reload children with the new sort.
        modelDidChange()
    }

    // MARK: Drag & drop

    func outlineView(_ outlineView: NSOutlineView,
                     pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        (item as? ListNode)?.item.url as NSURL?
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard DropBehavior.canAcceptFileDrop(info) else { return [] }
        // Local drags expose their URLs at hover; external ones don't until
        // drop — self-drop guards apply only when we can see the sources.
        let sources = DropBehavior.urls(from: info)
        if let node = item as? ListNode, node.item.isDirectory {
            guard !sources.contains(node.item.url) else { return [] }
            outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return DropBehavior.hoverOperation(info)
        }
        outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        guard !sources.contains(where: { $0.deletingLastPathComponent() == model.directoryURL })
            || sources.isEmpty else { return [] }  // already here
        return DropBehavior.hoverOperation(info)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        let sources = DropBehavior.urls(from: info)
        guard !sources.isEmpty else { return false }
        let destination: URL
        if let node = item as? ListNode, node.item.isDirectory {
            destination = node.item.url
        } else {
            destination = model.directoryURL
        }
        let operation = DropBehavior.operation(for: sources, destination: destination, info: info)
        return DropBehavior.perform(operation, sources: sources, destination: destination)
    }

    // MARK: Actions

    @objc private func doubleClicked() {
        let row = outlineView.clickedRow
        guard let node = outlineView.item(atRow: row) as? ListNode else { return }
        onOpen?(node.item.url)
    }

    // MARK: Rename in place

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let row = outlineView.row(for: field)
        guard let node = outlineView.item(atRow: row) as? ListNode else { return }
        let item = node.item
        let newName = field.stringValue
        guard !newName.isEmpty, newName != item.name else {
            field.stringValue = item.name
            return
        }
        do {
            try FileOperations.rename(item.url, to: newName)
            // The FSEvents watcher refreshes root-level renames; renames inside
            // an expanded folder refresh on next expand.
        } catch {
            NSAlert(error: error).runModal()
            field.stringValue = item.name
        }
    }
}
