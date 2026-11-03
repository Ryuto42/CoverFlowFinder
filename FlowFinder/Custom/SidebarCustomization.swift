import AppKit
import SwiftUI

extension SidebarOutlineView {
    /// Pasteboard type for reordering sections and non-favorite items inside the sidebar (no file URL, like
    /// `favoriteDragType`).
    static let layoutDragType = NSPasteboard.PasteboardType("com.coverflowfinder.sidebar.layout")
}

/// What the sidebar's layout customization adds to `SidebarSnapshot`.
struct SidebarLayoutSnapshot: Equatable {
    let layout: SidebarLayout
    let groupRevision: Int
    let activeKindID: String?
    let smartFolderRevision: Int
    let activeSmartFolderID: String?
}

final class SidebarLayoutMenuPayload: NSObject {
    let sectionID: String
    let itemID: String?
    let title: String
    let value: String?

    init(sectionID: String, itemID: String? = nil, title: String, value: String? = nil) {
        self.sectionID = sectionID
        self.itemID = itemID
        self.title = title
        self.value = value
    }
}

extension SidebarOutlineView.Coordinator {
    private static var previousSearchModes: [ObjectIdentifier: SearchMode] = [:]
    private static var draggedFolderCache: (sequence: Int, urls: [URL], hasFolder: Bool)?

    // MARK: - Building

    func layoutSnapshot() -> SidebarLayoutSnapshot {
        let layout = appSettings.sidebarLayout
        let store = SidebarGroupFolderStore.shared
        store.request(layout.sections.filter { $0.type == .group }.flatMap(\.folders))
        return SidebarLayoutSnapshot(layout: layout, groupRevision: store.revision, activeKindID: activeKindFilter()?.id,
                                     smartFolderRevision: SmartFolderStore.shared.revision,
                                     activeSmartFolderID: activeSmartFolder()?.itemID)
    }

