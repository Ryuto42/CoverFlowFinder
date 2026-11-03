import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension View {
    /// Puts the Drop Stack under the sidebar.
    func dropStackPanel() -> some View {
        VStack(spacing: 0) {
            self
            DropStackPanel()
        }
    }
}

struct DropStackPanel: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var store = DropStackStore.shared
    @State private var isTargeted = false

    private static let rowHeight: CGFloat = 24
    private static let maxVisibleRows = 6

    var body: some View {
        if settings.showDropStack {
            VStack(spacing: 0) {
                Divider()
                header
                if !store.isCollapsed {
                    if store.items.isEmpty {
                        emptyArea
                    } else {
                        DropStackList(items: store.items)
                            .frame(height: CGFloat(min(store.items.count, Self.maxVisibleRows)) * Self.rowHeight + 4)
                            .padding(.bottom, 4)
                    }
                }
            }
            .uiBackground(.chrome)
            .onDrop(of: [.fileURL], delegate: DropStackDropDelegate(isTargeted: $isTargeted))
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { store.isCollapsed.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(store.isCollapsed ? 0 : 90))
                    Text("Drop Stack")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !store.items.isEmpty {
                Text(verbatim: "\(store.items.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.2)))
            }

            Spacer(minLength: 0)

            if !store.existingItems.isEmpty {
                DropStackDragAllHandle()
                    .frame(width: 18, height: 16)
                    .help("Drag all items")
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isTargeted && !store.isCollapsed && !store.items.isEmpty ? Color.accentColor.opacity(0.15) : .clear)
        .contextMenu {
            Button("Clear All") { store.removeAll() }
                .disabled(store.items.isEmpty)
        }
    }

    private var emptyArea: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.5),
                          style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [4, 3]))
            .background(RoundedRectangle(cornerRadius: 8).fill(isTargeted ? Color.accentColor.opacity(0.1) : .clear))
            .overlay {
                Text("Drag items here")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(height: 52)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
    }
}

private struct DropStackDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        !DropStackStore.shared.isDraggingOut && info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        DropHelper.collectFileURLs(from: providers) { urls in
            MainActor.assumeIsolated {
                DropStackStore.shared.add(urls)
            }
        }
        return true
    }
}

// MARK: - List

private struct DropStackList: NSViewRepresentable {
    let items: [DropStackStore.Item]

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = DropStackTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.rowHeight = 24
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.allowsMultipleSelection = true
        tableView.focusRingType = .none
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask(.every, forLocal: true)
        tableView.setDraggingSourceOperationMask(.every, forLocal: false)
        tableView.draggingDestinationFeedbackStyle = .regular
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.openClickedItem(_:))
        let menu = NSMenu()
        menu.delegate = context.coordinator
        tableView.menu = menu
        context.coordinator.tableView = tableView

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(items)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        weak var tableView: NSTableView?
        private var items: [DropStackStore.Item] = []
        private var draggedIDs: Set<UUID> = []
        private let thumbnailOwner = ThumbnailRequestOwner()
        private var thumbnails: [URL: NSImage] = [:]
        private var requestedThumbnails: Set<URL> = []

        func update(_ newItems: [DropStackStore.Item]) {
            guard newItems != items, let tableView else { return }
            let selectedIDs = Set(tableView.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0].id : nil })
            items = newItems
            tableView.reloadData()
            let rows = IndexSet(items.indices.filter { selectedIDs.contains(items[$0].id) })
            tableView.selectRowIndexes(rows, byExtendingSelection: false)
        }

        /// The clicked row's items: the selection when the row is in it.
        private func targetItems(clickedRow row: Int) -> [DropStackStore.Item] {
            guard let tableView, items.indices.contains(row) else { return [] }
            if tableView.selectedRowIndexes.contains(row) {
                return tableView.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0] : nil }
            }
            return [items[row]]
        }

        fileprivate func selectedItems() -> [DropStackStore.Item] {
            guard let tableView else { return [] }
            return tableView.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0] : nil }
        }

        @objc func openClickedItem(_ sender: Any?) {
            guard let tableView, items.indices.contains(tableView.clickedRow) else { return }
            let item = items[tableView.clickedRow]
            guard item.exists else {
                NSSound.beep()
                return
            }
            NSWorkspace.shared.open(item.url)
        }

        // MARK: Rows

        func numberOfRows(in tableView: NSTableView) -> Int {
            items.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("DropStackCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? DropStackCell ?? DropStackCell()
            cell.identifier = identifier
            let item = items[row]
            cell.textField?.stringValue = FileManager.default.displayName(atPath: item.url.path)
            cell.imageView?.image = icon(for: item)
            cell.alphaValue = item.exists ? 1 : 0.4
            cell.toolTip = item.exists ? (item.url.path as NSString).abbreviatingWithTildeInPath : String(localized: "The item can’t be found.")
            return cell
        }

        private func icon(for item: DropStackStore.Item) -> NSImage {
            let url = item.url
            if let thumbnail = thumbnails[url] { return thumbnail }
            guard item.exists else { return NSWorkspace.shared.icon(for: .item) }
            let fileItem = FileItem(url: url)
            if !fileItem.isDirectory, !requestedThumbnails.contains(url),
               ThumbnailCacheManager.mediaKind(forPathExtension: url.pathExtension) != .other {
                requestedThumbnails.insert(url)
                ThumbnailCacheManager.shared.requestThumbnail(for: fileItem, maxPixelSize: 64, owner: thumbnailOwner) { [weak self] result in
                    MainActor.assumeIsolated {
                        guard let self, let image = result.image else { return }
                        self.thumbnails[url] = image
                        if let row = self.items.firstIndex(where: { $0.url == url }) {
                            self.tableView?.reloadData(forRowIndexes: [row], columnIndexes: [0])
                        }
                    }
                }
                if let thumbnail = thumbnails[url] { return thumbnail }
            }
            return fileItem.icon
        }

        // MARK: Dragging out

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard items.indices.contains(row), items[row].exists else { return nil }
            return items[row].url as NSURL
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            let dragged = rowIndexes.compactMap { items.indices.contains($0) && items[$0].exists ? items[$0] : nil }
            draggedIDs = Set(dragged.map(\.id))
            DropStackStore.shared.isDraggingOut = true
            InternalDragState.shared.beginDrag(urls: dragged.map(\.url))
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            DropStackStore.shared.isDraggingOut = false
            InternalDragState.shared.endDrag()
            let ids = draggedIDs
            draggedIDs = []
            if !operation.isEmpty {
                DropStackStore.shared.didTakeOut(ids)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                DropStackStore.shared.refresh()
            }
        }

        // MARK: Dropping in

        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard !DropStackStore.shared.isDraggingOut, !Self.fileURLs(in: info).isEmpty else { return [] }
            tableView.setDropRow(-1, dropOperation: .on)
            let mask = info.draggingSourceOperationMask
            return [NSDragOperation.copy, .link, .generic, .move].first { mask.contains($0) } ?? []
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            let urls = Self.fileURLs(in: info)
            guard !urls.isEmpty else { return false }
            DropStackStore.shared.add(urls)
            return true
        }

        private static func fileURLs(in info: any NSDraggingInfo) -> [URL] {
            (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tableView else { return }
            let targets = targetItems(clickedRow: tableView.clickedRow)
            let window = tableView.window
            let canUse = targets.contains(where: \.exists)
            let canTransfer = canUse && DropStackActions.canTransfer(into: DropStackActions.activeViewModel(for: window))
            var entries: [CustomMenuEntry] = []
            if !targets.isEmpty {
                entries += [
                    .action(String(localized: "Move Here"), enabled: canTransfer) {
                        DropStackActions.transfer(targets, operation: .move, window: window)
                    },
                    .action(String(localized: "Copy Here"), enabled: canTransfer) {
                        DropStackActions.transfer(targets, operation: .copy, window: window)
                    },
                    .separator,
                    .action(String(localized: "Show in Finder"), enabled: canUse) {
                        DropStackActions.reveal(targets)
                    },
                    .separator,
                    .action(String(localized: "Remove from Stack"), enabled: true) {
                        DropStackStore.shared.remove(Set(targets.map(\.id)))
                    }
                ]
            }
            entries.append(.action(String(localized: "Clear All"), enabled: !items.isEmpty) {
                DropStackStore.shared.removeAll()
            })
            CustomActions.append(entries, to: menu)
        }
    }
}

