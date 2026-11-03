import SwiftUI
import AppKit

// MARK: - Copy Path

enum PathCopyStyle: CaseIterable {
    case path, name, tildePath, fileURL

    var title: String {
        switch self {
        case .path: String(localized: "Path")
        case .name: String(localized: "Name")
        case .tildePath: String(localized: "Path with ~")
        case .fileURL: String(localized: "File URL")
        }
    }

    func string(for url: URL) -> String {
        switch self {
        case .path: url.path
        case .name: url.lastPathComponent
        case .tildePath: (url.path as NSString).abbreviatingWithTildeInPath
        case .fileURL: url.absoluteString
        }
    }
}

@MainActor
enum PathCopy {
    static func copy(_ urls: [URL], style: PathCopyStyle) {
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urls.map(style.string(for:)).joined(separator: "\n"), forType: .string)
    }
}

// MARK: - Terminal

@MainActor
enum TerminalLauncher {
    struct App: Identifiable, Hashable {
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }

    static let defaultBundleID = "com.apple.Terminal"

    private static let candidates: [App] = [
        App(bundleID: "com.apple.Terminal", name: "Terminal"),
        App(bundleID: "com.googlecode.iterm2", name: "iTerm2"),
        App(bundleID: "com.mitchellh.ghostty", name: "Ghostty"),
        App(bundleID: "dev.warp.Warp-Stable", name: "Warp"),
        App(bundleID: "com.github.wez.wezterm", name: "WezTerm"),
        App(bundleID: "net.kovidgoyal.kitty", name: "kitty"),
        App(bundleID: "org.alacritty", name: "Alacritty")
    ]

    static var installedApps: [App] {
        candidates.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }

    /// A folder opens itself; a file (or package) opens the folder it is in.
    static func folder(for items: [FileItem]) -> URL? {
        guard let item = items.first, !item.isFromArchive, item.url.isFileURL else { return nil }
        return item.isDirectory && !item.isPackage ? item.url : item.url.deletingLastPathComponent()
    }

    static func open(_ folder: URL?) {
        guard let folder, folder.isFileURL else {
            NSSound.beep()
            return
        }
        let workspace = NSWorkspace.shared
        guard let appURL = workspace.urlForApplication(withBundleIdentifier: AppSettings.shared.terminalAppBundleID)
                ?? workspace.urlForApplication(withBundleIdentifier: defaultBundleID) else {
            NSSound.beep()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.open([folder], withApplicationAt: appURL, configuration: configuration) { _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                NSAlert(error: error).runModal()
            }
        }
    }
}

// MARK: - New File

struct NewFileTemplate: Hashable {
    let title: String
    let fileName: String
    /// Copied to make the new file; nil makes an empty file.
    let source: URL?

    static let text = NewFileTemplate(title: String(localized: "Text File"), fileName: "untitled.txt", source: nil)
    static let markdown = NewFileTemplate(title: String(localized: "Markdown File"), fileName: "untitled.md", source: nil)
    static let word = bundled(String(localized: "Word Document (.docx)"), "docx")
    static let excel = bundled(String(localized: "Excel Workbook (.xlsx)"), "xlsx")
    static let powerPoint = bundled(String(localized: "PowerPoint Presentation (.pptx)"), "pptx")

    static var builtIn: [NewFileTemplate] { [text, markdown, word, excel, powerPoint] }

    private static func bundled(_ title: String, _ ext: String) -> NewFileTemplate {
        NewFileTemplate(title: title, fileName: "untitled.\(ext)", source: Bundle.main.url(forResource: "blank", withExtension: ext))
    }
}

