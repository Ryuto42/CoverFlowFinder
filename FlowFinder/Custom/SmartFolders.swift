import AppKit
import SwiftUI

// MARK: - Model

struct SmartFolder: Equatable {
    let url: URL
    var file: SavedSearchFile

    var name: String { url.deletingPathExtension().lastPathComponent }
    var itemID: String { Self.itemID(for: url) }

    static func itemID(for url: URL) -> String {
        "smart:\(url.standardizedFileURL.path)"
    }

    static func isSmartFolder(_ url: URL) -> Bool {
        url.pathExtension.caseInsensitiveCompare(SavedSearchFile.fileExtension) == .orderedSame
    }
}

// MARK: - Store

/// The smart folders in ~/Library/Saved Searches (watched) and the ones in Finder's sidebar favorites.
@MainActor
final class SmartFolderStore {
    static let shared = SmartFolderStore()

    private(set) var folders: [SmartFolder] = []
    /// Bumped whenever `folders` changes.
    private(set) var revision = 0
    /// Smart folders opened from a file list that aren't in the sidebar.
    private var opened: [SmartFolder] = []
    private var source: DispatchSourceFileSystemObject?
    private var reloadScheduled = false
    private var activationObserver: NSObjectProtocol?
    private let queue = DispatchQueue(label: "com.flowfinder.smartFolders", qos: .utility)

