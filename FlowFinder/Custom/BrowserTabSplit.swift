import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Split state

enum SplitSide {
    case left, right

    var opposite: SplitSide { self == .left ? .right : .left }
}

/// The second pane of a split tab. A class so dragging the divider or moving the focus doesn't
/// rewrite the store's tab array; focus changes are forwarded to the owning store because the
/// window's menus, toolbar and sidebar follow the focused pane.
@MainActor
final class TabSplitState: ObservableObject {
    let rightViewModel: FileBrowserViewModel
    @Published var ratio: CGFloat
    @Published var focusedSide: SplitSide {
        willSet {
            if newValue != focusedSide { owner?.objectWillChange.send() }
        }
    }
    weak var owner: BrowserTabStore?

    init(rightViewModel: FileBrowserViewModel, ratio: CGFloat = 0.5, focusedSide: SplitSide = .left) {
        self.rightViewModel = rightViewModel
        self.ratio = ratio
        self.focusedSide = focusedSide
    }
}

extension EnvironmentValues {
    /// False for the unfocused pane of a split tab: its file view doesn't take the arrow keys.
    @Entry var isFocusedSplitPane: Bool = true
    /// True inside either pane of a split tab.
    @Entry var isInSplitPane: Bool = false
}

extension BrowserTab {
    init(viewModel: FileBrowserViewModel) {
        self.id = UUID()
        self.viewModel = viewModel
        self.split = nil
    }

    var focusedSide: SplitSide { split?.focusedSide ?? .left }

    var focusedViewModel: FileBrowserViewModel {
        viewModel(for: focusedSide)
    }

    func viewModel(for side: SplitSide) -> FileBrowserViewModel {
        if side == .right, let split { return split.rightViewModel }
        return viewModel
    }

    var allViewModels: [FileBrowserViewModel] {
        [viewModel] + (split.map { [$0.rightViewModel] } ?? [])
    }
}

// MARK: - Tab store operations

extension BrowserTabStore {
    static let closedTabHistoryLimit = 20

    func recordClosedTab(_ tab: BrowserTab) {
        InstallerCleanup.panesDidClose(tab.allViewModels, in: self)
        closedTabURLs.append(ContentView.newTabFolder(for: tab.viewModel))
        if closedTabURLs.count > Self.closedTabHistoryLimit {
            closedTabURLs.removeFirst(closedTabURLs.count - Self.closedTabHistoryLimit)
        }
    }

