import SwiftUI
import AppKit

// MARK: - Layout

/// How Finder lays out a folder's icon view, read from the folder's `.DS_Store`: the window an
/// installer disk image opens with (background picture, icon positions and sizes).
struct FolderWindowLayout {
    var iconSize: CGFloat = 64
    var textSize: CGFloat = 12
    var labelOnBottom = true
    var backgroundColor: NSColor?
    var backgroundImage: NSImage?
    /// The icon view's size: the background picture's, else the window's content.
    var canvasSize = CGSize(width: 600, height: 400)
    /// Icon centers by file name, from the top left of the window's content.
    var positions: [String: CGPoint] = [:]
    /// The background is dark: labels are drawn in white.
    var usesLightText = false

    private static let imageExtensions: Set<String> = ["png", "tif", "tiff", "jpg", "jpeg", "gif", "heic", "bmp", "pdf", "icns"]

    /// Reads the layout of `folder` (off the main thread: it reads files). Nil when Finder would show
    /// a plain icon view: no icon view options, or neither a disk image's volume nor a background picture.
    static func load(folder: URL) -> FolderWindowLayout? {
        guard let store = DSStore(contentsOf: folder.appendingPathComponent(".DS_Store")) else { return nil }
        let options = store.plist("icvp")
        let legacyOptions = store.value("icvo")?.blob
        guard options != nil || legacyOptions != nil else { return nil }
        let volumeRoot = DiskImageVolumes.diskImageVolumeRoot(containing: folder)
        let isDiskImageRoot = volumeRoot.map { VolumePaths.pathKey($0) == VolumePaths.pathKey(folder) } ?? false
        let backgroundType = (options?["backgroundType"] as? NSNumber)?.intValue ?? 0
        guard isDiskImageRoot || backgroundType == 2 else { return nil }

        var layout = FolderWindowLayout()
        if let options {
            if let size = (options["iconSize"] as? NSNumber)?.doubleValue { layout.iconSize = CGFloat(min(max(size, 16), 512)) }
            if let size = (options["textSize"] as? NSNumber)?.doubleValue { layout.textSize = CGFloat(min(max(size, 8), 24)) }
            if let bottom = options["labelOnBottom"] as? NSNumber { layout.labelOnBottom = bottom.boolValue }
        } else if let legacyOptions, legacyOptions.count >= 6, legacyOptions.prefix(4) == Data("icv4".utf8) {
            layout.iconSize = CGFloat(min(max(Int(legacyOptions[4]) << 8 | Int(legacyOptions[5]), 16), 512))
        }

        for record in store.records where record.code == "Iloc" {
            guard let data = record.value.blob, data.count >= 8 else { continue }
            let bytes = [UInt8](data.prefix(8))
            let x = Int32(bitPattern: UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
            let y = Int32(bitPattern: UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7]))
            guard abs(x) < 100_000, abs(y) < 100_000 else { continue }
            layout.positions[record.filename] = CGPoint(x: CGFloat(x), y: CGFloat(y))
        }

        switch backgroundType {
        case 1:
            if let options {
                func component(_ key: String) -> CGFloat { CGFloat((options[key] as? NSNumber)?.doubleValue ?? 1) }
                layout.backgroundColor = NSColor(srgbRed: component("backgroundColorRed"), green: component("backgroundColorGreen"),
                                                 blue: component("backgroundColorBlue"), alpha: 1)
            }
        case 2:
            layout.backgroundImage = backgroundImageURL(store: store, options: options, folder: folder, volumeRoot: volumeRoot)
                .flatMap(loadImage)
        default:
            break
        }

