import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Finder の「情報を見る」の「このアプリケーションで開く」と同じ設定：ポップアップで選んだアプリをこの書類の
/// 標準にし、「すべてを変更…」で同じ種類の書類すべての標準にする。
@MainActor
final class DefaultAppModel: ObservableObject {
    let fileURLs: [URL]
    @Published private(set) var apps: [OpenWithMenuBuilder.AppInfo] = []
    @Published private(set) var selectedAppURL: URL?
    @Published private(set) var isWorking = false

    init(fileURLs: [URL]) {
        self.fileURLs = fileURLs
        reload()
    }

    private var contentTypes: [UTType] {
        var seen = Set<String>()
        return fileURLs.compactMap { (try? $0.resourceValues(forKeys: [.contentTypeKey]))?.contentType }
            .filter { seen.insert($0.identifier).inserted }
    }

    private var typeDescription: String {
        let extensions = Set(fileURLs.map { $0.pathExtension.lowercased() }.filter { !$0.isEmpty }).sorted()
        if !extensions.isEmpty { return extensions.map { "“.\($0)”" }.joined(separator: "、") }
        return contentTypes.compactMap(\.localizedDescription).joined(separator: "、")
    }

    func reload() {
        apps = OpenWithMenuBuilder.compatibleApps(for: fileURLs)
        selectedAppURL = fileURLs.first.flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    }

    func choose(_ appURL: URL) {
        guard appURL != selectedAppURL else { return }
        perform { workspace in
            for url in self.fileURLs {
                try await workspace.setDefaultApplication(at: appURL, toOpenFileAt: url)
            }
        }
    }

    func chooseOther(in window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Application")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let appURL = panel.url else { return }
            self?.choose(appURL)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    func changeAll(in window: NSWindow?) {
        guard let appURL = selectedAppURL else { return }
        let types = contentTypes
        guard !types.isEmpty else { return }
        let appName = FileManager.default.displayName(atPath: appURL.path)
        let alert = NSAlert()
        alert.messageText = String(localized: "Change all similar documents to open with “\(appName)”?")
        alert.informativeText = String(localized: "This change will apply to all documents with the extension \(typeDescription).")
        alert.addButton(withTitle: String(localized: "Continue"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.perform { workspace in
                for type in types {
                    try await workspace.setDefaultApplication(at: appURL, toOpen: type)
                }
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: apply) } else { apply(alert.runModal()) }
    }

    private func perform(_ body: @escaping @MainActor (NSWorkspace) async throws -> Void) {
        isWorking = true
        Task {
            do {
                try await body(NSWorkspace.shared)
            } catch {
                let nsError = error as NSError
                if !(nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError) {
                    showFailure(error)
                }
            }
            isWorking = false
            reload()
        }
    }

    /// API で変えられなかったときは Finder の「情報を見る」を開けるようにする。
    private func showFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Couldn’t change the default application.")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: String(localized: "Show Info in Finder"))
        alert.addButton(withTitle: String(localized: "OK"))
        if alert.runModal() == .alertFirstButtonReturn {
            DefaultAppChooser.showFinderInfo(for: fileURLs)
        }
    }
}

struct DefaultAppSection: View {
    @StateObject private var model: DefaultAppModel
    @State private var hostWindow: NSWindow?
    private let otherTag = URL(fileURLWithPath: "/.flowfinder-other-app")

    init(fileURLs: [URL]) {
        _model = StateObject(wrappedValue: DefaultAppModel(fileURLs: fileURLs))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Open With")
                .font(.headline)
                .padding(.bottom, 4)

            Picker("", selection: Binding(
                get: { model.selectedAppURL ?? otherTag },
                set: { url in
                    if url == otherTag { model.chooseOther(in: hostWindow) } else { model.choose(url) }
                }
            )) {
                ForEach(model.apps, id: \.url) { app in
                    Label {
                        Text(app.isDefault ? String(localized: "\(app.name) (default)") : app.name)
                    } icon: {
                        Image(nsImage: app.icon)
                    }
                    .tag(app.url)
                }
                Divider()
                Text("Other...").tag(otherTag)
            }
            .labelsHidden()
            .disabled(model.isWorking)

            Text("Use this application to open all documents like this one.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Change All...") { model.changeAll(in: hostWindow) }
                    .disabled(model.isWorking || model.selectedAppURL == nil)
                if model.isWorking {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WindowAccessor(window: $hostWindow))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.reload()
        }
    }
}

private struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if window !== nsView.window {
            DispatchQueue.main.async { window = nsView.window }
        }
    }
}

/// 「このアプリケーションで開く」メニューから開く単独のウインドウ。
@MainActor
final class DefaultAppChooser: NSObject {
    static let shared = DefaultAppChooser()
    private var windows: [NSWindow] = []

    /// 「このアプリケーションで開く」サブメニューの末尾に付ける項目。
    nonisolated static func menuItem(for fileURLs: [URL]) -> NSMenuItem {
        MainActor.assumeIsolated {
            let item = NSMenuItem(title: String(localized: "Change Default Application..."),
                                  action: #selector(showFromMenu(_:)), keyEquivalent: "")
            item.target = shared
            item.representedObject = fileURLs
            return item
        }
    }

    @objc private func showFromMenu(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL] else { return }
        Self.show(for: urls)
    }

    static func show(for fileURLs: [URL]) {
        guard !fileURLs.isEmpty else { return }
        let title = fileURLs.count == 1
            ? FileManager.default.displayName(atPath: fileURLs[0].path)
            : String(localized: "\(fileURLs.count) items")
        let content = VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: fileURLs[0].path))
                    .resizable()
                    .frame(width: 32, height: 32)
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
            }
            Divider()
            DefaultAppSection(fileURLs: fileURLs)
        }
        .padding(20)
        .frame(width: 360)

        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = String(localized: "Open With")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        shared.windows.append(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { note in
            MainActor.assumeIsolated {
                shared.windows.removeAll { $0 === note.object as? NSWindow }
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Finder の「情報を見る」ウインドウを開く。
    static func showFinderInfo(for fileURLs: [URL]) {
        for url in fileURLs {
            let path = url.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let source = """
            tell application "Finder"
                activate
                open information window of (POSIX file "\(path)" as alias)
            end tell
            """
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if error != nil {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return
            }
        }
    }
}
