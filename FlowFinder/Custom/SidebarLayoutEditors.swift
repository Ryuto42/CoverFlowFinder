import AppKit
import SwiftUI

// MARK: - Sheets

@MainActor
enum SidebarSheet {
    private final class Holder {
        var sheet: NSWindow?
    }

    /// Shows a SwiftUI view as a sheet on `window`; `content` gets the closure that dismisses it.
    static func present<Content: View>(on window: NSWindow, content: (@escaping () -> Void) -> Content) {
        let holder = Holder()
        let dismiss: () -> Void = { [weak window] in
            guard let sheet = holder.sheet else { return }
            holder.sheet = nil
            window?.endSheet(sheet)
        }
        let controller = NSHostingController(rootView: content(dismiss))
        let sheet = NSWindow(contentViewController: controller)
        holder.sheet = sheet
        window.beginSheet(sheet)
    }
}

// MARK: - Catalog

/// The items each section has (or would have), for the settings tab and the hidden-items list.
@MainActor
enum SidebarLayoutCatalog {
    enum EntryKind: Equatable {
        case hideable
        case favorite
        case groupFolder
        case kindFilter(isBuiltin: Bool)
    }

    struct Entry: Identifiable, Equatable {
        let id: String
        let title: String
        let kind: EntryKind
    }

    static func entries(for section: SidebarLayoutSection, settings: AppSettings) -> [Entry] {
        let environment = SidebarEnvironmentStore.shared.environment
        let entries: [Entry]
        switch section.type {
        case .kinds:
            return settings.sidebarLayout.kindFilters.map {
                Entry(id: $0.itemID, title: $0.displayName, kind: .kindFilter(isBuiltin: $0.isBuiltin))
            }
        case .group:
            let store = SidebarGroupFolderStore.shared
            return section.folders.map {
                Entry(id: $0.id, title: store.resolution(for: $0).name.finderDisplayName, kind: .groupFolder)
            }
        case .smartFolders:
            entries = SmartFolderStore.shared.folders.map { Entry(id: $0.itemID, title: $0.name, kind: .hideable) }
        case .builtin:
            switch section.id {
            case "favorites":
                return [
                    Entry(id: "airdrop", title: "AirDrop", kind: .hideable),
                    Entry(id: "photosLibrary", title: String(localized: "Photos Library"), kind: .hideable)
                ] + settings.sidebarFavorites.map { favorite in
                    let resolution = environment.favoriteResolutions[favorite.id] ?? SidebarFavoriteResolution.provisional(for: favorite)
                    return Entry(id: favorite.id, title: resolution.name.finderDisplayName, kind: .favorite)
                }
            case "icloud":
                entries = [Entry(id: "icloud", title: String(localized: "iCloud Drive"), kind: .hideable)]
                    + environment.cloudLocations.map { Entry(id: $0.itemID, title: $0.name, kind: .hideable) }
            case "locations":
                entries = environment.locations.map {
                    Entry(id: "location:\($0.url.path)", title: $0.name.finderDisplayName, kind: .hideable)
                }
            case "tags":
                entries = FinderTag.allTags.map { Entry(id: "tag:\($0.name)", title: $0.name, kind: .hideable) }
            default:
                entries = []
            }
        }
        var rank: [String: Int] = [:]
        for (index, id) in section.itemOrder.enumerated() where rank[id] == nil {
            rank[id] = index
        }
        return entries.enumerated().sorted { lhs, rhs in
            switch (rank[lhs.element.id], rank[rhs.element.id]) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    static func title(forItem id: String, settings: AppSettings) -> String {
        for section in settings.sidebarLayout.sections {
            if let entry = entries(for: section, settings: settings).first(where: { $0.id == id }) {
                return entry.title
            }
        }
        if let title = settings.sidebarLayout.items[id]?.hiddenTitle { return title }
        if id.hasPrefix("location:") { return URL(fileURLWithPath: String(id.dropFirst(9))).lastPathComponent }
        if id.hasPrefix("tag:") { return String(id.dropFirst(4)) }
        return id
    }

    static func symbol(for section: SidebarLayoutSection) -> String {
        switch section.type {
        case .group: return "folder"
        case .kinds: return "line.3.horizontal.decrease.circle"
        case .smartFolders: return "gearshape"
        case .builtin:
            switch section.id {
            case "favorites": return "star"
            case "icloud": return "icloud"
            case "locations": return "externaldrive"
            case "tags": return "tag"
            default: return "list.bullet"
            }
        }
    }

    /// Applies a reorder made in the settings list.
    static func reorder(_ section: SidebarLayoutSection, ids: [String], settings: AppSettings) {
        switch section.type {
        case .kinds:
            let filters = settings.sidebarLayout.kindFilters
            settings.sidebarLayout.kindFilters = ids.compactMap { id in filters.first { $0.itemID == id } }
        case .group:
            settings.sidebarLayout.updateSection(section.id) { entry in
                entry.folders = ids.compactMap { id in entry.folders.first { $0.id == id } }
            }
        case .builtin where section.id == "favorites":
            let favorites = settings.sidebarFavorites
            settings.sidebarFavorites = ids.compactMap { id in favorites.first { $0.id == id } }
        case .builtin, .smartFolders:
            settings.sidebarLayout.updateSection(section.id) { $0.itemOrder = ids }
        }
    }

    static func chooseFolders(forGroup id: String, settings: AppSettings) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK else { return }
        settings.addFolders(panel.urls, toSidebarGroup: id)
    }
}

// MARK: - Hidden items

struct SidebarHiddenItemsView: View {
    @ObservedObject var settings: AppSettings
    let onDone: () -> Void