    private init() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                SmartFolderStore.shared.reload()
            }
        }
        reload()
    }

    func folder(named name: String) -> SmartFolder? {
        (folders + opened).first { $0.name.compare(name, options: [.caseInsensitive]) == .orderedSame }
    }

    func folder(at url: URL) -> SmartFolder? {
        let path = url.standardizedFileURL.path
        return (folders + opened).first { $0.url.standardizedFileURL.path == path }
    }

    /// Reads a smart folder opened from a file list so its search text resolves to it.
    func register(_ url: URL) -> SmartFolder? {
        guard let file = SavedSearchFile(contentsOf: url) else { return nil }
        let folder = SmartFolder(url: url.standardizedFileURL, file: file)
        if folders.contains(where: { $0.url == folder.url }) {
            replace(folder)
        } else {
            opened.removeAll { $0.url == folder.url || $0.name == folder.name }
            opened.append(folder)
        }
        return folder
    }

    /// Applies a save right away (the directory watcher's reload follows).
    func replace(_ folder: SmartFolder, removing oldURL: URL? = nil) {
        var list = folders
        if let oldURL { list.removeAll { $0.url == oldURL.standardizedFileURL } }
        if let index = list.firstIndex(where: { $0.url == folder.url }) {
            list[index] = folder
        } else {
            list.append(folder)
        }
        apply(sorted(list))
        reload()
    }

    func remove(_ url: URL) {
        let standardized = url.standardizedFileURL
        opened.removeAll { $0.url == standardized }
        apply(folders.filter { $0.url != standardized })
        reload()
    }

    func reload() {
        startWatching()
        guard !reloadScheduled else { return }
        reloadScheduled = true
        queue.asyncAfter(deadline: .now() + 0.2) {
            let loaded = Self.loadFolders()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let store = SmartFolderStore.shared
                    store.reloadScheduled = false
                    store.apply(loaded)
                }
            }
        }
    }

    private func apply(_ list: [SmartFolder]) {
        guard list != folders else { return }
        folders = list
        revision &+= 1
        SidebarEnvironmentStore.shared.environmentDidChange.send()
    }

    private func sorted(_ list: [SmartFolder]) -> [SmartFolder] {
        list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func startWatching() {
        guard source == nil else { return }
        let fd = open(SavedSearchFile.directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                let store = SmartFolderStore.shared
                if let event = store.source?.data, event.contains(.delete) || event.contains(.rename) {
                    // The folder itself went away: watch it again once it's back.
                    store.source?.cancel()
                    store.source = nil
                }
                store.reload()
            }
        }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    nonisolated private static func loadFolders() -> [SmartFolder] {
        let fileManager = FileManager.default
        var urls = ((try? fileManager.contentsOfDirectory(
            at: SavedSearchFile.directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []).filter(SmartFolder.isSmartFolder)
        let known = Set(urls.map(\.standardizedFileURL.path))
        urls += finderSidebarSmartFolders().filter { !known.contains($0.standardizedFileURL.path) }
        let folders = urls.compactMap { url -> SmartFolder? in
            guard let file = SavedSearchFile(contentsOf: url) else { return nil }
            return SmartFolder(url: url.standardizedFileURL, file: file)
        }
        return folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Smart folders the user added to Finder's sidebar (Finder keeps its favorites in a shared file list).
    nonisolated private static func finderSidebarSmartFolders() -> [URL] {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.sharedfilelist", isDirectory: true)
        for version in ["sfl4", "sfl3", "sfl2"] {
            let url = directory.appendingPathComponent("com.apple.LSSharedFileList.FavoriteItems.\(version)")
            guard let data = try? Data(contentsOf: url),
                  let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { continue }
            unarchiver.requiresSecureCoding = false
            let root = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSDictionary
            unarchiver.finishDecoding()
            let items = root?["items"] as? [NSDictionary] ?? []
            return items.compactMap { item -> URL? in
                guard let bookmark = item["Bookmark"] as? Data else { return nil }
                var stale = false
                guard let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                              relativeTo: nil, bookmarkDataIsStale: &stale),
                      SmartFolder.isSmartFolder(resolved),
                      FileManager.default.fileExists(atPath: resolved.path) else { return nil }
                return resolved
            }
        }
        return []
    }
}

// MARK: - Search

/// A smart folder runs as a Spotlight search whose text is "smart:<name>", like the Kinds section's "kind:<name>",
/// so the existing search results UI shows it with live updates.
@MainActor
enum SmartFolderSearch {
    static let prefix = "smart:"

    static func searchText(for folder: SmartFolder) -> String {
        prefix + folder.name
    }

    static func folder(matching text: String) -> SmartFolder? {
        guard text.lowercased().hasPrefix(prefix) else { return nil }
        let name = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return SmartFolderStore.shared.folder(named: name)
    }

    static func spotlightQuery(for text: String) -> (predicate: NSPredicate, scopes: [URL])? {
        guard let folder = folder(matching: text) else { return nil }
        // Read again: Finder may have edited the file since the store loaded it.
        let file = SavedSearchFile(contentsOf: folder.url) ?? folder.file
        guard let predicate = SmartFolderQuery.predicate(for: file.rawQuery) else { return nil }
        return (predicate, scopes(for: file.scopes))
    }

    static func scopes(for strings: [String]) -> [URL] {
        var urls: [URL] = []
        for scope in strings {
            switch scope {
            case SavedSearchFile.computerScope, "kMDQueryScopeComputerIndexed":
                // Like the Kinds section's This Mac: the home folder without ~/Library, plus Applications.
                urls += SidebarKindSearch.thisMacScopes() + [URL(fileURLWithPath: "/Applications", isDirectory: true)]
            case SavedSearchFile.homeScope, "kMDQueryScopeHomeIndexed":
                urls.append(FileManager.default.homeDirectoryForCurrentUser)
            default:
                let path = (scope as NSString).expandingTildeInPath
                if path.hasPrefix("/") {
                    urls.append(URL(fileURLWithPath: path, isDirectory: true))
                }
            }
        }
        return urls.isEmpty ? SidebarKindSearch.thisMacScopes() : urls
    }

    static func start(_ folder: SmartFolder, in viewModel: FileBrowserViewModel) {
        let text = searchText(for: folder)
        if viewModel.searchMode != .finder {
            viewModel.searchMode = .finder
        }
        if viewModel.searchText == text {
            viewModel.performSearch(query: text)
        } else {
            viewModel.searchText = text
        }
    }

    /// Opening a .savedSearch file shows its results instead of opening it in Finder.
    static func open(_ url: URL, in viewModel: FileBrowserViewModel) -> Bool {
        guard url.isFileURL, SmartFolder.isSmartFolder(url), let folder = SmartFolderStore.shared.register(url) else { return false }
        start(folder, in: viewModel)
        return true
    }

    static func isSmartFolderSearch(_ viewModel: FileBrowserViewModel) -> Bool {
        viewModel.searchMode == .finder && viewModel.searchText.lowercased().hasPrefix(prefix)
    }
}

// MARK: - Creating, editing, renaming, deleting

@MainActor
enum SmartFolderActions {
    static func newSmartFolder(viewModel: FileBrowserViewModel?, window: NSWindow? = nil) {
        var criteria = SmartFolderCriteria()
        criteria.folderPath = viewModel.flatMap { $0.isInsideArchive ? nil : $0.currentPath.path }
        presentEditor(folder: nil, criteria: criteria, viewModel: viewModel, window: window)
    }

    /// The search bar's Save button: the current Spotlight search as a new smart folder.
    static func saveCurrentSearch(of viewModel: FileBrowserViewModel, window: NSWindow? = nil) {
        var criteria = SmartFolderCriteria()
        criteria.folderPath = viewModel.currentPath.path
        let text = viewModel.searchText
        var name = text
        if let kind = SidebarKindSearch.filter(matching: text) {
            var rule = SmartFolderRule(attribute: .kind)
            rule.kindID = SmartFolderKind.other.rawValue
            rule.text = kind.contentTypes.joined(separator: ", ")
            criteria.rules = [rule]
            if !kind.extensions.isEmpty {
                var extensions = SmartFolderRule(attribute: .fileExtension)
                extensions.text = kind.extensions.joined(separator: ", ")
                criteria.rules.append(extensions)
                criteria.match = .any
            }
            criteria.scope = kind.scope == .thisMac ? .thisMac : .folder
            name = kind.displayName
        } else {
            var rule = SmartFolderRule(attribute: .name)
            rule.text = text
            criteria.rules = [rule]
            criteria.scope = .folder
        }
        presentEditor(folder: nil, criteria: criteria, name: name, viewModel: viewModel, window: window)
    }

    static func editCriteria(of folder: SmartFolder, viewModel: FileBrowserViewModel?, window: NSWindow?) {
        let file = SavedSearchFile(contentsOf: folder.url) ?? folder.file
        presentEditor(folder: folder, criteria: file.editableCriteria, viewModel: viewModel, window: window)
    }

    private static func presentEditor(folder: SmartFolder?, criteria: SmartFolderCriteria, name: String? = nil,
                                      viewModel: FileBrowserViewModel?, window: NSWindow?) {
        guard let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let initialName = folder?.name ?? name ?? String(localized: "Untitled Smart Folder")
        SidebarSheet.present(on: window) { dismiss in
            SmartFolderEditorView(
                name: initialName,
                criteria: criteria,
                isNew: folder == nil,
                onSave: { name, criteria in
                    do {
                        let saved = try save(name: name, criteria: criteria, replacing: folder)
                        dismiss()
                        if let viewModel {
                            SmartFolderSearch.start(saved, in: viewModel)
                        }
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                },
                onCancel: dismiss
            )
        }
    }

    private struct SaveError: LocalizedError {
        let errorDescription: String?
    }

    static func fileName(for name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    private static func save(name: String, criteria: SmartFolderCriteria, replacing folder: SmartFolder?) throws -> SmartFolder {
        let baseName = fileName(for: name)
        guard !baseName.isEmpty, !baseName.hasPrefix("."), let file = SavedSearchFile(criteria: criteria) else {
            throw SaveError(errorDescription: String(localized: "Enter a name and at least one condition."))
        }
        let directory = folder?.url.deletingLastPathComponent() ?? SavedSearchFile.directory
        let url = directory.appendingPathComponent(baseName).appendingPathExtension(SavedSearchFile.fileExtension).standardizedFileURL
        let renamed = folder.map { $0.url != url } ?? true
        if renamed, FileManager.default.fileExists(atPath: url.path),
           folder?.url.path.lowercased() != url.path.lowercased() {
            throw SaveError(errorDescription: String(localized: "A smart folder named “\(baseName)” already exists."))
        }
        if let old = folder?.url, renamed {
            try FileManager.default.moveItem(at: old, to: url)
            moveCustomization(from: old, to: url)
        }
        try file.write(to: url, updating: folder == nil ? nil : url)
        let saved = SmartFolder(url: url, file: file)
        SmartFolderStore.shared.replace(saved, removing: folder?.url)
        AppSettings.shared.setSidebarSectionHidden(SidebarLayout.smartFoldersSectionID, false)
        return saved
    }

    static func rename(_ folder: SmartFolder, to name: String, viewModel: FileBrowserViewModel?) throws {
        let baseName = fileName(for: name)
        guard !baseName.isEmpty, baseName != folder.name else { return }
        let url = folder.url.deletingLastPathComponent()
            .appendingPathComponent(baseName).appendingPathExtension(SavedSearchFile.fileExtension).standardizedFileURL
        let wasActive = viewModel.map { SmartFolderSearch.folder(matching: $0.searchText)?.url == folder.url } ?? false
        try FileManager.default.moveItem(at: folder.url, to: url)
        moveCustomization(from: folder.url, to: url)
        let renamed = SmartFolder(url: url, file: folder.file)
        SmartFolderStore.shared.replace(renamed, removing: folder.url)
        if wasActive, let viewModel {
            SmartFolderSearch.start(renamed, in: viewModel)
        }
    }

    static func moveToTrash(_ folder: SmartFolder, viewModel: FileBrowserViewModel?) {
        if let viewModel, SmartFolderSearch.folder(matching: viewModel.searchText)?.url == folder.url {
            viewModel.clearSearchQuery()
        }
        NSWorkspace.shared.recycle([folder.url]) { _, error in
            let failed = error != nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if failed {
                        NSSound.beep()
                    } else {
                        AppSettings.shared.sidebarLayout.items[folder.itemID] = nil
                        SmartFolderStore.shared.remove(folder.url)
                    }
                }
            }
        }
    }

    /// Keeps a renamed smart folder's sidebar icon, alias and place.
    private static func moveCustomization(from old: URL, to new: URL) {
        let oldID = SmartFolder.itemID(for: old)
        let newID = SmartFolder.itemID(for: new)
        var layout = AppSettings.shared.sidebarLayout
        if let custom = layout.items.removeValue(forKey: oldID) {
            layout.items[newID] = custom
        }
        layout.updateSection(SidebarLayout.smartFoldersSectionID) { section in
            section.itemOrder = section.itemOrder.map { $0 == oldID ? newID : $0 }
        }
        if layout != AppSettings.shared.sidebarLayout {
            AppSettings.shared.sidebarLayout = layout
        }
    }
}

/// The search bar's "Save" button (Finder's), shown during a Spotlight search.
/// "Save as Smart Folder" in the search mode menu, while a Spotlight search is shown.
struct SmartFolderSaveMenuItem: View {
    @ObservedObject var viewModel: FileBrowserViewModel

    var body: some View {
        if viewModel.searchMode == .finder, !viewModel.searchText.isEmpty, !SmartFolderSearch.isSmartFolderSearch(viewModel) {
            Divider()
            Button("Save as Smart Folder…") {
                SmartFolderActions.saveCurrentSearch(of: viewModel)
            }
        }
    }
}

struct SmartFolderSaveButton: View {
    @ObservedObject var viewModel: FileBrowserViewModel

    var body: some View {
        if viewModel.searchMode == .finder, !viewModel.searchText.isEmpty, !SmartFolderSearch.isSmartFolderSearch(viewModel) {
            Button("Save") {
                SmartFolderActions.saveCurrentSearch(of: viewModel)
            }
            .help("Save this search as a smart folder")
        }
    }
}

// MARK: - Sidebar

final class SmartFolderMenuPayload: NSObject {
    let url: URL

    init(url: URL) {
        self.url = url
    }
}

extension SidebarOutlineView.Coordinator {
    func makeSmartFolderSection(_ entry: SidebarLayoutSection) -> SidebarSection? {
        let folders = SmartFolderStore.shared.folders
        guard !entry.isHidden, !folders.isEmpty else { return nil }
        let items = folders.map { SidebarItem(kind: .smartFolder($0), id: $0.itemID, title: $0.name) }
        return SidebarSection(kind: .smartFolders, title: entry.defaultTitle, items: items, layoutID: entry.id)
    }

    func smartFolderPresentation(_ folder: SmartFolder) -> SidebarItemPresentation {
        SidebarItemPresentation(
            title: folder.name,
            icon: SidebarSymbols.image("gearshape"),
            iconTint: SidebarSymbols.favoriteTint,
            accessory: nil,
            isEnabled: true
        )
    }

    func activeSmartFolder() -> SmartFolder? {
        guard viewModel.searchMode == .finder else { return nil }
        return SmartFolderSearch.folder(matching: viewModel.searchText)
    }

    func activeSmartFolderItem() -> SidebarItem? {
        guard let active = activeSmartFolder() else { return nil }
        for section in sections where section.kind == .smartFolders {
            if let item = section.items.first(where: { $0.id == active.itemID }) {
                return item
            }
        }
        return nil
    }

    func openSmartFolder(_ folder: SmartFolder) {
        SmartFolderSearch.start(folder, in: viewModel)
    }

    func smartFolderMenuItems(for folder: SmartFolder) -> [NSMenuItem] {
        let payload = SmartFolderMenuPayload(url: folder.url)
        return [
            smartFolderMenuItem("Edit Criteria…", #selector(editSmartFolderFromMenu(_:)), payload),
            smartFolderMenuItem("Rename…", #selector(renameSmartFolderFromMenu(_:)), payload),
            smartFolderMenuItem("Move to Trash", #selector(trashSmartFolderFromMenu(_:)), payload)
        ]
    }

    func newSmartFolderMenuItem() -> NSMenuItem {
        smartFolderMenuItem("New Smart Folder", #selector(newSmartFolderFromMenu(_:)), nil)
    }

    private func smartFolderMenuItem(_ title: String, _ action: Selector, _ payload: SmartFolderMenuPayload?) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: String.LocalizationValue(title)), action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = payload
        return item
    }

    private func smartFolder(from sender: NSMenuItem) -> SmartFolder? {
        guard let payload = sender.representedObject as? SmartFolderMenuPayload else { return nil }
        return SmartFolderStore.shared.folder(at: payload.url)
    }

    @objc func newSmartFolderFromMenu(_ sender: NSMenuItem) {
        SmartFolderActions.newSmartFolder(viewModel: viewModel, window: outlineView?.window)
    }

    @objc func editSmartFolderFromMenu(_ sender: NSMenuItem) {
        guard let folder = smartFolder(from: sender) else { return }
        SmartFolderActions.editCriteria(of: folder, viewModel: viewModel, window: outlineView?.window)
    }

    @objc func renameSmartFolderFromMenu(_ sender: NSMenuItem) {
        guard let folder = smartFolder(from: sender) else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Rename “\(folder.name)”")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(string: folder.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let viewModel = viewModel
        let window = outlineView?.window
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                try SmartFolderActions.rename(folder, to: field.stringValue, viewModel: viewModel)
            } catch {
                if let window {
                    NSAlert(error: error).beginSheetModal(for: window)
                } else {
                    NSAlert(error: error).runModal()
                }
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    @objc func trashSmartFolderFromMenu(_ sender: NSMenuItem) {
        guard let folder = smartFolder(from: sender) else { return }
        SmartFolderActions.moveToTrash(folder, viewModel: viewModel)
    }
}
