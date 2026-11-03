import AppKit

/// Saves the tabs of the browser window in front, with each pane's back/forward history, when the app
/// quits (or its last window closes), when it goes to the background and before the Mac sleeps or locks,
/// and restores them in the first window of the next launch.
@MainActor
enum TabSession {
    private struct SavedPane: Codable {
        var path: String
        var viewMode: String
        var history: [String]?
        var historyIndex: Int?
    }

    private struct SavedTab: Codable {
        var left: SavedPane
        var right: SavedPane?
        var ratio: Double?
    }

    private struct SavedSession: Codable {
        var tabs: [SavedTab]
        var selectedIndex: Int
    }

    private static let defaultsKey = "customTabSession"
    private static let stores = NSMapTable<NSWindow, BrowserTabStore>.weakToWeakObjects()
    private static var didAttemptRestore = false

    /// The browser window in front and its tabs.
    static var frontWindow: (NSWindow, BrowserTabStore)? {
        guard let window = openWindows().first, let store = stores.object(forKey: window) else { return nil }
        return (window, store)
    }

    /// The tabs of the window one of whose tabs shows `viewModel`.
    static func store(containing viewModel: FileBrowserViewModel) -> BrowserTabStore? {
        allStores.first { store in store.tabs.contains { $0.allViewModels.contains { $0 === viewModel } } }
    }

    static var allStores: [BrowserTabStore] {
        stores.objectEnumerator()?.allObjects.compactMap { $0 as? BrowserTabStore } ?? []
    }

    static func window(of store: BrowserTabStore) -> NSWindow? {
        openWindows().first { stores.object(forKey: $0) === store }
    }

    /// True once a browser window has attached since launch.
    static var hasHadWindow: Bool { didAttemptRestore }
    private static var isObservingTermination = false

    /// Called when a browser window's content attaches to its window.
    static func attach(_ store: BrowserTabStore, to window: NSWindow) {
        guard stores.object(forKey: window) !== store else { return }
        stores.setObject(store, forKey: window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { notification in
            MainActor.assumeIsolated {
                guard let closing = notification.object as? NSWindow else { return }
                if let store = stores.object(forKey: closing) {
                    InstallerCleanup.panesDidClose(store.tabs.flatMap(\.allViewModels), in: nil)
                }
                let others = openWindows().filter { $0 !== closing }
                if others.isEmpty, let store = stores.object(forKey: closing) {
                    save(store)
                }
            }
        }
        if !isObservingTermination {
            isObservingTermination = true
            observeSaveTriggers()
        }
        if !didAttemptRestore {
            didAttemptRestore = true
            if AppSettings.shared.restoreTabsOnLaunch {
                DispatchQueue.main.async { [weak store] in
                    if let store { restore(into: store) }
                }
            }
        }
        OpenFolderRequests.windowDidAttach()
    }

    /// Quitting may never come (a crash, a forced restart, being killed while the screen is locked),
    /// so the session is also written whenever the app or the Mac steps away.
    private static func observeSaveTriggers() {
        let saveFront: (Notification) -> Void = { _ in
            MainActor.assumeIsolated {
                if let window = openWindows().first, let store = stores.object(forKey: window) {
                    save(store)
                }
            }
        }
        for name in [NSApplication.willTerminateNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main, using: saveFront)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willPowerOffNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main, using: saveFront)
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: saveFront)
    }

    /// Browser windows that are open, front to back.
    private static func openWindows() -> [NSWindow] {
        NSApp.orderedWindows.filter { $0.isVisible && stores.object(forKey: $0) != nil }
    }

    private static func pane(_ viewModel: FileBrowserViewModel) -> SavedPane {
        // Only folders are kept: archive and Photos locations can't be reopened reliably after a relaunch.
        var history: [String] = []
        var historyIndex = 0
        for (index, location) in viewModel.navigationHistory.enumerated() {
            if case .filesystem(let url) = location {
                history.append(url.path)
            }
            if index == viewModel.historyIndex {
                historyIndex = max(history.count - 1, 0)
            }
        }
        return SavedPane(path: ContentView.newTabFolder(for: viewModel).path, viewMode: viewModel.viewMode.rawValue,
                         history: history.isEmpty ? nil : history, historyIndex: historyIndex)
    }

    private static func save(_ store: BrowserTabStore) {
        guard AppSettings.shared.restoreTabsOnLaunch else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return
        }
        let tabs = store.tabs.map { tab in
            SavedTab(left: pane(tab.viewModel), right: tab.split.map { pane($0.rightViewModel) }, ratio: tab.split.map { Double($0.ratio) })
        }
        let session = SavedSession(tabs: tabs, selectedIndex: store.index(of: store.selectedTabId) ?? 0)
        if let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private static func existingFolder(_ path: String) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func makeViewModel(_ pane: SavedPane) -> FileBrowserViewModel? {
        guard let url = existingFolder(pane.path) else { return nil }
        let viewModel = FileBrowserViewModel(initialPath: url)
        restoreHistory(pane, into: viewModel, current: url)
        if let mode = ViewMode(rawValue: pane.viewMode), mode != .dualPane, mode != .quadPane {
            viewModel.viewMode = mode
        }
        return viewModel
    }

    /// Folders that no longer exist are dropped; the current entry is always the folder that was reopened.
    private static func restoreHistory(_ pane: SavedPane, into viewModel: FileBrowserViewModel, current: URL) {
        guard let paths = pane.history, let savedIndex = pane.historyIndex, paths.indices.contains(savedIndex) else { return }
        var locations: [NavigationLocation] = []
        var index = 0
        for (offset, path) in paths.enumerated() {
            if offset == savedIndex {
                index = locations.count
                locations.append(.filesystem(current))
            } else if let url = existingFolder(path) {
                locations.append(.filesystem(url))
            }
        }
        viewModel.navigationHistory = locations
        viewModel.historyIndex = index
    }

    private static func restore(into store: BrowserTabStore) {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let session = try? JSONDecoder().decode(SavedSession.self, from: data) else { return }
        var restored: [BrowserTab] = []
        var selectedId: UUID?
        for (index, saved) in session.tabs.enumerated() {
            let left = makeViewModel(saved.left)
            let right = saved.right.flatMap(makeViewModel)
            guard let primary = left ?? right else { continue }
            var tab = BrowserTab(viewModel: primary)
            if left != nil, let right {
                let split = TabSplitState(rightViewModel: right, ratio: CGFloat(saved.ratio ?? 0.5), focusedSide: .left)
                split.owner = store
                tab.split = split
            }
            restored.append(tab)
            if index <= session.selectedIndex { selectedId = tab.id }
        }
        guard !restored.isEmpty else { return }
        let replaced = store.tabs
        store.tabs = restored
        store.selectedTabId = selectedId ?? restored[0].id
        replaced.flatMap(\.allViewModels).forEach { $0.tearDown() }
    }
}
