import AppKit

/// Finder-style drag images: one item shows its icon and the start of its name; several show a
/// small stack of icons.
@MainActor
enum DragPreview {
    private static let singleIconSize: CGFloat = 32
    private static let stackIconSize: CGFloat = 40
    private static let stackOffset: CGFloat = 5
    private static let maxNameWidth: CGFloat = 150
    private static let nameFont = NSFont.systemFont(ofSize: 12)

    /// Replaces the session's images. `icons` are in drag order; the image is centered on the cursor.
    static func apply(to session: NSDraggingSession, in view: NSView, screenPoint: NSPoint, icons: [NSImage], firstName: String, classes: [AnyClass]) {
        guard let window = view.window, let firstIcon = icons.first else { return }
        let image = icons.count == 1
            ? singleImage(icon: firstIcon, name: firstName)
            : stackImage(icons: Array(icons.prefix(3)))
        let point = view.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        let iconSize = icons.count == 1 ? singleIconSize : stackIconSize
        let frame = NSRect(
            x: point.x - iconSize / 2,
            y: point.y - image.size.height / 2,
            width: image.size.width,
            height: image.size.height
        )

        session.draggingFormation = .none
        session.enumerateDraggingItems(options: [], for: view, classes: classes, searchOptions: [:]) { item, index, _ in
            if index == 0 {
                item.setDraggingFrame(frame, contents: image)
            } else {
                item.draggingFrame = NSRect(origin: frame.origin, size: NSSize(width: 1, height: 1))
                item.imageComponentsProvider = { [] }
            }
        }
    }

    private static func singleImage(icon: NSImage, name: String) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [.font: nameFont, .foregroundColor: NSColor.labelColor]
        let textWidth = min(ceil((name as NSString).size(withAttributes: attributes).width), maxNameWidth)
        let labelPadding: CGFloat = 5
        let labelHeight = ceil(nameFont.boundingRectForFont.height) + 2
        let size = NSSize(width: singleIconSize + 4 + textWidth + labelPadding * 2, height: singleIconSize)
        return NSImage(size: size, flipped: false) { _ in
            icon.draw(in: NSRect(x: 0, y: 0, width: singleIconSize, height: singleIconSize))
            let labelRect = NSRect(x: singleIconSize + 4, y: (size.height - labelHeight) / 2, width: textWidth + labelPadding * 2, height: labelHeight)
            NSColor.windowBackgroundColor.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4).fill()
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            var textAttributes = attributes
            textAttributes[.paragraphStyle] = style
            (name as NSString).draw(in: labelRect.insetBy(dx: labelPadding, dy: 1), withAttributes: textAttributes)
            return true
        }
    }

    /// macOS adds the count badge itself.
    private static func stackImage(icons: [NSImage]) -> NSImage {
        let stackExtent = stackOffset * CGFloat(icons.count - 1)
        let size = NSSize(width: stackIconSize + stackExtent, height: stackIconSize + stackExtent)
        return NSImage(size: size, flipped: false) { _ in
            for (index, icon) in icons.enumerated().reversed() {
                let offset = stackOffset * CGFloat(index)
                icon.draw(in: NSRect(x: offset, y: stackExtent - offset, width: stackIconSize, height: stackIconSize))
            }
            return true
        }
    }
}
