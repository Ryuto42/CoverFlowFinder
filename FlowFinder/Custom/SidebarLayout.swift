import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - Model

/// The user's customization of the sidebar, layered on top of the sections `SidebarOutlineView` builds: section
/// order and visibility, custom groups, the Kinds section, and per-item aliases, icons, order and visibility.
/// The built-in sections' visibility stays in `sidebarShowFavorites` etc. (see `AppSettings.isSidebarSectionHidden`).
struct SidebarLayout: Codable, Equatable {
    var sections: [SidebarLayoutSection]
    /// By sidebar item id ("airdrop", a favorite's id, "location:/path", "tag:Red", "kind:<id>", a group folder's id).
    var items: [String: SidebarItemCustomization]
    var kindFilters: [SidebarKindFilter]

    static let builtinSectionIDs = ["favorites", "icloud", "locations", "tags"]
    static let kindsSectionID = "kinds"
    static let smartFoldersSectionID = "smartFolders"

    static let `default` = SidebarLayout(
        sections: builtinSectionIDs.map { SidebarLayoutSection(id: $0, type: .builtin) }
            + [SidebarLayoutSection(id: kindsSectionID, type: .kinds),
               SidebarLayoutSection(id: smartFoldersSectionID, type: .smartFolders)],
        items: [:],
        kindFilters: SidebarKindFilter.defaults
    )

    init(sections: [SidebarLayoutSection], items: [String: SidebarItemCustomization], kindFilters: [SidebarKindFilter]) {
        self.sections = sections
        self.items = items
        self.kindFilters = kindFilters
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sections = try container.decodeIfPresent([SidebarLayoutSection].self, forKey: .sections) ?? []
        items = try container.decodeIfPresent([String: SidebarItemCustomization].self, forKey: .items) ?? [:]
        kindFilters = try container.decodeIfPresent([SidebarKindFilter].self, forKey: .kindFilters) ?? SidebarKindFilter.defaults
        self = normalized()
    }

    /// Every built-in section and the Kinds section exactly once (missing ones appended in their default order).
    func normalized() -> SidebarLayout {
        var copy = self
        var seen = Set<String>()
        copy.sections = sections.filter { seen.insert($0.id).inserted }
        for id in Self.builtinSectionIDs where !seen.contains(id) {
            copy.sections.append(SidebarLayoutSection(id: id, type: .builtin))
        }
        if !seen.contains(Self.kindsSectionID) {
            copy.sections.append(SidebarLayoutSection(id: Self.kindsSectionID, type: .kinds))
        }
        if !seen.contains(Self.smartFoldersSectionID) {
            copy.sections.append(SidebarLayoutSection(id: Self.smartFoldersSectionID, type: .smartFolders))
        }
        copy.items = items.filter { !$0.value.isEmpty }
        return copy
    }

    static func decode(_ data: Data?) -> SidebarLayout {
        guard let data, let layout = try? JSONDecoder().decode(SidebarLayout.self, from: data) else { return .default }
        return layout
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    func section(_ id: String) -> SidebarLayoutSection? {
        sections.first { $0.id == id }
    }

    mutating func updateSection(_ id: String, _ change: (inout SidebarLayoutSection) -> Void) {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
        change(&sections[index])
    }

    mutating func updateItem(_ id: String, _ change: (inout SidebarItemCustomization) -> Void) {
        var item = items[id] ?? SidebarItemCustomization()
        change(&item)
        items[id] = item.isEmpty ? nil : item
    }
}

struct SidebarLayoutSection: Codable, Equatable, Identifiable {
    enum SectionType: String, Codable {
        case builtin
        case group
        case kinds
        case smartFolders
    }

