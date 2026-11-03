import AppKit

/// Folders extracted from an archive open in a new tab: by the app's own Extract, and by another app
/// (Archive Utility, opened from here or from Finder) when they appear: those named after an
/// archive in the folder ("X" or "X 2" for "X.zip"), and anything new after an archive was opened
/// from here.
@MainActor
enum ExtractionReveal {
    private struct Watch {
        let folderKey: String
        let deadline: Date
    }

    private static var watches: [Watch] = []
    private static var listedKeys: [String: Set<String>] = [:]
    private static var listedOrder: [String] = []
    private static let watchDuration: TimeInterval = 300
    private static let maxRememberedFolders = 20
    private static let partialSuffixes = [".download", ".crdownload", ".part"]
    private static var openedKeys: [String: Date] = [:]

    static func noteOpened(_ item: FileItem) {
        guard item.fileType == .archive, item.url.isFileURL else { return }
        let folderKey = item.url.deletingLastPathComponent().standardizedPathKey
        let now = Date()
        watches.removeAll { $0.folderKey == folderKey || $0.deadline < now }
        watches.append(Watch(folderKey: folderKey, deadline: now + watchDuration))
    }

    /// The new items extracted into `folder`, seen when it's listed again, or nil.
    static func itemsToReveal(in folder: URL, items: [FileItem], isReload: Bool) -> Set<URL>? {
        let folderKey = folder.standardizedPathKey
        let keys = Set(items.map(\.url.standardizedPathKey))
        let previous = listedKeys[folderKey]
        remember(keys, for: folderKey)
        guard isReload, let previous else { return nil }

        let fresh = items.filter { item in
            !previous.contains(item.url.standardizedPathKey)
                && !item.name.hasPrefix(".")
                && !partialSuffixes.contains { item.name.hasSuffix($0) }
        }
        guard !fresh.isEmpty else { return nil }

        let now = Date()
        watches.removeAll { $0.deadline < now }
        if let index = watches.firstIndex(where: { $0.folderKey == folderKey }) {
            watches.remove(at: index)
            return Set(fresh.map(\.url))
        }

        let archiveNames = Set(items.filter { $0.fileType == .archive }.map { $0.url.deletingPathExtension().lastPathComponent })
        guard !archiveNames.isEmpty else { return nil }
        let extracted = fresh.filter { archiveNames.contains(baseName($0.name)) }
        return extracted.isEmpty ? nil : Set(extracted.map(\.url))
    }

    /// "X 2" → "X" (the name Archive Utility gives when "X" exists).
    private static func baseName(_ name: String) -> String {
        guard let space = name.lastIndex(of: " "),
              let number = Int(name[name.index(after: space)...]), number > 1 else { return name }
        return String(name[..<space])
    }

    static func wasOpened(_ key: String) -> Bool {
        openedKeys.contains { $0.key == key && $0.value > Date() }
    }

    static func noteOpenedFolder(_ key: String) {
        let now = Date()
        openedKeys = openedKeys.filter { $0.value > now }
        openedKeys[key] = now + 30
    }

    private static func remember(_ keys: Set<String>, for folderKey: String) {
        listedKeys[folderKey] = keys
        listedOrder.removeAll { $0 == folderKey }
        listedOrder.append(folderKey)
        if listedOrder.count > maxRememberedFolders {
            listedKeys[listedOrder.removeFirst()] = nil
        }
    }
}

extension FileBrowserViewModel {
    /// Opens the first folder among `urls` in a new tab, only once (an extraction is seen both by
    /// its own completion and by the folder's directory events). One tab even when an archive
    /// spills several folders.
    func openExtractedFolders(_ urls: [URL]) {
        guard !urls.contains(where: { ExtractionReveal.wasOpened($0.standardizedPathKey) }) else { return }
        for url in urls where openFolderInNewTab(FileItem(url: url)) {
            urls.forEach { ExtractionReveal.noteOpenedFolder($0.standardizedPathKey) }
            return
        }
    }

    /// After `currentPath` was listed again or a directory event changed it.
    func openExtractedFolders(isReload: Bool) {
        guard !isInsideArchive,
              let urls = ExtractionReveal.itemsToReveal(in: currentPath, items: items, isReload: isReload) else { return }
        openExtractedFolders(urls.sorted { $0.path < $1.path })
    }

    /// Opening an archive extracts it the first time (Archive Utility); once it has been
    /// extracted, opening it browses its contents.
    func extractOnFirstOpen(_ item: FileItem) -> Bool {
        guard item.url.isFileURL, !item.isFromArchive,
              item.url.deletingLastPathComponent().isWritableDirectory,
              !ExtractionReveal.wasExtracted(item.url) else { return false }
        ExtractionReveal.noteExtracted(item.url)
        extractArchives([item], mode: .here, wrapsSeveralItems: true)
        return true
    }
}

extension ExtractionReveal {
    private static let extractedKey = "autoExtractedArchives"
    private static let maxRememberedArchives = 300

    /// Extracted by opening it here before, or its folder ("X" for "X.zip") is next to it.
    static func wasExtracted(_ archive: URL) -> Bool {
        if (UserDefaults.standard.stringArray(forKey: extractedKey) ?? []).contains(archive.standardizedPathKey) { return true }
        let folder = archive.deletingLastPathComponent()
            .appendingPathComponent(ArchiveManager.extractionFolderName(for: archive))
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func noteExtracted(_ archive: URL) {
        var keys = (UserDefaults.standard.stringArray(forKey: extractedKey) ?? []).filter { $0 != archive.standardizedPathKey }
        keys.append(archive.standardizedPathKey)
        UserDefaults.standard.set(Array(keys.suffix(maxRememberedArchives)), forKey: extractedKey)
    }
}

private extension URL {
    var isWritableDirectory: Bool { FileManager.default.isWritableFile(atPath: path) }
}
