import AppKit

final class DoubleClickCollectionView: NSCollectionView {
    var onDoubleClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { onDoubleClick?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: point),
           !selectionIndexPaths.contains(indexPath) {
            deselectAll(nil)
            selectionIndexPaths = [indexPath]
        }
        return super.menu(for: event)
    }
}

final class FileCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FileCollectionItem")

    override func loadView() {
        let image = NSImageView()
        let label = NSTextField(labelWithString: "")
        label.alignment = .center
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        let stack = NSStackView(views: [image, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        stack.wantsLayer = true
        stack.layer?.cornerRadius = 6
        view = stack
        imageView = image
        textField = label
        NSLayoutConstraint.activate([
            image.widthAnchor.constraint(equalToConstant: 64),
            image.heightAnchor.constraint(equalToConstant: 64),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 100),
        ])
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.backgroundColor = isSelected
                ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).cgColor
                : nil
        }
    }
}

final class IconViewController: NSViewController, DirectoryView,
    NSCollectionViewDataSource, NSCollectionViewDelegate {
    var model: DirectoryModel
    var onOpen: ((URL) -> Void)?
    var contextMenu: NSMenu? {
        didSet { if isViewLoaded { collectionView.menu = contextMenu } }
    }
    let collectionView = DoubleClickCollectionView()
    private let scrollView = NSScrollView()

    init(model: DirectoryModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    var selectedURLs: [URL] {
        collectionView.selectionIndexPaths.compactMap {
            model.items.indices.contains($0.item) ? model.items[$0.item].url : nil
        }
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
        let paths = Set(model.items.indices
            .filter { urls.contains(model.items[$0].url) }
            .map { IndexPath(item: $0, section: 0) })
        collectionView.selectionIndexPaths = paths
    }

    func modelDidChange() {
        let selected = Set(selectedURLs)
        collectionView.reloadData()
        if !selected.isEmpty {
            let paths = Set(model.items.indices
                .filter { selected.contains(model.items[$0].url) }
                .map { IndexPath(item: $0, section: 0) })
            collectionView.selectionIndexPaths = paths
        }
    }

    override func loadView() {
        view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 110, height: 100)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 16
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        collectionView.collectionViewLayout = layout
        collectionView.register(FileCollectionItem.self,
                                forItemWithIdentifier: FileCollectionItem.identifier)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.menu = contextMenu
        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        collectionView.onDoubleClick = { [weak self] in
            guard let self, let url = self.selectedURLs.first else { return }
            self.onOpen?(url)
        }
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        modelDidChange()
    }

    func collectionView(_ collectionView: NSCollectionView,
                        numberOfItemsInSection section: Int) -> Int {
        model.items.count
    }

    // MARK: Drag & drop

    func collectionView(_ collectionView: NSCollectionView,
                        pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard model.items.indices.contains(indexPath.item) else { return nil }
        return model.items[indexPath.item].url as NSURL
    }

    func collectionView(_ collectionView: NSCollectionView,
                        validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let sources = DropBehavior.urls(from: draggingInfo)
        guard !sources.isEmpty else { return [] }
        let index = proposedIndexPath.pointee.item
        if dropOperation.pointee == .on, model.items.indices.contains(index),
           model.items[index].isDirectory {
            let dest = model.items[index].url
            guard !sources.contains(dest) else { return [] }
            return DropBehavior.operation(for: sources, destination: dest)
        }
        dropOperation.pointee = .before
        guard !sources.contains(where: { $0.deletingLastPathComponent() == model.directoryURL })
        else { return [] }  // already here
        return DropBehavior.operation(for: sources, destination: model.directoryURL)
    }

    func collectionView(_ collectionView: NSCollectionView,
                        acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath,
                        dropOperation: NSCollectionView.DropOperation) -> Bool {
        let sources = DropBehavior.urls(from: draggingInfo)
        let destination: URL
        if dropOperation == .on, model.items.indices.contains(indexPath.item),
           model.items[indexPath.item].isDirectory {
            destination = model.items[indexPath.item].url
        } else {
            destination = model.directoryURL
        }
        let operation = DropBehavior.operation(for: sources, destination: destination)
        return DropBehavior.perform(operation, sources: sources, destination: destination)
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: FileCollectionItem.identifier,
                                           for: indexPath)
        let file = model.items[indexPath.item]
        item.textField?.stringValue = file.name
        item.textField?.textColor = file.cloudStatus == .inCloudOnly
            ? .secondaryLabelColor : .labelColor
        let icon = file.icon
        icon.size = NSSize(width: 64, height: 64)
        item.imageView?.image = icon
        return item
    }
}