    var id: String
    var type: SectionType
    /// A group's name, or a renamed built-in section's title (nil: the default title).
    var title: String?
    /// Used by groups and Kinds; built-in sections use their `sidebarShow…` setting.
    var isHidden: Bool = false
    /// Item ids in the user's order for built-in sections (items not listed keep their place after these).
    var itemOrder: [String] = []
    /// A group's folders, held like custom favorites (path plus a non-security-scoped bookmark).
    var folders: [SidebarFavorite] = []

    init(id: String, type: SectionType, title: String? = nil) {
        self.id = id
        self.type = type
        self.title = title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(SectionType.self, forKey: .type)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        itemOrder = try container.decodeIfPresent([String].self, forKey: .itemOrder) ?? []
        folders = try container.decodeIfPresent([SidebarFavorite].self, forKey: .folders) ?? []
    }

    static func newGroup(named name: String) -> SidebarLayoutSection {
        SidebarLayoutSection(id: "group.\(UUID().uuidString)", type: .group, title: name)
    }

    var defaultTitle: String {
        switch id {
        case "favorites": return String(localized: "Favorites")
        case "icloud": return String(localized: "Cloud")
        case "locations": return String(localized: "Locations")
        case "tags": return String(localized: "Tags")
        case SidebarLayout.kindsSectionID: return String(localized: "Kinds")
        case SidebarLayout.smartFoldersSectionID: return String(localized: "Smart Folders")
        default: return String(localized: "Group")
        }
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return defaultTitle
    }
}

struct SidebarItemCustomization: Codable, Equatable {
    var alias: String?
    /// SF Symbol name.
    var symbol: String?
    /// "#RRGGBB".
    var color: String?
    var isHidden: Bool = false
    /// The item's title when it was hidden, to list it while it isn't in the sidebar (e.g. an unmounted volume).
    var hiddenTitle: String?

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        alias = try container.decodeIfPresent(String.self, forKey: .alias)
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
        color = try container.decodeIfPresent(String.self, forKey: .color)
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        hiddenTitle = try container.decodeIfPresent(String.self, forKey: .hiddenTitle)
    }

    var isEmpty: Bool {
        (alias ?? "").isEmpty && (symbol ?? "").isEmpty && (color ?? "").isEmpty && !isHidden
    }

    var hasAppearanceChanges: Bool {
        !(alias ?? "").isEmpty || !(symbol ?? "").isEmpty || !(color ?? "").isEmpty
    }
}

struct SidebarKindFilter: Codable, Equatable, Identifiable {
    enum Scope: String, Codable, CaseIterable {
        case thisMac
        case currentFolder

        var title: String {
            switch self {
            case .thisMac: return String(localized: "This Mac")
            case .currentFolder: return String(localized: "Current Folder")
            }
        }
    }

    var id: String
    var name: String
    var contentTypes: [String]
    /// File name extensions (without the dot), matched by name as well as by type.
    var extensions: [String]
    var scope: Scope
    var symbol: String
    /// Built-in kinds are hidden rather than deleted.
    var isBuiltin: Bool

    var itemID: String { "kind:\(id)" }

