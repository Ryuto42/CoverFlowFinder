import AppKit
import Combine
import SwiftUI

/// Finder's "Always open in … view": the folders that keep their own view mode and icon sizes,
/// applied whenever a pane opens them (navigation, back/forward, new and restored tabs).
///
/// Sort and list columns stay in `PerFolderColumnStateManager`; this store adds what that one
/// lacks. Keyed like it, by standardized path. Icon sizes are app-wide settings, so a folder's
/// sizes are applied to them while it is shown and the defaults come back for other folders.
/// Main thread only.
@MainActor
final class FolderViewOptionsStore: ObservableObject {
    static let shared = FolderViewOptionsStore()

    struct Sizes: Codable, Equatable {
        var iconGridIconSize: Double
        var iconGridSpacing: Double
        var iconGridFontSize: Double
        var listIconSize: Double

        @MainActor static var current: Sizes {
            let settings = AppSettings.shared
            return Sizes(iconGridIconSize: settings.iconGridIconSize, iconGridSpacing: settings.iconGridSpacing,
                         iconGridFontSize: settings.iconGridFontSize, listIconSize: settings.listIconSize)
        }
    }

    struct Entry: Codable {
        var viewMode: String?
        var sizes: Sizes?
    }

    private struct SavedData: Codable {
        var entries: [String: Entry]
        var order: [String]
        var defaultSizes: Sizes?
    }

    private static let maxEntries = 2000
    private let persistenceKey = "FolderViewOptions"

    @Published private(set) var revision = 0
    private var entries: [String: Entry] = [:]
    private var order: [String] = []  // Most recently used at end
    /// The sizes folders without their own use
    private var defaultSizes: Sizes?
    /// The folder whose sizes are applied now (nil: the defaults are)
    private var appliedKey: String?
    /// The sizes last seen in the settings, to tell user changes from applied ones
    private var knownSizes: Sizes
    private var sizeCheckScheduled = false
    private var pendingSave: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []
    /// View models seen once: right after creation their creator still sets the view mode
    private let seenViewModels = NSHashTable<FileBrowserViewModel>.weakObjects()

