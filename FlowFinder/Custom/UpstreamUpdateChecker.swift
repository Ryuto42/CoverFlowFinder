import AppKit

/// Checks the upstream CoverFlowFinder releases by hand. Installing an upstream build would replace
/// this customized app, so an update merges the upstream source and rebuilds it locally instead.
@MainActor
enum UpstreamUpdateChecker {
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/elliotttate/CoverFlowFinder/releases/latest")!

    static func checkForUpdates() {
        Task {
            do {
                var request = URLRequest(url: latestReleaseURL)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, _) = try await URLSession.shared.data(for: request)
                struct Release: Decodable { let tag_name: String; let html_url: String }
                let release = try JSONDecoder().decode(Release.self, from: data)
                present(latest: release.tag_name, notesURL: URL(string: release.html_url))
            } catch {
                showMessage(String(localized: "Could not check for updates."), info: error.localizedDescription)
            }
        }
    }

    private static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static func present(latest tag: String, notesURL: URL?) {
        let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard latest.compare(currentVersion, options: .numeric) == .orderedDescending else {
            showMessage(String(localized: "FlowFinder is up to date."), info: String(localized: "Upstream version: \(latest)"))
            return
        }

        let alert = NSAlert()
        alert.messageText = String(localized: "Upstream version \(latest) is available.")
        alert.informativeText = String(localized: "Current version: \(currentVersion). Updating merges the upstream source into your customized branch and rebuilds the app, so your changes are kept.")
        alert.addButton(withTitle: String(localized: "Merge and Rebuild"))
        alert.addButton(withTitle: String(localized: "Release Notes"))
        alert.addButton(withTitle: String(localized: "Later"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            runUpdateScript()
        case .alertSecondButtonReturn:
            if let notesURL { NSWorkspace.shared.open(notesURL) }
        default:
            break
        }
    }

    private static func runUpdateScript() {
        guard let root = Bundle.main.object(forInfoDictionaryKey: "FFSourceRoot") as? String, !root.isEmpty else {
            showMessage(String(localized: "The source folder is unknown."), info: "")
            return
        }
        let script = URL(fileURLWithPath: root).appendingPathComponent("scripts/update-from-upstream.command")
        guard FileManager.default.isExecutableFile(atPath: script.path),
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            showMessage(String(localized: "The update script was not found."), info: script.path)
            return
        }
        NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func showMessage(_ message: String, info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.runModal()
    }
}
