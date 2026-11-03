import SwiftUI
import AppKit
import DiskArbitration

// MARK: - Disk image volumes

enum DiskImageVolumes {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var diskImageDevices: [String: Bool] = [:]

    /// The mount point of the disk image volume `url` is on, if it is on one. Reads only the mount
    /// table and Disk Arbitration (never the volume), so it is fine on the main thread.
    static func diskImageVolumeRoot(containing url: URL) -> URL? {
        let path = VolumePaths.pathKey(url)
        guard path.hasPrefix("/Volumes/") else { return nil }
        let mount = SidebarMountTable.current().mounts
            .filter { $0.path != "/" && (path == $0.path || path.hasPrefix($0.path + "/")) }
            .max { $0.path.count < $1.path.count }
        guard let mount, isDiskImage(device: mount.source) else { return nil }
        return URL(fileURLWithPath: mount.path, isDirectory: true)
    }

    private static func isDiskImage(device: String) -> Bool {
        guard device.hasPrefix("/dev/disk") else { return false }
        lock.lock()
        if let known = diskImageDevices[device] {
            lock.unlock()
            return known
        }
        lock.unlock()
        var result = false
        if let session = DASessionCreate(kCFAllocatorDefault),
           let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, String(device.dropFirst("/dev/".count))),
           let description = DADiskCopyDescription(disk) as? [CFString: Any] {
            let model = description[kDADiskDescriptionDeviceModelKey] as? String ?? ""
            let transport = description[kDADiskDescriptionDeviceProtocolKey] as? String ?? ""
            result = model.contains("Disk Image") || transport.contains("Disk Image")
        }
        lock.lock()
        diskImageDevices[device] = result
        lock.unlock()
        return result
    }
}

// MARK: - Mounting

/// Opens disk images the way Finder does: mounts them (in the background, with progress in the
/// path bar) and shows the volume in a new tab, in its window layout. Encrypted images, and
/// anything `hdiutil` can't attach on its own (a license agreement), go to DiskImageMounter.
@MainActor
final class DiskImageMounter: ObservableObject {
    static let shared = DiskImageMounter()

    struct Activity: Identifiable {
        let id = UUID()
        let imageURL: URL
        weak var viewModel: FileBrowserViewModel?
        var process: Process?
        var isVisible = false
        var isCancelled = false
    }

    @Published private(set) var activities: [Activity] = []

    private static let imageExtensions: Set<String> = ["dmg", "sparseimage", "sparsebundle"]

    static func canMount(_ item: FileItem) -> Bool {
        let ext = item.url.pathExtension.lowercased()
        return !item.isFromArchive && item.url.isFileURL && imageExtensions.contains(ext)
            && (ext == "sparsebundle" || !item.isDirectory)
    }