    init(id: String = UUID().uuidString, name: String, contentTypes: [String], extensions: [String] = [],
         scope: Scope = .thisMac, symbol: String, isBuiltin: Bool = false) {
        self.id = id
        self.name = name
        self.contentTypes = contentTypes
        self.extensions = extensions
        self.scope = scope
        self.symbol = symbol
        self.isBuiltin = isBuiltin
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        contentTypes = try container.decodeIfPresent([String].self, forKey: .contentTypes) ?? []
        extensions = try container.decodeIfPresent([String].self, forKey: .extensions) ?? []
        scope = (try? container.decodeIfPresent(Scope.self, forKey: .scope)) ?? .thisMac
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol) ?? "doc"
        isBuiltin = try container.decodeIfPresent(Bool.self, forKey: .isBuiltin) ?? false
    }

    static let defaults: [SidebarKindFilter] = [
        SidebarKindFilter(id: "images", name: "Images", contentTypes: ["public.image"], symbol: "photo", isBuiltin: true),
        SidebarKindFilter(id: "pdfs", name: "PDFs", contentTypes: ["com.adobe.pdf"], symbol: "doc.richtext", isBuiltin: true),
        SidebarKindFilter(id: "movies", name: "Movies", contentTypes: ["public.movie"], symbol: "film", isBuiltin: true),
        SidebarKindFilter(id: "music", name: "Music", contentTypes: ["public.audio"], symbol: "music.note", isBuiltin: true),
        SidebarKindFilter(
            id: "documents", name: "Documents",
            contentTypes: [
                "org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc",
                "org.openxmlformats.spreadsheetml.sheet", "com.microsoft.excel.xls",
                "org.openxmlformats.presentationml.presentation", "com.microsoft.powerpoint.ppt",
                "com.apple.iwork.pages.sffpages", "com.apple.iwork.pages.pages",
                "com.apple.iwork.numbers.sffnumbers", "com.apple.iwork.numbers.numbers",
                "com.apple.iwork.keynote.sffkey", "com.apple.iwork.keynote.key",
                "public.rtf", "public.plain-text"
            ],
            symbol: "doc.text", isBuiltin: true
        ),
        SidebarKindFilter(
            id: "archives", name: "Archives",
            contentTypes: ["public.archive", "public.zip-archive", "org.7-zip.7-zip-archive", "com.rarlab.rar-archive",
                           "org.gnu.gnu-zip-archive", "public.tar-archive"],
            extensions: ["zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "xz"],
            symbol: "archivebox", isBuiltin: true
        ),
        SidebarKindFilter(
            id: "code", name: "Code",
            contentTypes: ["public.source-code", "public.script", "public.shell-script", "public.json", "public.xml"],
            symbol: "chevron.left.forwardslash.chevron.right", isBuiltin: true
        )
    ]

    /// Parses "jpg, .png" style input.
    static func parseList(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Settings access

extension AppSettings {
    /// A built-in section's visibility is its existing `sidebarShow…` setting; groups and Kinds use the layout.
    func isSidebarSectionHidden(_ id: String) -> Bool {
        switch id {
        case "favorites": return !sidebarShowFavorites
        case "icloud": return !sidebarShowICloud
        case "locations": return !sidebarShowLocations
        case "tags": return !sidebarShowTags
        default: return sidebarLayout.section(id)?.isHidden ?? true
        }
    }

    func setSidebarSectionHidden(_ id: String, _ hidden: Bool) {
        switch id {
        case "favorites": sidebarShowFavorites = !hidden
        case "icloud": sidebarShowICloud = !hidden
        case "locations": sidebarShowLocations = !hidden
        case "tags": sidebarShowTags = !hidden
        default: sidebarLayout.updateSection(id) { $0.isHidden = hidden }
        }
    }

    func setSidebarItemHidden(_ id: String, title: String?, hidden: Bool) {
        sidebarLayout.updateItem(id) {
            $0.isHidden = hidden
            $0.hiddenTitle = hidden ? title : nil
        }
    }

    /// Moves `id` before the section `beforeID` (nil: to the end).
    func moveSidebarSection(_ id: String, before beforeID: String?) {
        guard id != beforeID else { return }
        var layout = sidebarLayout
        guard let index = layout.sections.firstIndex(where: { $0.id == id }) else { return }
        let section = layout.sections.remove(at: index)
        if let beforeID, let target = layout.sections.firstIndex(where: { $0.id == beforeID }) {
            layout.sections.insert(section, at: target)
        } else {
            layout.sections.append(section)
        }
        sidebarLayout = layout
    }

    func addSidebarGroup(named name: String) -> String {
        let section = SidebarLayoutSection.newGroup(named: name)
        sidebarLayout.sections.append(section)
        return section.id
    }

    func removeSidebarGroup(_ id: String) {
        var layout = sidebarLayout
        let folderIDs = layout.section(id)?.folders.map(\.id) ?? []
        layout.sections.removeAll { $0.id == id }
        for folderID in folderIDs {
            layout.items[folderID] = nil
        }
        sidebarLayout = layout
    }

    /// Adds folders (not files or packages) to a group, skipping ones it already has. Returns how many were added.
    @discardableResult
    func addFolders(_ urls: [URL], toSidebarGroup id: String, at index: Int? = nil) -> Int {
        guard let section = sidebarLayout.section(id), section.type == .group else { return 0 }
        var folders = section.folders
        let existing = Set(folders.compactMap { $0.path.map { URL(fileURLWithPath: $0).standardizedFileURL.path } })
        var insertIndex = min(max(0, index ?? folders.count), folders.count)
        var added = 0
        for url in urls {
            let standardized = url.standardizedFileURL
            let values = try? standardized.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            guard values?.isDirectory == true, values?.isPackage != true,
                  !existing.contains(standardized.path) else { continue }
            folders.insert(SidebarFavorite.custom(url: standardized), at: insertIndex)
            insertIndex += 1
            added += 1
        }
        if added > 0 {
            sidebarLayout.updateSection(id) { $0.folders = folders }
        }
        return added
    }

    func removeFolder(_ folderID: String, fromSidebarGroup id: String) {
        var layout = sidebarLayout
        layout.updateSection(id) { $0.folders.removeAll { $0.id == folderID } }
        layout.items[folderID] = nil
        sidebarLayout = layout
    }

    func upsertSidebarKindFilter(_ filter: SidebarKindFilter) {
        if let index = sidebarLayout.kindFilters.firstIndex(where: { $0.id == filter.id }) {
            sidebarLayout.kindFilters[index] = filter
        } else {
            sidebarLayout.kindFilters.append(filter)
        }
    }

    func removeSidebarKindFilter(_ id: String) {
        var layout = sidebarLayout
        layout.kindFilters.removeAll { $0.id == id }
        layout.items["kind:\(id)"] = nil
        sidebarLayout = layout
    }
}

// MARK: - Kind search

/// Kinds run as a Spotlight search whose text is "kind:<name>", so the existing search results UI shows them
/// (the search field, clearing, re-scoping on navigation). `FileBrowserViewModel` asks here for the query.
@MainActor
enum SidebarKindSearch {
    static let prefix = "kind:"

    static func searchText(for filter: SidebarKindFilter) -> String {
        prefix + filter.name
    }

    static func filter(matching text: String) -> SidebarKindFilter? {
        guard text.lowercased().hasPrefix(prefix) else { return nil }
        let name = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return AppSettings.shared.sidebarLayout.kindFilters.first {
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    /// The Spotlight predicate and scope for a "kind:<name>" search, or nil for an ordinary name search.
    static func spotlightQuery(for text: String, currentPath: URL) -> (predicate: NSPredicate, scopes: [URL])? {
        if let smartFolder = SmartFolderSearch.spotlightQuery(for: text) { return smartFolder }
        guard let filter = filter(matching: text), let predicate = predicate(for: filter) else { return nil }
        return (predicate, filter.scope == .thisMac ? thisMacScopes() : [currentPath])
    }

    /// The home folder without ~/Library and other hidden folders (Finder doesn't show their contents either;
    /// ~/Library alone can hold tens of thousands of cached images).
    static func thisMacScopes() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let children = (try? FileManager.default.contentsOfDirectory(
            at: home, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        let folders = children.filter {
            $0.lastPathComponent != "Library" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        return folders.isEmpty ? [home] : folders
    }

    static func predicate(for filter: SidebarKindFilter) -> NSPredicate? {
        var types = filter.contentTypes
        for ext in filter.extensions {
            if let type = UTType(filenameExtension: ext), !type.isDynamic {
                types.append(type.identifier)
            }
        }
        // Spotlight's own query syntax: NSMetadataQuery throws on some NSCompoundPredicate shapes.
        func sanitized(_ text: String) -> String {
            text.filter { !"\"'\\*?".contains($0) }
        }
        var terms = Array(Set(types.map(sanitized))).filter { !$0.isEmpty }.sorted().map {
            "kMDItemContentTypeTree == \"\($0)\""
        }
        terms += filter.extensions.map(sanitized).filter { !$0.isEmpty }.map {
            "kMDItemFSName == \"*.\($0)\"c"
        }
        guard !terms.isEmpty else { return nil }
        return NSPredicate(fromMetadataQueryString: terms.joined(separator: " || "))
    }
}

// MARK: - Group folders

/// Resolves the custom groups' folders in the background (bookmarks follow renamed or moved folders), like
/// `SidebarEnvironmentStore` does for favorites, and loads their icons.
@MainActor
final class SidebarGroupFolderStore {
    static let shared = SidebarGroupFolderStore()

    private(set) var resolutions: [String: SidebarFavoriteResolution] = [:]
    private(set) var icons: [String: NSImage] = [:]
    /// Bumped whenever a resolution or icon arrives.
    private(set) var revision = 0
    private var requested: [SidebarFavorite] = []
    private var inFlight: Set<String> = []
    private let queue = DispatchQueue(label: "com.flowfinder.sidebar.groupFolders", qos: .utility, attributes: .concurrent)
    private var activationObserver: NSObjectProtocol?

    private init() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                SidebarGroupFolderStore.shared.resolveAll()
            }
        }
    }

    func request(_ folders: [SidebarFavorite]) {
        guard folders != requested else { return }
        let previousIDs = Set(requested.map(\.id))
        requested = folders
        let ids = Set(folders.map(\.id))
        resolutions = resolutions.filter { ids.contains($0.key) }
        icons = icons.filter { ids.contains($0.key) }
        for folder in folders where !previousIDs.contains(folder.id) || resolutions[folder.id]?.favorite != folder {
            resolve(folder)
        }
    }

    func resolution(for folder: SidebarFavorite) -> SidebarFavoriteResolution {
        resolutions[folder.id] ?? SidebarFavoriteResolution.provisional(for: folder)
    }

    private func resolveAll() {
        requested.forEach(resolve)
    }

    private func resolve(_ folder: SidebarFavorite) {
        guard inFlight.insert(folder.id).inserted else { return }
        queue.async {
            let resolution = folder.resolve()
            let icon = resolution.isAvailable ? resolution.url.map { NSWorkspace.shared.icon(forFile: $0.path) } : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    SidebarGroupFolderStore.shared.finish(folder, resolution: resolution, icon: icon)
                }
            }
        }
    }

    private func finish(_ folder: SidebarFavorite, resolution: SidebarFavoriteResolution, icon: NSImage?) {
        inFlight.remove(folder.id)
        guard requested.contains(where: { $0.id == folder.id }) else { return }
        let changed = resolutions[folder.id] != resolution || (icon != nil) != (icons[folder.id] != nil)
        resolutions[folder.id] = resolution
        icons[folder.id] = icon
        if let updated = resolution.updatedFavorite {
            // The folder moved or got a bookmark: store it, keeping the id.
            let settings = AppSettings.shared
            var layout = settings.sidebarLayout
            for index in layout.sections.indices {
                if let folderIndex = layout.sections[index].folders.firstIndex(where: { $0.id == folder.id }) {
                    layout.sections[index].folders[folderIndex] = updated
                }
            }
            if layout != settings.sidebarLayout {
                settings.sidebarLayout = layout
            }
        }
        if changed {
            revision &+= 1
            SidebarEnvironmentStore.shared.environmentDidChange.send()
        }
    }
}

// MARK: - Colors

extension NSColor {
    convenience init?(sidebarHex hex: String?) {
        guard var text = hex?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = Int(text, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }

    var sidebarHex: String? {
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
