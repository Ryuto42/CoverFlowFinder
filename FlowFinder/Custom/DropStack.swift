import SwiftUI
import AppKit

/// The app-wide shelf of files and folders (Path Finder's Drop Stack). Items are kept as bookmarks,
/// so they follow moves and renames, and survive relaunches.
@MainActor
final class DropStackStore: ObservableObject {
    static let shared = DropStackStore()

    struct Item: Identifiable, Equatable {
        let id: UUID
        fileprivate(set) var bookmark: Data
        fileprivate(set) var url: URL
        fileprivate(set) var exists: Bool
    }

    @Published private(set) var items: [Item] = []
    @Published var isCollapsed: Bool {
        didSet { defaults.set(isCollapsed, forKey: Self.collapsedKey) }
    }
    /// True while items are being dragged out of the stack (it doesn't take its own items back).
    var isDraggingOut = false

    private static let itemsKey = "dropStack.bookmarks"
    private static let collapsedKey = "dropStack.collapsed"
    private let defaults = UserDefaults.standard
    private var refreshTimer: Timer?
    private var activationObserver: NSObjectProtocol?

    private init() {
        isCollapsed = defaults.bool(forKey: Self.collapsedKey)
        let bookmarks = defaults.array(forKey: Self.itemsKey) as? [Data] ?? []
        items = bookmarks.map { Item(id: UUID(), bookmark: $0, url: URL(fileURLWithPath: "/"), exists: false) }
        refresh()
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.items.isEmpty else { return }
                self.refresh()
            }
        }
    }

    var existingItems: [Item] { items.filter(\.exists) }

    func add(_ urls: [URL]) {
        var newItems = items
        for url in urls where url.isFileURL {
            let path = url.standardizedFileURL.path
            guard !newItems.contains(where: { $0.url.standardizedFileURL.path == path }),
                  let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { continue }
            newItems.append(Item(id: UUID(), bookmark: bookmark, url: url, exists: true))
        }
        guard newItems != items else { return }
        items = newItems
        save()
    }

    /// Adds the items and shows the stack.
    func addAndShow(_ urls: [URL]) {
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        add(urls)
        AppSettings.shared.showDropStack = true
        isCollapsed = false
    }

    func remove(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        save()
    }

    func removeAll() {
        items = []
        save()
    }

    /// Items taken out of the stack (dropped somewhere, moved or copied) leave it unless the setting keeps them.
    func didTakeOut(_ ids: Set<UUID>) {
        guard !AppSettings.shared.dropStackKeepsItems else { return }
        remove(ids)
    }

    /// Follows the bookmarks to the items' current locations. Items in the Trash count as gone.
    func refresh() {
        var updated = items
        var needsSave = false
        for index in updated.indices {
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: updated[index].bookmark,
                                     options: [.withoutUI, .withoutMounting],
                                     relativeTo: nil,
                                     bookmarkDataIsStale: &isStale) else {
                updated[index].exists = false
                continue
            }
            updated[index].url = url
            updated[index].exists = FileManager.default.fileExists(atPath: url.path) && !url.path.contains("/.Trash/")
            if isStale, let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                updated[index].bookmark = bookmark
                needsSave = true
            }
        }
        if updated != items { items = updated }
        if needsSave { save() }
    }

    private func save() {
        defaults.set(items.map(\.bookmark), forKey: Self.itemsKey)
    }
}

// MARK: - Actions

@MainActor
enum DropStackActions {
    /// The active pane of `window` (or of the browser window the menus act on).
    static func activeViewModel(for window: NSWindow?) -> FileBrowserViewModel? {
        let menuState = MenuValidationState.shared
        return (menuState.context(for: window) ?? menuState.commandContext)?.viewModel
    }

    static func canTransfer(into viewModel: FileBrowserViewModel?) -> Bool {
        guard let viewModel else { return false }
        return !viewModel.isInsideArchive && viewModel.currentPath.isFileURL && viewModel.canAddItemsToCurrentLocation
    }

    /// Moves or copies the items into the folder shown in the active pane, as a drop would.
    static func transfer(_ items: [DropStackStore.Item], operation: FileDropOperation, window: NSWindow?) {
        let items = items.filter(\.exists)
        guard let viewModel = activeViewModel(for: window), canTransfer(into: viewModel), !items.isEmpty else {
            NSSound.beep()
            return
        }
        let destination = viewModel.currentPath
        let urls = items.map(\.url)
        if DropHelper.isSelfOrDescendantDrop(sources: urls, destination: destination) {
            NSSound.beep()
            return
        }
        viewModel.handleDrop(urls: urls, to: destination, operation: operation) {
            DropStackStore.shared.refresh()
        }
        DropStackStore.shared.didTakeOut(Set(items.map(\.id)))
    }

    static func reveal(_ items: [DropStackStore.Item]) {
        let urls = items.filter(\.exists).map(\.url)
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// The "Add to Drop Stack" item of the item context menus.
    static func addEntry(enabled: Bool, targets: @escaping () -> [FileItem]) -> CustomMenuEntry {
        .action(String(localized: "Add to Drop Stack"), enabled: enabled) {
            DropStackStore.shared.addAndShow(targets().filter { !$0.isFromArchive && $0.url.isFileURL }.map(\.url))
        }
    }
}

// MARK: - Menu bar and toolbar

struct DropStackCommands: Commands {
    @ObservedObject var settings: AppSettings

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Toggle("Show Drop Stack", isOn: $settings.showDropStack)
        }
    }
}

struct DropStackToolbarButton: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var store = DropStackStore.shared

    var body: some View {
        Button {
            settings.showDropStack.toggle()
            if settings.showDropStack { store.isCollapsed = false }
        } label: {
            Label("Drop Stack", systemImage: store.items.isEmpty ? "tray" : "tray.full")
        }
        .help(settings.showDropStack ? "Hide Drop Stack" : "Show Drop Stack")
    }
}
