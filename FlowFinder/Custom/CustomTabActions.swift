import SwiftUI
import AppKit

// MARK: - Open a folder in a new tab / split

extension Notification.Name {
    static let openFolderInNewTab = Notification.Name("openFolderInNewTab")
    static let openFolderInSplit = Notification.Name("openFolderInSplit")
}

enum FolderOpenRequest {
    static let urlKey = "url"

    /// Posted with the pane the request came from; the window owning that pane handles it.
    @MainActor
    static func post(_ name: Notification.Name, folder: URL, from viewModel: FileBrowserViewModel) {
        NotificationCenter.default.post(name: name, object: viewModel, userInfo: [urlKey: folder])
    }
}

struct FolderOpenNotifications: ViewModifier {
    let onNewTab: (FileBrowserViewModel, URL) -> Void
    let onSplit: (FileBrowserViewModel, URL) -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .openFolderInNewTab)) { notification in
                guard let source = notification.object as? FileBrowserViewModel,
                      let url = notification.userInfo?[FolderOpenRequest.urlKey] as? URL else { return }
                onNewTab(source, url)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openFolderInSplit)) { notification in
                guard let source = notification.object as? FileBrowserViewModel,
                      let url = notification.userInfo?[FolderOpenRequest.urlKey] as? URL else { return }
                onSplit(source, url)
            }
    }
}

// MARK: - New tab location

enum NewTabLocation: String, CaseIterable, Identifiable {
    case current, home, desktop, documents, downloads, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .current: String(localized: "Last Opened Folder")
        case .home: String(localized: "Home")
        case .desktop: String(localized: "Desktop")
        case .documents: String(localized: "Documents")
        case .downloads: String(localized: "Downloads")
        case .custom: String(localized: "Specific Folder…")
        }
    }

    /// The folder a new tab opens; nil means the folder of the pane in front.
    @MainActor
    static func folder() -> URL? {
        let settings = AppSettings.shared
        let manager = FileManager.default
        switch NewTabLocation(rawValue: settings.newTabLocation) ?? .current {
        case .current: return nil
        case .home: return manager.homeDirectoryForCurrentUser
        case .desktop: return manager.urls(for: .desktopDirectory, in: .userDomainMask).first
        case .documents: return manager.urls(for: .documentDirectory, in: .userDomainMask).first
        case .downloads: return manager.urls(for: .downloadsDirectory, in: .userDomainMask).first
        case .custom:
            var isDirectory: ObjCBool = false
            let path = settings.newTabCustomPath
            guard !path.isEmpty, manager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }
}

struct NewTabLocationSetting: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Picker("New tabs open", selection: Binding(
            get: { NewTabLocation(rawValue: settings.newTabLocation) ?? .current },
            set: { choose($0) }
        )) {
            ForEach(NewTabLocation.allCases) { location in
                Text(verbatim: label(for: location)).tag(location)
            }
        }
    }

    private func label(for location: NewTabLocation) -> String {
        guard location == .custom, !settings.newTabCustomPath.isEmpty else { return location.title }
        return "\(location.title) (\((settings.newTabCustomPath as NSString).lastPathComponent))"
    }

    private func choose(_ location: NewTabLocation) {
        guard location == .custom else {
            settings.newTabLocation = location.rawValue
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.newTabCustomPath = url.path
        settings.newTabLocation = location.rawValue
    }
}

// MARK: - Command-open and middle click

extension FileBrowserViewModel {
    /// Opening a plain folder while ⌘ is held (⌘ double-click, ⌘↓) opens it in a new tab instead.
    @MainActor
    func openFolderInNewTabIfCommandHeld(_ item: FileItem) -> Bool {
        NSEvent.modifierFlags.contains(.command) && openFolderInNewTab(item)
    }

    @MainActor
    func openFolderInNewTab(_ item: FileItem) -> Bool {
        guard item.isDirectory, !item.isFromArchive, !item.isPackage, !item.isBrowsableArchive,
              !item.isAliasFile, item.url.isFileURL,
              !NSWorkspace.shared.isFilePackage(atPath: item.url.path) else { return false }
        FolderOpenRequest.post(.openFolderInNewTab, folder: item.url, from: self)
        return true
    }
}

private struct MiddleClickModifier: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content.overlay(MiddleClickCatcher(action: action))
    }
}

private struct MiddleClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.action = action
    }

    final class CatcherView: NSView {
        var action: (() -> Void)?

        // Only the middle button is claimed; everything else falls through to the view below.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard NSApp.currentEvent?.type == .otherMouseDown || NSApp.currentEvent?.type == .otherMouseUp,
                  NSApp.currentEvent?.buttonNumber == 2 else { return nil }
            return super.hitTest(point)
        }

        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2 { action?() } else { super.otherMouseUp(with: event) }
        }
    }
}

extension View {
    func onMiddleClick(_ action: @escaping () -> Void) -> some View {
        modifier(MiddleClickModifier(action: action))
    }
}
