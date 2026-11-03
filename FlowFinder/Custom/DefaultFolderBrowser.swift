import SwiftUI
import UniformTypeIdentifiers

enum DefaultFolderBrowser {
    private static let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")

    static var isInstalledInApplications: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    static var isDefault: Bool {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: .folder) else { return false }
        return Bundle(url: url)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    @MainActor
    static func set(_ makeDefault: Bool, completion: @escaping @MainActor () -> Void) {
        let target = makeDefault ? Bundle.main.bundleURL : finderURL
        Task { @MainActor in
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: target, toOpen: .folder)
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = String(localized: "Couldn't change the default folder browser.")
                alert.runModal()
            }
            completion()
        }
    }
}

struct DefaultFolderBrowserSetting: View {
    @State private var isDefault = DefaultFolderBrowser.isDefault

    var body: some View {
        let installed = DefaultFolderBrowser.isInstalledInApplications
        Toggle("Make FlowFinder the default folder browser", isOn: Binding(
            get: { isDefault },
            set: { newValue in
                DefaultFolderBrowser.set(newValue) { isDefault = DefaultFolderBrowser.isDefault }
            }
        ))
        .disabled(!installed)
        .onAppear { isDefault = DefaultFolderBrowser.isDefault }
        if !installed {
            Text("Install to /Applications first (scripts/install-local.sh)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
