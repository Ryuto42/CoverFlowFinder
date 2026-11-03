import Cocoa
import FinderSync

/// Adds "Open in FlowFinder" to Finder's context menus (items, the empty area of a folder, the sidebar).
final class FinderSync: FIFinderSync {
    private static let appBundleID = "com.ryuto.FlowFinder"

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        switch menuKind {
        case .contextualMenuForItems, .contextualMenuForContainer, .contextualMenuForSidebar:
            let menu = NSMenu(title: "")
            let item = NSMenuItem(title: Self.menuTitle, action: #selector(openInFlowFinder(_:)), keyEquivalent: "")
            item.target = self
            if let appURL = Self.appURL {
                let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            menu.addItem(item)
            return menu
        default:
            return nil
        }
    }

    @objc private func openInFlowFinder(_ sender: AnyObject?) {
        let controller = FIFinderSyncController.default()
        var urls = controller.selectedItemURLs() ?? []
        if urls.isEmpty, let target = controller.targetedURL() {
            urls = [target]
        }
        guard !urls.isEmpty else { return }

        guard let appURL = Self.appURL else {
            openViaScheme(urls)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: configuration) { _, error in
            if error != nil {
                DispatchQueue.main.async { self.openViaScheme(urls) }
            }
        }
    }

    /// Fallback when the sandbox refuses to hand the files over: `flowfinder://open?path=…`.
    private func openViaScheme(_ urls: [URL]) {
        var components = URLComponents()
        components.scheme = "flowfinder"
        components.host = "open"
        components.queryItems = urls.map { URLQueryItem(name: "path", value: $0.path) }
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    /// The app this extension is embedded in (…/FlowFinder.app/Contents/PlugIns/X.appex), else by bundle ID.
    private static var appURL: URL? {
        let container = Bundle.main.bundleURL
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if container.pathExtension == "app" { return container }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleID)
    }

    private static var menuTitle: String {
        Locale.preferredLanguages.first?.hasPrefix("ja") == true ? "FlowFinder で開く" : "Open in FlowFinder"
    }
}
