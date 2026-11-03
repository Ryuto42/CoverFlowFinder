import SwiftUI
import AppKit

/// Back / Forward from trackpad swipes (two-finger scroll swipes and three-finger swipes), the
/// mouse's back / forward buttons and Backspace, for the pane under the pointer.
@MainActor
final class SwipeNavigator {
    static let shared = SwipeNavigator()

    private var monitors: [Any] = []
    private let anchors = NSHashTable<SwipePaneAnchorView>.weakObjects()
    /// The swipe being tracked by `trackSwipeEvent`, until it commits or ends.
    private var isTrackingSwipe = false

    /// Share of the gesture that commits the swipe, without waiting for the fingers to lift.
    private static let commitAmount: CGFloat = 0.3
    /// Share that still commits when the fingers lift.
    private static let releaseAmount: CGFloat = 0.14

    private enum Direction {
        case back, forward
    }

    private struct Target {
        let viewModel: FileBrowserViewModel
        let anchor: SwipePaneAnchorView?
    }

    func install() {
        guard monitors.isEmpty else { return }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { event in
            SwipeNavigator.shared.handleScroll(event) ? nil : event
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .swipe, handler: { event in
            SwipeNavigator.shared.handleSwipe(event) ? nil : event
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown, handler: { event in
            SwipeNavigator.shared.handleMouseButton(event) ? nil : event
        }) {
            monitors.append(monitor)
        }
    }

    func register(_ anchor: SwipePaneAnchorView) {
        anchors.add(anchor)
    }

    func unregister(_ anchor: SwipePaneAnchorView) {
        anchors.remove(anchor)
    }

    /// The other pane of the split tab `viewModel` is shown in, if it is in one.
    func otherPane(of viewModel: FileBrowserViewModel) -> FileBrowserViewModel? {
        let live = anchors.allObjects.filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor && $0.viewModel != nil }
        guard let window = live.first(where: { $0.viewModel === viewModel })?.window else { return nil }
        let others = live.filter { $0.window === window && $0.viewModel !== viewModel }.compactMap(\.viewModel)
        return others.count == 1 ? others[0] : nil
    }

    /// Moves the keyboard focus into `viewModel`'s pane (a click on a split tab's pane in the tab
    /// bar): its list or Cover Flow takes it; for the other views the window keeps it, so the pane's
    /// keyboard handler gets the keys.
    func focusPane(of viewModel: FileBrowserViewModel) {
        DispatchQueue.main.async {
            let live = self.anchors.allObjects.filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
            guard let anchor = live.first(where: { $0.viewModel === viewModel }),
                  let window = anchor.window, let contentView = window.contentView else { return }
            let paneFrame = anchor.convert(anchor.bounds, to: nil)
            var best: NSView?
            var bestArea: CGFloat = 0
            func visit(_ view: NSView) {
                if !view.isHiddenOrHasHiddenAncestor, view is NSTableView || view is CoverFlowNSView {
                    let frame = view.convert(view.visibleRect, to: nil)
                    let area = frame.width * frame.height
                    if paneFrame.contains(NSPoint(x: frame.midX, y: frame.midY)), area > bestArea, view.acceptsFirstResponder {
                        best = view
                        bestArea = area
                    }
                    return
                }
                view.subviews.forEach(visit)
            }
            visit(contentView)
            if let best {
                window.makeFirstResponder(best)
            } else if let responder = window.firstResponder as? NSView,
                      !paneFrame.contains(responder.convert(responder.bounds, to: nil)),
                      KeyboardResponderKind.classify(responder) != .textEditing {
                window.makeFirstResponder(nil)
            }
        }
    }

    // MARK: Keyboard

    /// Backspace: Back in the active pane. Cover Flow handles its own keys (its type-ahead comes
    /// first) and calls this with its view model.
    static func goBackFromKeyboard(in window: NSWindow?, viewModel: FileBrowserViewModel? = nil) -> Bool {
        guard AppSettings.shared.backspaceGoesBack else { return false }
        if viewModel == nil, window?.firstResponder is CoverFlowNSView { return false }
        guard let target = viewModel ?? MenuValidationState.shared.context(for: window)?.viewModel else { return false }
        if target.canGoBack {
            target.goBack()
        } else {
            NSSound.beep()
        }
        return true
    }

    // MARK: Events

    /// AppKit hands a scroll gesture's later events to the scroll view directly (responsive
    /// scrolling), so the swipe has to be taken over from its first event with `trackSwipeEvent`.
    private func handleScroll(_ event: NSEvent) -> Bool {
        guard event.phase.contains(.began), !isTrackingSwipe,
              event.scrollingDeltaX != 0, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY),
              let window = event.window,
              let target = swipeTarget(for: event) else { return false }
        let canGoBack = target.viewModel.canGoBack
        let canGoForward = target.viewModel.canGoForward
        guard canGoBack || canGoForward,
              !canScrollSideways(event, in: window, towardsBack: fingerDeltaX(event) > 0) else { return false }

