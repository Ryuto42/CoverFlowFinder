import AppKit

/// Uploads and downloads in iCloud, OneDrive and Google Drive start and finish without any change
/// the folder watcher sees, so the shown statuses are re-read every few seconds while a cloud folder is on screen.
@MainActor
final class CloudStatusLiveRefresh {
    static let shared = CloudStatusLiveRefresh()

    private static let interval: TimeInterval = 4
    private static let maxItemsPerPane = 500
    private var timer: Timer?

    func install() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated { CloudStatusLiveRefresh.shared.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refresh() {
        for store in TabSession.allStores {
            if let window = TabSession.window(of: store), !window.isVisible || window.isMiniaturized { continue }
            for viewModel in store.selectedTab.allViewModels {
                guard !viewModel.isInsideArchive,
                      CloudStatusManager.shared.isInICloud(viewModel.currentPath) else { continue }
                let urls = viewModel.items.lazy
                    .filter { $0.cloudStatus != nil }
                    .prefix(Self.maxItemsPerPane)
                    .map(\.url)
                CloudStatusManager.shared.invalidate(urls: Array(urls))
            }
        }
    }
}