    /// The newest closed tab's folder that still exists.
    func popClosedTabURL() -> URL? {
        while let url = closedTabURLs.popLast() {
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    func index(of tabId: UUID) -> Int? {
        tabs.firstIndex(where: { $0.id == tabId })
    }

    func insertTab(_ tab: BrowserTab, at index: Int) {
        tab.split?.owner = self
        tabs.insert(tab, at: min(max(index, 0), tabs.count))
        selectedTabId = tab.id
    }

    /// Moves a tab so it ends up before the tab now at `insertionIndex` (`tabs.count`: last).
    func moveTab(_ tabId: UUID, toInsertionIndex insertionIndex: Int) {
        guard let from = index(of: tabId) else { return }
        let destination = insertionIndex > from ? insertionIndex - 1 : insertionIndex
        guard destination != from else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: min(max(destination, 0), tabs.count))
    }

    /// ⌥⌘1–⌥⌘8 select that tab, ⌥⌘9 the last one.
    func selectTab(atShortcutIndex index: Int) {
        guard !tabs.isEmpty else { return }
        if index >= 8 {
            selectedTabId = tabs[tabs.count - 1].id
        } else if index < tabs.count {
            selectedTabId = tabs[index].id
        }
    }

    func closeTabs(otherThan tabId: UUID) -> [BrowserTab] {
        guard let keep = tabs.first(where: { $0.id == tabId }) else { return [] }
        let removed = tabs.filter { $0.id != tabId }
        removed.forEach(recordClosedTab)
        tabs = [keep]
        selectedTabId = tabId
        return removed
    }

    func closeTabs(rightOf tabId: UUID) -> [BrowserTab] {
        guard let index = index(of: tabId), index + 1 < tabs.count else { return [] }
        let removed = Array(tabs[(index + 1)...])
        removed.forEach(recordClosedTab)
        tabs.removeSubrange((index + 1)...)
        if !tabs.contains(where: { $0.id == selectedTabId }) {
            selectedTabId = tabId
        }
        return removed
    }

    func split(_ tabId: UUID, rightViewModel: FileBrowserViewModel) {
        guard let index = index(of: tabId), tabs[index].split == nil else { return }
        let split = TabSplitState(rightViewModel: rightViewModel, focusedSide: .right)
        split.owner = self
        tabs[index].split = split
    }

    /// The right pane becomes a tab of its own next to the tab, which is selected again.
    @discardableResult
    func unsplit(_ tabId: UUID) -> BrowserTab? {
        guard let index = index(of: tabId), let split = tabs[index].split else { return nil }
        tabs[index].split = nil
        let rightTab = BrowserTab(viewModel: split.rightViewModel)
        tabs.insert(rightTab, at: index + 1)
        selectedTabId = tabId
        return rightTab
    }

    /// Closes one pane of a split tab; the other one stays as a plain tab in its place. Returns the
    /// closed pane's view model so it can be shut down.
    @discardableResult
    func closeSplitSide(_ tabId: UUID, side: SplitSide) -> FileBrowserViewModel? {
        guard let index = index(of: tabId), let split = tabs[index].split else { return nil }
        let closed = tabs[index].viewModel(for: side)
        recordClosedTab(BrowserTab(viewModel: closed))
        if side == .right {
            tabs[index].split = nil
        } else {
            let remaining = BrowserTab(viewModel: split.rightViewModel)
            let wasSelected = selectedTabId == tabId
            tabs[index] = remaining
            if wasSelected { selectedTabId = remaining.id }
        }
        return closed
    }

    func swapSides(_ tabId: UUID) {
        guard let index = index(of: tabId), let split = tabs[index].split else { return }
        var swapped = BrowserTab(viewModel: split.rightViewModel)
        let newSplit = TabSplitState(
            rightViewModel: tabs[index].viewModel,
            ratio: 1 - split.ratio,
            focusedSide: split.focusedSide.opposite
        )
        newSplit.owner = self
        swapped.split = newSplit
        let wasSelected = selectedTabId == tabId
        tabs[index] = swapped
        if wasSelected { selectedTabId = swapped.id }
    }

    /// Whether `draggedTabId` can be dropped on the selected tab's content to make it a split tab.
    func canMerge(_ draggedTabId: UUID) -> Bool {
        guard draggedTabId != selectedTabId,
              let dragged = tabs.first(where: { $0.id == draggedTabId }) else { return false }
        return dragged.split == nil && selectedTab.split == nil
    }

    /// Joins the dragged tab with the selected one; the dragged tab's pane goes to `side` and is focused.
    func merge(_ draggedTabId: UUID, onto side: SplitSide) {
        guard canMerge(draggedTabId),
              let draggedIndex = index(of: draggedTabId) else { return }
        let dragged = tabs.remove(at: draggedIndex)
        guard let targetIndex = index(of: selectedTabId) else { return }
        let target = tabs[targetIndex]
        var merged: BrowserTab
        let split: TabSplitState
        if side == .right {
            merged = target
            split = TabSplitState(rightViewModel: dragged.viewModel, focusedSide: .right)
        } else {
            merged = dragged
            split = TabSplitState(rightViewModel: target.viewModel, focusedSide: .left)
        }
        split.owner = self
        merged.split = split
        tabs[targetIndex] = merged
        selectedTabId = merged.id
        for viewModel in merged.allViewModels where viewModel.viewMode == .dualPane || viewModel.viewMode == .quadPane {
            viewModel.viewMode = .coverFlow
        }
    }
}

// MARK: - Copy / move to the other pane

enum SplitPaneTransfer {
    /// F5 / F6: the focused pane's selection goes to the folder the other pane shows, through the
    /// same undoable transfer a drop uses.
    @MainActor
    static func transfer(from source: FileBrowserViewModel, to destination: FileBrowserViewModel, operation: FileDropOperation) {
        let urls = source.filteredItems
            .filter { source.selectedItems.contains($0) && !$0.isFromArchive && $0.url.isFileURL && !source.isPhotosItem($0) }
            .map(\.url)
        guard !urls.isEmpty,
              !(operation == .move && FileOperationEngine.canonicalPath(source.currentPath) == FileOperationEngine.canonicalPath(destination.currentPath)) else {
            NSSound.beep()
            return
        }
        destination.handleDrop(urls: urls, operation: operation) { [weak source] in
            if operation == .move { source?.refresh() }
        }
    }
}

// MARK: - Window commands

extension Notification.Name {
    static let reopenClosedTab = Notification.Name("reopenClosedTab")
    static let selectTabAtIndex = Notification.Name("selectTabAtIndex")
    static let toggleSplitTab = Notification.Name("toggleSplitTab")
    static let copyToOtherPane = Notification.Name("copyToOtherPane")
    static let moveToOtherPane = Notification.Name("moveToOtherPane")
}

enum SplitTabCommand {
    static let tabIndexKey = "tabIndex"
}

struct SplitTabNotifications: ViewModifier {
    let isTargetWindow: (Any?) -> Bool
    let onReopenClosedTab: () -> Void
    let onSelectTab: (Int) -> Void
    let onToggleSplit: () -> Void
    let onTransfer: (FileDropOperation) -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .reopenClosedTab)) { notification in
                if isTargetWindow(notification.object) { onReopenClosedTab() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .selectTabAtIndex)) { notification in
                guard isTargetWindow(notification.object),
                      let index = notification.userInfo?[SplitTabCommand.tabIndexKey] as? Int else { return }
                onSelectTab(index)
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleSplitTab)) { notification in
                if isTargetWindow(notification.object) { onToggleSplit() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .copyToOtherPane)) { notification in
                if isTargetWindow(notification.object) { onTransfer(.copy) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .moveToOtherPane)) { notification in
                if isTargetWindow(notification.object) { onTransfer(.move) }
            }
    }
}

