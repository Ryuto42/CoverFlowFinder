import SwiftUI
import AppKit

/// Cover Flow beside the list: the list on the left, a tall panel on the right with the covers
/// above the selection's info, scrolling as one. With several items selected, `grid` replaces the
/// covers. Without the panel (`showsPanel` false) the strip stays hidden, keeping keyboard focus.
struct CoverFlowSidePanelLayout<Strip: View, List: View, Info: View, Grid: View>: View {
    let strip: Strip
    let list: List
    let info: Info?
    let grid: Grid?
    var showsPanel = true

    @EnvironmentObject private var settings: AppSettings
    @State private var liveWidth: CGFloat?
    @State private var dragStartWidth: CGFloat?
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var scrollMetrics = PanelScrollMetrics()

    private let handleWidth: CGFloat = 8
    private let minPanelWidth: CGFloat = 260
    private let minListWidth: CGFloat = 200
    private let maxPanelFraction: CGFloat = 0.6

    var body: some View {
        if showsPanel {
            panelLayout
        } else {
            HStack(spacing: 0) {
                list
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                strip
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .allowsHitTesting(false)
            }
        }
    }

    private var panelLayout: some View {
        GeometryReader { geometry in
            let maxWidth = min(geometry.size.width * maxPanelFraction, geometry.size.width - handleWidth - minListWidth)
            let panelWidth = clamp(liveWidth ?? CGFloat(settings.coverFlowPanelWidth), max: maxWidth)
            let showsGrid = grid != nil
            let stripHeight = info == nil && !showsGrid ? geometry.size.height : panelWidth * 1.1

            HStack(spacing: 0) {
                list
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .preference(key: SwipeIndicatorTrailingInsetKey.self, value: panelWidth + handleWidth)

                CoverFlowPanelResizeHandle(
                    width: handleWidth,
                    onDrag: { delta in
                        if dragStartWidth == nil {
                            dragStartWidth = panelWidth
                        }
                        // The panel is on the right: dragging left widens it
                        liveWidth = clamp((dragStartWidth ?? panelWidth) - delta, max: maxWidth)
                    },
                    onDragEnded: {
                        if let liveWidth {
                            settings.coverFlowPanelWidth = Double(liveWidth)
                        }
                        liveWidth = nil
                        dragStartWidth = nil
                    }
                )
                .frame(width: handleWidth)
                .frame(maxHeight: .infinity)

                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        // Kept while hidden so the covers (and keyboard focus) survive a multiple selection
                        strip
                            .frame(height: showsGrid ? 0 : stripHeight)
                            .opacity(showsGrid ? 0 : 1)
                            .allowsHitTesting(!showsGrid)
                        if let grid {
                            grid
                        } else if let info {
                            info
                        }
                    }
                    .frame(width: panelWidth)
                    .frame(minHeight: geometry.size.height, alignment: .top)
                }
                .scrollPosition($scrollPosition)
                // The covers are an AppKit view drawn above the scroll view's own indicator, which then showed
                // only beside the info below them: draw the indicator on top of the whole panel instead.
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize)
                .onScrollGeometryChange(for: PanelScrollMetrics.self) { geometry in
                    PanelScrollMetrics(
                        offset: geometry.contentOffset.y + geometry.contentInsets.top,
                        contentHeight: geometry.contentSize.height,
                        visibleHeight: geometry.containerSize.height
                    )
                } action: { _, metrics in
                    scrollMetrics = metrics
                }
                .overlay(alignment: .trailing) {
                    PanelScrollIndicator(metrics: scrollMetrics) { offset in
                        scrollPosition.scrollTo(y: offset)
                    }
                    .frame(width: PanelScrollIndicatorView.trackWidth)
                    .frame(maxHeight: .infinity)
                }
                .onChange(of: showsGrid) { _, _ in
                    scrollPosition.scrollTo(edge: .top)
                }
                .frame(width: panelWidth)
                .frame(maxHeight: .infinity)
                .uiBackground(.panelBottom)
            }
        }
    }

    private func clamp(_ width: CGFloat, max maxWidth: CGFloat) -> CGFloat {
        if maxWidth < minPanelWidth {
            return Swift.max(maxWidth, 0)
        }
        return Swift.min(Swift.max(width, minPanelWidth), maxWidth)
    }
}

/// The border between the list and the panel. An AppKit view, so the drag and the resize cursor work next to the
/// list's and the covers' own AppKit views (a SwiftUI gesture there was hard to catch).
struct CoverFlowPanelResizeHandle: NSViewRepresentable {
    let width: CGFloat
    let onDrag: (CGFloat) -> Void
    let onDragEnded: () -> Void

    func makeNSView(context: Context) -> PanelResizeHandleView {
        let view = PanelResizeHandleView()
        view.onDrag = onDrag
        view.onDragEnded = onDragEnded
        return view
    }

    func updateNSView(_ view: PanelResizeHandleView, context: Context) {
        view.onDrag = onDrag
        view.onDragEnded = onDragEnded
    }
}

