import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// What the tab bar's context menu and gestures ask the window to do.
struct ChromeTabBarActions {
    let newTab: () -> Void
    let closeTab: (UUID) -> Void
    let duplicateTab: (UUID) -> Void
    let closeOtherTabs: (UUID) -> Void
    let closeTabsToRight: (UUID) -> Void
    let unsplit: (UUID) -> Void
    let swapSides: (UUID) -> Void
    /// Closes one pane of a split tab; the other stays as a plain tab.
    let closeSplitSide: (UUID, SplitSide) -> Void
}

/// The insertion line of a tab drag, and which drop target put it there.
struct TabDropMarker: Equatable {
    let index: Int
    let owner: Int
}

struct ChromeTabBar: View {
    @ObservedObject var store: BrowserTabStore
    let actions: ChromeTabBarActions

    /// Where a dragged tab would be inserted (index in `store.tabs`, `count` = last).
    @State private var dropMarker: TabDropMarker?

    static let height: CGFloat = 38
    private let minTabWidth: CGFloat = 100
    private let maxTabWidth: CGFloat = 240
    private let splitWidthFactor: CGFloat = 1.7

    private let newTabButtonWidth: CGFloat = 38

    var body: some View {
        GeometryReader { geometry in
            let widths = tabWidths(available: geometry.size.width)
            let tabsWidth = widths.reduce(0, +)
            // Too many tabs to fit: the tabs scroll and "+" stays at the right edge
            let overflows = tabsWidth + newTabButtonWidth > geometry.size.width
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(store.tabs.enumerated()), id: \.element.id) { index, tab in
                            ChromeTabItem(
                                tab: tab,
                                index: index,
                                isSelected: tab.id == store.selectedTabId,
                                canClose: store.tabs.count > 1,
                                hasTabsToRight: index < store.tabs.count - 1,
                                store: store,
                                actions: actions,
                                dropMarker: $dropMarker
                            )
                            .frame(width: widths[index], height: Self.height)
                            .clipped()
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.4, anchor: .leading)),
                                removal: .opacity.combined(with: .scale(scale: 0.4, anchor: .leading))
                            ))
                        }

                        if !overflows {
                            newTabButton
                        }

                        emptyArea(width: overflows ? 24 : max(geometry.size.width - tabsWidth - newTabButtonWidth, 0))
                    }
                    .frame(height: Self.height)
                    .animation(.spring(response: 0.28, dampingFraction: 0.86), value: tabLayoutKey)
                }
                .frame(width: overflows ? max(geometry.size.width - newTabButtonWidth, 0) : geometry.size.width)

                if overflows {
                    newTabButton
                }
            }
        }
        .frame(height: Self.height)
        .uiBackground(.chrome)
        // A target can still report a hover right after the drop moved the tabs.
        .onChange(of: store.tabs.map(\.id)) { _, _ in
            DispatchQueue.main.async { dropMarker = nil }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
    }

    /// Changes when tabs come, go, move or split: the bar animates to the new layout.
    private var tabLayoutKey: [String] {
        store.tabs.map { "\($0.id)\($0.split == nil ? "" : "|")" }
    }

    private var newTabButton: some View {
        Button(action: actions.newTab) {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New Tab (⌘T)")
        .frame(width: newTabButtonWidth, height: Self.height)
    }

    private func tabWidths(available: CGFloat) -> [CGFloat] {
        let units = store.tabs.map { $0.split == nil ? 1 : splitWidthFactor }
        let totalUnits = max(units.reduce(0, +), 1)
        let unitWidth = min(max((available - newTabButtonWidth) / totalUnits, minTabWidth), maxTabWidth)
        return units.map { ($0 * unitWidth).rounded(.down) }
    }

    private func emptyArea(width: CGFloat) -> some View {
        Color.clear
            .frame(width: width, height: Self.height)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                if dropMarker?.index == store.tabs.count {
                    TabDropIndicator()
                }
            }
            .onTapGesture(count: 2, perform: actions.newTab)
            .onDrop(of: [.flowFinderTab], delegate: ChromeTabDropDelegate(
                store: store,
                tabId: nil,
                targetIndex: store.tabs.count,
                width: 0,
                splitDividerX: nil,
                dropMarker: $dropMarker,
                fileDropSide: .constant(nil)
            ))
    }
}

private struct TabDropIndicator: View {
    var body: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: 2)
            .padding(.vertical, 6)
            .allowsHitTesting(false)
    }
}