// MARK: - Split content

struct SplitTabContent: View {
    let tabId: UUID
    let leftViewModel: FileBrowserViewModel
    @ObservedObject var split: TabSplitState

    private let minPaneWidth: CGFloat = 220
    private let dividerHitWidth: CGFloat = 7

    var body: some View {
        GeometryReader { geometry in
            let available = max(geometry.size.width - 1, 1)
            let leftWidth = clampedLeftWidth(available: available)
            HStack(spacing: 0) {
                pane(.left, viewModel: leftViewModel)
                    .frame(width: leftWidth)
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
                    .overlay(dividerHandle(available: available))
                pane(.right, viewModel: split.rightViewModel)
                    .frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: "splitTabContent")
        }
    }

    private func clampedLeftWidth(available: CGFloat) -> CGFloat {
        let minimum = min(minPaneWidth, available / 2)
        return min(max(available * split.ratio, minimum), available - minimum)
    }

    private func pane(_ side: SplitSide, viewModel: FileBrowserViewModel) -> some View {
        let isFocused = split.focusedSide == side
        return TabContentWrapper(viewModel: viewModel, selectedTabId: tabId)
            .environment(\.isFocusedSplitPane, isFocused)
            .environment(\.isInSplitPane, true)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .opacity(isFocused ? 0.85 : 0)
                    .allowsHitTesting(false)
            }
            .background(MouseDownMonitor { _ in
                if split.focusedSide != side { split.focusedSide = side }
            })
            .modifier(SwipeNavigationPane(viewModel: viewModel, onActivate: {
                if split.focusedSide != side { split.focusedSide = side }
            }))
            .id(ObjectIdentifier(viewModel))
    }

    private func dividerHandle(available: CGFloat) -> some View {
        Color.clear
            .frame(width: dividerHitWidth)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("splitTabContent"))
                    .onChanged { value in
                        split.ratio = min(max(value.location.x / available, 0.05), 0.95)
                    }
            )
    }
}

// MARK: - Mouse monitoring