        if let image = layout.backgroundImage, image.size.width >= 1, image.size.height >= 1 {
            layout.canvasSize = CGSize(width: min(image.size.width, 8000), height: min(image.size.height, 8000))
        } else if let content = windowContentSize(store) {
            layout.canvasSize = content
        }
        layout.usesLightText = isDark(image: layout.backgroundImage, color: layout.backgroundColor)
        return layout
    }

    /// The window's content size from `bwsp` (window frame less the title bar and visible bars), or `fwi0`.
    private static func windowContentSize(_ store: DSStore) -> CGSize? {
        if let settings = store.plist("bwsp"), let bounds = settings["WindowBounds"] as? String {
            let rect = NSRectFromString(bounds)
            guard rect.width >= 100, rect.height >= 100 else { return nil }
            func shows(_ key: String) -> Bool { (settings[key] as? NSNumber)?.boolValue == true }
            var height = rect.height - 28
            if shows("ShowToolbar") { height -= 24 }
            if shows("ShowPathbar") { height -= 22 }
            if shows("ShowStatusBar") { height -= 22 }
            var width = rect.width
            if shows("ShowSidebar") { width -= CGFloat((settings["SidebarWidth"] as? NSNumber)?.doubleValue ?? 0) }
            return CGSize(width: min(max(width, 100), 8000), height: min(max(height, 100), 8000))
        }
        if let info = store.value("fwi0")?.blob, info.count >= 8 {
            let bytes = [UInt8](info.prefix(8))
            func value(_ index: Int) -> CGFloat { CGFloat(Int16(bitPattern: UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))) }
            let width = value(6) - value(2), height = value(4) - value(0)
            guard width >= 100, height >= 100 else { return nil }
            return CGSize(width: min(width, 8000), height: min(height, 8000))
        }
        return nil
    }

    // MARK: Background picture

    /// The background picture: where its bookmark or alias says (moved onto the volume as it is
    /// mounted now), else a picture in one of the hidden folders installer images keep it in.
    private static func backgroundImageURL(store: DSStore, options: [String: Any]?, folder: URL, volumeRoot: URL?) -> URL? {
        let root = volumeRoot ?? folder
        var paths: [String] = []
        if let bookmark = store.value("pBBk")?.blob,
           let path = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: bookmark)?.path {
            paths.append(path)
        }
        if let alias = options?["backgroundImageAlias"] as? Data, let path = AliasRecordPaths.volumeRelativePath(from: alias) {
            paths.append(root.path + path)
        }
        for path in paths {
            if let url = relocate(path, folder: folder, root: root) { return url }
        }
        if let alias = options?["backgroundImageAlias"] as? Data,
           let bookmark = CFURLCreateBookmarkDataFromAliasRecord(kCFAllocatorDefault, alias as CFData)?.takeRetainedValue() as Data? {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &isStale),
               isImageFile(url), VolumePaths.isURL(url, onVolumeAt: root) {
                return url
            }
        }
        return searchHiddenBackground(in: folder) ?? (root == folder ? nil : searchHiddenBackground(in: root))
    }

    /// `path` itself when it is on this volume, else the same trailing components under the folder
    /// or the volume (the image was laid out on a volume mounted elsewhere, or from a source folder).
    private static func relocate(_ path: String, folder: URL, root: URL) -> URL? {
        let url = URL(fileURLWithPath: path)
        if (VolumePaths.isURL(url, onVolumeAt: root) || VolumePaths.pathKey(url).hasPrefix(VolumePaths.pathKey(folder) + "/")),
           isImageFile(url) {
            return url
        }
        let components = url.pathComponents.filter { $0 != "/" }
        for count in stride(from: min(components.count, 4), through: 1, by: -1) {
            let suffix = components.suffix(count).joined(separator: "/")
            for base in [folder, root] {
                let candidate = base.appendingPathComponent(suffix)
                if isImageFile(candidate) { return candidate }
            }
        }
        return nil
    }

    private static func isImageFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return imageExtensions.contains(url.pathExtension.lowercased())
            && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private static func searchHiddenBackground(in directory: URL) -> URL? {
        let manager = FileManager.default
        var candidates: [URL] = []
        for name in [".background", ".bg", ".Background", ".images", ".resources", ".assets"] {
            let folder = directory.appendingPathComponent(name)
            if let contents = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                candidates += contents.filter(isImageFile).sorted { $0.lastPathComponent < $1.lastPathComponent }
            }
        }
        if let contents = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            candidates += contents.filter { url in
                let name = url.lastPathComponent.lowercased()
                return name.hasPrefix(".") && (name.contains("background") || name.hasPrefix(".bg")) && isImageFile(url)
            }
        }
        func score(_ url: URL) -> Int {
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            return (name.hasSuffix("@2x") ? 2 : 0) + (name.contains("background") || name.contains("bg") ? 0 : 1)
        }
        return candidates.min { score($0) < score($1) }
    }

    /// The picture at its size in points: a lone `@2x` file at half its pixels, and a `name@2x`
    /// next to `name` added as the Retina representation.
    private static func loadImage(_ url: URL) -> NSImage? {
        guard let image = NSImage(contentsOf: url), let first = image.representations.first,
              first.pixelsWide > 0, first.pixelsHigh > 0 else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        let isPixelSized = Int(image.size.width.rounded()) == first.pixelsWide
        if name.hasSuffix("@2x") {
            if isPixelSized {
                image.size = NSSize(width: CGFloat(first.pixelsWide) / 2, height: CGFloat(first.pixelsHigh) / 2)
            }
        } else {
            let retina = url.deletingLastPathComponent().appendingPathComponent("\(name)@2x").appendingPathExtension(url.pathExtension)
            if image.representations.count == 1, isImageFile(retina), let reps = NSImageRep.imageReps(withContentsOf: retina) {
                for rep in reps {
                    rep.size = image.size
                    image.addRepresentation(rep)
                }
            }
        }
        return image
    }

    /// Whether labels need light text: the background's average luminance is low.
    private static func isDark(image: NSImage?, color: NSColor?) -> Bool {
        var red: CGFloat = 1, green: CGFloat = 1, blue: CGFloat = 1
        if let image, let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
                                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
           let context = NSGraphicsContext(bitmapImageRep: bitmap) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 1, height: 1).fill()
            context.imageInterpolation = .medium
            image.draw(in: NSRect(x: 0, y: 0, width: 1, height: 1))
            NSGraphicsContext.restoreGraphicsState()
            guard let average = bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB) else { return false }
            red = average.redComponent; green = average.greenComponent; blue = average.blueComponent
        } else if let color = color?.usingColorSpace(.sRGB) {
            red = color.redComponent; green = color.greenComponent; blue = color.blueComponent
        } else {
            return false
        }
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue < 0.45
    }
}

