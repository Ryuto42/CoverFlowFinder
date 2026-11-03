import AppKit

/// After an app is copied or moved into an Applications folder, remembers where it came from (a
/// disk image, an archive, a folder an archive was expanded into) for the tab that did it, and
/// offers to eject and trash that installer when the tab is closed.
@MainActor
enum InstallerCleanup {
    struct DiskImage: Equatable {
        let image: URL
        let mountPoint: URL
    }

    enum Source: Equatable {
        case diskImage(DiskImage)
        /// An archive, and the folder it was expanded into when there is one.
        case files([URL])
    }

    private final class WeakViewModel {
        weak var value: FileBrowserViewModel?
        init(_ value: FileBrowserViewModel) { self.value = value }
    }

    private struct Pending {
        var apps: [URL] = []
        var images: [DiskImage] = []
        var items: [URL] = []
        var owners: [WeakViewModel] = []

        func isOwned(by ids: Set<ObjectIdentifier>) -> Bool {
            owners.contains { $0.value.map { ids.contains(ObjectIdentifier($0)) } ?? false }
        }

        mutating func merge(_ other: Pending) {
            for app in other.apps where !apps.contains(app) { apps.append(app) }
            for image in other.images where !images.contains(image) { images.append(image) }
            for item in other.items where !items.contains(item) { items.append(item) }
            owners += other.owners
        }
    }

    private static var pending: [Pending] = []
    private static var closed: Pending?
    private static var preferredWindow: NSWindow?
    private static var isQuitting = false

    nonisolated private static let archiveLock = NSLock()
    nonisolated(unsafe) private static var archiveCopies: [String: URL] = [:]

    nonisolated private static let archiveSuffixes = [".zip", ".xip", ".7z", ".rar", ".tar.gz", ".tgz", ".tar.bz2", ".tar.xz"]

    // MARK: Recording

    /// An item copied out of `archive` (to the clipboard) was extracted to `extracted`.
    nonisolated static func noteArchiveCopy(_ extracted: URL, from archive: URL) {
        let root = ArchiveManager.shared.rootArchiveURL(for: archive)
        archiveLock.lock()
        archiveCopies[extracted.resolvingSymlinksInPath().path] = root
        archiveLock.unlock()
    }

    nonisolated private static func archive(copiedTo url: URL) -> URL? {
        archiveLock.lock()
        defer { archiveLock.unlock() }
        return archiveCopies[url.resolvingSymlinksInPath().path]
    }

