import AppKit

/// Geometry of moving the drag source window aside (pure functions, screen coordinates).
enum DragAsideGeometry {
    /// How far past the window's edge the cursor goes before the window moves aside.
    static let exitMargin: CGFloat = 20
    /// How much of the window stays on screen while it is aside.
    static let peek: CGFloat = 48

    enum Edge: Equatable { case left, right }

    static func cursorHasLeft(_ frame: CGRect, cursor: CGPoint) -> Bool {
        !frame.insetBy(dx: -exitMargin, dy: -exitMargin).contains(cursor)
    }

    /// The frame that leaves `peek` points of `frame` at the nearer side edge of `visibleFrame`
    /// (the window's screen, menu bar and Dock excluded), or nil when it can't be moved aside:
    /// a window larger than the screen, or one whose hidden part would show on another display.
    static func asideFrame(for frame: CGRect, visibleFrame: CGRect, otherScreens: [CGRect]) -> (edge: Edge, frame: CGRect)? {
        guard frame.width > peek,
              frame.width <= visibleFrame.width + 1,
              frame.height <= visibleFrame.height + 1 else { return nil }
        let leftFirst = frame.midX - visibleFrame.minX <= visibleFrame.maxX - frame.midX
        for edge in leftFirst ? [Edge.left, .right] : [.right, .left] {
            let x = edge == .left ? visibleFrame.minX + peek - frame.width : visibleFrame.maxX - peek
            let target = CGRect(x: x, y: frame.minY, width: frame.width, height: frame.height)
            let hidden = edge == .left
                ? CGRect(x: target.minX, y: target.minY, width: frame.width - peek, height: frame.height)
                : CGRect(x: target.minX + peek, y: target.minY, width: frame.width - peek, height: frame.height)
            if otherScreens.contains(where: { $0.intersects(hidden) }) { continue }
            return (edge, target)
        }
        return nil
    }

    /// Whether the cursor is over the part of the aside window left on screen.
    static func cursorIsOverPeek(asideFrame: CGRect, visibleFrame: CGRect, cursor: CGPoint) -> Bool {
        asideFrame.intersection(visibleFrame).contains(cursor)
    }
}

/// While a file drag that started in this app leaves its window, slides the window to the
/// nearer screen edge so what's behind it can take the drop; brings it back when the drag ends
/// or the cursor rests on the part left on screen. Driven by `InternalDragState`.
@MainActor
final class DragAsideController {
    static let shared = DragAsideController()

    private enum Phase { case idle, inPlace, aside }

    private static let pollInterval: TimeInterval = 1.0 / 30
    private static let animationDuration: TimeInterval = 0.25
    private static let hoverReturnDelay: TimeInterval = 0.3

    private var phase = Phase.idle
    private weak var window: NSWindow?
    private var originalOrigin = CGPoint.zero
    private var originalFrame = CGRect.zero
    private var currentAside = CGRect.zero
    private var visibleFrame = CGRect.zero
    /// After returning on hover, the cursor must come into the window before it can go aside again.
    private var needsEnterBeforeAside = false
    private var leftPeek = false
    private var hoverStartedAt: Date?
    private var pollTimer: Timer?
    private var animationTimer: Timer?

    private init() {}

    func dragDidBegin() {
        guard phase == .idle, AppSettings.shared.dragMovesWindowAside,
              !Self.stageManagerEnabled,
              let window = Self.sourceWindow(),
              window.isVisible, !window.isMiniaturized, !window.styleMask.contains(.fullScreen),
              window.sheetParent == nil, window.parent == nil else { return }
        self.window = window
        originalFrame = window.frame
        originalOrigin = window.frame.origin
        needsEnterBeforeAside = false
        phase = .inPlace
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { _ in
            MainActor.assumeIsolated { DragAsideController.shared.poll() }
        }
        // Common modes: the drag session runs its own tracking loop.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func dragDidEnd() {
        guard phase != .idle else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        let wasAside = phase == .aside || animationTimer != nil
        phase = .idle
        hoverStartedAt = nil
        if wasAside, let window {
            animate(window, to: originalOrigin)
        }
        window = nil
    }

    private func poll() {
        guard let window, window.isVisible else { return dragDidEnd() }
        if NSEvent.pressedMouseButtons & 1 == 0 { return dragDidEnd() }
        let cursor = NSEvent.mouseLocation
        switch phase {
        case .idle:
            break
        case .inPlace:
            if needsEnterBeforeAside {
                if originalFrame.contains(cursor) { needsEnterBeforeAside = false }
                return
            }
            guard animationTimer == nil, DragAsideGeometry.cursorHasLeft(originalFrame, cursor: cursor),
                  let screen = window.screen else { return }
            let others = NSScreen.screens.filter { $0 != screen }.map(\.frame)
            guard let aside = DragAsideGeometry.asideFrame(for: originalFrame, visibleFrame: screen.visibleFrame, otherScreens: others) else { return }
            currentAside = aside.frame
            visibleFrame = screen.visibleFrame
            leftPeek = false
            hoverStartedAt = nil
            phase = .aside
            animate(window, to: aside.frame.origin)
        case .aside:
            guard animationTimer == nil else { return }
            let overPeek = DragAsideGeometry.cursorIsOverPeek(asideFrame: currentAside, visibleFrame: visibleFrame, cursor: cursor)
            guard overPeek else {
                leftPeek = true
                hoverStartedAt = nil
                return
            }
            guard leftPeek else { return }
            let start = hoverStartedAt ?? Date()
            hoverStartedAt = start
            if Date().timeIntervalSince(start) >= Self.hoverReturnDelay {
                phase = .inPlace
                needsEnterBeforeAside = true
                hoverStartedAt = nil
                animate(window, to: originalOrigin)
            }
        }
    }

    private func animate(_ window: NSWindow, to target: CGPoint) {
        animationTimer?.invalidate()
        let start = window.frame.origin
        let startedAt = Date()
        let duration = Self.animationDuration
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
            MainActor.assumeIsolated {
                let t = min(1, Date().timeIntervalSince(startedAt) / duration)
                let eased = t * t * (3 - 2 * t)
                window.setFrameOrigin(CGPoint(x: start.x + (target.x - start.x) * eased,
                                              y: start.y + (target.y - start.y) * eased))
                if t >= 1 {
                    timer.invalidate()
                    if DragAsideController.shared.animationTimer === timer {
                        DragAsideController.shared.animationTimer = nil
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    /// The app window under the cursor (where the drag started), else the key window.
    private static func sourceWindow() -> NSWindow? {
        let number = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
        return NSApp.window(withWindowNumber: number) ?? NSApp.keyWindow
    }

    private static var stageManagerEnabled: Bool {
        CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString) as? Bool ?? false
    }
}