// MARK: - Store

/// Layouts of the folders shown in icon view, read in the background and kept while the folder's
/// `.DS_Store` is unchanged.
@MainActor
final class FolderLayoutStore: ObservableObject {
    static let shared = FolderLayoutStore()

    enum State {
        case loading
        case none
        case layout(FolderWindowLayout)
    }

    @Published private(set) var states: [String: State] = [:]
    /// Folders the user switched to the plain grid (this session).
    @Published private(set) var gridPaths: Set<String> = []
    private var signatures: [String: Date] = [:]
    private var pending: [String: [() -> Void]] = [:]

    func state(for folder: URL) -> State? {
        states[VolumePaths.pathKey(folder)]
    }

    func layout(for folder: URL) -> FolderWindowLayout? {
        if case .layout(let layout) = state(for: folder) { return layout }
        return nil
    }

    func showsGrid(_ folder: URL) -> Bool {
        gridPaths.contains(VolumePaths.pathKey(folder))
    }

    func setShowsGrid(_ showsGrid: Bool, for folder: URL) {
        let key = VolumePaths.pathKey(folder)
        if showsGrid { gridPaths.insert(key) } else { gridPaths.remove(key) }
    }

    /// Reads the folder's layout again if its `.DS_Store` changed (or was never read).
    func refresh(_ folder: URL, completion: (() -> Void)? = nil) {
        guard folder.isFileURL else {
            completion?()
            return
        }
        let key = VolumePaths.pathKey(folder)
        if pending[key] != nil {
            if let completion { pending[key]?.append(completion) }
            return
        }
        pending[key] = completion.map { [$0] } ?? []
        if states[key] == nil { states[key] = .loading }
        let known = signatures[key]
        DispatchQueue.global(qos: .userInitiated).async {
            let storeURL = folder.appendingPathComponent(".DS_Store")
            let modified = (try? storeURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let unchanged = modified != nil && modified == known
            let layout = unchanged ? nil : (modified == nil ? nil : FolderWindowLayout.load(folder: folder))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let store = FolderLayoutStore.shared
                    if !unchanged {
                        store.signatures[key] = modified
                        store.states[key] = layout.map { .layout($0) } ?? State.none
                    }
                    let completions = store.pending.removeValue(forKey: key) ?? []
                    completions.forEach { $0() }
                }
            }
        }
    }
}

