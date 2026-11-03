import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Share

@MainActor
enum FileSharing {
    static let shareExtensionsURL = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.share-services")!

    /// File URLs of the items that can be shared (nothing inside archives).
    static func shareableURLs(_ items: [FileItem]) -> [URL] {
        guard items.allSatisfy({ !$0.isFromArchive && $0.url.isFileURL }) else { return [] }
        return items.map(\.url)
    }

    static func services(for urls: [URL]) -> [NSSharingService] {
        guard !urls.isEmpty else { return [] }
        return (LegacySharingLister() as SharingServiceLister).services(for: urls)
    }

    static func openShareExtensionSettings() {
        NSWorkspace.shared.open(shareExtensionsURL)
    }

    /// The "Share" submenu: every service that can take the items, then "Other…".
    static func menuEntry(enabled: Bool, targets: @escaping () -> [FileItem]) -> CustomMenuEntry {
        let urls = enabled ? shareableURLs(targets()) : []
        var children: [CustomMenuEntry] = services(for: urls).map { service in
            .iconAction(service.menuItemTitle, image: service.image) {
                service.perform(withItems: shareableURLs(targets()))
            }
        }
        if !children.isEmpty { children.append(.separator) }
        children.append(.action(String(localized: "Other…"), enabled: true) { openShareExtensionSettings() })
        return .submenu(String(localized: "Share"), enabled: !urls.isEmpty, children)
    }

    static func showPicker(for urls: [URL], relativeTo view: NSView) {
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        NSSharingServicePicker(items: urls).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}

/// `sharingServices(forItems:)` is deprecated without a replacement that lists the services;
/// calling it through a protocol keeps the warning out of the build.
private protocol SharingServiceLister {
    func services(for items: [Any]) -> [NSSharingService]
}

private struct LegacySharingLister: SharingServiceLister {
    @available(macOS, deprecated: 13.0)
    func services(for items: [Any]) -> [NSSharingService] {
        NSSharingService.sharingServices(forItems: items)
    }
}

/// An invisible view to anchor the share picker on a SwiftUI button.
private struct PickerAnchor: NSViewRepresentable {
    let holder: PickerAnchorHolder

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        holder.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        holder.view = view
    }
}

private final class PickerAnchorHolder {
    weak var view: NSView?
}

/// The toolbar's Share button.
struct ToolbarShareButton: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    @State private var anchor = PickerAnchorHolder()

    var body: some View {
        let urls = FileSharing.shareableURLs(CustomActions.orderedSelection(of: viewModel))
        Button {
            if let view = anchor.view { FileSharing.showPicker(for: urls, relativeTo: view) }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .background(PickerAnchor(holder: anchor))
        .disabled(urls.isEmpty)
        .help("Share")
        .onAppear { FileServices.registerSendTypes() }
    }
}

