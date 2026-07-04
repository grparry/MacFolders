import AppKit

/// Search results over the content area: an explicit Name/Contents mode
/// switch, a scope switch that ALWAYS starts at the current folder (never
/// the whole Mac), and a streaming results table.
final class SearchResultsViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate {

    var onOpen: ((URL) -> Void)?
    var onRevealInFolder: ((URL) -> Void)?

    private let engine = SearchEngine()
    private var results: [URL] = []
    private var term = ""
    private var folder = FileManager.default.homeDirectoryForCurrentUser
    private var capReached = false

    private let modeControl = NSSegmentedControl(
        labels: ["Name", "Contents"], trackingMode: .selectOne,
        target: nil, action: nil)
    private let scopeControl = NSSegmentedControl(
        labels: ["Folder", "This Mac"], trackingMode: .selectOne,
        target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        modeControl.target = self
        modeControl.action = #selector(controlsChanged)
        scopeControl.target = self
        scopeControl.action = #selector(controlsChanged)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)

        let header = NSStackView(views: [modeControl, scopeControl,
                                         NSView(), statusLabel])
        header.orientation = .horizontal
        header.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        header.translatesAutoresizingMaskIntoConstraints = false

        for (id, title, width) in [("name", "Name", CGFloat(280)),
                                   ("where", "Where", 340),
                                   ("dateModified", "Date Modified", 160)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 20
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked)
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(header)
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        engine.onResults = { [weak self] batch, complete in
            guard let self else { return }
            self.results += batch
            self.capReached = complete && self.results.count >= SearchEngine.resultCap
            // Results only append, so indices are stable — keep the user's
            // in-progress selection across streaming reloads.
            let selected = self.tableView.selectedRowIndexes
            self.tableView.reloadData()
            self.tableView.selectRowIndexes(selected, byExtendingSelection: false)
            self.statusLabel.stringValue = complete
                ? "\(self.results.count) result\(self.results.count == 1 ? "" : "s")"
                    + (self.capReached ? " (first \(SearchEngine.resultCap) shown)" : "")
                : "Searching… \(self.results.count)"
        }
    }

    /// New search session: scope snaps back to the current folder — searching
    /// the whole Mac is a choice, never a default.
    func beginSession(folder: URL) {
        self.folder = folder
        scopeControl.setLabel("“\(folder.lastPathComponent)”", forSegment: 0)
        scopeControl.selectedSegment = 0
        modeControl.selectedSegment = UserDefaults.standard.integer(forKey: "searchMode")
    }

    func update(term: String) {
        self.term = term
        runSearch()
    }

    func cancel() {
        engine.cancel()
    }

    @objc private func controlsChanged() {
        UserDefaults.standard.set(modeControl.selectedSegment, forKey: "searchMode")
        runSearch()
    }

    private func runSearch() {
        results = []
        capReached = false
        tableView.reloadData()
        statusLabel.stringValue = "Searching…"
        engine.search(
            term: term,
            mode: SearchMode(rawValue: modeControl.selectedSegment) ?? .name,
            scope: SearchScope(rawValue: scopeControl.selectedSegment) ?? .folder,
            folder: folder)
    }

    /// Clicked row when outside the selection; the whole selection when
    /// inside it — the standard multi-selection contract.
    private func actionTargets() -> [URL] {
        let clicked = tableView.clickedRow
        if clicked >= 0, tableView.selectedRowIndexes.contains(clicked) {
            return tableView.selectedRowIndexes.compactMap {
                results.indices.contains($0) ? results[$0] : nil
            }
        }
        if results.indices.contains(clicked) { return [results[clicked]] }
        return tableView.selectedRowIndexes.compactMap {
            results.indices.contains($0) ? results[$0] : nil
        }
    }

    @objc private func doubleClicked() {
        for url in actionTargets() { onOpen?(url) }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        results.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard let column = tableColumn, results.indices.contains(row) else { return nil }
        let url = results[row]
        let cellID = NSUserInterfaceItemIdentifier("search-\(column.identifier.rawValue)")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: cellID, owner: self)
            as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = cellID
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text
            var leading = cell.leadingAnchor
            if column.identifier.rawValue == "name" {
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
                text.leadingAnchor.constraint(equalTo: leading, constant: 5),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        switch column.identifier.rawValue {
        case "name":
            cell.textField?.stringValue = url.lastPathComponent
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            cell.imageView?.image = icon
        case "where":
            cell.textField?.stringValue =
                (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            cell.textField?.textColor = .secondaryLabelColor
        case "dateModified":
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            cell.textField?.stringValue = date.map(Self.dateFormatter.string(from:)) ?? "--"
        default:
            break
        }
        return cell
    }
}

extension SearchResultsViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard !actionTargets().isEmpty else { return }
        for (title, action) in [("Open", #selector(menuOpen(_:))),
                                ("Show in Enclosing Folder", #selector(menuReveal(_:))),
                                ("Copy Pathname", #selector(menuCopyPath(_:))),
                                ("Get Info", #selector(menuGetInfo(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
    }

    @objc private func menuOpen(_ sender: NSMenuItem) {
        for url in actionTargets() { onOpen?(url) }
    }

    @objc private func menuReveal(_ sender: NSMenuItem) {
        guard let url = actionTargets().first else { return }
        onRevealInFolder?(url)
    }

    @objc private func menuCopyPath(_ sender: NSMenuItem) {
        let targets = actionTargets()
        guard !targets.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(targets.map(\.path).joined(separator: "\n"),
                             forType: .string)
    }

    @objc private func menuGetInfo(_ sender: NSMenuItem) {
        for url in actionTargets() {
            GetInfoPanelController.show(for: url)
        }
    }
}