    /// Opens `item` when it is a disk image; false for anything else.
    func open(_ item: FileItem, from viewModel: FileBrowserViewModel) -> Bool {
        guard Self.canMount(item) else { return false }
        let imageURL = item.url.standardizedFileURL
        guard !activities.contains(where: { $0.imageURL == imageURL }) else { return true }
        let activity = Activity(imageURL: imageURL, viewModel: viewModel)
        let id = activity.id
        activities.append(activity)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, let index = self.activities.firstIndex(where: { $0.id == id }) else { return }
            self.activities[index].isVisible = true
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Self.mount(imageURL) { process in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let mounter = DiskImageMounter.shared
                        guard let index = mounter.activities.firstIndex(where: { $0.id == id }) else {
                            process.terminate()
                            return
                        }
                        mounter.activities[index].process = process
                    }
                }
            }
            var layoutFolder: URL?
            if case .mounted(let mountPoint) = outcome {
                layoutFolder = mountPoint
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let finish = {
                        DiskImageMounter.shared.finish(id, outcome: outcome)
                    }
                    if let layoutFolder {
                        // Read the layout first, so the tab opens in it rather than the grid
                        FolderLayoutStore.shared.refresh(layoutFolder, completion: finish)
                    } else {
                        finish()
                    }
                }
            }
        }
        return true
    }

    func cancel(_ id: UUID) {
        guard let index = activities.firstIndex(where: { $0.id == id }) else { return }
        activities[index].isCancelled = true
        activities[index].process?.terminate()
        activities.remove(at: index)
    }

    private enum Outcome {
        case mounted(URL)
        case handOff
    }

    private func finish(_ id: UUID, outcome: Outcome) {
        guard let index = activities.firstIndex(where: { $0.id == id }) else {
            // Cancelled: an image that got mounted anyway stays mounted, as with Finder.
            return
        }
        let activity = activities.remove(at: index)
        switch outcome {
        case .handOff:
            NSWorkspace.shared.open(activity.imageURL)
        case .mounted(let mountPoint):
            guard let viewModel = activity.viewModel else { return }
            show(mountPoint, from: viewModel)
        }
    }

    /// Selects a tab already showing the volume, or opens one in its window layout.
    private func show(_ mountPoint: URL, from viewModel: FileBrowserViewModel) {
        let key = VolumePaths.pathKey(mountPoint)
        let store = TabSession.store(containing: viewModel) ?? TabSession.frontWindow?.1
        if let store, let tab = store.tabs.first(where: { VolumePaths.pathKey($0.focusedViewModel.currentPath) == key }) {
            store.selectedTabId = tab.id
            return
        }
        FolderOpenRequest.post(.openFolderInNewTab, folder: mountPoint, from: viewModel)
        if let store, let tab = store.tabs.last(where: { VolumePaths.pathKey($0.viewModel.currentPath) == key }),
           FolderLayoutStore.shared.layout(for: mountPoint) != nil {
            tab.viewModel.viewMode = .icons
        }
    }

    // MARK: hdiutil

    /// Runs off the main thread: the image's mount point when it is (or now got) mounted.
    nonisolated private static func mount(_ imageURL: URL, started: @escaping (Process) -> Void) -> Outcome {
        if let mountPoint = existingMountPoint(of: imageURL) {
            return .mounted(mountPoint)
        }
        if let encrypted = runPlist(["isencrypted", "-plist", imageURL.path])?["encrypted"] as? Bool, encrypted {
            return .handOff
        }
        // Not -nobrowse: the volume shows in the sidebar like one Finder mounted.
        guard let result = runPlist(["attach", "-plist", "-noautoopen", imageURL.path], started: started),
              let mountPoint = mountPoint(in: result) else { return .handOff }
        return .mounted(mountPoint)
    }

    nonisolated private static func existingMountPoint(of imageURL: URL) -> URL? {
        guard let info = runPlist(["info", "-plist"]), let images = info["images"] as? [[String: Any]] else { return nil }
        let target = imageURL.resolvingSymlinksInPath().path
        for image in images {
            guard let path = image["image-path"] as? String,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().path == target else { continue }
            if let mountPoint = mountPoint(in: image) { return mountPoint }
        }
        return nil
    }

    nonisolated private static func mountPoint(in plist: [String: Any]) -> URL? {
        let entities = plist["system-entities"] as? [[String: Any]] ?? []
        let path = entities.compactMap { $0["mount-point"] as? String }.first
        return path.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    nonisolated private static func runPlist(_ arguments: [String], started: ((Process) -> Void)? = nil) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        // No terminal: a password or license prompt fails instead of waiting.
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        started?(process)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        return plist as? [String: Any]
    }
}

// MARK: - Path bar

/// In the path bar: the progress of a disk image being opened from this pane, or Eject while it
/// shows a disk image's volume.
struct DiskImagePathBarAccessory: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    @ObservedObject private var mounter = DiskImageMounter.shared
    @Environment(\.browserWindow) private var browserWindow

    var body: some View {
        HStack(spacing: 6) {
            if let activity = mounter.activities.first(where: { $0.isVisible && $0.viewModel === viewModel }) {
                ProgressView()
                    .controlSize(.small)
                Text("Opening “\(activity.imageURL.lastPathComponent)”…")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    mounter.cancel(activity.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Stop")
            }
            if let volume = DiskImageVolumes.diskImageVolumeRoot(containing: viewModel.currentPath) {
                Button {
                    let name = (try? volume.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? volume.lastPathComponent
                    SidebarVolumeEjector.eject(
                        SidebarLocation(name: name, url: volume, isEjectable: true, isNetwork: false),
                        window: browserWindow?.window
                    )
                } label: {
                    Label("Eject", systemImage: "eject")
                        .labelStyle(.iconOnly)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Eject “\(volume.lastPathComponent)”"))
            }
        }
    }
}