    private init() {
        knownSizes = Sizes.current
        if let data = UserDefaults.standard.data(forKey: persistenceKey),
           let saved = try? JSONDecoder().decode(SavedData.self, from: data) {
            entries = saved.entries
            order = saved.order.filter { saved.entries[$0] != nil }
            order = entries.keys.filter { !order.contains($0) } + order
            defaultSizes = saved.defaultSizes
        }
        let settings = AppSettings.shared
        Publishers.MergeMany(
            settings.$iconGridIconSize.map { _ in () }.eraseToAnyPublisher(),
            settings.$iconGridSpacing.map { _ in () }.eraseToAnyPublisher(),
            settings.$iconGridFontSize.map { _ in () }.eraseToAnyPublisher(),
            settings.$listIconSize.map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self] in
            MainActor.assumeIsolated { self?.scheduleSizeCheck() }
        }
        .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.flushPendingSave() }
            }
            .store(in: &cancellables)
    }

    static func key(for folder: URL) -> String {
        PerFolderColumnStateManager.key(for: folder)
    }

    /// Whether the view options can be remembered for the pane's current location (not inside an
    /// archive, the Photos library or /Network, like the per-folder column state).
    static func canRemember(_ viewModel: FileBrowserViewModel) -> Bool {
        !viewModel.isInsideArchive && !viewModel.isPhotosLibraryActive && viewModel.currentPath.path != "/Network"
    }

    private static func isPaneLayout(_ mode: ViewMode) -> Bool {
        mode == .dualPane || mode == .quadPane
    }

    func isRemembered(_ folder: URL) -> Bool {
        entries[Self.key(for: folder)] != nil
    }

    // MARK: - Applying

    /// `viewModel` is about to show `folder` (called with its sort and column state).
    func apply(to viewModel: FileBrowserViewModel, folder: URL) {
        let isNew = !seenViewModels.contains(viewModel)
        if isNew {
            seenViewModels.add(viewModel)
        }
        let key = Self.key(for: folder)
        let entry = AppSettings.shared.rememberViewOptionsPerFolder && folder.path != "/Network" ? entries[key] : nil
        if entry != nil {
            markUsed(key)
        }
        applySizes(entry?.sizes, key: key)
        guard let raw = entry?.viewMode, let mode = ViewMode(rawValue: raw), !Self.isPaneLayout(mode) else { return }
        applyViewMode(mode, to: viewModel)
        if isNew {
            // New tabs, restored tabs and split panes get their mode from their creator after init
            DispatchQueue.main.async { [weak viewModel] in
                guard let viewModel, viewModel.currentPath.standardizedPathKey == key else { return }
                self.applyViewMode(mode, to: viewModel)
            }
        }
    }

    private func applyViewMode(_ mode: ViewMode, to viewModel: FileBrowserViewModel) {
        guard !Self.isPaneLayout(viewModel.viewMode), viewModel.viewMode != mode else { return }
        viewModel.viewMode = mode
    }

    private func applySizes(_ sizes: Sizes?, key: String) {
        if let sizes {
            if appliedKey == nil {
                defaultSizes = Sizes.current
            }
            appliedKey = key
            setSizes(sizes)
        } else if appliedKey != nil {
            appliedKey = nil
            if let defaultSizes {
                setSizes(defaultSizes)
            }
        }
    }

    private func setSizes(_ sizes: Sizes) {
        knownSizes = sizes
        let settings = AppSettings.shared
        if settings.iconGridIconSize != sizes.iconGridIconSize { settings.iconGridIconSize = sizes.iconGridIconSize }
        if settings.iconGridSpacing != sizes.iconGridSpacing { settings.iconGridSpacing = sizes.iconGridSpacing }
        if settings.iconGridFontSize != sizes.iconGridFontSize { settings.iconGridFontSize = sizes.iconGridFontSize }
        if settings.listIconSize != sizes.listIconSize { settings.listIconSize = sizes.listIconSize }
    }

    // MARK: - User changes

    /// The user chose a view mode in `viewModel` (toolbar, View menu, ⌘1…).
    func viewModeChanged(in viewModel: FileBrowserViewModel) {
        guard AppSettings.shared.rememberViewOptionsPerFolder, Self.canRemember(viewModel),
              !Self.isPaneLayout(viewModel.viewMode) else { return }
        let key = Self.key(for: viewModel.currentPath)
        guard entries[key] != nil else { return }
        entries[key]?.viewMode = viewModel.viewMode.rawValue
        markUsed(key)
        changed()
    }

    private func scheduleSizeCheck() {
        guard !sizeCheckScheduled else { return }
        sizeCheckScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sizeCheckScheduled = false
            self.sizesMayHaveChanged()
        }
    }

    /// A size changed in the settings by the user (pinch, Settings, View Options): it belongs to the
    /// focused folder when that remembers its options, otherwise to the defaults.
    private func sizesMayHaveChanged() {
        let sizes = Sizes.current
        guard sizes != knownSizes else { return }
        knownSizes = sizes
        if AppSettings.shared.rememberViewOptionsPerFolder,
           let viewModel = MenuValidationState.shared.commandContext?.viewModel, Self.canRemember(viewModel) {
            let key = Self.key(for: viewModel.currentPath)
            if entries[key] != nil {
                entries[key]?.sizes = sizes
                appliedKey = key
                changed()
                return
            }
        }
        appliedKey = nil
        defaultSizes = sizes
        scheduleSave()
    }

    // MARK: - View Options panel

    /// "Always open in … view": remembers (or forgets) the pane's current folder's options.
    func setRemembered(_ remembered: Bool, for viewModel: FileBrowserViewModel) {
        guard Self.canRemember(viewModel) else { return }
        let folder = viewModel.currentPath
        let key = Self.key(for: folder)
        if remembered {
            if appliedKey == nil {
                defaultSizes = Sizes.current
            }
            let mode = Self.isPaneLayout(viewModel.viewMode) ? nil : viewModel.viewMode.rawValue
            entries[key] = Entry(viewMode: mode, sizes: Sizes.current)
            appliedKey = key
            markUsed(key)
            if AppSettings.shared.usePerFolderColumnState {
                PerFolderColumnStateManager.shared.saveState(
                    for: folder,
                    columns: viewModel.folderColumns ?? ListColumnConfigManager.shared.columns,
                    sortState: viewModel.sortState
                )
            }
        } else {
            forget(key)
        }
        changed()
    }

    /// "Use as Defaults": the pane's sort, columns and sizes become those of folders without their own.
    func useAsDefaults(_ viewModel: FileBrowserViewModel) {
        let config = ListColumnConfigManager.shared
        if let columns = viewModel.folderColumns, config.columns != columns {
            config.columns = columns
        }
        config.defaultSortState = viewModel.sortState
        defaultSizes = Sizes.current
        changed()
    }

    /// "Reset This Folder's Settings": the folder forgets its options and shows the defaults.
    func reset(_ viewModel: FileBrowserViewModel) {
        guard Self.canRemember(viewModel) else { return }
        forget(Self.key(for: viewModel.currentPath))
        viewModel.resetFolderColumnState()
        changed()
    }

    private func forget(_ key: String) {
        entries.removeValue(forKey: key)
        order.removeAll { $0 == key }
        if appliedKey == key {
            applySizes(nil, key: key)
        }
    }

    // MARK: - Persistence

    private func markUsed(_ key: String) {
        if let index = order.lastIndex(of: key) {
            guard index != order.count - 1 else { return }
            order.remove(at: index)
        }
        order.append(key)
        while order.count > Self.maxEntries {
            entries.removeValue(forKey: order.removeFirst())
        }
        scheduleSave()
    }

    private func changed() {
        revision &+= 1
        scheduleSave()
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.save() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func flushPendingSave() {
        guard pendingSave != nil else { return }
        pendingSave?.cancel()
        save()
    }

    private func save() {
        pendingSave = nil
        let data = SavedData(entries: entries, order: order, defaultSizes: defaultSizes)
        if let encoded = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(encoded, forKey: persistenceKey)
        }
    }
}