private final class DropStackTableView: NSTableView {
    override func keyDown(with event: NSEvent) {
        let deleteKeys: Set<UInt16> = [51, 117]
        if deleteKeys.contains(event.keyCode),
           let coordinator = delegate as? DropStackList.Coordinator {
            let ids = Set(coordinator.selectedItems().map(\.id))
            if !ids.isEmpty {
                DropStackStore.shared.remove(ids)
                return
            }
        }
        super.keyDown(with: event)
    }
}

private final class DropStackCell: NSTableCellView {
    init() {
        super.init(frame: .zero)
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        let textField = NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingMiddle
        textField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(imageView)
        addSubview(textField)
        self.imageView = imageView
        self.textField = textField
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 18),
            imageView.heightAnchor.constraint(equalToConstant: 18),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Drag all

/// The header's handle that drags every item of the stack at once.
private struct DropStackDragAllHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragAllHandleView {
        DragAllHandleView()
    }

    func updateNSView(_ nsView: DragAllHandleView, context: Context) {}
}

private final class DragAllHandleView: NSView, NSDraggingSource {
    private let imageView = NSImageView()
    private var mouseDownPoint: NSPoint?
    private var draggedIDs: Set<UUID> = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: String(localized: "Drag all items"))
        imageView.contentTintColor = .secondaryLabelColor
        imageView.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
        mouseDownPoint = nil
        MainActor.assumeIsolated { beginDrag(event: event, at: point) }
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
    }

    @MainActor
    private func beginDrag(event: NSEvent, at point: NSPoint) {
        let items = DropStackStore.shared.existingItems
        guard !items.isEmpty else { return }
        let draggingItems = items.enumerated().map { index, item in
            let draggingItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
            let offset = CGFloat(min(index, 4)) * 3
            draggingItem.setDraggingFrame(NSRect(x: point.x - 16 + offset, y: point.y - 16 - offset, width: 32, height: 32),
                                          contents: NSWorkspace.shared.icon(forFile: item.url.path))
            return draggingItem
        }
        draggedIDs = Set(items.map(\.id))
        DropStackStore.shared.isDraggingOut = true
        InternalDragState.shared.beginDrag(urls: items.map(\.url))
        beginDraggingSession(with: draggingItems, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .every
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated {
            DropStackStore.shared.isDraggingOut = false
            InternalDragState.shared.endDrag()
            let ids = draggedIDs
            draggedIDs = []
            if !operation.isEmpty {
                DropStackStore.shared.didTakeOut(ids)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                DropStackStore.shared.refresh()
            }
        }
    }
}