@MainActor
enum NewFileCreator {
    static var templatesFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FlowFinder/Templates", isDirectory: true)
    }

    private static var cachedTemplates: (date: Date, templates: [NewFileTemplate])?

    /// The files in the Templates folder (created if missing).
    static func userTemplates() -> [NewFileTemplate] {
        if let cached = cachedTemplates, -cached.date.timeIntervalSinceNow < 2 { return cached.templates }
        let folder = templatesFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let templates = urls
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { NewFileTemplate(title: $0.lastPathComponent, fileName: $0.lastPathComponent, source: $0) }
        cachedTemplates = (Date(), templates)
        return templates
    }

    static func canCreate(in directory: URL, viewModel: FileBrowserViewModel) -> Bool {
        guard !viewModel.isInsideArchive, directory.isFileURL else { return false }
        let isShown = directory.standardizedFileURL.path == viewModel.currentPath.standardizedFileURL.path
        return !isShown || viewModel.canAddItemsToCurrentLocation
    }

    /// Creates the file next to the others (with Undo), selects it and starts renaming it, like New Folder.
    static func create(_ template: NewFileTemplate, in directory: URL, viewModel: FileBrowserViewModel) {
        guard canCreate(in: directory, viewModel: viewModel) else {
            NSSound.beep()
            return
        }
        viewModel.createNewFolder(in: directory, name: template.fileName, actionName: String(localized: "New File")) { url in
            if let source = template.source {
                try FileManager.default.copyItem(at: source, to: url)
            } else {
                try Data().write(to: url, options: .withoutOverwriting)
            }
        }
    }

    /// Asks for a name and an extension in a sheet, then creates the empty file.
    static func createWithExtension(in directory: URL, viewModel: FileBrowserViewModel) {
        guard canCreate(in: directory, viewModel: viewModel) else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "New File")
        alert.informativeText = String(localized: "Enter a name and an extension.")
        alert.addButton(withTitle: String(localized: "Create"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let nameField = NSTextField(string: String(localized: "untitled"))
        let extensionField = NSTextField(string: "")
        extensionField.placeholderString = "txt"
        let nameLabel = NSTextField(labelWithString: String(localized: "Name:"))
        let extensionLabel = NSTextField(labelWithString: String(localized: "Extension:"))
        let grid = NSGridView(views: [[nameLabel, nameField], [extensionLabel, extensionField]])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 220
        grid.frame = NSRect(x: 0, y: 0, width: 300, height: 56)
        alert.accessoryView = grid
        alert.window.initialFirstResponder = nameField

        let finish: (NSApplication.ModalResponse) -> Void = { [weak viewModel] response in
            guard response == .alertFirstButtonReturn, let viewModel else { return }
            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let ext = extensionField.stringValue.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
            guard !name.isEmpty, !name.contains("/"), !ext.contains("/") else {
                NSSound.beep()
                return
            }
            let fileName = ext.isEmpty ? name : "\(name).\(ext)"
            create(NewFileTemplate(title: fileName, fileName: fileName, source: nil), in: directory, viewModel: viewModel)
        }
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    static func openTemplatesFolder() {
        try? FileManager.default.createDirectory(at: templatesFolder, withIntermediateDirectories: true)
        cachedTemplates = nil
        NSWorkspace.shared.open(templatesFolder)
    }
}

// MARK: - Menu entries

/// One definition of the extra context-menu items, rendered as SwiftUI or AppKit menu items.
enum CustomMenuEntry {
    case action(String, enabled: Bool, perform: () -> Void)
    case submenu(String, enabled: Bool, [CustomMenuEntry])
    case iconAction(String, image: NSImage, perform: () -> Void)
    case separator
}

@MainActor
enum CustomActions {
    /// Items for a menu on items. `targets` resolves the items the command acts on when it runs.
    static func itemEntries(viewModel: FileBrowserViewModel, canUse: Bool, targets: @escaping () -> [FileItem]) -> [CustomMenuEntry] {
        var entries: [CustomMenuEntry] = [
            .separator,
            .action(String(localized: "Open in Terminal"), enabled: canUse) {
                TerminalLauncher.open(TerminalLauncher.folder(for: targets()))
            },
            copyPathSubmenu(enabled: canUse) { targets().map(\.url) },
            DropStackActions.addEntry(enabled: canUse, targets: targets)
        ]
        if canUse, let convert = FileConversion.menuEntry(viewModel: viewModel, targets: targets) {
            entries.insert(convert, at: 1)
        }
        let selected = targets()
        if canUse, BatchRename.canRename(selected) {
            entries.insert(.action(String(localized: "Rename Items…"), enabled: true) { [weak viewModel] in
                guard let viewModel else { return }
                BatchRename.present(items: targets(), viewModel: viewModel)
            }, at: 1)
        }
        if canUse, FolderAppearance.canChange(selected) {
            entries.insert(contentsOf: FolderAppearance.menuEntries(viewModel: viewModel, targets: targets), at: 1)
        }
        if canUse, selected.count == 1, let folder = selected.first, folder.isDirectory, !folder.isPackage {
            entries.insert(contentsOf: [
                .separator,
                .action(String(localized: "Open in New Tab"), enabled: true) { [weak viewModel] in
                    guard let viewModel else { return }
                    FolderOpenRequest.post(.openFolderInNewTab, folder: folder.url, from: viewModel)
                },
                .action(String(localized: "Open in Split View"), enabled: true) { [weak viewModel] in
                    guard let viewModel else { return }
                    FolderOpenRequest.post(.openFolderInSplit, folder: folder.url, from: viewModel)
                }
            ], at: 0)
        }
        if canUse, selected.count == 2, selected.allSatisfy({ $0.isDirectory && !$0.isPackage }) {
            entries.append(.action(String(localized: "Compare Folders"), enabled: true) { [weak viewModel] in
                FolderCompareWindowController.show(left: selected[0].url, right: selected[1].url, viewModel: viewModel, panes: viewModel.map { [$0] } ?? [])
            })
        }
        if canUse, let other = SwipeNavigator.shared.otherPane(of: viewModel) {
            entries.append(.separator)
            for (title, operation) in [(String(localized: "Copy to Other Pane"), FileDropOperation.copy),
                                       (String(localized: "Move to Other Pane"), FileDropOperation.move)] {
                entries.append(.action(title, enabled: true) { [weak viewModel, weak other] in
                    guard let viewModel, let other else { return }
                    let items = targets()
                    if !items.allSatisfy(viewModel.selectedItems.contains) {
                        viewModel.selectedItems = Set(items)
                    }
                    SplitPaneTransfer.transfer(from: viewModel, to: other, operation: operation)
                })
            }
        }
        entries.append(.separator)
        entries.append(FileSharing.menuEntry(enabled: canUse, targets: targets))
        entries.append(QuickActions.menuEntry(viewModel: viewModel, enabled: canUse, targets: targets))
        return entries
    }

    /// Items for a menu on the background of `folder`.
    static func backgroundEntries(viewModel: FileBrowserViewModel, folder: URL) -> [CustomMenuEntry] {
        let canUse = !viewModel.isInsideArchive && folder.isFileURL
        return [
            .separator,
            newFileSubmenu(viewModel: viewModel, folder: folder),
            .action(String(localized: "Open in Terminal"), enabled: canUse) {
                TerminalLauncher.open(folder)
            },
            copyPathSubmenu(enabled: canUse) { [folder] }
        ]
    }

    private static func copyPathSubmenu(enabled: Bool, urls: @escaping () -> [URL]) -> CustomMenuEntry {
        .submenu(String(localized: "Copy Path"), enabled: enabled, PathCopyStyle.allCases.map { style in
            .action(style.title, enabled: true) { PathCopy.copy(urls(), style: style) }
        })
    }

    private static func newFileSubmenu(viewModel: FileBrowserViewModel, folder: URL) -> CustomMenuEntry {
        let make: (NewFileTemplate) -> CustomMenuEntry = { template in
            .action(template.title, enabled: true) {
                NewFileCreator.create(template, in: folder, viewModel: viewModel)
            }
        }
        var children = NewFileTemplate.builtIn.map(make)
        children.append(.action(String(localized: "Other…"), enabled: true) {
            NewFileCreator.createWithExtension(in: folder, viewModel: viewModel)
        })
        let templates = NewFileCreator.userTemplates()
        if !templates.isEmpty {
            children.append(.separator)
            children += templates.map(make)
        }
        children.append(.separator)
        children.append(.action(String(localized: "Open Templates Folder"), enabled: true) {
            NewFileCreator.openTemplatesFolder()
        })
        return .submenu(String(localized: "New File"), enabled: NewFileCreator.canCreate(in: folder, viewModel: viewModel), children)
    }

    /// The selection in display order (Column view's sub-column selections aren't in the list).
    static func orderedSelection(of viewModel: FileBrowserViewModel) -> [FileItem] {
        let selection = viewModel.selectedItems
        let ordered = viewModel.filteredItems.filter { selection.contains($0) }
        if ordered.count == selection.count { return ordered }
        return selection.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }

    // MARK: AppKit

    static func append(_ entries: [CustomMenuEntry], to menu: NSMenu) {
        for entry in entries {
            switch entry {
            case .separator:
                if let last = menu.items.last, !last.isSeparatorItem { menu.addItem(.separator()) }
            case let .action(title, enabled, perform):
                menu.addItem(CustomActionMenuItem(title: title, enabled: enabled, handler: perform))
            case let .iconAction(title, image, perform):
                let item = CustomActionMenuItem(title: title, enabled: true, handler: perform)
                item.image = image
                menu.addItem(item)
            case let .submenu(title, enabled, children):
                let item = CustomActionMenuItem(title: title, enabled: enabled, handler: nil)
                let submenu = NSMenu(title: title)
                append(children, to: submenu)
                item.submenu = submenu
                menu.addItem(item)
            }
        }
    }
}

final class CustomActionMenuItem: NSMenuItem, NSMenuItemValidation {
    private var handler: (() -> Void)?
    private var isActionEnabled = true

    convenience init(title: String, enabled: Bool, handler: (() -> Void)?) {
        self.init(title: title, action: handler == nil ? nil : #selector(fire(_:)), keyEquivalent: "")
        self.handler = handler
        self.isActionEnabled = enabled
        self.isEnabled = enabled
        if handler != nil { target = self }
    }

    @objc private func fire(_ sender: Any?) {
        handler?()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        isActionEnabled
    }
}

// MARK: - SwiftUI

struct CustomMenuItems: View {
    let entries: [CustomMenuEntry]

    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            switch entry {
            case let .action(title, enabled, perform):
                Button(title, action: perform).disabled(!enabled)
            case let .iconAction(title, image, perform):
                Button(action: perform) {
                    Label { Text(verbatim: title) } icon: { Image(nsImage: image) }
                }
            case let .submenu(title, enabled, children):
                Menu(title) { CustomMenuItems(entries: children) }.disabled(!enabled)
            case .separator:
                Divider()
            }
        }
    }
}