        isTrackingSwipe = true
        var committed = false
        event.trackSwipeEvent(
            options: [.lockDirection, .clampGestureAmount],
            dampenAmountThresholdMin: canGoForward ? -1 : 0,
            max: canGoBack ? 1 : 0
        ) { [weak self] amount, phase, isComplete, stop in
            guard let self else { return }
            if !committed {
                SwipeIndicatorState.shared.update(target.viewModel, amount: min(max(amount / Self.commitAmount, -1), 1))
                if abs(amount) >= Self.commitAmount {
                    committed = true
                    SwipeIndicatorState.shared.update(nil, amount: 0)
                    self.navigate(target.viewModel, amount > 0 ? .back : .forward, anchor: target.anchor)
                    stop.pointee = true
                    self.isTrackingSwipe = false
                }
            }
            if !committed, phase == .ended, abs(amount) >= Self.releaseAmount {
                committed = true
                self.navigate(target.viewModel, amount > 0 ? .back : .forward, anchor: target.anchor)
            }
            if phase == .ended || phase == .cancelled || isComplete {
                SwipeIndicatorState.shared.update(nil, amount: 0)
                self.isTrackingSwipe = false
            }
        }
        return true
    }

    /// The pane a two-finger swipe starting with `event` would navigate.
    private func swipeTarget(for event: NSEvent) -> Target? {
        guard AppSettings.shared.swipeToNavigate,
              NSEvent.isSwipeTrackingFromScrollEventsEnabled,
              let window = event.window,
              acceptsNavigation(in: window),
              !isOverHorizontalScroller(event, in: window),
              let target = target(at: event.locationInWindow, in: window),
              target.viewModel.canGoBack || target.viewModel.canGoForward else { return nil }
        return target
    }

    /// Sideways finger travel: positive to the right (Back), whatever the scroll direction setting.
    private func fingerDeltaX(_ event: NSEvent) -> CGFloat {
        event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
    }

    /// Three-finger swipes ("Swipe between pages" set to three fingers).
    private func handleSwipe(_ event: NSEvent) -> Bool {
        guard event.deltaX != 0,
              AppSettings.shared.swipeToNavigate,
              let window = event.window,
              acceptsNavigation(in: window),
              let target = target(at: event.locationInWindow, in: window) else { return false }
        navigate(target.viewModel, event.deltaX > 0 ? .back : .forward, anchor: target.anchor)
        return true
    }

    private func handleMouseButton(_ event: NSEvent) -> Bool {
        let direction: Direction
        switch event.buttonNumber {
        case 3: direction = .back
        case 4: direction = .forward
        default: return false
        }
        guard let window = event.window,
              KeyboardManager.shared.isBrowserWindow(window),
              window.attachedSheet == nil,
              let target = target(at: event.locationInWindow, in: window) else { return false }
        navigate(target.viewModel, direction, anchor: target.anchor)
        return true
    }

    private func navigate(_ viewModel: FileBrowserViewModel, _ direction: Direction, anchor: SwipePaneAnchorView?) {
        anchor?.onActivate?()
        switch direction {
        case .back:
            if viewModel.canGoBack { viewModel.goBack() } else { NSSound.beep() }
        case .forward:
            if viewModel.canGoForward { viewModel.goForward() } else { NSSound.beep() }
        }
    }

    // MARK: Targeting

    private func acceptsNavigation(in window: NSWindow) -> Bool {
        KeyboardManager.shared.isBrowserWindow(window)
            && window.attachedSheet == nil
            && NSApp.modalWindow == nil
            && KeyboardResponderKind.classify(window.firstResponder) != .textEditing
    }

    /// The pane under `point` (window coordinates); the active pane where none is registered (Dual
    /// and Quad Pane).
    private func target(at point: NSPoint, in window: NSWindow) -> Target? {
        let candidates = anchors.allObjects.filter { anchor in
            guard anchor.window === window, !anchor.isHiddenOrHasHiddenAncestor, anchor.viewModel != nil else { return false }
            return anchor.convert(anchor.bounds, to: nil).contains(point)
        }
        if let anchor = candidates.min(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }),
           let viewModel = anchor.viewModel {
            return Target(viewModel: viewModel, anchor: anchor)
        }
        guard let viewModel = MenuValidationState.shared.context(for: window)?.viewModel else { return nil }
        return Target(viewModel: viewModel, anchor: nil)
    }

    /// Cover Flow scrolls its covers sideways: swipes there move the covers.
    private func isOverHorizontalScroller(_ event: NSEvent, in window: NSWindow) -> Bool {
        views(under: event, in: window).contains { $0 is CoverFlowNSView }
    }

    /// Like Safari: a view that scrolls sideways (Column view, a wide list) takes the swipe until it
    /// reaches its edge in the swipe's direction.
    private func canScrollSideways(_ event: NSEvent, in window: NSWindow, towardsBack: Bool) -> Bool {
        for case let scrollView as NSScrollView in views(under: event, in: window) {
            guard let documentView = scrollView.documentView else { continue }
            let visible = scrollView.contentView.bounds
            let content = documentView.frame
            guard content.width > visible.width + 1 else { continue }
            let atLeftEdge = visible.minX <= content.minX + 1
            let atRightEdge = visible.maxX >= content.maxX - 1
            if towardsBack ? !atLeftEdge : !atRightEdge { return true }
        }
        return false
    }

    private func views(under event: NSEvent, in window: NSWindow) -> [NSView] {
        guard let frameView = window.contentView?.superview ?? window.contentView else { return [] }
        let point = frameView.superview.map { $0.convert(event.locationInWindow, from: nil) } ?? event.locationInWindow
        var result: [NSView] = []
        var current = frameView.hitTest(point)
        while let view = current {
            result.append(view)
            current = view.superview
        }
        return result
    }
}