    /// Called after every successful copy/move batch, with what it did.
    static func noteTransfer(_ steps: [FileOperationStep], by viewModel: FileBrowserViewModel) {
        guard AppSettings.shared.offerInstallerCleanup, !isQuitting else { return }
        let installs: [(from: URL, to: URL)] = steps.compactMap { step in
            switch step {
            case let .copied(from, to), let .moved(from, to):
                return isInstalledApp(to) && !isInApplicationsFolder(from) ? (from, to) : nil
            default:
                return nil
            }
        }
        guard !installs.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let found = installs.compactMap { install in
                installerSource(of: install.from).map { (app: install.to, source: $0, origin: install.from) }
            }
            guard !found.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    record(found, by: viewModel)
                }
            }
        }
    }

    nonisolated static func isInstalledApp(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "app" && isInApplicationsFolder(url.deletingLastPathComponent(), orInside: true)
    }

    nonisolated private static func isInApplicationsFolder(_ url: URL, orInside: Bool = true) -> Bool {
        var path = url.standardizedFileURL.path
        if path.hasPrefix("/System/Volumes/Data/") { path = String(path.dropFirst("/System/Volumes/Data".count)) }
        let roots = ["/Applications", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").standardizedFileURL.path]
        return roots.contains { path == $0 || (orInside && path.hasPrefix($0 + "/")) }
    }

    /// Where the app at `source` (before it was copied or moved) was installed from, if that can be told.
    nonisolated static func installerSource(of source: URL) -> Source? {
        if let archive = archive(copiedTo: source) {
            return FileManager.default.fileExists(atPath: archive.path) ? .files([archive]) : nil
        }
        if let mountPoint = DiskImageVolumes.diskImageVolumeRoot(containing: source) {
            return imagePath(mountedAt: mountPoint).map { .diskImage(DiskImage(image: $0, mountPoint: mountPoint)) }
        }
        guard source.isFileURL else { return nil }
        let parent = source.deletingLastPathComponent()
        let grandparent = parent.deletingLastPathComponent()
        let appName = source.deletingPathExtension().lastPathComponent
        // A folder an archive of the same name was expanded into
        if !isProtectedFolder(parent), let archive = existingArchive(named: parent.lastPathComponent, in: grandparent) {
            return .files([archive, parent])
        }
        for directory in [parent, grandparent] {
            for name in [appName, parent.lastPathComponent] {
                if let archive = existingArchive(named: name, in: directory) {
                    return .files([archive])
                }
            }
        }
        return nil
    }

    nonisolated private static func existingArchive(named name: String, in directory: URL) -> URL? {
        guard !name.isEmpty else { return nil }
        for suffix in archiveSuffixes {
            let url = directory.appendingPathComponent(name + suffix)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return url
            }
        }
        return nil
    }

    /// Folders never offered for the Trash even when named like an archive next to them.
    nonisolated private static func isProtectedFolder(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let protected = ["/", "/Users", "/Volumes", home] + ["Desktop", "Documents", "Downloads", "Applications", "Library"].map { home + "/" + $0 }
        if protected.contains(path) || isInApplicationsFolder(url) { return true }
        let values = try? url.resourceValues(forKeys: [.isVolumeKey, .isPackageKey])
        return values?.isVolume == true || values?.isPackage == true
    }

    /// The disk image mounted at `mountPoint`, from `hdiutil info`.
    nonisolated static func imagePath(mountedAt mountPoint: URL) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        let output = Pipe()
        process.standardOutput = output
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return nil }
        let target = mountPoint.resolvingSymlinksInPath().standardizedFileURL.path
        for image in images {
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            let mounted = entities.compactMap { $0["mount-point"] as? String }
            guard mounted.contains(where: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path == target }),
                  let path = image["image-path"] as? String else { continue }
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func record(_ found: [(app: URL, source: Source, origin: URL)], by viewModel: FileBrowserViewModel) {
        var entry = Pending()
        var owners: [FileBrowserViewModel] = [viewModel]
        if let store = TabSession.store(containing: viewModel),
           let tab = store.tabs.first(where: { $0.allViewModels.contains { $0 === viewModel } }) {
            owners = tab.allViewModels
        }
        for (app, source, origin) in found {
            if !entry.apps.contains(app) { entry.apps.append(app) }
            switch source {
            case .diskImage(let image):
                if !entry.images.contains(image) { entry.images.append(image) }
            case .files(let items):
                for item in items where !entry.items.contains(item) { entry.items.append(item) }
            }
            owners += viewModelsShowing(source, origin: origin)
        }
        var seen = Set<ObjectIdentifier>()
        entry.owners = owners.filter { seen.insert(ObjectIdentifier($0)).inserted }.map(WeakViewModel.init)
        if let index = pending.firstIndex(where: { $0.isOwned(by: seen) }) {
            pending[index].merge(entry)
        } else {
            pending.append(entry)
        }
    }

    /// Panes (in any window) showing the installer: the disk image's volume, the archive or the
    /// folder holding it, the expanded folder, or the folder the app was in.
    private static func viewModelsShowing(_ source: Source, origin: URL) -> [FileBrowserViewModel] {
        var folders: [String] = [origin.deletingLastPathComponent().standardizedFileURL.path]
        switch source {
        case .diskImage(let image):
            folders.append(image.mountPoint.standardizedFileURL.path)
        case .files(let items):
            for item in items {
                folders.append(item.standardizedFileURL.path)
                folders.append(item.deletingLastPathComponent().standardizedFileURL.path)
            }
        }
        let all = TabSession.allStores.flatMap { $0.tabs.flatMap(\.allViewModels) }
        return all.filter { viewModel in
            let path = viewModel.currentPath.standardizedFileURL.path
            return folders.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
    }

    // MARK: Closing

    /// Panes are closing (a tab, one side of a split tab, or a window). `store` is the window's
    /// tabs when the window stays open.
    static func panesDidClose(_ viewModels: [FileBrowserViewModel], in store: BrowserTabStore?) {
        pending.removeAll { $0.owners.allSatisfy { $0.value == nil } }
        guard !pending.isEmpty, !isQuitting else { return }
        let ids = Set(viewModels.map(ObjectIdentifier.init))
        let matching = pending.filter { $0.isOwned(by: ids) }
        guard !matching.isEmpty else { return }
        pending.removeAll { $0.isOwned(by: ids) }
        guard AppSettings.shared.offerInstallerCleanup else { return }
        let isFirst = closed == nil
        var merged = closed ?? Pending()
        matching.forEach { merged.merge($0) }
        closed = merged
        if let store, preferredWindow == nil {
            preferredWindow = TabSession.window(of: store)
        }
        guard isFirst else { return }
        // Once the tab (or window) is gone, and once for tabs closed together.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let entry = closed else { return }
                let window = preferredWindow
                closed = nil
                preferredWindow = nil
                guard !isQuitting else { return }
                present(entry, window: window)
            }
        }
    }

    static func appWillQuit() {
        isQuitting = true
        pending.removeAll()
        closed = nil
    }

    // MARK: Alert

    private static func quotedList(_ urls: [URL], withoutExtension: Bool = false) -> String {
        let names = urls.map { "“\(withoutExtension ? $0.deletingPathExtension().lastPathComponent : $0.finderDisplayName)”" }
        if names.count == 2 {
            return String(localized: "\(names[0]) and \(names[1])")
        }
        return ListFormatter.localizedString(byJoining: names)
    }

    private static func present(_ entry: Pending, window: NSWindow?) {
        let fileManager = FileManager.default
        let apps = entry.apps.filter { fileManager.fileExists(atPath: $0.path) }
        guard !apps.isEmpty else { return }
        var images: [DiskImage] = []
        var items: [URL] = []
        for image in entry.images {
            if DiskImageVolumes.diskImageVolumeRoot(containing: image.mountPoint) != nil {
                images.append(image)
            } else if fileManager.fileExists(atPath: image.image.path) {
                // Already ejected: the image itself can still go
                items.append(image.image)
            }
        }
        items += entry.items.filter { fileManager.fileExists(atPath: $0.path) && !items.contains($0) }
        guard !images.isEmpty || !items.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSWorkspace.shared.icon(forFile: apps[0].path)
        alert.messageText = String(localized: "\(quotedList(apps, withoutExtension: true)) was installed in the Applications folder.")
        if !images.isEmpty {
            let names = quotedList(images.map(\.image))
            alert.informativeText = items.isEmpty
                ? String(localized: "Do you want to eject the disk image \(names) and move it to the Trash?")
                : String(localized: "Do you want to eject the disk image \(names) and move it to the Trash, along with \(quotedList(items))?")
            alert.addButton(withTitle: String(localized: "Eject and Move to Trash"))
            alert.addButton(withTitle: String(localized: "Eject Only"))
        } else {
            alert.informativeText = String(localized: "Do you want to move \(quotedList(items)) to the Trash?")
            alert.addButton(withTitle: String(localized: "Move to Trash"))
        }
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don’t show this message again")

        let sheetWindow = (window?.isVisible == true ? window : nil) ?? TabSession.frontWindow?.0
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            if alert.suppressionButton?.state == .on {
                AppSettings.shared.offerInstallerCleanup = false
            }
            let wantsTrash: Bool
            switch response {
            case .alertFirstButtonReturn: wantsTrash = true
            case .alertSecondButtonReturn where !images.isEmpty: wantsTrash = false
            default: return
            }
            ejectAll(images, window: sheetWindow) { ejected in
                guard wantsTrash else { return }
                trash(ejected.map(\.image) + items, window: sheetWindow)
            }
        }
        if let sheetWindow {
            alert.beginSheetModal(for: sheetWindow) { response in
                MainActor.assumeIsolated { handle(response) }
            }
        } else {
            handle(alert.runModal())
        }
    }

    /// Ejects the images one after another; `completion` gets those that were ejected. A failure
    /// is shown like the sidebar's Eject.
    private static func ejectAll(_ images: [DiskImage], window: NSWindow?, ejected: [DiskImage] = [], completion: @escaping ([DiskImage]) -> Void) {
        guard let image = images.first else {
            completion(ejected)
            return
        }
        let rest = Array(images.dropFirst())
        eject(image, window: window) { success in
            ejectAll(rest, window: window, ejected: success ? ejected + [image] : ejected, completion: completion)
        }
    }

    private static func eject(_ image: DiskImage, window: NSWindow?, completion: @escaping (Bool) -> Void) {
        let url = image.mountPoint
        let name = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? url.lastPathComponent
        // Panes showing the volume move away first, so they don't keep it busy.
        SidebarEnvironmentStore.postVolumeNotification(.volumeWillUnmount, volumeURL: url)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) {
            FileManager.default.unmountVolume(at: url, options: [.allPartitionsAndEjectDisk, .withoutUI]) { error in
                let failure = error.map { $0 as NSError }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let failure {
                            SidebarEnvironmentStore.postVolumeNotification(.volumeUnmountFailed, volumeURL: url)
                            SidebarVolumeEjector.presentEjectError(failure, volumeName: name, window: window)
                            completion(false)
                        } else {
                            SidebarEnvironmentStore.shared.requestRefresh()
                            completion(true)
                        }
                    }
                }
            }
        }
    }

    /// Through a pane of the window, so it is one Undo step there.
    private static func trash(_ urls: [URL], window: NSWindow?) {
        guard !urls.isEmpty else { return }
        let store = window.flatMap { window in TabSession.allStores.first { TabSession.window(of: $0) === window } }
            ?? TabSession.frontWindow?.1
        guard let viewModel = store?.selectedTab.focusedViewModel else { return }
        viewModel.moveItemsToTrash(urls, window: window)
    }
}