/// The extra items of an item's context menu.
struct CustomItemMenu: View {
    let item: FileItem
    let viewModel: FileBrowserViewModel

    var body: some View {
        let viewModel = viewModel
        let item = item
        CustomMenuItems(entries: CustomActions.itemEntries(
            viewModel: viewModel,
            canUse: !item.isFromArchive && item.url.isFileURL
        ) {
            viewModel.selectedItems.contains(item) ? CustomActions.orderedSelection(of: viewModel) : [item]
        })
    }
}

/// The extra items of a folder background's context menu.
struct CustomBackgroundMenu: View {
    let viewModel: FileBrowserViewModel
    var folder: URL?

    var body: some View {
        let folder = folder ?? viewModel.currentPath
        CustomMenuItems(entries: CustomActions.backgroundEntries(viewModel: viewModel, folder: folder))
        if viewModel.viewMode == .icons, FolderLayoutStore.shared.showsGrid(folder), FolderLayoutStore.shared.layout(for: folder) != nil {
            Button("Show Window Layout") { FolderLayoutStore.shared.setShowsGrid(false, for: folder) }
        }
    }
}

// MARK: - New item menu

struct NewFileMenuItems: View {
    let viewModel: FileBrowserViewModel?
    var withShortcut = false

    var body: some View {
        if withShortcut {
            Button("New Text File") { create(.text) }
                .keyboardShortcut("n", modifiers: [.command, .option])
        } else {
            Button("New Text File") { create(.text) }
        }
        ForEach(NewFileTemplate.builtIn.dropFirst(), id: \.self) { template in
            Button(template.title) { create(template) }
        }
        Button("Other…") {
            guard let viewModel else { return }
            NewFileCreator.createWithExtension(in: viewModel.currentPath, viewModel: viewModel)
        }
        let templates = NewFileCreator.userTemplates()
        if !templates.isEmpty {
            Divider()
            ForEach(templates, id: \.self) { template in
                Button(template.title) { create(template) }
            }
        }
        Divider()
        Button("Open Templates Folder") { NewFileCreator.openTemplatesFolder() }
    }