final class PanelResizeHandleView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    private var dragStartX: CGFloat?
    private var isHovering = false {
        didSet { if isHovering != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var resizeCursor: NSCursor { NSCursor.columnResize }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: resizeCursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
            owner: self
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        resizeCursor.set()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        if dragStartX == nil { isHovering = false }
    }

    override func mouseDown(with event: NSEvent) {
        dragStartX = NSEvent.mouseLocation.x
        resizeCursor.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartX else { return }
        onDrag?(NSEvent.mouseLocation.x - dragStartX)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStartX != nil else { return }
        dragStartX = nil
        NSCursor.pop()
        onDragEnded?()
        let location = convert(event.locationInWindow, from: nil)
        isHovering = bounds.contains(location)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: floor(bounds.midX), y: 0, width: 1, height: bounds.height).fill()
        let grip = NSRect(x: bounds.midX - 1.5, y: bounds.midY - 18, width: 3, height: 36)
        NSColor.secondaryLabelColor.withAlphaComponent(isHovering || dragStartX != nil ? 0.9 : 0.6).setFill()
        NSBezierPath(roundedRect: grip, xRadius: 1.5, yRadius: 1.5).fill()
    }
}

// MARK: - Panel scroll indicator

struct PanelScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var contentHeight: CGFloat = 0
    var visibleHeight: CGFloat = 0

    var isScrollable: Bool { contentHeight > visibleHeight + 1 && visibleHeight > 0 }
    var maxOffset: CGFloat { max(0, contentHeight - visibleHeight) }
}

/// An overlay scroller for the panel, drawn as an AppKit view above the whole scroll view (covers included).
/// Shown while scrolling or when the pointer is over it; the knob can be dragged and the track clicked.
struct PanelScrollIndicator: NSViewRepresentable {
    let metrics: PanelScrollMetrics
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> PanelScrollIndicatorView {
        let view = PanelScrollIndicatorView()
        view.onScroll = onScroll
        view.metrics = metrics
        return view
    }

    func updateNSView(_ view: PanelScrollIndicatorView, context: Context) {
        view.onScroll = onScroll
        view.metrics = metrics
    }
}

final class PanelScrollIndicatorView: NSView {
    static let trackWidth: CGFloat = 12
    private static let minKnobHeight: CGFloat = 24
    private static let inset: CGFloat = 3

    var onScroll: ((CGFloat) -> Void)?
    var metrics = PanelScrollMetrics() {
        didSet {
            guard metrics != oldValue else { return }
            if metrics.offset != oldValue.offset { flash() }
            needsDisplay = true
        }
    }

    private var isHovering = false
    private var isShown = false
    private var dragAnchor: (mouseY: CGFloat, offset: CGFloat)?
    private var hideWorkItem: DispatchWorkItem?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard metrics.isScrollable, !isHidden else { return nil }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        show()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        scheduleHide()
    }

    private var trackRect: NSRect {
        bounds.insetBy(dx: 0, dy: Self.inset)
    }

    private var knobRect: NSRect {
        guard metrics.isScrollable else { return .zero }
        let track = trackRect
        let height = max(Self.minKnobHeight, track.height * metrics.visibleHeight / metrics.contentHeight)
        let progress = min(max(metrics.offset / max(metrics.maxOffset, 1), 0), 1)
        let y = track.minY + (track.height - height) * progress
        let width: CGFloat = isHovering || dragAnchor != nil ? 8 : 6
        return NSRect(x: bounds.maxX - width - 2, y: y, width: width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isShown, metrics.isScrollable else { return }
        if isHovering || dragAnchor != nil {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.maxX - 11, y: trackRect.minY, width: 10, height: trackRect.height),
                         xRadius: 5, yRadius: 5).fill()
        }
        let knob = knobRect
        NSColor.labelColor.withAlphaComponent(isHovering || dragAnchor != nil ? 0.5 : 0.35).setFill()
        NSBezierPath(roundedRect: knob, xRadius: knob.width / 2, yRadius: knob.width / 2).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard metrics.isScrollable else { return }
        let point = convert(event.locationInWindow, from: nil)
        let knob = knobRect
        if !knob.contains(point) {
            // Clicking the track jumps there, centring the knob on the click
            let track = trackRect
            let fraction = (point.y - track.minY - knob.height / 2) / max(track.height - knob.height, 1)
            onScroll?(min(max(fraction, 0), 1) * metrics.maxOffset)
        }
        dragAnchor = (point.y, metrics.offset)
        show()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragAnchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        let travel = trackRect.height - knobRect.height
        guard travel > 0 else { return }
        let offset = dragAnchor.offset + (point.y - dragAnchor.mouseY) * metrics.maxOffset / travel
        onScroll?(min(max(offset, 0), metrics.maxOffset))
    }

    override func mouseUp(with event: NSEvent) {
        dragAnchor = nil
        needsDisplay = true
        scheduleHide()
    }

    private func flash() {
        show()
        scheduleHide()
    }

    private func show() {
        hideWorkItem?.cancel()
        isShown = true
        needsDisplay = true
    }

    private func scheduleHide() {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isHovering, self.dragAnchor == nil else { return }
            self.isShown = false
            self.needsDisplay = true
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}
