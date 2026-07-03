import AppKit
import UniformTypeIdentifiers
import QuickLookThumbnailing

/// Finder-style Get Info window: one per item, reused if already open.
final class GetInfoPanelController: NSWindowController, NSWindowDelegate {
    private static var openPanels: [GetInfoPanelController] = []

    static func show(for url: URL) {
        if let existing = openPanels.first(where: { $0.itemURL == url }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = GetInfoPanelController(url: url)
        openPanels.append(controller)
        controller.window?.center()
        controller.showWindow(nil)
    }

    let itemURL: URL
    private var parentWatcher: DirectoryWatcher?
    private let sizeValueLabel = NSTextField(labelWithString: "—")
    private let permissionSummaryLabel = NSTextField(labelWithString: "")
    private var privilegePopups: [(shift: Int, popup: NSPopUpButton)] = []

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
    private static let byteFormatter = ByteCountFormatter()

    init(url: URL) {
        itemURL = url
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "\(url.lastPathComponent) Info"
        super.init(window: window)
        window.delegate = self
        buildContent()
        watchForItemRemoval()
    }

    /// Close the panel when the item it describes moves or is deleted —
    /// stale info is worse than no window. Best-effort: if the watch can't
    /// start, the panel simply won't auto-close.
    private func watchForItemRemoval() {
        let watcher = DirectoryWatcher(directoryURL: itemURL.deletingLastPathComponent())
        watcher.onChange = { [weak self] in
            guard let self,
                  !FileManager.default.fileExists(atPath: self.itemURL.path) else { return }
            self.close()
        }
        do {
            try watcher.start()
            parentWatcher = watcher
        } catch {
            parentWatcher = nil
        }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func windowWillClose(_ notification: Notification) {
        GetInfoPanelController.openPanels.removeAll { $0 === self }
    }

    private func buildContent() {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                                         .contentTypeKey, .creationDateKey,
                                         .contentModificationDateKey]
        let values = try? itemURL.resourceValues(forKeys: keys)
        let isDirectory = values?.isDirectory ?? false
        let rawKind = values?.contentType?.localizedDescription
            ?? (isDirectory ? "Folder" : "Document")
        let kind = rawKind.prefix(1).uppercased() + rawKind.dropFirst()

        // Header: big icon, name, kind.
        let iconView = NSImageView()
        let icon = NSWorkspace.shared.icon(forFile: itemURL.path)
        icon.size = NSSize(width: 64, height: 64)
        iconView.image = icon
        let nameLabel = NSTextField(wrappingLabelWithString: itemURL.lastPathComponent)
        nameLabel.font = .boldSystemFont(ofSize: 14)
        let kindLabel = NSTextField(labelWithString: kind)
        kindLabel.font = .systemFont(ofSize: 11)
        kindLabel.textColor = .secondaryLabelColor
        let titleStack = NSStackView(views: [nameLabel, kindLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2
        let header = NSStackView(views: [iconView, titleStack])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12

        // Detail grid.
        var rows: [[NSView]] = []
        func addRow(_ title: String, _ value: String) {
            rows.append([Self.rowTitle(title), Self.rowValue(value)])
        }
        func addRow(_ title: String, view: NSView) {
            rows.append([Self.rowTitle(title), view])
        }

        addRow("Kind:", kind)
        if isDirectory {
            sizeValueLabel.stringValue = "Calculating…"
            addRow("Size:", view: sizeValueLabel)
            calculateFolderSize()
        } else {
            addRow("Size:", Self.byteFormatter.string(
                fromByteCount: Int64(values?.fileSize ?? 0)))
        }
        addRow("Where:", itemURL.deletingLastPathComponent().path)
        if values?.isSymbolicLink == true,
           let destination = try? FileManager.default
               .destinationOfSymbolicLink(atPath: itemURL.path) {
            addRow("Original:", destination)
        }
        if let created = values?.creationDate {
            addRow("Created:", Self.dateFormatter.string(from: created))
        }
        if let modified = values?.contentModificationDate {
            addRow("Modified:", Self.dateFormatter.string(from: modified))
        }

        let grid = NSGridView(views: rows)
        grid.rowSpacing = 5
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing

        // Preview: Quick Look thumbnail, big icon until (or unless) it arrives.
        let previewImage = NSImageView()
        previewImage.imageScaling = .scaleProportionallyUpOrDown
        let placeholder = NSWorkspace.shared.icon(forFile: itemURL.path)
        placeholder.size = NSSize(width: 128, height: 128)
        previewImage.image = placeholder
        previewImage.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            previewImage.heightAnchor.constraint(equalToConstant: 190),
            previewImage.widthAnchor.constraint(equalToConstant: 308),
        ])
        loadPreview(into: previewImage)

        // Sharing & Permissions (privileges editable via popups).
        permissionSummaryLabel.stringValue = permissionInfo().summary
        permissionSummaryLabel.font = .systemFont(ofSize: 11)
        let youCanLabel = permissionSummaryLabel
        var permissionGridRows: [[NSView]] = []
        if let attributes = try? FileManager.default.attributesOfItem(atPath: itemURL.path),
           let posix = attributes[.posixPermissions] as? Int {
            let owner = attributes[.ownerAccountName] as? String ?? "owner"
            let group = attributes[.groupOwnerAccountName] as? String ?? "group"
            let ownerLabel = owner == NSUserName() ? "\(owner) (Me)" : owner
            for (label, shift) in [(ownerLabel, 6), (group, 3), ("everyone", 0)] {
                let popup = makePrivilegePopup(bits: (posix >> shift) & 0b111, shift: shift)
                privilegePopups.append((shift, popup))
                permissionGridRows.append([Self.rowValue(label), popup])
            }
        } else {
            permissionGridRows = [[Self.rowValue("—"), Self.rowValue("—")]]
        }
        let permissionsGrid = NSGridView(views: permissionGridRows)
        permissionsGrid.rowSpacing = 4
        permissionsGrid.columnSpacing = 24

        func sectionSeparator() -> NSBox {
            let box = NSBox()
            box.boxType = .separator
            return box
        }

        let stack = NSStackView(views: [
            header, sectionSeparator(), grid,
            sectionSeparator(), Self.rowTitle("Preview:"), previewImage,
            sectionSeparator(), Self.rowTitle("Sharing & Permissions:"),
            youCanLabel, permissionsGrid,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
        ])
        window?.contentView = content
        window?.setContentSize(content.fittingSize)
    }

    private static func rowTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private static func rowValue(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.isSelectable = true
        label.preferredMaxLayoutWidth = 300
        return label
    }

    private func loadPreview(into imageView: NSImageView) {
        let request = QLThumbnailGenerator.Request(
            fileAt: itemURL,
            size: CGSize(width: 308, height: 190),
            scale: window?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            [weak imageView] thumbnail, _ in
            guard let thumbnail else { return }  // keep the icon fallback
            DispatchQueue.main.async {
                imageView?.image = thumbnail.nsImage
            }
        }
    }

    // MARK: Permission editing

    private func makePrivilegePopup(bits: Int, shift: Int) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.font = .systemFont(ofSize: 11)
        popup.controlSize = .small
        popup.isBordered = false
        for (title, tag) in [("Read & Write", 6), ("Read only", 4), ("No Access", 0)] {
            popup.addItem(withTitle: title)
            popup.lastItem?.tag = tag
        }
        let readWrite = bits & 0b110
        if let index = popup.itemArray.firstIndex(where: { $0.tag == readWrite }) {
            popup.selectItem(at: index)
        } else {
            popup.addItem(withTitle: "Write only")   // representable, not offerable
            popup.lastItem?.tag = 0b010
            popup.select(popup.lastItem)
        }
        popup.tag = shift
        popup.target = self
        popup.action = #selector(privilegeChanged(_:))
        return popup
    }