/// Calls `handler` for mouse-downs in its frame without taking them: SwiftUI's own gestures don't
/// see clicks on the AppKit file views, and there's no middle-click gesture.
struct MouseDownMonitor: NSViewRepresentable {
    var events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    let handler: (NSEvent) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.events = events
        view.handler = handler
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.handler = handler
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class MonitorView: NSView {
        var events: NSEvent.EventTypeMask = []
        var handler: ((NSEvent) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
                if let self, let window = self.window, event.window === window, !self.isHiddenOrHasHiddenAncestor {
                    let point = self.convert(event.locationInWindow, from: nil)
                    if self.bounds.contains(point) { self.handler?(event) }
                }
                return event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

// MARK: - Tab dragging

extension UTType {
    static let flowFinderTab = UTType(exportedAs: "com.ryuto.flowfinder.tab")
}

/// The tab being dragged in this process. Drop targets accept only a tab of their own window.
@MainActor
final class TabDragState {
    static let shared = TabDragState()
    private(set) var draggedTabId: UUID?
    /// Each drag's own token: a late release of an earlier drag's item provider (the same tab
    /// dragged again) must not end the current drag.
    private var session: UUID?

    /// Starts a tab drag. The state is cleared, and `onEnd` called, once the mouse button is up
    /// again, however the drag ended (dropped, refused, outside the bar, Esc).
    func beginDrag(_ tabId: UUID, onEnd: @escaping () -> Void) -> NSItemProvider {
        let session = UUID()
        self.session = session
        draggedTabId = tabId
        DropHighlightReset.shared.clearWhenDragEnds {
            onEnd()
            TabDragState.shared.endDrag(session: session)
        }
        return TabDragItemProvider(tabId: tabId, session: session)
    }

    /// Ends the drag (`session`: only if it is still that drag).
    func endDrag(session: UUID? = nil) {
        guard session == nil || session == self.session else { return }
        draggedTabId = nil
        self.session = nil
    }
}

/// Also ends the drag state when the drag session lets go of it.
final class TabDragItemProvider: NSItemProvider {
    private var session: UUID?

    convenience init(tabId: UUID, session: UUID) {
        self.init()
        self.session = session
        registerDataRepresentation(forTypeIdentifier: UTType.flowFinderTab.identifier, visibility: .ownProcess) { completion in
            completion(Data(tabId.uuidString.utf8), nil)
            return nil
        }
    }

    deinit {
        guard let session else { return }
        DispatchQueue.main.async {
            TabDragState.shared.endDrag(session: session)
        }
    }
}

/// Dropping a tab near the left or right edge of the content area makes it the left or right
/// pane of a split with the selected tab.
struct TabSplitDropTarget: ViewModifier {
    let isEnabled: Bool
    let canAccept: (UUID) -> Bool
    let onDrop: (UUID, SplitSide) -> Void

    @State private var zone: SplitSide?
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .background(GeometryReader { geometry in
                    Color.clear
                        .onAppear { width = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, newWidth in width = newWidth }
                })
                .overlay(alignment: zone == .right ? .trailing : .leading) {
                    if zone != nil {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.accentColor.opacity(0.14))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.7), lineWidth: 2))
                            .padding(6)
                            .frame(width: width / 2)
                            .allowsHitTesting(false)
                    }
                }
                .onDrop(of: [.flowFinderTab], delegate: Delegate(
                    width: width,
                    zone: $zone,
                    canAccept: canAccept,
                    onDrop: onDrop
                ))
        } else {
            content
        }
    }

    private struct Delegate: DropDelegate {
        let width: CGFloat
        @Binding var zone: SplitSide?
        let canAccept: (UUID) -> Bool
        let onDrop: (UUID, SplitSide) -> Void

        private var draggedTabId: UUID? {
            MainActor.assumeIsolated { TabDragState.shared.draggedTabId }
        }

        func validateDrop(info: DropInfo) -> Bool {
            guard let id = draggedTabId else { return false }
            return MainActor.assumeIsolated { canAccept(id) }
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            let x = info.location.x
            if x < width * 0.3 {
                zone = .left
            } else if x > width * 0.7 {
                zone = .right
            } else {
                zone = nil
            }
            return DropProposal(operation: zone == nil ? .forbidden : .move)
        }

        func dropExited(info: DropInfo) {
            zone = nil
        }

        func performDrop(info: DropInfo) -> Bool {
            let side = zone
            zone = nil
            guard let side, let id = draggedTabId else { return false }
            MainActor.assumeIsolated {
                TabDragState.shared.endDrag()
                onDrop(id, side)
            }
            return true
        }
    }
}