// MARK: - Pane anchor

/// Marks a pane's frame and view model for swipes and the mouse's back / forward buttons, and
/// shows the swipe's arrow over it.
struct SwipeNavigationPane: ViewModifier {
    let viewModel: FileBrowserViewModel
    var onActivate: (() -> Void)?
    @State private var trailingInset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background(SwipePaneAnchor(viewModel: viewModel, onActivate: onActivate))
            .onPreferenceChange(SwipeIndicatorTrailingInsetKey.self) { trailingInset = $0 }
            .overlay(
                SwipeIndicatorOverlay(viewModel: viewModel)
                    .padding(.trailing, trailingInset)
                    .allowsHitTesting(false)
            )
    }
}

/// Width at the pane's trailing edge the swipe arrow keeps clear of (the Cover Flow side panel).
struct SwipeIndicatorTrailingInsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct SwipePaneAnchor: NSViewRepresentable {
    let viewModel: FileBrowserViewModel
    let onActivate: (() -> Void)?

    func makeNSView(context: Context) -> SwipePaneAnchorView {
        let view = SwipePaneAnchorView()
        view.viewModel = viewModel
        view.onActivate = onActivate
        return view
    }

    func updateNSView(_ nsView: SwipePaneAnchorView, context: Context) {
        nsView.viewModel = viewModel
        nsView.onActivate = onActivate
    }

    static func dismantleNSView(_ nsView: SwipePaneAnchorView, coordinator: ()) {
        SwipeNavigator.shared.unregister(nsView)
    }
}

final class SwipePaneAnchorView: NSView {
    weak var viewModel: FileBrowserViewModel?
    var onActivate: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            SwipeNavigator.shared.register(self)
        } else {
            SwipeNavigator.shared.unregister(self)
        }
    }
}

// MARK: - Indicator

@MainActor
final class SwipeIndicatorState: ObservableObject {
    static let shared = SwipeIndicatorState()

    @Published private(set) var target: ObjectIdentifier?
    /// Positive: Back (left edge); negative: Forward (right edge).
    @Published private(set) var amount: CGFloat = 0

    func update(_ viewModel: FileBrowserViewModel?, amount: CGFloat) {
        let id = viewModel.map(ObjectIdentifier.init)
        if target != id { target = id }
        if self.amount != amount { self.amount = amount }
    }
}

private struct SwipeIndicatorOverlay: View {
    let viewModel: FileBrowserViewModel
    @ObservedObject private var state = SwipeIndicatorState.shared

    private let size: CGFloat = 44

    var body: some View {
        let amount = state.target == ObjectIdentifier(viewModel) ? state.amount : 0
        let progress = min(abs(amount), 1)
        ZStack {
            if amount != 0 {
                Circle()
                    .fill(progress >= 0.99 ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.regularMaterial))
                    .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                    .overlay(
                        Image(systemName: amount > 0 ? "chevron.left" : "chevron.right")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(progress >= 0.99 ? Color.white : Color.primary)
                    )
                    .frame(width: size, height: size)
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
                    .opacity(Double(min(progress * 2, 1)))
                    .offset(x: (amount > 0 ? 1 : -1) * (-size + progress * (size + 16)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: amount > 0 ? .leading : .trailing)
            }
        }
    }
}
