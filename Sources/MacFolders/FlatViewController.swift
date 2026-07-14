import AppKit

/// Flat view: every file under the folder, one sortable table, filters as
/// header chips. Each folder's configuration persists individually — you
/// get back exactly the flat view you left, per folder.
final class FlatViewController: NSViewController, DirectoryView,
    NSTableViewDataSource, NSTableViewDelegate {

    var model: DirectoryModel {
        didSet { configure(for: model.directoryURL) }
    }
    var onOpen: ((URL) -> Void)?
    var onRevealInFolder: ((URL) -> Void)?
    var contextMenu: NSMenu? {
        didSet { if isViewLoaded { tableView.menu = contextMenu } }
    }
    var selectedURLs: [URL] {
        tableView.selectedRowIndexes.compactMap {
            results.indices.contains($0) ? results[$0].url : nil
        }
    }

    private let scanner = FlatScanner()
    private var results: [FileItem] = []
    private var config = FlatViewConfig()
    private var root = FileManager.default.homeDirectoryForCurrentUser
    private var watcher: DirectoryWatcher?
    private var pendingRescan: DispatchWorkItem?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let dotTreesChip = NSButton(checkboxWithTitle: "Skip listed folders",
                                        target: nil, action: nil)
    private let minSizePopup = NSPopUpButton()
    private let modifiedPopup = NSPopUpButton()
    private let pauseBanner = NSStackView()
    private let pauseLabel = NSTextField(labelWithString: "")

    private static let minSizeChoices: [(String, Int64)] = [
        ("Any size", 0), ("≥ 1 MB", 1 << 20), ("≥ 10 MB", 10 << 20),
        ("≥ 100 MB", 100 << 20), ("≥ 1 GB", 1 << 30),
    ]
    private static let modifiedChoices: [(String, Int)] = [
        ("Any time", 0), ("Past day", 1), ("Past week", 7),
        ("Past month", 31), ("Past year", 366),
    ]
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
    private static let byteFormatter = ByteCountFormatter()

    init(model: DirectoryModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        dotTreesChip.target = self
        dotTreesChip.action = #selector(chipsChanged)
        minSizePopup.addItems(withTitles: Self.minSizeChoices.map(\.0))
        minSizePopup.target = self
        minSizePopup.action = #selector(chipsChanged)
        modifiedPopup.addItems(withTitles: Self.modifiedChoices.map(\.0))
        modifiedPopup.target = self
        modifiedPopup.action = #selector(chipsChanged)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)

        let editSkipButton = NSButton(title: "Edit List…",
                                      target: self, action: #selector(editSkipList))
        editSkipButton.controlSize = .small
        editSkipButton.bezelStyle = .rounded
        let header = NSStackView(views: [dotTreesChip, editSkipButton,
                                         minSizePopup, modifiedPopup,
                                         NSView(), statusLabel])
        header.orientation = .horizontal
        header.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        header.translatesAutoresizingMaskIntoConstraints = false

        pauseLabel.font = .systemFont(ofSize: 11)
        let continueButton = NSButton(title: "Continue",
                                      target: self, action: #selector(continueScan))
        let stopButton = NSButton(title: "Stop Here",
                                  target: self, action: #selector(stopScan))
        continueButton.controlSize = .small
        stopButton.controlSize = .small
        pauseBanner.setViews([pauseLabel, continueButton, stopButton, NSView()],
                             in: .leading)
        pauseBanner.orientation = .horizontal
        pauseBanner.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        pauseBanner.wantsLayer = true
        pauseBanner.layer?.backgroundColor =
            NSColor.systemYellow.withAlphaComponent(0.15).cgColor
        pauseBanner.isHidden = true
        pauseBanner.translatesAutoresizingMaskIntoConstraints = false

        for (id, title, width, sortable) in [
            ("name", "Name", CGFloat(260), true),
            ("where", "Where", 300, true),
            ("size", "Size", 90, true),
            ("dateModified", "Date Modified", 160, true),
        ] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            if sortable {
                column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            }
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 20
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked)
        tableView.menu = contextMenu
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(header)
        view.addSubview(pauseBanner)
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pauseBanner.topAnchor.constraint(equalTo: header.bottomAnchor),
            pauseBanner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pauseBanner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: pauseBanner.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        scanner.onEvent = { [weak self] event in
            self?.handle(event)
        }
        updateSkipTooltip()
        configure(for: model.directoryURL)
    }

    // MARK: Configuration (per folder — the folder's saved flat view)

    private func configure(for url: URL) {
        guard isViewLoaded else { return }
        root = url
        config = AppDelegate.shared.workspaceManager.flatConfig(forPath: url.path)
        dotTreesChip.state = config.skipDotTrees ? .on : .off
        minSizePopup.selectItem(at: Self.minSizeChoices.firstIndex {
            $0.1 == config.minSizeBytes } ?? 0)
        modifiedPopup.selectItem(at: Self.modifiedChoices.firstIndex {
            $0.1 == config.modifiedWithinDays } ?? 0)
        applySortIndicators()
        startWatching()
        rescan()
    }

    private func persistConfig() {
        do {
            try AppDelegate.shared.workspaceManager.setFlatConfig(config,
                                                                  forPath: root.path)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// The skip list is app-wide (what "clutter" means doesn't vary by
    /// folder); the per-folder toggle decides whether it applies here.
    @objc private func editSkipList() {
        let alert = NSAlert()
        alert.messageText = "Skipped Folders"
        alert.informativeText = "Flat view will not descend into folders "
            + "matching these patterns (one per line). Globs supported — "
            + "“.*” matches every dot-folder."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        let text = NSTextView(frame: scroll.bounds)
        text.string = FlatScanner.skipPatterns.joined(separator: "\n")
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.autoresizingMask = [.width]
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = text
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        FlatScanner.skipPatterns = text.string
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        updateSkipTooltip()
        rescan()
    }

    private func updateSkipTooltip() {
        dotTreesChip.toolTip = "Skipping: "
            + FlatScanner.skipPatterns.joined(separator: ", ")
    }

    /// Right-click → skip this folder name everywhere. Adding implies
    /// wanting it applied, so the folder's toggle switches on too.
    func addToSkipList(_ name: String) {
        var patterns = FlatScanner.skipPatterns
        if !patterns.contains(name) {
            patterns.append(name)
            FlatScanner.skipPatterns = patterns
        }
        if !config.skipDotTrees {
            config.skipDotTrees = true
            dotTreesChip.state = .on
            persistConfig()
        }
        updateSkipTooltip()
        rescan()
    }

    @objc private func chipsChanged() {
        config.skipDotTrees = dotTreesChip.state == .on
        config.minSizeBytes = Self.minSizeChoices[minSizePopup.indexOfSelectedItem].1
        config.modifiedWithinDays = Self.modifiedChoices[modifiedPopup.indexOfSelectedItem].1
        persistConfig()
        rescan()
    }

    // MARK: Scanning

    private func rescan() {
        pauseBanner.isHidden = true
        results = []
        tableView.reloadData()
        statusLabel.stringValue = "Scanning…"
        scanner.scan(root: root, config: config)
    }

    private func handle(_ event: FlatScanner.Event) {
        switch event {
        case .batch(let items):
            let selected = Set(selectedURLs)
            results += items
            sortResults()
            tableView.reloadData()
            applySelection(selected)
            statusLabel.stringValue = "Scanning… \(results.count)"
        case .paused(let count):
            pauseLabel.stringValue =
                "Paused at \(count) files — more remain below this folder."
            pauseBanner.isHidden = false
            statusLabel.stringValue = "\(results.count) files (paused)"
        case .finished(let total):
            pauseBanner.isHidden = true
            statusLabel.stringValue =
                "\(total) file\(total == 1 ? "" : "s")"
        }
    }

    @objc private func continueScan() {
        pauseBanner.isHidden = true
        scanner.resume()
    }

    @objc private func stopScan() {
        pauseBanner.isHidden = true
        scanner.cancel()
        statusLabel.stringValue = "\(results.count) files (stopped)"
    }

    // MARK: Sorting (persisted per folder)

    private func sortResults() {
        switch config.sortKey {
        case .name:
            results.sort {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case .size:
            results.sort { $0.size < $1.size }
        case .dateModified:
            results.sort { $0.dateModified < $1.dateModified }
        case .location:
            // Groups files by containing folder, walking the tree in order.
            results.sort {
                let a = $0.url.deletingLastPathComponent().path
                let b = $1.url.deletingLastPathComponent().path
                if a == b {
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                return a.localizedStandardCompare(b) == .orderedAscending
            }
        default:
            results.sort { $0.size < $1.size }
        }
        if !config.ascending {
            results.reverse()
        }
    }

    private func applySortIndicators() {
        for column in tableView.tableColumns {
            if column.identifier.rawValue == config.sortKey.rawValue {
                tableView.setIndicatorImage(
                    NSImage(named: config.ascending
                        ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"),
                    in: column)
            } else {
                tableView.setIndicatorImage(nil, in: column)
            }
        }
    }

    func tableView(_ tableView: NSTableView,
                   sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key, let sortKey = SortKey(rawValue: key) else { return }
        config.sortKey = sortKey
        config.ascending = descriptor.ascending
        persistConfig()
        applySortIndicators()
        let selected = Set(selectedURLs)
        sortResults()
        tableView.reloadData()
        applySelection(selected)
    }

    // MARK: Live updates (recursive — any change below the root)

    private func startWatching() {
        watcher?.stop()
        let created = DirectoryWatcher(directoryURL: root, recursive: true)
        created.onChange = { [weak self] in
            guard let self else { return }
            self.pendingRescan?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.rescan() }
            self.pendingRescan = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
        }
        do { try created.start() } catch {
            NSAlert(error: error).runModal()
        }
        watcher = created
    }

    // MARK: DirectoryView

    func modelDidChange() {
        // Root-level model reloads are covered by the recursive watcher; a
        // model swap (navigation) reconfigures via the model didSet.
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

    func applySelection(_ urls: Set<URL>) {
        var indexes = IndexSet()
        for (row, item) in results.enumerated() where urls.contains(item.url) {
            indexes.insert(row)
        }
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
    }

    // MARK: Interaction

    @objc private func doubleClicked() {
        let clicked = tableView.clickedRow
        guard results.indices.contains(clicked) else { return }
        let whereColumn = tableView.tableColumns.firstIndex {
            $0.identifier.rawValue == "where"
        }
        if tableView.clickedColumn == whereColumn {
            onRevealInFolder?(results[clicked].url)
            return
        }
        let targets = tableView.selectedRowIndexes.contains(clicked)
            ? selectedURLs : [results[clicked].url]
        for url in targets { onOpen?(url) }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        results.count
    }

    func tableView(_ tableView: NSTableView,
                   pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard results.indices.contains(row) else { return nil }
        return results[row].url as NSURL
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard let column = tableColumn, results.indices.contains(row) else { return nil }
        let item = results[row]
        let cellID = NSUserInterfaceItemIdentifier("flat-\(column.identifier.rawValue)")
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
            cell.textField?.stringValue = item.name
            let icon = item.icon
            icon.size = NSSize(width: 16, height: 16)
            cell.imageView?.image = icon
        case "where":
            let parent = item.url.deletingLastPathComponent().path
            let rootPath = root.path
            cell.textField?.stringValue = parent == rootPath ? "—"
                : parent.hasPrefix(rootPath + "/")
                    ? String(parent.dropFirst(rootPath.count + 1))
                    : (parent as NSString).abbreviatingWithTildeInPath
            cell.textField?.textColor = .secondaryLabelColor
        case "size":
            cell.textField?.stringValue =
                Self.byteFormatter.string(fromByteCount: item.size)
        case "dateModified":
            cell.textField?.stringValue =
                Self.dateFormatter.string(from: item.dateModified)
        default:
            break
        }
        return cell
    }
}