    @objc private func privilegeChanged(_ sender: NSPopUpButton) {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: itemURL.path)
            guard let posix = attributes[.posixPermissions] as? Int else { return }
            let isDirectory = attributes[.type] as? FileAttributeType == .typeDirectory
            let updated = Self.updatedPermissions(
                current: posix, shift: sender.tag,
                newReadWrite: sender.selectedItem?.tag ?? 0, isDirectory: isDirectory)
            try FileManager.default.setAttributes(
                [.posixPermissions: updated], ofItemAtPath: itemURL.path)
        } catch {
            NSAlert(error: error).runModal()
        }
        refreshPermissionControls()
    }

    /// Pure bit math, unit-tested. Readable directories stay traversable
    /// (r implies x); files keep whatever execute bit they had.
    static func updatedPermissions(current: Int, shift: Int,
                                   newReadWrite: Int, isDirectory: Bool) -> Int {
        let oldBits = (current >> shift) & 0b111
        var newBits = newReadWrite & 0b110
        if isDirectory {
            if newBits & 0b100 != 0 { newBits |= 0b001 }
        } else {
            newBits |= oldBits & 0b001
        }
        return (current & ~(0b111 << shift)) | (newBits << shift)
    }

    private func refreshPermissionControls() {
        permissionSummaryLabel.stringValue = permissionInfo().summary
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: itemURL.path),
              let posix = attributes[.posixPermissions] as? Int else { return }
        for (shift, popup) in privilegePopups {
            let readWrite = (posix >> shift) & 0b110
            if let index = popup.itemArray.firstIndex(where: { $0.tag == readWrite }) {
                popup.selectItem(at: index)
            }
        }
    }

    private func permissionInfo() -> (summary: String, rows: [(String, String)]) {
        let fm = FileManager.default
        let readable = fm.isReadableFile(atPath: itemURL.path)
        let writable = fm.isWritableFile(atPath: itemURL.path)
        let summary: String
        switch (readable, writable) {
        case (true, true): summary = "You can read and write"
        case (true, false): summary = "You can only read"
        case (false, true): summary = "You can only write"
        case (false, false): summary = "You have no access"
        }
        guard let attributes = try? fm.attributesOfItem(atPath: itemURL.path),
              let posix = attributes[.posixPermissions] as? Int else {
            return (summary, [])
        }
        func privilege(_ bits: Int) -> String {
            let canRead = bits & 0b100 != 0
            let canWrite = bits & 0b010 != 0
            if canRead && canWrite { return "Read & Write" }
            if canRead { return "Read only" }
            if canWrite { return "Write only" }
            return "No Access"
        }
        let owner = attributes[.ownerAccountName] as? String ?? "owner"
        let group = attributes[.groupOwnerAccountName] as? String ?? "group"
        let ownerLabel = owner == NSUserName() ? "\(owner) (Me)" : owner
        return (summary, [
            (ownerLabel, privilege(posix >> 6)),
            (group, privilege(posix >> 3)),
            ("everyone", privilege(posix)),
        ])
    }

    private func calculateFolderSize() {
        let url = itemURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var total: Int64 = 0
            var count = 0
            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                options: [],
                errorHandler: { _, _ in true })
            while let item = enumerator?.nextObject() as? URL {
                guard self != nil else { return }  // panel closed — stop working
                if let size = (try? item.resourceValues(
                    forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize {
                    total += Int64(size)
                }
                count += 1
            }
            let text = "\(Self.byteFormatter.string(fromByteCount: total)) for \(count) items"
            DispatchQueue.main.async { [weak self] in
                self?.sizeValueLabel.stringValue = text
            }
        }
    }
}