private struct ChromeTabItem: View {
    @Environment(\.colorScheme) private var colorScheme
    let tab: BrowserTab
    let index: Int
    let isSelected: Bool
    let canClose: Bool
    let hasTabsToRight: Bool
    let store: BrowserTabStore
    let actions: ChromeTabBarActions
    @Binding var dropMarker: TabDropMarker?

    @State private var isHovering = false
    @State private var isCloseHovering = false
    /// The pane a file drag is over (`.left` for a plain tab).
    @State private var fileDropSide: SplitSide?
    @State private var splitDividerX: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 4) {
                if let split = tab.split {
                    SplitTabTitles(
                        leftViewModel: tab.viewModel,
                        split: split,
                        isSelected: isSelected,
                        showsCloseButtons: isHovering || isSelected,
                        dropSide: fileDropSide,
                        onSelect: select,
                        onClose: { actions.closeSplitSide(tab.id, $0) },
                        onDividerX: { splitDividerX = $0 }
                    )
                    unsplitButton
                        .padding(.trailing, 8)
                } else {
                    TabTitle(viewModel: tab.viewModel, isEmphasized: isSelected)
                        .padding(.leading, 12)
                    closeButton
                        .padding(.trailing, 8)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(background)
            .overlay {
                if tab.split == nil && fileDropSide != nil {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.accentColor, lineWidth: 2)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 3)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
                    .padding(.vertical, 9)
                    .opacity(isSelected ? 0 : 1)
            }
            .overlay(alignment: .leading) {
                if dropMarker?.index == index { TabDropIndicator() }
            }
            .contentShape(Rectangle())
            .onTapGesture { select(nil) }
            .onHover { isHovering = $0 }
            .background(MouseDownMonitor(events: [.otherMouseDown]) { event in
                if event.buttonNumber == 2 && canClose { actions.closeTab(tab.id) }
            })
            .coordinateSpace(name: ChromeTabItem.coordinateSpace)
            .onDrag {
                let binding = $dropMarker
                return TabDragState.shared.beginDrag(tab.id) {
                    binding.wrappedValue = nil
                }
            }
            .onDrop(of: [.flowFinderTab] + DropHelper.acceptedDropTypes, delegate: ChromeTabDropDelegate(
                store: store,
                tabId: tab.id,
                targetIndex: index,
                width: geometry.size.width,
                splitDividerX: tab.split == nil ? nil : splitDividerX,
                dropMarker: $dropMarker,
                fileDropSide: $fileDropSide
            ))
            .contextMenu { contextMenu }
            .help(helpText)
        }
    }

    static let coordinateSpace = "chromeTabItem"

    /// Selects the tab; a click on a pane of a split tab also focuses that pane.
    private func select(_ side: SplitSide?) {
        store.selectedTabId = tab.id
        guard let split = tab.split, let side else { return }
        if split.focusedSide != side { split.focusedSide = side }
        SwipeNavigator.shared.focusPane(of: tab.viewModel(for: side))
    }

    private var unsplitButton: some View {
        Button(action: { actions.unsplit(tab.id) }) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 20, height: 18)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(isCloseHovering ? 0.12 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isCloseHovering = $0 }
        .help("Unsplit")
        .opacity(isHovering || isSelected ? 1 : 0.55)
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(backgroundColor)
            .shadow(color: .black.opacity(isSelected ? 0.12 : 0), radius: 1.5, y: 0.5)
            .padding(.vertical, 4)
            .padding(.horizontal, 3)
    }

    private var backgroundColor: Color {
        if isSelected {
            return colorScheme == .dark ? Color.white.opacity(0.11) : Color(nsColor: .controlBackgroundColor)
        }
        return isHovering ? Color.primary.opacity(0.06) : Color.clear
    }

    @ViewBuilder
    private var closeButton: some View {
        if canClose && (isHovering || isSelected) {
            Button(action: { actions.closeTab(tab.id) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.primary.opacity(isCloseHovering ? 0.12 : 0)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { isCloseHovering = $0 }
            .help("Close Tab (⌘W)")
        } else {
            Color.clear.frame(width: 18, height: 18)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Duplicate Tab") { actions.duplicateTab(tab.id) }
        Divider()
        Button("Close Tab") { actions.closeTab(tab.id) }
            .disabled(!canClose)
        Button("Close Other Tabs") { actions.closeOtherTabs(tab.id) }
            .disabled(!canClose)
        Button("Close Tabs to the Right") { actions.closeTabsToRight(tab.id) }
            .disabled(!hasTabsToRight)
        if tab.split != nil {
            Divider()
            Button("Unsplit Tab") { actions.unsplit(tab.id) }
            Button("Swap Left and Right") { actions.swapSides(tab.id) }
        }
    }

    private var helpText: String {
        tab.allViewModels.map { $0.currentPath.path }.joined(separator: "  |  ")
    }
}

/// A folder icon and the location's name; observes the view model so it follows navigation.
private struct TabTitle: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    let isEmphasized: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: iconPath))
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
            Text(viewModel.locationTitle)
                .font(.system(size: 13, weight: isEmphasized ? .medium : .regular))
                .foregroundColor(isEmphasized ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private var iconPath: String {
        if viewModel.isInsideArchive, let archiveURL = viewModel.currentArchiveURL {
            return archiveURL.path
        }
        return viewModel.currentPath.path
    }
}