    private var hiddenSections: [SidebarLayoutSection] {
        settings.sidebarLayout.sections.filter { settings.isSidebarSectionHidden($0.id) }
    }

    private var hiddenItems: [(id: String, title: String)] {
        settings.sidebarLayout.items.filter { $0.value.isHidden }.keys
            .map { ($0, SidebarLayoutCatalog.title(forItem: $0, settings: settings)) }
            .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hidden Sidebar Items").font(.headline)
            List {
                if !hiddenSections.isEmpty {
                    Section("Sections") {
                        ForEach(hiddenSections) { section in
                            row(section.displayTitle) { settings.setSidebarSectionHidden(section.id, false) }
                        }
                    }
                }
                if !hiddenItems.isEmpty {
                    Section("Items") {
                        ForEach(hiddenItems, id: \.id) { item in
                            row(item.title) { settings.setSidebarItemHidden(item.id, title: nil, hidden: false) }
                        }
                    }
                }
                if hiddenSections.isEmpty && hiddenItems.isEmpty {
                    Text("Nothing is hidden.").foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 220)
            HStack {
                Button("Show All") {
                    hiddenSections.forEach { settings.setSidebarSectionHidden($0.id, false) }
                    hiddenItems.forEach { settings.setSidebarItemHidden($0.id, title: nil, hidden: false) }
                }
                .disabled(hiddenSections.isEmpty && hiddenItems.isEmpty)
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func row(_ title: String, show: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button("Show", action: show)
        }
    }
}

// MARK: - Icon editor

struct SidebarIconEditorView: View {
    let itemTitle: String
    @State private var symbol: String
    @State private var colorHex: String?
    @State private var customColor: Color
    let onSave: (String?, String?) -> Void
    let onCancel: () -> Void

    static let presets = [
        "folder", "folder.fill", "star", "star.fill", "heart", "house", "desktopcomputer", "laptopcomputer",
        "doc", "doc.text", "doc.richtext", "book", "books.vertical", "bookmark", "photo", "camera",
        "film", "music.note", "headphones", "mic", "paintbrush", "paintpalette", "hammer", "wrench.and.screwdriver",
        "terminal", "chevron.left.forwardslash.chevron.right", "cpu", "gamecontroller", "briefcase", "cart",
        "creditcard", "graduationcap", "person", "person.2", "tray", "tray.full", "archivebox", "shippingbox",
        "externaldrive", "internaldrive", "icloud", "globe", "network", "server.rack", "cloud", "bolt",
        "flame", "leaf", "sun.max", "moon", "flag", "tag", "pin", "mappin", "calendar", "clock",
        "lock", "key", "trash", "sparkles"
    ]

    static let colors: [(name: String, hex: String?)] = [
        (String(localized: "Default"), nil), (String(localized: "Red"), "#FF3B30"), (String(localized: "Orange"), "#FF9500"),
        (String(localized: "Yellow"), "#FFCC00"), (String(localized: "Green"), "#34C759"),
        (String(localized: "Teal"), "#30B0C7"), (String(localized: "Blue"), "#007AFF"), (String(localized: "Purple"), "#AF52DE"),
        (String(localized: "Pink"), "#FF2D55"), (String(localized: "Brown"), "#A2845E"),
        (String(localized: "Gray"), "#8E8E93")
    ]

    init(itemTitle: String, symbol: String, color: String?, onSave: @escaping (String?, String?) -> Void, onCancel: @escaping () -> Void) {
        self.itemTitle = itemTitle
        _symbol = State(initialValue: symbol.isEmpty ? "folder" : symbol)
        _colorHex = State(initialValue: color)
        _customColor = State(initialValue: Color(nsColor: NSColor(sidebarHex: color) ?? .controlAccentColor))
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var isValidSymbol: Bool {
        NSImage(systemSymbolName: symbol.trimmingCharacters(in: .whitespaces), accessibilityDescription: nil) != nil
    }

    private var previewColor: Color {
        Color(nsColor: NSColor(sidebarHex: colorHex) ?? .controlAccentColor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Icon for “\(itemTitle)”").font(.headline)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 4), count: 12), spacing: 4) {
                ForEach(Self.presets, id: \.self) { name in
                    Button {
                        symbol = name
                    } label: {
                        Image(systemName: name)
                            .frame(width: 28, height: 28)
                            .foregroundStyle(previewColor)
                            .background(RoundedRectangle(cornerRadius: 5).fill(symbol == name ? Color.accentColor.opacity(0.25) : Color.clear))
                    }
                    .buttonStyle(.plain)
                    .help(name)
                }
            }

            HStack {
                Text("Symbol name:")
                TextField("folder.fill", text: $symbol)
                    .textFieldStyle(.roundedBorder)
                Image(systemName: isValidSymbol ? symbol : "exclamationmark.triangle")
                    .foregroundStyle(isValidSymbol ? previewColor : .orange)
                    .frame(width: 24)
            }

            HStack(spacing: 6) {
                Text("Color:")
                ForEach(Self.colors, id: \.name) { entry in
                    Button {
                        colorHex = entry.hex
                    } label: {
                        Circle()
                            .fill(Color(nsColor: NSColor(sidebarHex: entry.hex) ?? .controlAccentColor))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(Color.primary, lineWidth: colorHex == entry.hex ? 2 : 0))
                    }
                    .buttonStyle(.plain)
                    .help(entry.name)
                }
                ColorPicker("", selection: $customColor, supportsOpacity: false)
                    .labelsHidden()
                    .onChange(of: customColor) { _, newValue in
                        colorHex = NSColor(newValue).sidebarHex
                    }
            }

            HStack {
                Button("Use Default Icon") { onSave(nil, nil) }
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Done") {
                    onSave(symbol.trimmingCharacters(in: .whitespaces), colorHex)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValidSymbol)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

// MARK: - Kind filter editor

struct SidebarKindFilterEditorView: View {
    private let original: SidebarKindFilter?
    @State private var name: String
    @State private var extensions: String
    @State private var types: String
    @State private var scope: SidebarKindFilter.Scope
    @State private var symbol: String
    let onSave: (SidebarKindFilter) -> Void
    let onCancel: () -> Void

    init(filter: SidebarKindFilter?, onSave: @escaping (SidebarKindFilter) -> Void, onCancel: @escaping () -> Void) {
        original = filter
        _name = State(initialValue: filter?.name ?? "")
        _extensions = State(initialValue: filter?.extensions.joined(separator: ", ") ?? "")
        _types = State(initialValue: filter?.contentTypes.joined(separator: ", ") ?? "")
        _scope = State(initialValue: filter?.scope ?? .thisMac)
        _symbol = State(initialValue: filter?.symbol ?? "doc")
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var isDuplicateName: Bool {
        AppSettings.shared.sidebarLayout.kindFilters.contains {
            $0.id != original?.id && $0.name.compare(trimmedName, options: .caseInsensitive) == .orderedSame
        }
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && !isDuplicateName
            && !(SidebarKindFilter.parseList(extensions).isEmpty && SidebarKindFilter.parseList(types).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(original == nil ? "New Kind Filter" : "Edit Kind Filter").font(.headline)
            Form {
                TextField("Name:", text: $name, prompt: Text("Raw Photos"))
                TextField("Extensions:", text: $extensions, prompt: Text("cr2, nef, arw"))
                TextField("Types (UTType):", text: $types, prompt: Text("public.image, com.adobe.pdf"))
                Picker("Search:", selection: $scope) {
                    ForEach(SidebarKindFilter.Scope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                HStack {
                    TextField("Symbol:", text: $symbol, prompt: Text("doc"))
                    Image(systemName: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil ? symbol : "questionmark")
                        .frame(width: 20)
                }
            }
            Text("Separate entries with commas. A file matches when its type conforms to one of the types or its name ends with one of the extensions.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if isDuplicateName {
                Text("Another kind filter already has this name.").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") {
                    var filter = original ?? SidebarKindFilter(name: trimmedName, contentTypes: [], symbol: "doc")
                    filter.name = trimmedName
                    filter.extensions = SidebarKindFilter.parseList(extensions).map { $0.lowercased() }
                    filter.contentTypes = SidebarKindFilter.parseList(types)
                    filter.scope = scope
                    let trimmedSymbol = symbol.trimmingCharacters(in: .whitespaces)
                    filter.symbol = NSImage(systemSymbolName: trimmedSymbol, accessibilityDescription: nil) != nil ? trimmedSymbol : "doc"
                    onSave(filter)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - Settings tab

struct SidebarLayoutSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var selection: String? = "favorites"
    @State private var kindEditor: KindEditorRequest?
    @State private var showingReset = false

    private struct KindEditorRequest: Identifiable {
        let id = UUID()
        let filter: SidebarKindFilter?
    }

    private var selectedSection: SidebarLayoutSection? {
        selection.flatMap { settings.sidebarLayout.section($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                sectionsColumn
                itemsColumn
            }
            HStack {
                Text("Drag to reorder. Right-click the sidebar for more options.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset Sidebar Layout…") { showingReset = true }
            }
        }
        .sheet(item: $kindEditor) { request in
            SidebarKindFilterEditorView(filter: request.filter, onSave: { filter in
                settings.upsertSidebarKindFilter(filter)
                kindEditor = nil
            }, onCancel: { kindEditor = nil })
        }
        .alert("Reset the sidebar layout?", isPresented: $showingReset) {
            Button("Reset", role: .destructive) {
                settings.sidebarLayout = .default
                for id in SidebarLayout.builtinSectionIDs {
                    settings.setSidebarSectionHidden(id, false)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Groups, kind filters, names, icons, order and hidden items return to their defaults. Favorites are kept.")
        }
    }

    private var sectionsColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sections").font(.headline)
            List(selection: $selection) {
                ForEach(settings.sidebarLayout.sections) { section in
                    HStack(spacing: 6) {
                        Toggle("", isOn: Binding(
                            get: { !settings.isSidebarSectionHidden(section.id) },
                            set: { settings.setSidebarSectionHidden(section.id, !$0) }
                        ))
                        .labelsHidden()
                        Image(systemName: SidebarLayoutCatalog.symbol(for: section))
                            .frame(width: 16)
                            .foregroundStyle(.secondary)
                        Text(section.displayTitle).lineLimit(1)
                    }
                    .tag(section.id)
                }
                .onMove { from, to in
                    settings.sidebarLayout.sections.move(fromOffsets: from, toOffset: to)
                }
            }
            .frame(width: 190)
            HStack(spacing: 6) {
                Button("New Group") {
                    selection = settings.addSidebarGroup(named: String(localized: "New Group"))
                }
            }
        }
    }

    @ViewBuilder
    private var itemsColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let section = selectedSection {
                HStack {
                    Text("Name:")
                    TextField(section.defaultTitle, text: Binding(
                        get: { settings.sidebarLayout.section(section.id)?.title ?? "" },
                        set: { value in
                            settings.sidebarLayout.updateSection(section.id) { $0.title = value.isEmpty ? nil : value }
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
                let entries = SidebarLayoutCatalog.entries(for: section, settings: settings)
                List {
                    ForEach(entries) { entry in
                        itemRow(entry, section: section)
                    }
                    .onMove { from, to in
                        var ids = entries.map(\.id)
                        ids.move(fromOffsets: from, toOffset: to)
                        SidebarLayoutCatalog.reorder(section, ids: ids, settings: settings)
                    }
                }
                HStack(spacing: 6) {
                    if section.type == .group {
                        Button("Add Folder…") { SidebarLayoutCatalog.chooseFolders(forGroup: section.id, settings: settings) }
                        Spacer()
                        Button("Delete Group", role: .destructive) {
                            settings.removeSidebarGroup(section.id)
                            selection = nil
                        }
                    } else if section.type == .kinds {
                        Button("New Kind Filter…") { kindEditor = KindEditorRequest(filter: nil) }
                    }
                }
            } else {
                Text("Select a section.").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func itemRow(_ entry: SidebarLayoutCatalog.Entry, section: SidebarLayoutSection) -> some View {
        HStack(spacing: 6) {
            switch entry.kind {
            case .hideable, .kindFilter:
                Toggle("", isOn: Binding(
                    get: { settings.sidebarLayout.items[entry.id]?.isHidden != true },
                    set: { settings.setSidebarItemHidden(entry.id, title: entry.title, hidden: !$0) }
                ))
                .labelsHidden()
            case .favorite, .groupFolder:
                Image(systemName: "folder").frame(width: 16).foregroundStyle(.secondary)
            }
            Text(settings.sidebarLayout.items[entry.id]?.alias.flatMap { $0.isEmpty ? nil : "\($0) (\(entry.title))" } ?? entry.title)
                .lineLimit(1)
            Spacer()
            if case .kindFilter(let isBuiltin) = entry.kind,
               let filter = settings.sidebarLayout.kindFilters.first(where: { $0.itemID == entry.id }) {
                Picker("", selection: Binding(
                    get: { filter.scope },
                    set: { scope in
                        var edited = filter
                        edited.scope = scope
                        settings.upsertSidebarKindFilter(edited)
                    }
                )) {
                    ForEach(SidebarKindFilter.Scope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 120)
                Button {
                    kindEditor = KindEditorRequest(filter: filter)
                } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help("Edit")
                if !isBuiltin {
                    Button {
                        settings.removeSidebarKindFilter(filter.id)
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Delete")
                }
            }
            if entry.kind == .groupFolder {
                Button {
                    settings.removeFolder(entry.id, fromSidebarGroup: section.id)
                } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Remove from Group")
            }
            if entry.kind == .favorite {
                Button {
                    settings.sidebarFavorites.removeAll { $0.id == entry.id }
                } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Remove from Favorites")
            }
        }
    }
}
