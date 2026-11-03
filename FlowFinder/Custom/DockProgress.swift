import AppKit

/// Shows the combined progress of running file operations on the Dock icon.
@MainActor
final class DockProgress {
    static let shared = DockProgress()

    private var tracked: [ObjectIdentifier: (progress: Progress, start: Date)] = [:]
    private var timer: Timer?
    private var tileView: DockProgressTileView?
    private let showDelay: TimeInterval = 0.5

    func track(_ progress: Progress) {
        tracked[ObjectIdentifier(progress)] = (progress, Date())
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { DockProgress.shared.tick() }
        }
    }

    private func tick() {
        tracked = tracked.filter { FileOperationEngine.isRunning($0.value.progress) }
        guard !tracked.isEmpty else {
            timer?.invalidate()
            timer = nil
            hide()
            return
        }
        guard AppSettings.shared.showDockProgress else {
            hide()
            return
        }
        guard tileView != nil || tracked.values.contains(where: { -$0.start.timeIntervalSinceNow >= showDelay }) else { return }
        let fractions = tracked.values.map { min(max($0.progress.fractionCompleted, 0), 1) }
        show(fractions.reduce(0, +) / Double(fractions.count))
    }

    private func show(_ fraction: Double) {
        let dockTile = NSApp.dockTile
        if tileView == nil {
            let view = DockProgressTileView(frame: NSRect(origin: .zero, size: dockTile.size))
            tileView = view
            dockTile.contentView = view
        }
        tileView?.fraction = fraction
        dockTile.display()
    }

    private func hide() {
        guard tileView != nil else { return }
        tileView = nil
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
    }
}

final class DockProgressTileView: NSView {
    var fraction: Double = 0

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)

        let barHeight = max(bounds.height * 0.1, 8)
        let inset = bounds.width * 0.1
        let barRect = NSRect(x: inset, y: bounds.height * 0.08, width: bounds.width - inset * 2, height: barHeight)
        let radius = barHeight / 2

        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: radius, yRadius: radius).fill()

        let inner = barRect.insetBy(dx: 1.5, dy: 1.5)
        let filled = NSRect(x: inner.minX, y: inner.minY, width: max(inner.height, inner.width * fraction), height: inner.height)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: filled, xRadius: inner.height / 2, yRadius: inner.height / 2).fill()
    }
}
