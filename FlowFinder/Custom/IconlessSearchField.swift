import AppKit
import SwiftUI

/// A search field without the magnifying glass: the search mode button beside it already says what it searches.
final class IconlessSearchField: NSSearchField {
    /// Called with true when editing starts and false when it ends.
    var onFocusChange: ((Bool) -> Void)?

    /// Off when the surrounding control draws the focus ring for the field and its mode button together.
    var drawsOwnFocusRing = true {
        didSet {
            focusRingType = drawsOwnFocusRing ? .default : .none
            isBezeled = drawsOwnFocusRing
            isBordered = drawsOwnFocusRing
            drawsBackground = drawsOwnFocusRing
        }
    }

    override class var cellClass: AnyClass? {
        get { IconlessSearchFieldCell.self }
        set {}
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(false)
    }
}

final class IconlessSearchFieldCell: NSSearchFieldCell {
    override func searchButtonRect(forBounds rect: NSRect) -> NSRect { .zero }

    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        var textRect = super.searchTextRect(forBounds: rect)
        let left = rect.minX + 8
        textRect.size.width += textRect.minX - left
        textRect.origin.x = left
        return textRect
    }

    // Without the bezel the field editor is laid over the whole bounds, so the text jumped left when
    // editing began; edit in the same rect the placeholder and text are drawn in.
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: editingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: editingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }

    private func editingRect(forBounds rect: NSRect) -> NSRect {
        isBezeled ? rect : searchTextRect(forBounds: rect)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        searchButtonCell = nil
        super.drawInterior(withFrame: cellFrame, in: controlView)
    }
}

/// The search control's toolbar item. From macOS 26 the control draws its own glass capsule (instead of
/// the toolbar's shared one) so the focus glow can follow that capsule's outline exactly.
struct SearchToolbarItem<Content: View>: ToolbarContent {
    @ViewBuilder let content: Content

    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItem(placement: .primaryAction) { content }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) { content }
        }
    }
}

/// One capsule around the search mode button and the field; it glows while the field is edited.
struct SearchControlFrame: ViewModifier {
    let isFocused: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .frame(height: 36)
                // Brightens on hover like the toolbar's own glass buttons.
                .background(Capsule().fill(Color.white.opacity(isHovered ? 0.055 : 0)))
                .glassEffect(.regular, in: Capsule())
                .onHover { isHovered = $0 }
                .overlay(focusGlow)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        } else {
            content
                .padding(.leading, 6)
                .padding(.trailing, 4)
                .frame(height: 30)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                .overlay(focusGlow)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }

    private var focusGlow: some View {
        Capsule()
            .strokeBorder(Color.accentColor, lineWidth: 2.5)
            .shadow(color: Color.accentColor.opacity(0.7), radius: 4)
            .opacity(isFocused ? 1 : 0)
            .allowsHitTesting(false)
    }
}
