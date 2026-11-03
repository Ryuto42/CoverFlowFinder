import Foundation

/// Filter mode's search below the current folder (like Finder's "This folder" search): items in
/// subfolders whose names match the filter text, found in the background and streamed in after
/// the folder's own matching items. The matches are the view model's `searchResults`.
@MainActor
final class RecursiveFilterSearch {
    nonisolated static let maxResults = 5000
    nonisolated static let maxDepth = 32
    /// Entries looked at before giving up (a search from "/" or a huge tree)
    nonisolated static let maxVisited = 1_000_000
    /// Folders never searched inside (.git always; node_modules by default)
    nonisolated static let excludedFolderNames: Set<String> = [".git", "node_modules"]

    private(set) var root: URL?
    private var cancellation: Cancellation?
    /// Stable IDs per path, so results keep their identity when the text changes
    private var idsByPath: [String: UUID] = [:]
    private var combinedSources: (direct: [FileItem], deep: [FileItem], filterTag: String?, git: Set<URL>?)?
    private var combinedCache: [FileItem] = []

    var isRunning: Bool { cancellation != nil }

    /// Same matching for the folder's items and the subfolders' (case, diacritics such as
    /// dakuten, and full/half width are ignored).
    nonisolated static func nameMatches(_ name: String, _ query: String) -> Bool {
        foldedJapanese(name).range(of: foldedJapanese(query), options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                   locale: .current) != nil
    }

    /// Half-width kana as full-width (ﾎﾟ → ポ) and kana without (han)dakuten (ダ → タ), which the
    /// comparison options don't fold.
    private nonisolated static func foldedJapanese(_ string: String) -> String {
        guard string.unicodeScalars.contains(where: { $0.value >= 0x3000 }) else { return string }
        var string = string
        if string.unicodeScalars.contains(where: { (0xFF61...0xFF9F).contains($0.value) }) {
            string = string.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? string
        }
        var scalars = String.UnicodeScalarView()
        for scalar in string.decomposedStringWithCanonicalMapping.unicodeScalars where !(0x3099...0x309C).contains(scalar.value) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    func cancel() {
        cancellation?.cancel()
        cancellation = nil
    }

    /// Searches `root`'s subfolders; `deliver` gets batches of matches in the order found, then
    /// `finished` once.
    func start(root: URL, query: String, showHidden: Bool,
               deliver: @escaping @MainActor (_ batch: [FileItem], _ finished: Bool) -> Void) {
        cancel()
        self.root = root
        if idsByPath.count > 50_000 { idsByPath.removeAll() }
        let cancellation = Cancellation()
        self.cancellation = cancellation
        let knownIDs = idsByPath
        let send: @Sendable ([FileItem], [String: UUID], Bool) -> Void = { [weak self] batch, newIDs, finished in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !cancellation.isCancelled else { return }
                    self.idsByPath.merge(newIDs) { _, new in new }
                    if finished { self.cancellation = nil }
                    deliver(batch, finished)
                }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            Self.search(root: root, query: query, showHidden: showHidden, knownIDs: knownIDs,
                        cancellation: cancellation, send: send)
        }
    }

