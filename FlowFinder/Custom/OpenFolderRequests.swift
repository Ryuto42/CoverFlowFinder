import AppKit

/// Folders and files handed to the app by the system ("Open With", `open -a`, or being the default
/// folder browser): a folder opens in a new tab of the window in front, a file opens its folder with
/// the file selected. A folder already shown in a tab of any window brings that tab forward instead.
/// Requests that arrive before a window exists wait until one has attached.
@MainActor
enum OpenFolderRequests {
    private static var pending: [URL] = []
    private static var isOpeningWindow = false

    static func handle(_ urls: [URL]) {
        pending.append(contentsOf: urls.flatMap(fileURLs(from:)))
        guard !pending.isEmpty else { return }
        if TabSession.frontWindow != nil {
            flush()
        } else if TabSession.hasHadWindow, !isOpeningWindow {
            // Every window was closed: open one; its attach delivers the requests
            isOpeningWindow = true
            NSApp.sendAction(Selector(("newWindow:")), to: nil, from: nil)
        }
    }

    /// `flowfinder://open?path=…` comes from the Finder Sync extension when the sandbox blocks handing files over directly.
    private static func fileURLs(from url: URL) -> [URL] {
        if url.isFileURL { return [url] }
        guard url.scheme == "flowfinder", url.host == "open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [] }
        return items.filter { $0.name == "path" }.compactMap(\.value).map { URL(fileURLWithPath: $0) }
    }

    /// A browser window attached to the app (after its tabs were restored).
    static func windowDidAttach() {
        isOpeningWindow = false
        guard !pending.isEmpty else { return }
        DispatchQueue.main.async { flush() }
    }

    private static func flush() {
        guard let (window, store) = TabSession.frontWindow else { return }
        let urls = pending
        pending = []
        var targetWindow = window
        for url in urls {
            targetWindow = open(url, in: store) ?? window
        }
        targetWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Returns the window of an existing tab that was brought forward, if any.
    private static func open(_ url: URL, in store: BrowserTabStore) -> NSWindow? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        let folder = isDirectory.boolValue ? url : url.deletingLastPathComponent()
        if let (existingStore, tab, viewModel) = existingTab(showing: folder, preferring: store) {
            existingStore.selectedTabId = tab.id
            if !isDirectory.boolValue {
                PendingSelection.select(url, in: viewModel, navigatingTo: folder)
            }
            return TabSession.window(of: existingStore)
        }
        let tab = BrowserTab(initialPath: folder)
        let mode = store.selectedTab.viewModel.viewMode
        if mode != .dualPane, mode != .quadPane {
            tab.viewModel.viewMode = mode
        }
        store.addTab(tab)
        if !isDirectory.boolValue {
            PendingSelection.select(url, in: tab.viewModel, navigatingTo: folder)
        }
        return nil
    }

    /// A tab (in the front window first, then the others) one of whose panes shows `folder`.
    private static func existingTab(showing folder: URL, preferring front: BrowserTabStore)
        -> (BrowserTabStore, BrowserTab, FileBrowserViewModel)? {
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let stores = [front] + TabSession.allStores.filter { $0 !== front }
        for store in stores {
            let ordered = [store.selectedTab] + store.tabs.filter { $0.id != store.selectedTabId }
            for tab in ordered {
                if let viewModel = tab.allViewModels.first(where: {
                    $0.currentPath.standardizedFileURL.resolvingSymlinksInPath().path == path
                }) {
                    return (store, tab, viewModel)
                }
            }
        }
        return nil
    }
}