    /// Orders the built sections, adds groups and Kinds, renames sections and hides and reorders items.
    func applySidebarLayout(to built: [SidebarSection]) -> [SidebarSection] {
        let layout = appSettings.sidebarLayout
        var remaining = Dictionary(built.map { ($0.layoutID, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [SidebarSection] = []

        for entry in layout.sections {
            let section: SidebarSection?
            switch entry.type {
            case .builtin:
                section = remaining.removeValue(forKey: entry.id)
            case .kinds:
                section = entry.isHidden ? nil : SidebarSection(
                    kind: .kinds,
                    title: entry.defaultTitle,
                    items: layout.kindFilters.map { SidebarItem(kind: .kindFilter($0), id: $0.itemID, title: $0.displayName) },
                    layoutID: entry.id
                )
            case .group:
                section = entry.isHidden ? nil : makeGroupSection(entry)
            case .smartFolders:
                section = makeSmartFolderSection(entry)
            }
            guard let section else { continue }
            if let title = entry.title, !title.isEmpty {
                section.title = title
            }
            section.items = arrangedItems(section.items, entry: entry, layout: layout)
            result.append(section)
        }
        result.append(contentsOf: built.filter { remaining[$0.layoutID] != nil })
        return result
    }

    private func makeGroupSection(_ entry: SidebarLayoutSection) -> SidebarSection {
        let store = SidebarGroupFolderStore.shared
        let items = entry.folders.map { folder -> SidebarItem in
            let resolution = store.resolution(for: folder)
            return SidebarItem(
                kind: .groupFolder(resolution, sectionID: entry.id),
                id: folder.id,
                title: resolution.name,
                isEnabled: resolution.isAvailable
            )
        }
        return SidebarSection(kind: .group, title: entry.displayTitle, items: items, layoutID: entry.id)
    }

    private func arrangedItems(_ items: [SidebarItem], entry: SidebarLayoutSection, layout: SidebarLayout) -> [SidebarItem] {
        let visible = items.filter { $0.id == "tag:clear" || layout.items[$0.id]?.isHidden != true }
        guard entry.type == .builtin || entry.type == .smartFolders, entry.id != "favorites", !entry.itemOrder.isEmpty else { return visible }
        var rank: [String: Int] = [:]
        for (index, id) in entry.itemOrder.enumerated() where rank[id] == nil {
            rank[id] = index
        }
        let pinnedLast = visible.filter { $0.id == "tag:clear" }
        let ordered = visible.enumerated()
            .filter { $0.element.id != "tag:clear" }
            .sorted { lhs, rhs in
                switch (rank[lhs.element.id], rank[rhs.element.id]) {
                case let (l?, r?): return l < r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
        return ordered + pinnedLast
    }

    // MARK: - Presentation

    func layoutItemPresentation(for item: SidebarItem) -> SidebarItemPresentation {
        switch item.kind {
        case .groupFolder(let resolution, _):
            return SidebarItemPresentation(
                title: resolution.name.finderDisplayName,
                icon: SidebarSymbols.image(SidebarSymbols.folder(url: resolution.url)),
                iconTint: SidebarSymbols.favoriteTint,
                accessory: nil,
                isEnabled: resolution.isAvailable
            )
        case .kindFilter(let filter):
            let isActive = activeKindFilter()?.id == filter.id
            return SidebarItemPresentation(
                title: filter.displayName,
                icon: layoutSymbol(filter.symbol) ?? layoutSymbol("doc"),
                iconTint: .controlAccentColor,
                accessory: isActive ? layoutSymbol("checkmark") : nil,
                isEnabled: true
            )
        case .smartFolder(let folder):
            return smartFolderPresentation(folder)
        default:
            return SidebarItemPresentation(title: item.title, icon: nil, iconTint: nil, accessory: nil, isEnabled: item.isEnabled)
        }
    }

    func applyItemCustomization(to presentation: SidebarItemPresentation, item: SidebarItem) -> SidebarItemPresentation {
        guard let custom = appSettings.sidebarLayout.items[item.id], custom.hasAppearanceChanges else { return presentation }
        var icon = presentation.icon
        var tint = presentation.iconTint
        if let symbol = custom.symbol, !symbol.isEmpty, let image = layoutSymbol(symbol) {
            icon = image
            tint = NSColor(sidebarHex: custom.color) ?? .controlAccentColor
        } else if let color = NSColor(sidebarHex: custom.color), icon?.isTemplate == true {
            tint = color
        }
        let alias = custom.alias.flatMap { $0.isEmpty ? nil : $0 }
        return SidebarItemPresentation(
            title: alias ?? presentation.title,
            icon: icon,
            iconTint: tint,
            accessory: presentation.accessory,
            isEnabled: presentation.isEnabled
        )
    }

    private func layoutSymbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    private func displayedTitle(of item: SidebarItem) -> String {
        presentation(forTitleOf: item)
    }

    private func presentation(forTitleOf item: SidebarItem) -> String {
        if let alias = appSettings.sidebarLayout.items[item.id]?.alias, !alias.isEmpty { return alias }
        switch item.kind {
        case .favorite(let resolution):
            return resolution.name.finderDisplayName
        case .groupFolder(let resolution, _):
            return resolution.name.finderDisplayName
        case .location(let location):
            return location.name.finderDisplayName
        default:
            return item.title
        }
    }

    // MARK: - Kinds

    func activeKindFilter() -> SidebarKindFilter? {
        guard viewModel.searchMode == .finder else { return nil }
        return SidebarKindSearch.filter(matching: viewModel.searchText)
    }

    func activeKindFilterItem() -> SidebarItem? {
        if let smartFolder = activeSmartFolderItem() { return smartFolder }
        guard let active = activeKindFilter() else { return nil }
        for section in sections where section.kind == .kinds {
            if let item = section.items.first(where: { $0.id == active.itemID }) {
                return item
            }
        }
        return nil
    }

    /// Clicking the active kind turns it off; another kind starts its Spotlight search.
    func toggleKindFilter(_ filter: SidebarKindFilter) {
        if activeKindFilter()?.id == filter.id {
            viewModel.clearSearchQuery()
            if let previous = Self.previousSearchModes.removeValue(forKey: ObjectIdentifier(viewModel)) {
                viewModel.searchMode = previous
            }
            return
        }
        startKindSearch(filter)
    }

    private func startKindSearch(_ filter: SidebarKindFilter) {
        let text = SidebarKindSearch.searchText(for: filter)
        if viewModel.searchMode != .finder {
            Self.previousSearchModes[ObjectIdentifier(viewModel)] = viewModel.searchMode
            viewModel.searchMode = .finder
        }
        if viewModel.searchText == text {
            viewModel.performSearch(query: text)
        } else {
            viewModel.searchText = text
        }
    }

    // MARK: - Menu

    func appendLayoutMenuItems(to menu: NSMenu, clickedRow row: Int) {
        guard let outlineView else { return }
        let clicked = row >= 0 ? outlineView.item(atRow: row) : nil
        var entries: [NSMenuItem] = []

        if let section = clicked as? SidebarSection {
            entries = sectionMenuItems(for: section)
        } else if let item = clicked as? SidebarItem,
                  let section = outlineView.parent(forItem: item) as? SidebarSection {
            entries = itemMenuItems(for: item, in: section)
        }

        if !entries.isEmpty { entries.append(.separator()) }
        entries.append(layoutMenuItem("New Group…", #selector(newGroupFromMenu(_:))))
        entries.append(layoutMenuItem("New Kind Filter…", #selector(newKindFilterFromMenu(_:))))
        entries.append(newSmartFolderMenuItem())
        let showHidden = layoutMenuItem("Show Hidden Items…", #selector(showHiddenItemsFromMenu(_:)))
        showHidden.isEnabled = hasHiddenSidebarContent()
        entries.append(showHidden)

        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.autoenablesItems = false
        entries.forEach(menu.addItem)
    }

    private func layoutMenuItem(_ title: String, _ action: Selector, _ payload: SidebarLayoutMenuPayload? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: String.LocalizationValue(title)), action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = payload
        return item
    }

    private func sectionMenuItems(for section: SidebarSection) -> [NSMenuItem] {
        let id = section.layoutID
        let payload = SidebarLayoutMenuPayload(sectionID: id, title: section.title)
        var entries: [NSMenuItem] = []
        if section.kind == .group {
            entries.append(layoutMenuItem("Add Folder…", #selector(addFolderToGroupFromMenu(_:)), payload))
            entries.append(layoutMenuItem("Rename Group…", #selector(renameSectionFromMenu(_:)), payload))
            entries.append(layoutMenuItem("Delete Group…", #selector(deleteGroupFromMenu(_:)), payload))
        } else {
            entries.append(layoutMenuItem("Rename Section…", #selector(renameSectionFromMenu(_:)), payload))
        }
        entries.append(layoutMenuItem("Hide Section", #selector(hideSectionFromMenu(_:)), payload))
        entries.append(.separator())
        let index = sections.firstIndex(of: section) ?? 0
        let up = layoutMenuItem("Move Section Up", #selector(moveSectionUpFromMenu(_:)), payload)
        up.isEnabled = index > 0
        let down = layoutMenuItem("Move Section Down", #selector(moveSectionDownFromMenu(_:)), payload)
        down.isEnabled = index < sections.count - 1
        entries += [up, down]
        return entries
    }

    private func itemMenuItems(for item: SidebarItem, in section: SidebarSection) -> [NSMenuItem] {
        if case .clearTagFilter = item.kind { return [] }
        let title = displayedTitle(of: item)
        let payload = SidebarLayoutMenuPayload(sectionID: section.layoutID, itemID: item.id, title: title)
        var entries: [NSMenuItem] = []

        if case .kindFilter(let filter) = item.kind {
            for scope in SidebarKindFilter.Scope.allCases {
                let scopePayload = SidebarLayoutMenuPayload(sectionID: section.layoutID, itemID: filter.id, title: title, value: scope.rawValue)
                let entry = layoutMenuItem(String(localized: "Search \(scope.title)"), #selector(setKindScopeFromMenu(_:)), scopePayload)
                entry.state = filter.scope == scope ? .on : .off
                entries.append(entry)
            }
            entries.append(layoutMenuItem("Edit Kind Filter…", #selector(editKindFilterFromMenu(_:)),
                                          SidebarLayoutMenuPayload(sectionID: section.layoutID, itemID: filter.id, title: title)))
            entries.append(.separator())
        }

        if case .smartFolder(let folder) = item.kind {
            entries += smartFolderMenuItems(for: folder)
            entries.append(.separator())
        } else {
            entries.append(layoutMenuItem("Rename…", #selector(renameItemFromMenu(_:)), payload))
        }
        entries.append(layoutMenuItem("Change Icon…", #selector(changeIconFromMenu(_:)), payload))
        if appSettings.sidebarLayout.items[item.id]?.hasAppearanceChanges == true {
            entries.append(layoutMenuItem("Reset Name and Icon", #selector(resetItemFromMenu(_:)), payload))
        }

        let movable = movableItemIDs(in: section)
        if let index = movable.firstIndex(of: item.id) {
            entries.append(.separator())
            let up = layoutMenuItem("Move Up", #selector(moveItemUpFromMenu(_:)), payload)
            up.isEnabled = index > 0
            let down = layoutMenuItem("Move Down", #selector(moveItemDownFromMenu(_:)), payload)
            down.isEnabled = index < movable.count - 1
            entries += [up, down]
        }

        switch item.kind {
        case .favorite, .smartFolder:
            break // "Remove from Favorites" / "Move to Trash" is already in the menu.
        case .groupFolder:
            entries.append(.separator())
            entries.append(layoutMenuItem("Remove from Group", #selector(removeGroupFolderFromMenu(_:)), payload))
        case .kindFilter(let filter) where !filter.isBuiltin:
            entries.append(.separator())
            entries.append(layoutMenuItem("Delete Kind Filter", #selector(deleteKindFilterFromMenu(_:)),
                                          SidebarLayoutMenuPayload(sectionID: section.layoutID, itemID: filter.id, title: title)))
        default:
            entries.append(.separator())
            entries.append(layoutMenuItem(String(localized: "Hide “\(title)”"), #selector(hideItemFromMenu(_:)), payload))
        }
        return entries
    }

    private func hasHiddenSidebarContent() -> Bool {
        let layout = appSettings.sidebarLayout
        return layout.items.values.contains { $0.isHidden }
            || layout.sections.contains { appSettings.isSidebarSectionHidden($0.id) }
    }

    // MARK: Menu actions

    @objc func newGroupFromMenu(_ sender: NSMenuItem) {
        promptForText(title: String(localized: "New Group"), message: String(localized: "Name of the new sidebar group:"),
                      initial: String(localized: "New Group")) { [weak self] name in
            guard let self, let name else { return }
            let id = self.appSettings.addSidebarGroup(named: name)
            self.chooseFolders(forGroup: id)
        }
    }

    @objc func newKindFilterFromMenu(_ sender: NSMenuItem) {
        presentKindFilterEditor(nil)
    }

    @objc func editKindFilterFromMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? SidebarLayoutMenuPayload,
              let filter = appSettings.sidebarLayout.kindFilters.first(where: { $0.id == payload.itemID }) else { return }
        presentKindFilterEditor(filter)
    }

    @objc func showHiddenItemsFromMenu(_ sender: NSMenuItem) {
        guard let window = outlineView?.window else { return }
        let settings = appSettings
        SidebarSheet.present(on: window) { dismiss in
            SidebarHiddenItemsView(settings: settings, onDone: dismiss)
        }
    }

    @objc func renameSectionFromMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? SidebarLayoutMenuPayload else { return }
        promptForText(title: String(localized: "Rename Section"), message: String(localized: "Leave empty to use the default name."),
                      initial: payload.title, allowsEmpty: true) { [weak self] name in
            guard let self, let name else { return }
            self.appSettings.sidebarLayout.updateSection(payload.sectionID) { section in
                if !name.isEmpty {
                    section.title = name
                } else if section.type != .group {
                    section.title = nil
                }
            }
        }
    }

    @objc func hideSectionFromMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? SidebarLayoutMenuPayload else { return }
        appSettings.setSidebarSectionHidden(payload.sectionID, true)
    }

    @objc func moveSectionUpFromMenu(_ sender: NSMenuItem) {
        moveSection(sender, offset: -1)
    }

    @objc func moveSectionDownFromMenu(_ sender: NSMenuItem) {
        moveSection(sender, offset: 1)
    }

    private func moveSection(_ sender: NSMenuItem, offset: Int) {
        guard let payload = sender.representedObject as? SidebarLayoutMenuPayload,
              let index = sections.firstIndex(where: { $0.layoutID == payload.sectionID }) else { return }
        let ids = sections.map(\.layoutID)
        if offset < 0 {
            guard index > 0 else { return }
            appSettings.moveSidebarSection(payload.sectionID, before: ids[index - 1])
        } else {
            guard index < ids.count - 1 else { return }
            appSettings.moveSidebarSection(payload.sectionID, before: index + 2 < ids.count ? ids[index + 2] : nil)
        }
    }

    @objc func addFolderToGroupFromMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? SidebarLayoutMenuPayload else { return }
        chooseFolders(forGroup: payload.sectionID)
    }

    @objc func deleteGroupFromMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? SidebarLayoutMenuPayload else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete the group “\(payload.title)”?")
        alert.informativeText = String(localized: "The folders themselves are not affected.")
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.appSettings.removeSidebarGroup(payload.sectionID)
        }
        if let window = outlineView?.window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    @objc func renameItemFromMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? SidebarLayoutMenuPayload, let itemID = payload.itemID else { return }
        promptForText(title: String(localized: "Rename “\(payload.title)”"),
                      message: String(localized: "Shown in the sidebar only; the folder itself keeps its name. Leave empty for the original name."),
                      initial: payload.title, allowsEmpty: true) { [weak self] name in
            guard let self, let name else { return }
            self.appSettings.sidebarLayout.updateItem(itemID) { $0.alias = name.isEmpty ? nil : name }
        }
    }

    @objc func changeIconFromMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? SidebarLayoutMenuPayload, let itemID = payload.itemID,
              let window = outlineView?.window else { return }
        let settings = appSettings
        let current = settings.sidebarLayout.items[itemID]
        SidebarSheet.present(on: window) { dismiss in
            SidebarIconEditorView(
                itemTitle: payload.title,
                symbol: current?.symbol ?? "",
                color: current?.color,
                onSave: { symbol, color in
                    settings.sidebarLayout.updateItem(itemID) {
                        $0.symbol = symbol
                        $0.color = color
                    }
                    dismiss()
                },
                onCancel: dismiss
            )
        }
    }

    @objc func resetItemFromMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? SidebarLayoutMenuPayload, let itemID = payload.itemID else { return }
        appSettings.sidebarLayout.updateItem(itemID) {
            $0.alias = nil
            $0.symbol = nil
            $0.color = nil
        }
    }

    @objc func moveItemUpFromMenu(_ sender: NSMenuItem) {
        moveItem(sender, offset: -1)
    }

    @objc func moveItemDownFromMenu(_ sender: NSMenuItem) {
        moveItem(sender, offset: 1)
    }

    private func moveItem(_ sender: NSMenuItem, offset: Int) {
        guard let payload = sender.representedObject as? SidebarLayoutMenuPayload, let itemID = payload.itemID,
              let section = sections.first(where: { $0.layoutID == payload.sectionID }) else { return }
        let ids = movableItemIDs(in: section)
        guard let index = ids.firstIndex(of: itemID) else { return }
        if offset < 0 {
            guard index > 0 else { return }
            moveLayoutItem(itemID, in: section, before: ids[index - 1])
        } else {
            guard index < ids.count - 1 else { return }
            moveLayoutItem(itemID, in: section, before: index + 2 < ids.count ? ids[index + 2] : nil)
        }
    }

    @objc func hideItemFromMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? SidebarLayoutMenuPayload, let itemID = payload.itemID else { return }
        appSettings.setSidebarItemHidden(itemID, title: payload.title, hidden: true)
    }

    @objc func removeGroupFolderFromMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? SidebarLayoutMenuPayload, let itemID = payload.itemID else { return }
        appSettings.removeFolder(itemID, fromSidebarGroup: payload.sectionID)
    }

    @objc func deleteKindFilterFromMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? SidebarLayoutMenuPayload, let id = payload.itemID else { return }
        if activeKindFilter()?.id == id {
            viewModel.clearSearchQuery()
        }
        appSettings.removeSidebarKindFilter(id)
    }

    @objc func setKindScopeFromMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? SidebarLayoutMenuPayload,
              let scope = payload.value.flatMap(SidebarKindFilter.Scope.init(rawValue:)),
              var filter = appSettings.sidebarLayout.kindFilters.first(where: { $0.id == payload.itemID }) else { return }
        filter.scope = scope
        appSettings.upsertSidebarKindFilter(filter)
        startKindSearch(filter)
    }

    // MARK: Editing helpers

    /// Ids of the section's items that can be reordered, in their shown order.
    private func movableItemIDs(in section: SidebarSection) -> [String] {
        section.items.compactMap { item in
            switch item.kind {
            case .clearTagFilter: return nil
            case .airDrop, .photosLibrary: return section.kind == .favorites ? nil : item.id
            default: return item.id
            }
        }
    }

    /// Moves `itemID` before `beforeID` (nil: to the end) among the section's items.
    func moveLayoutItem(_ itemID: String, in section: SidebarSection, before beforeID: String?) {
        guard itemID != beforeID else { return }
        func reordered(_ ids: [String]) -> [String] {
            var ids = ids.filter { $0 != itemID }
            if let beforeID, let index = ids.firstIndex(of: beforeID) {
                ids.insert(itemID, at: index)
            } else {
                ids.append(itemID)
            }
            return ids
        }

        switch section.kind {
        case .favorites:
            var favorites = appSettings.sidebarFavorites
            guard let moving = favorites.first(where: { $0.id == itemID }) else { return }
            favorites.removeAll { $0.id == itemID }
            if let beforeID, let index = favorites.firstIndex(where: { $0.id == beforeID }) {
                favorites.insert(moving, at: index)
            } else {
                favorites.append(moving)
            }
            appSettings.sidebarFavorites = favorites
        case .kinds:
            let filters = appSettings.sidebarLayout.kindFilters
            let order = reordered(filters.map(\.itemID))
            appSettings.sidebarLayout.kindFilters = order.compactMap { id in filters.first { $0.itemID == id } }
        case .group:
            appSettings.sidebarLayout.updateSection(section.layoutID) { entry in
                let order = reordered(entry.folders.map(\.id))
                entry.folders = order.compactMap { id in entry.folders.first { $0.id == id } }
            }
        default:
            let shown = movableItemIDs(in: section)
            let order = reordered(shown)
            appSettings.sidebarLayout.updateSection(section.layoutID) { entry in
                entry.itemOrder = order + entry.itemOrder.filter { !order.contains($0) }
            }
        }
    }

    private func chooseFolders(forGroup id: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add")
        panel.message = String(localized: "Choose folders to add to the group.")
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let self else { return }
            self.appSettings.addFolders(panel.urls, toSidebarGroup: id)
        }
        if let window = outlineView?.window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    private func presentKindFilterEditor(_ filter: SidebarKindFilter?) {
        guard let window = outlineView?.window else { return }
        let settings = appSettings
        SidebarSheet.present(on: window) { dismiss in
            SidebarKindFilterEditorView(filter: filter, onSave: { edited in
                settings.upsertSidebarKindFilter(edited)
                settings.setSidebarSectionHidden(SidebarLayout.kindsSectionID, false)
                dismiss()
            }, onCancel: dismiss)
        }
    }

    private func promptForText(title: String, message: String, initial: String, allowsEmpty: Bool = false,
                               completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return completion(nil) }
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(text.isEmpty && !allowsEmpty ? nil : text)
        }
        if let window = outlineView?.window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    // MARK: - Drag and drop

    private enum LayoutDragPayload {
        case section(String)
        case item(sectionID: String, itemID: String)

        var string: String {
            switch self {
            case .section(let id): return "section\t\(id)"
            case .item(let sectionID, let itemID): return "item\t\(sectionID)\t\(itemID)"
            }
        }

        init?(_ string: String?) {
            let parts = string?.components(separatedBy: "\t") ?? []
            if parts.count == 2, parts[0] == "section" {
                self = .section(parts[1])
            } else if parts.count == 3, parts[0] == "item" {
                self = .item(sectionID: parts[1], itemID: parts[2])
            } else {
                return nil
            }
        }
    }

    private enum LayoutDropTarget {
        case section(index: Int)
        case item(SidebarSection, index: Int)
        case intoGroupFolder(SidebarItem, URL)
        case addToGroup(SidebarSection, index: Int)
    }

    /// Section headers and the items of every section but Favorites (which keeps its own drag) are draggable.
    func layoutPasteboardWriter(for item: Any) -> NSPasteboardWriting? {
        let payload: LayoutDragPayload
        if let section = item as? SidebarSection {
            payload = .section(section.layoutID)
        } else if let sidebarItem = item as? SidebarItem,
                  let section = outlineView?.parent(forItem: sidebarItem) as? SidebarSection,
                  section.kind != .favorites,
                  movableItemIDs(in: section).contains(sidebarItem.id) {
            payload = .item(sectionID: section.layoutID, itemID: sidebarItem.id)
        } else {
            return nil
        }
        let pbItem = NSPasteboardItem()
        pbItem.setString(payload.string, forType: SidebarOutlineView.layoutDragType)
        return pbItem
    }

    /// Handles drags this file adds (reordering, folders into groups); nil leaves the drag to the favorites code.
    func validateLayoutDrop(_ info: NSDraggingInfo) -> NSDragOperation? {
        guard let outlineView else { return nil }
        guard let target = layoutDropTarget(info) else { return nil }
        switch target {
        case .none:
            return []
        case .some(.section(let index)):
            outlineView.setDropItem(nil, dropChildIndex: index)
            return .move
        case .some(.item(let section, let index)):
            outlineView.setDropItem(section, dropChildIndex: index)
            return .move
        case .some(.intoGroupFolder(let item, _)):
            outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return NSEvent.modifierFlags.contains(.option) ? .copy : .move
        case .some(.addToGroup(let section, let index)):
            outlineView.setDropItem(section, dropChildIndex: index)
            return .copy
        }
    }

    func acceptLayoutDrop(_ info: NSDraggingInfo) -> Bool? {
        guard let target = layoutDropTarget(info) else { return nil }
        switch target {
        case .none:
            return false
        case .some(.section(let index)):
            guard case let .section(id)? = LayoutDragPayload(info.draggingPasteboard.string(forType: SidebarOutlineView.layoutDragType)) else { return false }
            appSettings.moveSidebarSection(id, before: index < sections.count ? sections[index].layoutID : nil)
            return true
        case .some(.item(let section, let index)):
            guard case let .item(_, itemID)? = LayoutDragPayload(info.draggingPasteboard.string(forType: SidebarOutlineView.layoutDragType)) else { return false }
            let before = index < section.items.count ? section.items[index].id : nil
            moveLayoutItem(itemID, in: section, before: before == "tag:clear" ? nil : before)
            return true
        case .some(.intoGroupFolder(_, let destination)):
            let urls = draggedFileURLs(info).urls
            guard !urls.isEmpty else { return false }
            viewModel.handleDrop(urls: urls, to: destination, operation: FileDropOperation(modifierFlags: NSEvent.modifierFlags))
            return true
        case .some(.addToGroup(let section, let index)):
            return appSettings.addFolders(draggedFileURLs(info).urls, toSidebarGroup: section.layoutID, at: index) > 0
        }
    }

    /// nil: not ours; .some(nil): ours but rejected.
    private func layoutDropTarget(_ info: NSDraggingInfo) -> LayoutDropTarget?? {
        guard let outlineView else { return nil }
        let pasteboard = info.draggingPasteboard
        let point = outlineView.convert(info.draggingLocation, from: nil)

        if let payload = LayoutDragPayload(pasteboard.string(forType: SidebarOutlineView.layoutDragType)) {
            switch payload {
            case .section:
                return .some(.section(index: sectionInsertionIndex(at: point)))
            case .item(let sectionID, _):
                guard let section = section(at: point), section.layoutID == sectionID,
                      let index = itemInsertionIndex(in: section, at: point) else { return .some(nil) }
                return .some(.item(section, index: index))
            }
        }
        if pasteboard.types?.contains(SidebarOutlineView.favoriteDragType) == true { return nil }

        guard let section = section(at: point) else { return nil }
        if section.kind == .group {
            let dragged = draggedFileURLs(info)
            guard !dragged.urls.isEmpty else { return .some(nil) }
            let row = outlineView.row(at: point)
            if let item = outlineView.item(atRow: row) as? SidebarItem, let index = section.items.firstIndex(of: item) {
                let rect = outlineView.rect(ofRow: row)
                let fraction = (point.y - rect.minY) / max(rect.height, 1)
                let isFolders = dragged.hasFolder && dragged.urls.count == 1
                switch FavoriteRowDropZone.zone(fraction: fraction, isDraggingFolders: isFolders) {
                case .into:
                    if case let .groupFolder(resolution, _) = item.kind, resolution.isAvailable, let url = resolution.url {
                        return .some(.intoGroupFolder(item, url))
                    }
                    return dragged.hasFolder ? .some(.addToGroup(section, index: index + 1)) : .some(nil)
                case .before:
                    return dragged.hasFolder ? .some(.addToGroup(section, index: index)) : .some(nil)
                case .after:
                    return dragged.hasFolder ? .some(.addToGroup(section, index: index + 1)) : .some(nil)
                }
            }
            return dragged.hasFolder ? .some(.addToGroup(section, index: section.items.count)) : .some(nil)
        }
        // The favorites code treats everything above the Favorites header as "insert at the start".
        if let favoritesIndex = sections.firstIndex(where: { $0.kind == .favorites }),
           let index = sections.firstIndex(of: section), index < favoritesIndex {
            return .some(nil)
        }
        return nil
    }

    private func draggedFileURLs(_ info: NSDraggingInfo) -> (urls: [URL], hasFolder: Bool) {
        if let cached = Self.draggedFolderCache, cached.sequence == info.draggingSequenceNumber {
            return (cached.urls, cached.hasFolder)
        }
        let urls = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let hasFolder = urls.contains {
            let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return values?.isDirectory == true && values?.isPackage != true
        }
        Self.draggedFolderCache = (info.draggingSequenceNumber, urls, hasFolder)
        return (urls, hasFolder)
    }

    private func section(at point: NSPoint) -> SidebarSection? {
        guard let outlineView else { return nil }
        let row = outlineView.row(at: point)
        guard row >= 0 else { return nil }
        let item = outlineView.item(atRow: row)
        if let section = item as? SidebarSection { return section }
        return outlineView.parent(forItem: item) as? SidebarSection
    }

    private func sectionInsertionIndex(at point: NSPoint) -> Int {
        guard let outlineView, let section = section(at: point), let index = sections.firstIndex(of: section) else {
            return point.y <= 0 ? 0 : sections.count
        }
        var span = outlineView.rect(ofRow: outlineView.row(forItem: section))
        if outlineView.isItemExpanded(section), let last = section.items.last {
            let lastRow = outlineView.row(forItem: last)
            if lastRow >= 0 { span = span.union(outlineView.rect(ofRow: lastRow)) }
        }
        return point.y < span.midY ? index : index + 1
    }

    private func itemInsertionIndex(in section: SidebarSection, at point: NSPoint) -> Int? {
        guard let outlineView else { return nil }
        let maxIndex = section.items.last?.id == "tag:clear" ? section.items.count - 1 : section.items.count
        let row = outlineView.row(at: point)
        let item = outlineView.item(atRow: row)
        if item is SidebarSection { return 0 }
        guard let sidebarItem = item as? SidebarItem, let index = section.items.firstIndex(of: sidebarItem) else { return nil }
        let rect = outlineView.rect(ofRow: row)
        let proposed = point.y < rect.midY ? index : index + 1
        return min(proposed, maxIndex)
    }
}

// MARK: - Row appearance

/// Sizes of the sidebar rows, like Finder on macOS 26: larger outline icons and text, roomier rows.
enum SidebarRowMetrics {
    static let rowHeight: CGFloat = 28
    static let iconBox: CGFloat = 22
    static let iconPointSize: CGFloat = 16
    static let fontSize: CGFloat = 14

    static func configureTitle(_ field: NSTextField) {
        field.font = .systemFont(ofSize: fontSize)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.cell?.truncatesLastVisibleLine = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    static func configureIcon(_ view: NSImageView) {
        view.imageScaling = .scaleProportionallyDown
        view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: iconPointSize, weight: .regular)
    }
}

/// The SF Symbols the sidebar shows: favorites in the accent colour, places and cloud storage in grey.
enum SidebarSymbols {
    static let favoriteTint: NSColor = .controlAccentColor
    static let placeTint: NSColor = .secondaryLabelColor
    static let airDrop = "dot.radiowaves.left.and.right"
    static let photosLibrary = "photo.on.rectangle"

    static func image(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    static func favorite(_ kind: SidebarFavorite.Kind, url: URL?) -> String {
        switch kind {
        case .documents: return "doc"
        case .applications: return "a.square"
        case .desktop: return "menubar.dock.rectangle"
        case .downloads: return "arrow.down.circle"
        case .movies: return "film"
        case .music: return "music.note"
        case .pictures: return "photo"
        case .custom: return folder(url: url)
        }
    }

    /// A folder added by the user: the well-known folders keep their own symbol.
    static func folder(url: URL?) -> String {
        guard let path = url?.standardizedFileURL.path else { return "folder" }
        let fm = FileManager.default
        if path == fm.homeDirectoryForCurrentUser.standardizedFileURL.path { return "house" }
        let known: [(FileManager.SearchPathDirectory, FileManager.SearchPathDomainMask, SidebarFavorite.Kind)] = [
            (.documentDirectory, .userDomainMask, .documents),
            (.applicationDirectory, .localDomainMask, .applications),
            (.applicationDirectory, .userDomainMask, .applications),
            (.desktopDirectory, .userDomainMask, .desktop),
            (.downloadsDirectory, .userDomainMask, .downloads),
            (.moviesDirectory, .userDomainMask, .movies),
            (.musicDirectory, .userDomainMask, .music),
            (.picturesDirectory, .userDomainMask, .pictures)
        ]
        for (directory, domain, kind) in known
        where fm.urls(for: directory, in: domain).first?.standardizedFileURL.path == path {
            return favorite(kind, url: nil)
        }
        if path.hasPrefix(SidebarCloudLocation.storageURL.path + "/"),
           path.components(separatedBy: "/").count == SidebarCloudLocation.storageURL.pathComponents.count + 1 {
            return "cloud"
        }
        if path.hasSuffix("/Mobile Documents/com~apple~CloudDocs") { return "icloud" }
        if path.hasSuffix(".photoslibrary") { return photosLibrary }
        return "folder"
    }

    static func location(_ location: SidebarLocation) -> String {
        if location.url.path == "/Network" { return "network" }
        if location.url.path == "/" { return "internaldrive" }
        if location.isNetwork { return "externaldrive.connected.to.line.below" }
        return location.isEjectable ? "externaldrive" : "internaldrive"
    }
}