/// The two panes of a split tab as joined segments; the focused one stands out.
private struct SplitTabTitles: View {
    @Environment(\.colorScheme) private var colorScheme
    let leftViewModel: FileBrowserViewModel
    @ObservedObject var split: TabSplitState
    let isSelected: Bool
    let showsCloseButtons: Bool
    let dropSide: SplitSide?
    let onSelect: (SplitSide) -> Void
    let onClose: (SplitSide) -> Void
    let onDividerX: (CGFloat) -> Void

    var body: some View {
        HStack(spacing: 0) {
            segment(.left, viewModel: leftViewModel)
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .padding(.vertical, 3)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .named(ChromeTabItem.coordinateSpace)).midX
                } action: { x in
                    onDividerX(x)
                }
            segment(.right, viewModel: split.rightViewModel)
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .padding(.leading, 6)
        .padding(.vertical, 5)
    }

    private func segment(_ side: SplitSide, viewModel: FileBrowserViewModel) -> some View {
        let isFocused = isSelected && split.focusedSide == side
        return HStack(spacing: 2) {
            TabTitle(viewModel: viewModel, isEmphasized: isFocused || (!isSelected && side == .left))
            if showsCloseButtons {
                SegmentCloseButton(side: side) { onClose(side) }
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, showsCloseButtons ? 3 : 7)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isFocused ? Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.13) : Color.clear)
                .padding(1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.accentColor, lineWidth: 2)
                .padding(1)
                .opacity(dropSide == side ? 1 : 0)
                .allowsHitTesting(false)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect(side) }
    }
}

/// Closes one pane of a split tab.
private struct SegmentCloseButton: View {
    let side: SplitSide
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundColor(.secondary)
                .frame(width: 14, height: 14)
                .background(Circle().fill(Color.primary.opacity(isHovering ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(side == .left ? Text("Close Left Pane") : Text("Close Right Pane"))
    }
}

/// A tab's drop target: a dragged tab is inserted before or after it; files go into the folder
/// its pane shows, and resting on it with files switches to it (spring-loading).
private struct ChromeTabDropDelegate: DropDelegate {
    let store: BrowserTabStore
    /// nil for the space after the last tab (tab drags only).
    let tabId: UUID?
    let targetIndex: Int
    let width: CGFloat
    /// A split tab's divider; files dropped left of it go into the left pane.
    let splitDividerX: CGFloat?
    @Binding var dropMarker: TabDropMarker?
    @Binding var fileDropSide: SplitSide?

    private var draggedTabId: UUID? {
        MainActor.assumeIsolated { TabDragState.shared.draggedTabId }
    }

    private func isTabDrag(_ info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.flowFinderTab])
    }

    func validateDrop(info: DropInfo) -> Bool {
        if isTabDrag(info) {
            guard let id = draggedTabId else { return false }
            return MainActor.assumeIsolated { store.index(of: id) != nil }
        }
        return tabId != nil
            && info.hasItemsConforming(to: DropHelper.acceptedDropTypes)
            && !MainActor.assumeIsolated { DropHelper.isSidebarFavoriteDrag() }
    }

