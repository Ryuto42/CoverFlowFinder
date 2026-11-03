import SwiftUI
import AppKit

/// Finder's spring-loading: a file drag that rests on a folder (or a tab) opens it after a moment,
/// still dragging. One countdown at a time; it ends when the drag moves elsewhere or the mouse
/// button comes up.
@MainActor
final class SpringLoader {
    static let shared = SpringLoader()

    static let delay: TimeInterval = 1.0
    /// The end of the countdown blinks the target.
    private static let blinkDuration: TimeInterval = 0.3

    private struct Hover {
        let key: AnyHashable
        let owner: ObjectIdentifier?
        let start: Date
        let isTargeted: () -> Bool
        let blink: ((Bool) -> Void)?
        let open: () -> Void
    }

    private var hover: Hover?
    /// The target that just opened: resting on it doesn't open it again.
    private var firedKey: AnyHashable?
    private var timer: Timer?

    private init() {}

    /// Starts the countdown for `key` unless it is already running. `isTargeted` is polled until
    /// the blink; `blink(false)` / `blink(true)` hide and show the target's highlight.
    func hover(
        _ key: AnyHashable,
        owner: AnyObject? = nil,
        isTargeted: @escaping () -> Bool = { true },
        blink: ((Bool) -> Void)? = nil,
        open: @escaping () -> Void
    ) {
        guard hover?.key != key, firedKey != key else { return }
        cancel()
        firedKey = nil
        hover = Hover(
            key: key,
            owner: owner.map(ObjectIdentifier.init),
            start: Date(),
            isTargeted: isTargeted,
            blink: blink,
            open: open
        )
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { SpringLoader.shared.tick() }
        }
        // Common modes: it must fire while the drag session tracks the mouse.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel(key: AnyHashable) {
        if hover?.key == key { cancel() }
    }

    func cancel(owner: AnyObject) {
        if hover?.owner == ObjectIdentifier(owner) { cancel() }
    }

    func cancel() {
        hover = nil
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let hover else {
            cancel()
            return
        }
        if NSEvent.pressedMouseButtons & 1 == 0 {
            cancel()
            firedKey = nil
            return
        }
        let elapsed = Date().timeIntervalSince(hover.start)
        let blinkStart = Self.delay - Self.blinkDuration
        if elapsed < blinkStart {
            if !hover.isTargeted() { cancel() }
            return
        }
        if elapsed < Self.delay {
            let phase = Int((elapsed - blinkStart) / (Self.blinkDuration / 4))
            hover.blink?(phase % 2 == 1)
            return
        }
        cancel()
        firedKey = hover.key
        hover.blink?(true)
        hover.open()
    }

    /// A real folder to browse into: not a package, an application or an archive's folder.
    static func canSpring(into item: FileItem) -> Bool {
        item.isDirectory
            && !item.isPackage
            && !item.isFromArchive
            && item.url.isFileURL
            && !NSWorkspace.shared.isFilePackage(atPath: item.url.path)
    }

    /// Opens `item` in `viewModel` if it is still listed there (a view that's being replaced can
    /// still report the old folder).
    static func open(_ item: FileItem, in viewModel: FileBrowserViewModel) {
        guard viewModel.filteredItems.contains(where: { $0.url == item.url }) else { return }
        viewModel.openItem(item)
    }
}

// MARK: - Drop targets

extension UnifiedFolderDropDelegate {
    /// Spring-loads this folder while it is the drop target.
    func springLoad() {
        guard SpringLoader.canSpring(into: item) else { return }
        let binding = $dropTargetedItemID
        let item = item
        let viewModel = viewModel
        let springOpen = springOpen
        SpringLoader.shared.hover(
            item.url,
            isTargeted: { binding.wrappedValue == item.id },
            blink: { visible in
                if visible {
                    if binding.wrappedValue == nil { binding.wrappedValue = item.id }
                } else if binding.wrappedValue == item.id {
                    binding.wrappedValue = nil
                }
            },
            open: {
                if let springOpen {
                    springOpen(item)
                } else {
                    SpringLoader.open(item, in: viewModel)
                }
            }
        )
    }
}

extension FileTableCoordinator {
    /// Spring-loads the folder row the drop is proposed on (nil: not on a folder row).
    func springLoad(_ tableView: NSTableView, folder: FileItem?) {
        guard let folder, SpringLoader.canSpring(into: folder),
              !DropHelper.dragSourceURLs().contains(folder.url) else {
            SpringLoader.shared.cancel(owner: tableView)
            return
        }
        let viewModel = viewModel
        SpringLoader.shared.hover(folder.url, owner: tableView) {
            SpringLoader.open(folder, in: viewModel)
        }
    }
}