    private nonisolated static func search(root: URL, query: String, showHidden: Bool, knownIDs: [String: UUID],
                                           cancellation: Cancellation,
                                           send: @Sendable ([FileItem], [String: UUID], Bool) -> Void) {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !showHidden { options.insert(.skipsHiddenFiles) }
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: FileItem.listingResourceKeys, options: options,
            errorHandler: { _, _ in true }
        ) else {
            send([], [:], true)
            return
        }
        var batch: [FileItem] = []
        var newIDs: [String: UUID] = [:]
        var found = 0
        var visited = 0
        var lastSend = Date()
        while let url = enumerator.nextObject() as? URL {
            visited += 1
            if visited % 256 == 0, cancellation.isCancelled { return }
            let name = url.lastPathComponent
            let level = enumerator.level
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDirectory, excludedFolderNames.contains(name) || level >= maxDepth {
                enumerator.skipDescendants()
            }
            // The folder's own items are listed (and filtered) by the view model
            if level >= 2, !FileItem.isAlwaysHiddenName(name),
               nameMatches(name.replacingOccurrences(of: ":", with: "/"), query) {
                let path = url.path
                let id = knownIDs[path] ?? UUID()
                newIDs[path] = id
                batch.append(FileItem(url: url, id: id, loadMetadata: true))
                found += 1
            }
            if found >= maxResults || visited >= maxVisited { break }
            if !batch.isEmpty, batch.count >= 500 || Date().timeIntervalSince(lastSend) > 0.15 {
                send(batch, newIDs, false)
                batch.removeAll(keepingCapacity: true)
                newIDs.removeAll(keepingCapacity: true)
                lastSend = Date()
            }
        }
        guard !cancellation.isCancelled else { return }
        send(batch, newIDs, true)
    }

    /// The folder's items, then the subfolders' (both already sorted). Cached while the same
    /// arrays come in (the view model's sorted lists are cached, so their storage stays the same).
    func combined(direct: [FileItem], deep: [FileItem], filterTag: String?, gitFilter: Set<URL>?) -> [FileItem] {
        if let sources = combinedSources, Self.isSameStorage(sources.direct, direct), Self.isSameStorage(sources.deep, deep),
           sources.filterTag == filterTag, sources.git == gitFilter {
            return combinedCache
        }
        var extra = deep
        if let filterTag { extra = extra.filter { $0.tags.contains(filterTag) } }
        if let gitFilter { extra = extra.filter { gitFilter.contains($0.url) } }
        combinedSources = (direct, deep, filterTag, gitFilter)
        combinedCache = direct + extra
        return combinedCache
    }

    private static func isSameStorage(_ a: [FileItem], _ b: [FileItem]) -> Bool {
        a.count == b.count && a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pa.baseAddress == $0.baseAddress } }
    }

    func clearCache() {
        combinedSources = nil
        combinedCache = []
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }
}

extension FileBrowserViewModel {
    /// Whether filter mode also searches the subfolders of the location shown (not inside an
    /// archive, the Photos library or the Network browser).
    var canFilterSubfolders: Bool {
        AppSettings.shared.filterSearchesSubfolders && !isInsideArchive && !isPhotosLibraryActive
            && currentPath.isFileURL && currentPath.path != "/Network"
    }

    /// Whether the subfolders' matches are listed after the folder's own items.
    var showsRecursiveFilterResults: Bool {
        searchMode == .filter && !searchText.isEmpty && !searchResults.isEmpty && canFilterSubfolders
            && recursiveFilter.root?.standardizedPathKey == currentPath.standardizedPathKey
    }

    func withRecursiveFilterResults(_ direct: [FileItem]) -> [FileItem] {
        guard showsRecursiveFilterResults else { return direct }
        return recursiveFilter.combined(direct: direct, deep: sortedSearchResults, filterTag: filterTag, gitFilter: gitChangesFilter)
    }

    /// (Re)starts the subfolder search for the filter text, or stops it and clears its results.
    func updateRecursiveFilter() {
        guard searchMode == .filter else { return }
        recursiveFilter.cancel()
        recursiveFilter.clearCache()
        if !searchResults.isEmpty { searchResults = [] }
        let query = searchText
        guard !query.isEmpty, canFilterSubfolders, isBackgroundWorkActive else {
            isSearching = false
            return
        }
        isSearching = true
        recursiveFilter.start(root: currentPath, query: query, showHidden: AppSettings.shared.showHiddenFiles) { [weak self] batch, finished in
            guard let self else { return }
            if !batch.isEmpty { self.searchResults.append(contentsOf: batch) }
            if finished { self.isSearching = false }
        }
    }

    /// Stops the subfolder search and clears its results (leaving the location).
    func stopRecursiveFilter() {
        guard searchMode == .filter else { return }
        recursiveFilter.cancel()
        recursiveFilter.clearCache()
        if !searchResults.isEmpty { searchResults = [] }
        isSearching = false
    }
}