// MARK: - Icon view switch

/// The icon view of a folder: its Finder window layout when it has one (an installer disk image),
/// else the grid.
struct FolderLayoutSwitch<Grid: View>: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    @ObservedObject private var store = FolderLayoutStore.shared
    @ViewBuilder let grid: () -> Grid

    private var showsLayout: Bool {
        viewModel.searchText.isEmpty && !viewModel.isInsideArchive && !store.showsGrid(viewModel.currentPath)
    }

    var body: some View {
        Group {
            if showsLayout, let layout = store.layout(for: viewModel.currentPath) {
                FolderLayoutView(viewModel: viewModel, layout: layout)
            } else if showsLayout, case .loading = store.state(for: viewModel.currentPath),
                      DiskImageVolumes.diskImageVolumeRoot(containing: viewModel.currentPath) != nil {
                // Briefly, rather than the grid flashing up before the layout
                Color.clear.uiBackground(.content)
            } else {
                grid()
            }
        }
        .onAppear {
            if !viewModel.isInsideArchive { store.refresh(viewModel.currentPath) }
        }
    }
}

// MARK: - Layout view

struct FolderLayoutView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    let layout: FolderWindowLayout
    @Environment(\.browserWindow) private var browserWindow
    @State private var dropTargetedItemID: UUID?
    @State private var isDropTargeted = false
    @State private var tileFrames = TileFrameStore()
    @State private var lastClick: (url: URL, time: Date)?
    /// Folders the symbolic links and aliases point to (the "Applications" link of an installer image).
    @State private var linkTargets: [URL: FileItem] = [:]
    private static let space = "folderLayout"

    private struct Placed: Identifiable {
        let item: FileItem
        let center: CGPoint
        var id: URL { item.url }
    }

    private var items: [FileItem] {
        viewModel.filteredItems.filter { !$0.isHidden }
    }

    private var labelWidth: CGFloat {
        layout.labelOnBottom ? max(layout.iconSize + 24, layout.textSize * 9) : layout.textSize * 12
    }

    /// Items at their recorded positions; the others in a row below.
    private var placement: (items: [Placed], size: CGSize) {
        var placed: [Placed] = []
        var size = layout.canvasSize
        let half = layout.iconSize / 2
        let labelHeight = layout.labelOnBottom ? layout.textSize * 2.6 + 8 : 0
        var unplaced: [FileItem] = []
        for item in items {
            if let point = layout.positions[item.url.lastPathComponent] {
                placed.append(Placed(item: item, center: point))
            } else {
                unplaced.append(item)
            }
        }
        let bottom = placed.map { $0.center.y + half + labelHeight }.max() ?? 0
        let step = max(labelWidth, layout.iconSize) + 16
        let columns = max(1, Int((size.width - 16) / step))
        for (index, item) in unplaced.enumerated() {
            let column = CGFloat(index % columns), row = CGFloat(index / columns)
            placed.append(Placed(item: item, center: CGPoint(x: 16 + step * (column + 0.5),
                                                             y: bottom + 16 + half + row * (layout.iconSize + labelHeight + 16))))
        }
        for entry in placed {
            let right = entry.center.x + (layout.labelOnBottom ? max(half, labelWidth / 2) : half + 8 + labelWidth)
            size.width = max(size.width, right + 8)
            size.height = max(size.height, entry.center.y + half + labelHeight + 8)
        }
        return (placed, size)
    }

    var body: some View {
        let placement = placement
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                canvas(placement)
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture { clearSelection() }
            }
        }
        .uiBackground(.content)
        .onDrop(of: DropHelper.acceptedDropTypes, delegate: ContainerDropDelegate(
            viewModel: viewModel,
            isDropTargeted: $isDropTargeted,
            containerHeight: layout.canvasSize.height,
            items: items,
            autoScroll: false
        ))
        .contextMenu {
            Button("Show as Grid") { FolderLayoutStore.shared.setShowsGrid(true, for: viewModel.currentPath) }
            Divider()
            if viewModel.canPaste {
                Button("Paste") { viewModel.paste() }
            }
            Button("Refresh") { viewModel.refresh() }
            Button("Show in Finder") { viewModel.showInFinder() }
            CustomBackgroundMenu(viewModel: viewModel)
        }
        .keyboardNavigable(
            onUpArrow: { shift in move(by: -1, extend: shift) },
            onDownArrow: { shift in move(by: 1, extend: shift) },
            onLeftArrow: { shift in move(by: -1, extend: shift) },
            onRightArrow: { shift in move(by: 1, extend: shift) },
            onReturn: { if let item = viewModel.primarySelectedItem { viewModel.openItem(item) } },
            onSpace: { toggleQuickLook() },
            onDelete: { viewModel.deleteSelectedItems() },
            onCopy: { viewModel.copySelectedItems() },
            onCut: { viewModel.cutSelectedItems() },
            onPaste: { viewModel.paste() }
        )
        .onChange(of: viewModel.selectedItems) { _, _ in
            viewModel.updateQuickLookPreview(for: viewModel.primarySelectedItem, in: browserWindow?.window)
        }
        .task(id: items.map(\.url)) { resolveLinkTargets() }
    }

    private func canvas(_ placement: (items: [Placed], size: CGSize)) -> some View {
        ZStack(alignment: .topLeading) {
            background
                .frame(width: placement.size.width, height: placement.size.height, alignment: .topLeading)
                .contentShape(Rectangle())
                .onTapGesture { clearSelection() }
            ForEach(placement.items) { entry in
                tile(entry.item)
                    .offset(x: entry.center.x - tileAnchor.x, y: entry.center.y - tileAnchor.y)
            }
        }
        .frame(width: placement.size.width, height: placement.size.height, alignment: .topLeading)
        .fileDragContainer(for: viewModel)
        .coordinateSpace(name: Self.space)
        .onDrop(of: DropHelper.acceptedDropTypes, delegate: TileGridDropDelegate(
            viewModel: viewModel,
            item: { [tileFrames, items, linkTargets] point in
                tileFrames.tile(at: point).flatMap { url in
                    linkTargets[url] ?? items.first { $0.url == url }
                }
            },
            dropTargetedItemID: $dropTargetedItemID,
            container: ContainerDropDelegate(
                viewModel: viewModel,
                isDropTargeted: $isDropTargeted,
                containerHeight: placement.size.height,
                items: items,
                autoScroll: false
            )
        ))
    }

    @ViewBuilder
    private var background: some View {
        if let image = layout.backgroundImage {
            ZStack(alignment: .topLeading) {
                Color(nsColor: layout.backgroundColor ?? .white)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: image.size.width, height: image.size.height)
            }
        } else if let color = layout.backgroundColor {
            Color(nsColor: color)
        } else {
            Color.clear
        }
    }

    /// Where the icon's center is inside a tile.
    private var tileAnchor: CGPoint {
        let padding: CGFloat = 4
        if layout.labelOnBottom {
            return CGPoint(x: labelWidth / 2, y: padding + layout.iconSize / 2)
        }
        return CGPoint(x: padding + layout.iconSize / 2, y: padding + layout.iconSize / 2)
    }

    private func tile(_ item: FileItem) -> some View {
        let isSelected = viewModel.selectedItems.contains(item)
        let isDropTarget = dropTargetedItemID != nil
            && (dropTargetedItemID == item.id || dropTargetedItemID == linkTargets[item.url]?.id)
        let icon = Image(nsImage: item.icon)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: layout.iconSize, height: layout.iconSize)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(isSelected ? 0.18 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 3).opacity(isDropTarget ? 1 : 0))
        let label = Text(item.displayName)
            .font(.system(size: layout.textSize))
            .lineLimit(2)
            .multilineTextAlignment(layout.labelOnBottom ? .center : .leading)
            .foregroundColor(isSelected ? .white : (layout.usesLightText ? .white : .black))
            .shadow(color: layout.usesLightText && !isSelected ? .black.opacity(0.6) : .clear, radius: 1, y: 1)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(isSelected ? Color.accentColor : Color.clear))
        return Group {
            if layout.labelOnBottom {
                VStack(spacing: 2) {
                    icon
                    label.frame(maxWidth: labelWidth)
                }
                .frame(width: labelWidth, alignment: .top)
            } else {
                HStack(spacing: 4) {
                    icon
                    label.frame(maxWidth: labelWidth, alignment: .leading)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .opacity(viewModel.isItemCut(item) ? 0.5 : 1)
        .onTapGesture { click(item) }
        .fileDragItem(item)
        .reportsTileFrame(item.url, in: tileFrames, space: Self.space)
        .contextMenu {
            FileItemContextMenu(item: item, viewModel: viewModel) { _ in }
        }
        .help(item.displayName)
    }

    // MARK: Actions

    private func click(_ item: FileItem) {
        let now = Date()
        if let lastClick, lastClick.url == item.url, now.timeIntervalSince(lastClick.time) < NSEvent.doubleClickInterval {
            self.lastClick = nil
            viewModel.openItem(item)
            return
        }
        lastClick = (item.url, now)
        guard let index = viewModel.filteredItems.firstIndex(of: item) else { return }
        let modifiers = NSEvent.modifierFlags
        viewModel.handleSelection(item: item, index: index, in: viewModel.filteredItems,
                                  withShift: modifiers.contains(.shift), withCommand: modifiers.contains(.command),
                                  allowRename: false, clickedOnTextArea: false)
    }

    private func clearSelection() {
        viewModel.selectedItems.removeAll()
        viewModel.cancelPendingRename()
    }

    /// Moves the selection through the icons in reading order (top to bottom, left to right).
    private func move(by offset: Int, extend: Bool) {
        let ordered = placement.items.sorted {
            abs($0.center.y - $1.center.y) > layout.iconSize / 2 ? $0.center.y < $1.center.y : $0.center.x < $1.center.x
        }.map(\.item)
        guard !ordered.isEmpty else { return }
        let current = viewModel.primarySelectedItem.flatMap { ordered.firstIndex(of: $0) }
        let next = current.map { min(max($0 + offset, 0), ordered.count - 1) } ?? (offset > 0 ? 0 : ordered.count - 1)
        viewModel.selectItem(ordered[next], extend: extend)
    }

    private func toggleQuickLook() {
        viewModel.toggleQuickLookForSelection(in: browserWindow?.window) { offset in
            move(by: offset, extend: false)
        }
    }

    /// Symbolic links and aliases to folders take drops as the folder they point to.
    private func resolveLinkTargets() {
        let links = items.filter { $0.isSymbolicLink || $0.isAliasFile }.map(\.url)
        guard !links.isEmpty else {
            linkTargets = [:]
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var targets: [URL: URL] = [:]
            for link in links {
                let target = (try? URL(resolvingAliasFileAt: link, options: [.withoutUI, .withoutMounting])) ?? link.resolvingSymlinksInPath()
                let values = try? target.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                if target != link, values?.isDirectory == true, values?.isPackage != true {
                    targets[link] = target
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    linkTargets = targets.mapValues { FileItem(url: $0) }
                }
            }
        }
    }
}