    private func create(_ template: NewFileTemplate) {
        guard let viewModel else { return }
        NewFileCreator.create(template, in: viewModel.currentPath, viewModel: viewModel)
    }
}

/// The toolbar's "+" menu: New Folder, then the New File items.
struct NewItemToolbarMenu: View {
    @ObservedObject var viewModel: FileBrowserViewModel

    var body: some View {
        Menu {
            Button("New Folder") { viewModel.createNewFolder() }
            Divider()
            NewFileMenuItems(viewModel: viewModel)
        } label: {
            Image(systemName: "plus")
        }
        .disabled(!NewFileCreator.canCreate(in: viewModel.currentPath, viewModel: viewModel))
        .help("New")
    }
}

// MARK: - Menu bar

struct CustomCommands: Commands {
    @ObservedObject var menuState: MenuValidationState
    @ObservedObject private var settings = AppSettings.shared

    private var viewModel: FileBrowserViewModel? {
        menuState.isSheetActive ? nil : menuState.commandContext?.viewModel
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Menu("New File") {
                NewFileMenuItems(viewModel: viewModel, withShortcut: true)
            }
            .disabled(viewModel == nil)

            Button("New Smart Folder") {
                SmartFolderActions.newSmartFolder(viewModel: viewModel)
            }
            .disabled(viewModel == nil)

            Button("Open in Terminal") {
                guard let viewModel, !viewModel.isInsideArchive else {
                    NSSound.beep()
                    return
                }
                let selection = CustomActions.orderedSelection(of: viewModel)
                TerminalLauncher.open(selection.isEmpty ? viewModel.currentPath : TerminalLauncher.folder(for: selection))
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(viewModel == nil)

            Button("Compare Folders…") {
                guard let viewModel else { return }
                FolderCompareLauncher.open(from: viewModel)
            }
            .keyboardShortcut("c", modifiers: [.command, .option, .shift])
            .disabled(viewModel == nil)

            Button("Rename Items…") {
                guard let viewModel else { return }
                BatchRename.present(items: CustomActions.orderedSelection(of: viewModel), viewModel: viewModel)
            }
            .disabled(viewModel == nil)

            if let viewModel, let convert = FileConversion.menuEntry(viewModel: viewModel, targets: { CustomActions.orderedSelection(of: viewModel) }) {
                CustomMenuItems(entries: [convert])
            } else {
                Menu("Convert") {}.disabled(true)
            }
        }

        CommandGroup(after: .toolbar) {
            Button(ViewOptionsPanelController.shared.isVisible ? "Hide View Options" : "Show View Options") {
                ViewOptionsPanelController.shared.toggle()
            }
            .keyboardShortcut("j", modifiers: .command)
            .disabled(menuState.isSheetActive)

            Toggle("Combine view mode buttons", isOn: $settings.compactViewModePicker)
        }

        CommandGroup(after: .pasteboard) {
            Menu("Copy Path") {
                ForEach(PathCopyStyle.allCases, id: \.self) { style in
                    if style == .path {
                        Button(style.title) { copyPath(style) }
                            .keyboardShortcut("c", modifiers: [.command, .option])
                    } else {
                        Button(style.title) { copyPath(style) }
                    }
                }
            }
            .disabled(viewModel == nil || menuState.usesStandardEditing)
        }
    }

    /// The selection's paths, or the folder's when nothing is selected.
    private func copyPath(_ style: PathCopyStyle) {
        guard let viewModel else { return }
        let selection = CustomActions.orderedSelection(of: viewModel)
        if selection.contains(where: { $0.isFromArchive || !$0.url.isFileURL })
            || (selection.isEmpty && (viewModel.isInsideArchive || !viewModel.currentPath.isFileURL)) {
            NSSound.beep()
            return
        }
        PathCopy.copy(selection.isEmpty ? [viewModel.currentPath] : selection.map(\.url), style: style)
    }
}
