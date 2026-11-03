import AppKit
import SwiftUI

/// The rubber-band rectangle drawn while drag-selecting, styled like the desktop's.
enum MarqueeStyle {
    static func colors(isDark: Bool) -> (fill: NSColor, stroke: NSColor) {
        if isDark {
            return (NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0.6))
        }
        let accent = NSColor.controlAccentColor
        return (accent.withAlphaComponent(0.15), accent.withAlphaComponent(0.6))
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

final class MarqueeOverlayView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let colors = MarqueeStyle.colors(isDark: MarqueeStyle.isDark(effectiveAppearance))
        colors.fill.setFill()
        bounds.fill()
        colors.stroke.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
    }
}

/// SwiftUI version of the rectangle, for the icon grid.
struct MarqueeRectangle: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colors = MarqueeStyle.colors(isDark: colorScheme == .dark)
        Rectangle()
            .fill(Color(nsColor: colors.fill))
            .overlay(Rectangle().strokeBorder(Color(nsColor: colors.stroke), lineWidth: 1))
            .allowsHitTesting(false)
    }
}

// MARK: - List

extension KeyboardTableView {
    /// Whether a drag from `point` on `row` should drag-select rather than drag the file: anywhere
    /// in the name column except on the icon and the name's text (Finder), or outside every column.
    func marqueeCanStart(at point: NSPoint, row: Int) -> Bool {
        let column = column(at: point)
        guard column >= 0 else { return true }
        guard tableColumns[column].identifier.rawValue == ListColumn.name.rawValue else { return false }
        guard let cell = view(atColumn: column, row: row, makeIfNecessary: false) as? NSTableCellView else { return false }
        let local = cell.convert(point, from: self)
        if let icon = cell.subviews.first(where: { $0 is NSImageView }), icon.frame.insetBy(dx: -2, dy: -2).contains(local) {
            return false
        }
        if let text = cell.textField {
            var frame = text.frame
            let textWidth = text.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: .greatestFiniteMagnitude, height: frame.height)).width ?? frame.width
            frame.size.width = min(frame.width, textWidth) + 4
            if frame.insetBy(dx: 0, dy: -2).contains(local) { return false }
        }
        return true
    }

    /// Drag-selects rows with a rubber band. Returns false (leaving the mouse-up queued) when the
    /// mouse is released before it moved far enough to count as a drag.
    @discardableResult
    func trackMarqueeSelection(from event: NSEvent) -> Bool {
        guard let window else { return false }
        let start = convert(event.locationInWindow, from: nil)
        let threshold: CGFloat = 4

        while true {
            guard let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: false) else { return false }
            if next.type == .leftMouseUp { return false }
            _ = NSApp.nextEvent(matching: [.leftMouseDragged], until: .distantPast, inMode: .eventTracking, dequeue: true)
            let point = convert(next.locationInWindow, from: nil)
            if hypot(point.x - start.x, point.y - start.y) >= threshold { break }
        }

        let modifiers = event.modifierFlags
        let toggles = modifiers.contains(.command)
        let extends = modifiers.contains(.shift)
        if !toggles && !extends {
            coordinator?.handleEmptySpaceClick()
        }
        window.makeFirstResponder(self)
        let base = (toggles || extends) ? selectedRowIndexes : IndexSet()

        let overlay = MarqueeOverlayView()
        coordinator?.beginMouseSelection(row: -1)
        defer {
            overlay.removeFromSuperview()
            coordinator?.endMouseSelection()
        }

        func update() {
            let current = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            var rect = NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                              width: abs(current.x - start.x), height: abs(current.y - start.y))
            rect = rect.intersection(bounds)
            if rect.isNull { rect = NSRect(origin: start, size: .zero) }
            if overlay.superview !== self || subviews.last !== overlay {
                addSubview(overlay, positioned: .above, relativeTo: nil)
            }
            overlay.frame = rect
            overlay.needsDisplay = true

            let range = rows(in: NSRect(x: rect.minX, y: rect.minY, width: max(rect.width, 1), height: max(rect.height, 1)))
            let hits = IndexSet(integersIn: Range(range) ?? 0..<0)
            let selection = toggles ? base.symmetricDifference(hits) : base.union(hits)
            if selection != selectedRowIndexes {
                selectRowIndexes(selection, byExtendingSelection: false)
            }
        }

        update()
        while true {
            let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: Date(timeIntervalSinceNow: 1.0 / 30), inMode: .eventTracking, dequeue: true)
            if next?.type == .leftMouseUp { break }
            autoscrollForMarquee(from: start)
            update()
        }
        return true
    }

    /// Scrolls while the pointer is near (or past) the top or bottom of the visible rows, only in
    /// the direction the band is being dragged (a drag up from the bottom row mustn't scroll down).
    private func autoscrollForMarquee(from start: NSPoint) {
        guard let window, let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        // The clip view's insets are the real ones (the header, the toolbar); the scroll view's can be zero
        let insets = clip.contentInsets
        var visible = clip.documentVisibleRect
        visible.origin.y += insets.top
        visible.size.height -= insets.top + insets.bottom
        let y = convert(window.mouseLocationOutsideOfEventStream, from: nil).y
        let edge: CGFloat = 24

        var delta: CGFloat = 0
        if y < visible.minY + edge, y < start.y {
            delta = -min(40, (visible.minY + edge - y) / 2 + 2)
        } else if y > visible.maxY - edge, y > start.y {
            delta = min(40, (y - (visible.maxY - edge)) / 2 + 2)
        }
        guard delta != 0 else { return }

        var target = clip.bounds
        target.origin.y += delta
        let newY = clip.constrainBoundsRect(target).origin.y
        guard newY != clip.bounds.origin.y, (newY - clip.bounds.origin.y) * delta > 0 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: newY))
        scrollView.reflectScrolledClipView(clip)
    }
}