    func dropEntered(info: DropInfo) {
        _ = dropUpdated(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if isTabDrag(info) {
            let index = (width > 0 && info.location.x > width / 2) ? targetIndex + 1 : targetIndex
            let marker = TabDropMarker(index: index, owner: targetIndex)
            if dropMarker != marker { dropMarker = marker }
            return DropProposal(operation: .move)
        }
        return MainActor.assumeIsolated { fileDropUpdated(info) }
    }

    func dropExited(info: DropInfo) {
        if dropMarker?.owner == targetIndex { dropMarker = nil }
        if fileDropSide != nil { fileDropSide = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        if isTabDrag(info) {
            let insertion = dropMarker?.index ?? targetIndex
            dropMarker = nil
            guard let id = draggedTabId else { return false }
            MainActor.assumeIsolated {
                TabDragState.shared.endDrag()
                withAnimation(.easeOut(duration: 0.15)) {
                    store.moveTab(id, toInsertionIndex: insertion)
                }
            }
            return true
        }
        return MainActor.assumeIsolated { performFileDrop(info) }
    }

    // MARK: Files

    private func side(at location: CGPoint) -> SplitSide {
        guard let splitDividerX else { return .left }
        return location.x < splitDividerX ? .left : .right
    }

    @MainActor
    private var tab: BrowserTab? {
        tabId.flatMap { id in store.tabs.first { $0.id == id } }
    }

    @MainActor
    private func isUsefulDrop(into viewModel: FileBrowserViewModel) -> Bool {
        guard viewModel.canAddItemsToCurrentLocation else { return false }
        let flags = NSEvent.modifierFlags
        if DropHelper.isAliasDrop(modifierFlags: flags) { return true }
        let sources = DropHelper.dragSourceURLs()
        let destination = viewModel.currentPath
        if DropHelper.isSelfOrDescendantDrop(sources: sources, destination: destination) { return false }
        return !DropHelper.isNoOpDrop(sources: sources, destination: destination, operation: FileDropOperation(modifierFlags: flags))
    }

    @MainActor
    private func fileDropUpdated(_ info: DropInfo) -> DropProposal? {
        guard let tab else { return DropProposal(operation: .forbidden) }
        let side = side(at: info.location)
        if fileDropSide != side {
            fileDropSide = side
            let binding = $fileDropSide
            DropHighlightReset.shared.clearWhenDragEnds { binding.wrappedValue = nil }
        }
        springLoad(tab, side: side)

        let viewModel = tab.viewModel(for: side)
        guard isUsefulDrop(into: viewModel) else { return DropProposal(operation: .forbidden) }
        return DropProposal(operation: DropHelper.dropOperation(
            for: FileDropOperation(modifierFlags: NSEvent.modifierFlags),
            sources: DropHelper.dragSourceURLs(),
            destination: viewModel.currentPath
        ))
    }

    /// Resting on a tab (or the other pane of the split tab in front) shows it.
    @MainActor
    private func springLoad(_ tab: BrowserTab, side: SplitSide) {
        let key = "tab-\(tab.id)-\(side)"
        if store.selectedTabId == tab.id && tab.focusedSide == side {
            SpringLoader.shared.cancel(key: key)
            return
        }
        let binding = $fileDropSide
        let store = store
        let tabId = tab.id
        SpringLoader.shared.hover(
            key,
            isTargeted: { binding.wrappedValue == side },
            blink: { visible in
                if visible {
                    if binding.wrappedValue == nil { binding.wrappedValue = side }
                } else if binding.wrappedValue == side {
                    binding.wrappedValue = nil
                }
            },
            open: {
                guard let tab = store.tabs.first(where: { $0.id == tabId }) else { return }
                store.selectedTabId = tabId
                if let split = tab.split, split.focusedSide != side { split.focusedSide = side }
            }
        )
    }

    @MainActor
    private func performFileDrop(_ info: DropInfo) -> Bool {
        let side = side(at: info.location)
        fileDropSide = nil
        defer { InternalDragState.shared.endDrag() }
        guard let viewModel = tab?.viewModel(for: side), isUsefulDrop(into: viewModel) else { return false }
        let flags = NSEvent.modifierFlags
        let providers = info.itemProviders(for: [.fileURL])
        if DropHelper.isAliasDrop(modifierFlags: flags) {
            return DropHelper.performAliasDrop(providers: providers, into: viewModel.currentPath, viewModel: viewModel)
        }
        return DropHelper.performDrop(
            providers: providers,
            into: viewModel.currentPath,
            viewModel: viewModel,
            operation: FileDropOperation(modifierFlags: flags)
        )
    }
}
