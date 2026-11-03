import AppKit

/// A File Provider folder in ~/Library/CloudStorage (OneDrive, Google Drive, Dropbox, Box…), listed in the
/// sidebar's Cloud section below iCloud Drive.
struct SidebarCloudLocation: Equatable {
    let name: String
    let url: URL

    var itemID: String { "cloud:\(url.path)" }

    static var storageURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("CloudStorage", isDirectory: true)
    }

    /// Blocking (reads the folder): call off the main thread.
    static func load(excluding iCloudURL: URL?, fileManager: FileManager = .default) -> [SidebarCloudLocation] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .localizedNameKey]
        guard let children = try? fileManager.contentsOfDirectory(
            at: storageURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        let excluded = iCloudURL?.standardizedFileURL.path
        let folders = children.filter { url in
            url.standardizedFileURL.path != excluded
                && url.lastPathComponent != "iCloud Drive"
                && (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        let providers = folders.map { provider(of: $0.lastPathComponent) }

        let locations = folders.enumerated().map { index, url in
            let folderName = url.lastPathComponent
            let provider = providers[index]
            let isShared = providers.filter { $0 == provider }.count > 1
            let localized = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName
            return SidebarCloudLocation(
                name: displayName(folderName: folderName, localizedName: localized, providerIsShared: isShared),
                url: url
            )
        }
        return locations.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func provider(of folderName: String) -> String {
        folderName.split(separator: "-", maxSplits: 1).first.map(String.init) ?? folderName
    }

    /// "OneDrive-Personal" is "OneDrive - Personal" (like Finder); "GoogleDrive-a@b.com" is "Google Drive", with the
    /// account only when there are several of the same service.
    static func displayName(folderName: String, localizedName: String?, providerIsShared: Bool) -> String {
        let parts = folderName.split(separator: "-", maxSplits: 1).map(String.init)
        let provider = parts.first ?? folderName
        let account = parts.count > 1 ? parts[1] : nil
        let providerName: String
        switch provider.lowercased() {
        case "onedrive":
            return account.map { "OneDrive - \($0)" } ?? "OneDrive"
        case "googledrive": providerName = "Google Drive"
        case "dropbox": providerName = "Dropbox"
        case "box": providerName = "Box"
        default:
            if let localizedName, !localizedName.isEmpty, localizedName != folderName { return localizedName }
            return account.map { "\(provider) - \($0)" } ?? folderName
        }
        if providerIsShared, let account { return "\(providerName) - \(account)" }
        return providerName
    }
}

/// Watches ~/Library/CloudStorage for providers being added or removed and refreshes the sidebar.
@MainActor
final class SidebarCloudStorageMonitor {
    static let shared = SidebarCloudStorageMonitor()

    private var source: DispatchSourceFileSystemObject?
    private var retryTimer: Timer?

    @discardableResult
    func start() -> Bool {
        guard source == nil else { return true }
        let descriptor = open(SidebarCloudLocation.storageURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // The folder appears when the first provider is set up.
            scheduleRetry()
            return false
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.source else { return }
                if source.data.contains(.delete) || source.data.contains(.rename) {
                    self.stop()
                    self.scheduleRetry()
                }
                SidebarEnvironmentStore.shared.requestRefresh()
            }
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
        return true
    }

    private func stop() {
        source?.cancel()
        source = nil
    }

    private func scheduleRetry() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { _ in
            MainActor.assumeIsolated {
                SidebarCloudStorageMonitor.shared.retryTimer = nil
                if SidebarCloudStorageMonitor.shared.start() {
                    SidebarEnvironmentStore.shared.requestRefresh()
                }
            }
        }
    }
}