// MARK: - View Options panel (⌘J)

@MainActor
final class ViewOptionsPanelController: NSObject, NSWindowDelegate {
    static let shared = ViewOptionsPanelController()

    private var panel: NSPanel?
    private let model = ViewOptionsPanelModel()

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            MenuValidationState.shared.objectWillChange.send()
            return
        }
        show()
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.refresh()
        if !panel.isVisible, let window = KeyboardManager.shared.keyBrowserWindow() {
            let frame = window.frame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - 300, y: frame.maxY - 80))
        }
        panel.orderFront(nil)
        MenuValidationState.shared.objectWillChange.send()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 420),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let hosting = NSHostingView(rootView: ViewOptionsPanelView(model: model).environmentObject(AppSettings.shared))
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentView = hosting
        panel.title = String(localized: "View Options")
        return panel
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            MenuValidationState.shared.objectWillChange.send()
        }
    }

    fileprivate func setTitle(_ title: String) {
        panel?.title = title
    }
}

/// The view model the panel shows: the active pane of the browser window the menus act on.
@MainActor
final class ViewOptionsPanelModel: ObservableObject {
    @Published private(set) var viewModel: FileBrowserViewModel?
    private var subscription: AnyCancellable?
    private var refreshScheduled = false

    init() {
        subscription = MenuValidationState.shared.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    func refresh() {
        // Keeps the last browser pane while another window (Settings, the panel itself) is key
        if let current = MenuValidationState.shared.commandContext?.viewModel, current !== viewModel {
            viewModel = current
        }
    }
}

private struct ViewOptionsPanelView: View {
    @ObservedObject var model: ViewOptionsPanelModel

    var body: some View {
        Group {
            if let viewModel = model.viewModel {
                ViewOptionsContent(viewModel: viewModel)
            } else {
                Text("No folder")
                    .foregroundStyle(.secondary)
                    .frame(width: 260, height: 80)
            }
        }
    }
}

private struct ViewOptionsContent: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    @ObservedObject private var store = FolderViewOptionsStore.shared
    @ObservedObject private var columnConfig = ListColumnConfigManager.shared
    @EnvironmentObject private var settings: AppSettings