/// Small buttons for the usual share destinations, shown in the path bar while files are selected.
struct ShareRibbon: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    @EnvironmentObject private var settings: AppSettings
    @State private var anchor = PickerAnchorHolder()

    private static let favorites: [NSSharingService.Name] = [.sendViaAirDrop, .composeMessage, .composeEmail]

    var body: some View {
        let urls = viewModel.selectedItems.isEmpty ? [] : FileSharing.shareableURLs(CustomActions.orderedSelection(of: viewModel))
        if settings.showShareRibbon, !urls.isEmpty {
            HStack(spacing: 2) {
                ForEach(Self.favorites, id: \.rawValue) { name in
                    if let service = NSSharingService(named: name), service.canPerform(withItems: urls) {
                        Button {
                            service.perform(withItems: urls)
                        } label: {
                            Image(nsImage: service.image)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 16, height: 16)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(service.title)
                    }
                }
                Button {
                    if let view = anchor.view { FileSharing.showPicker(for: urls, relativeTo: view) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(PickerAnchor(holder: anchor))
                .help(String(localized: "Share"))
            }
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - Services menu

@MainActor
enum FileServices {
    nonisolated static let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    private static var didRegister = false

    static func registerSendTypes() {
        guard !didRegister else { return }
        didRegister = true
        NSApp.registerServicesMenuSendTypes([.fileURL, filenamesType], returnTypes: [])
    }

    static func write(_ urls: [URL], to pasteboard: NSPasteboard) -> Bool {
        guard !urls.isEmpty else { return false }
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        pasteboard.setPropertyList(urls.map(\.path), forType: filenamesType)
        return true
    }

    static func selectedURLs(in window: NSWindow?) -> [URL] {
        guard let viewModel = MenuValidationState.shared.context(for: window)?.viewModel,
              !viewModel.selectedItems.isEmpty else { return [] }
        return FileSharing.shareableURLs(CustomActions.orderedSelection(of: viewModel))
    }
}

/// The browser window's delegate answers for the whole window, so the app menu's Services
/// offer the file services for the selection whichever view (list, Cover Flow, SwiftUI) is focused.
extension PathMenuWindowDelegateProxy: NSServicesMenuRequestor {
    @objc func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        guard returnType == nil, let sendType, [.fileURL, FileServices.filenamesType].contains(sendType) else { return nil }
        let window = parentView?.window
        return MainActor.assumeIsolated { FileServices.selectedURLs(in: window).isEmpty } ? nil : self
    }

    public func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let window = parentView?.window
        return MainActor.assumeIsolated { FileServices.write(FileServices.selectedURLs(in: window), to: pboard) }
    }
}

// MARK: - Quick Actions

@MainActor
enum QuickActions {
    static let customizeURL = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.finder-quick-actions")!

    struct Workflow {
        let name: String
        let sendFileTypes: [String]?
    }

    /// The "Quick Actions" submenu for the items.
    static func menuEntry(viewModel: FileBrowserViewModel, enabled: Bool, targets: @escaping () -> [FileItem]) -> CustomMenuEntry {
        let items = enabled ? targets() : []
        let urls = FileSharing.shareableURLs(items)
        var children: [CustomMenuEntry] = []
        let canWrite = viewModel.canAddItemsToCurrentLocation
        if !urls.isEmpty, urls.allSatisfy({ ConversionKind.of($0) == .image }), !items.contains(where: \.isDirectory) {
            children.append(.iconAction(String(localized: "Rotate Left"), image: symbol("rotate.left")) { [weak viewModel] in
                rotateLeft(targets().map(\.url), viewModel: viewModel)
            })
        }
        let pdfable = urls.filter { [.image, .pdf].contains(ConversionKind.of($0)) }
        if !pdfable.isEmpty, pdfable.count == urls.count, canWrite, urls.count > 1 || ConversionKind.of(urls[0]) == .image {
            children.append(.iconAction(String(localized: "Create PDF"), image: symbol("doc.richtext")) { [weak viewModel] in
                guard let viewModel else { return }
                let items = targets()
                FileConversion.convert(items, action: items.count > 1 ? .combinePDF : .image(.pdf), viewModel: viewModel)
            })
        }
        if !urls.isEmpty {
            let types = urls.map(contentType(of:))
            let workflows = installedWorkflows().filter { workflow in
                guard let accepted = workflow.sendFileTypes else { return true }
                let acceptedTypes = accepted.compactMap { UTType($0) }
                return types.allSatisfy { type in acceptedTypes.contains { type.conforms(to: $0) } }
            }
            if !workflows.isEmpty {
                children.append(.separator)
                children += workflows.map { workflow in
                    .iconAction(workflow.name, image: symbol("gearshape")) {
                        perform(service: workflow.name, with: FileSharing.shareableURLs(targets()))
                    }
                }
            }
            let shortcuts = ShortcutsLibrary.names()
            if !shortcuts.isEmpty {
                children.append(.separator)
                children.append(.submenu(String(localized: "Shortcuts"), enabled: true, shortcuts.map { name in
                    .action(name, enabled: true) {
                        ShortcutsLibrary.run(name, with: FileSharing.shareableURLs(targets()))
                    }
                }))
            }
        }
        children.append(.separator)
        children.append(.action(String(localized: "Customize…"), enabled: true) {
            NSWorkspace.shared.open(customizeURL)
        })
        return .submenu(String(localized: "Quick Actions"), enabled: !urls.isEmpty, children)
    }

    private static func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
    }

    private static func contentType(of url: URL) -> UTType {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType { return type }
        return UTType(filenameExtension: url.pathExtension) ?? .item
    }

    /// The file services of the Automator/Shortcuts workflows in ~/Library/Services and /Library/Services.
    static func installedWorkflows() -> [Workflow] {
        let folders = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Services"),
                       URL(fileURLWithPath: "/Library/Services")]
        var result: [Workflow] = []
        for folder in folders {
            let bundles = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for bundle in bundles where bundle.pathExtension == "workflow" {
                let plist = bundle.appendingPathComponent("Contents/Info.plist")
                guard let info = NSDictionary(contentsOf: plist) as? [String: Any],
                      let services = info["NSServices"] as? [[String: Any]] else { continue }
                for service in services {
                    guard let name = (service["NSMenuItem"] as? [String: Any])?["default"] as? String else { continue }
                    if let fileTypes = service["NSSendFileTypes"] as? [String], !fileTypes.isEmpty {
                        result.append(Workflow(name: name, sendFileTypes: fileTypes))
                    } else if let sendTypes = service["NSSendTypes"] as? [String],
                              sendTypes.contains(where: { ["NSFilenamesPboardType", "public.file-url", "NSURLPboardType"].contains($0) }) {
                        result.append(Workflow(name: name, sendFileTypes: nil))
                    }
                }
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func perform(service name: String, with urls: [URL]) {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("FlowFinder.QuickActions"))
        guard FileServices.write(urls, to: pasteboard), NSPerformService(name, pasteboard) else {
            showError(String(localized: "The quick action “\(name)” couldn’t be run."), detail: nil)
            return
        }
    }

    /// Turns images 90° counterclockwise in place by changing their orientation (no re-encoding).
    static func rotateLeft(_ urls: [URL], viewModel: FileBrowserViewModel?) {
        DispatchQueue.global(qos: .userInitiated).async {
            var failed: [String] = []
            for url in urls where (try? ImageRotation.rotateLeft(url)) == nil {
                failed.append(url.lastPathComponent)
            }
            DispatchQueue.main.async {
                viewModel?.refresh()
                if !failed.isEmpty {
                    showError(String(localized: "Some images couldn’t be rotated."), detail: failed.joined(separator: "\n"))
                }
            }
        }
    }

    static func showError(_ message: String, detail: String?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        if let detail, !detail.isEmpty { alert.informativeText = detail }
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

enum ImageRotation {
    /// EXIF orientation after turning the displayed image 90° counterclockwise.
    private static let rotatedLeft: [Int: Int] = [1: 8, 8: 3, 3: 6, 6: 1, 2: 5, 5: 4, 4: 7, 7: 2]

    static func rotateLeft(_ url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source),
              CGImageSourceGetCount(source) > 0 else {
            throw FileOperationEngine.makeError(String(localized: "The image couldn’t be read."))
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let current = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let next = rotatedLeft[current] ?? 8
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".FlowFinder-rotate-" + UUID().uuidString + "." + url.pathExtension)
        defer { try? FileManager.default.removeItem(at: temp) }

        var written = false
        if let destination = CGImageDestinationCreateWithURL(temp as CFURL, type, 1, nil) {
            let options = [kCGImageDestinationOrientation: next] as CFDictionary
            written = CGImageDestinationCopyImageSource(destination, source, options, nil)
        }
        if !written, CGImageSourceGetCount(source) == 1,
           let destination = CGImageDestinationCreateWithURL(temp as CFURL, type, 1, nil) {
            var updated = properties
            updated[kCGImagePropertyOrientation] = next
            CGImageDestinationAddImageFromSource(destination, source, 0, updated as CFDictionary)
            written = CGImageDestinationFinalize(destination)
        }
        guard written else {
            throw FileOperationEngine.makeError(String(localized: "The image couldn’t be rotated."))
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }
}

// MARK: - Shortcuts

/// The user's shortcuts, read with the `shortcuts` command-line tool.
@MainActor
enum ShortcutsLibrary {
    nonisolated private static let tool = URL(fileURLWithPath: "/usr/bin/shortcuts")
    private static var cache: (date: Date, names: [String])?
    private static var isRefreshing = false

    /// Cached names; refreshed in the background when older than half a minute.
    static func names() -> [String] {
        guard FileManager.default.isExecutableFile(atPath: tool.path) else { return [] }
        guard let cache else {
            let names = list()
            self.cache = (Date(), names)
            return names
        }
        if Date().timeIntervalSince(cache.date) > 30, !isRefreshing {
            isRefreshing = true
            DispatchQueue.global(qos: .utility).async {
                let names = list()
                DispatchQueue.main.async {
                    self.cache = (Date(), names)
                    isRefreshing = false
                }
            }
        }
        return cache.names
    }

    nonisolated private static func list() -> [String] {
        let process = Process()
        process.executableURL = tool
        process.arguments = ["list"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    static func run(_ name: String, with urls: [URL]) {
        let process = Process()
        process.executableURL = tool
        process.arguments = ["run", name] + urls.flatMap { ["--input-path", $0.path] }
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        process.terminationHandler = { process in
            let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus != 0 else { return }
            DispatchQueue.main.async {
                QuickActions.showError(String(localized: "The shortcut “\(name)” couldn’t be run."), detail: detail)
            }
        }
        do {
            try process.run()
        } catch {
            QuickActions.showError(String(localized: "The shortcut “\(name)” couldn’t be run."), detail: error.localizedDescription)
        }
    }
}