    private static let modes: [ViewMode] = [.icons, .list, .columns, .coverFlow, .masonry]

    private var canRemember: Bool { FolderViewOptionsStore.canRemember(viewModel) }

    private var columns: [ColumnSettings] {
        viewModel.folderColumns ?? columnConfig.columns
    }

    var body: some View {
        let mode = viewModel.viewMode
        VStack(alignment: .leading, spacing: 10) {
            Toggle(String(localized: "Always open in \(mode.localizedName) view"), isOn: Binding(
                get: { store.isRemembered(viewModel.currentPath) },
                set: { store.setRemembered($0, for: viewModel) }
            ))
            .disabled(!canRemember || !settings.rememberViewOptionsPerFolder)

            Picker("View", selection: Binding(
                get: { mode },
                set: { BrowserWindowCommand.post(.browserSetViewMode, userInfo: [BrowserWindowCommand.viewModeKey: $0.rawValue]) }
            )) {
                ForEach(Self.modes, id: \.self) { mode in
                    Text(mode.localizedName).tag(mode)
                }
                if mode == .dualPane || mode == .quadPane {
                    Text(mode.localizedName).tag(mode)
                }
            }

            Divider()

            Picker("Sort by", selection: Binding(
                get: { viewModel.sortState.column },
                set: { viewModel.setSort(SortState(column: $0, direction: $0.defaultSortDirection)) }
            )) {
                ForEach(ListColumn.allCases) { column in
                    Text(column.localizedName).tag(column)
                }
            }
            Picker("Direction", selection: Binding(
                get: { viewModel.sortState.direction },
                set: { viewModel.setSort(SortState(column: viewModel.sortState.column, direction: $0)) }
            )) {
                Text("Ascending").tag(SortDirection.ascending)
                Text("Descending").tag(SortDirection.descending)
            }
            .pickerStyle(.segmented)
            Toggle("Keep folders on top", isOn: $settings.foldersFirst)

            Divider()

            if mode == .list {
                sizeSlider(value: $settings.listIconSize, range: 14...32, step: 1)
            } else if mode == .icons || mode == .masonry {
                sizeSlider(value: $settings.iconGridIconSize, range: 48...160, step: 4)
            }

            if mode == .list {
                Text("Show Columns:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(ListColumn.allCases.filter { $0 != .name }) { column in
                    Toggle(column.localizedName, isOn: Binding(
                        get: { columns.first(where: { $0.column == column })?.isVisible ?? false },
                        set: { setColumn(column, visible: $0) }
                    ))
                }
            }

            Divider()

            HStack {
                Button("Use as Defaults") { store.useAsDefaults(viewModel) }
                Spacer()
            }
            Button("Reset This Folder's Settings") { store.reset(viewModel) }
                .disabled(!canRemember)
        }
        .padding(14)
        .frame(width: 280)
        .onAppear(perform: updateTitle)
        .onChange(of: viewModel.currentPath) { _, _ in updateTitle() }
    }

    private func sizeSlider(value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Icon size")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Slider(value: value, in: range, step: step)
                Text(verbatim: String(format: "%.0f", value.wrappedValue))
                    .monospacedDigit()
                    .frame(width: 30, alignment: .trailing)
            }
        }
    }

    /// Like the list's header menu: the pane shows the change and the shared layout gets it.
    private func setColumn(_ column: ListColumn, visible: Bool) {
        let shared = ListColumnConfigManager.columns(columnConfig.columns, setting: column, visible: visible)
        if columnConfig.columns != shared {
            columnConfig.columns = shared
        }
        viewModel.columnLayoutChangedByUser(ListColumnConfigManager.columns(columns, setting: column, visible: visible))
    }

    private func updateTitle() {
        ViewOptionsPanelController.shared.setTitle(viewModel.locationTitle)
    }
}
