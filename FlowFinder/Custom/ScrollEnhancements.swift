import AppKit
import SwiftUI
import ObjectiveC

// MARK: - Thin scrollers

/// Every scroll view in the app gets thin overlay scrollers when it enters a window.
enum ThinScrollers {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        let original = #selector(NSView.viewDidMoveToWindow)
        let swizzled = #selector(NSScrollView.ff_viewDidMoveToWindow)
        guard let ours = class_getInstanceMethod(NSScrollView.self, swizzled) else { return }
        let imp = method_getImplementation(ours)
        let types = method_getTypeEncoding(ours)
        // NSScrollView may inherit viewDidMoveToWindow: add it on the class so NSView stays untouched
        if class_addMethod(NSScrollView.self, original, imp, types) {
            if let inherited = class_getInstanceMethod(NSView.self, original) {
                class_replaceMethod(NSScrollView.self, swizzled, method_getImplementation(inherited), method_getTypeEncoding(inherited))
            }
        } else if let theirs = class_getInstanceMethod(NSScrollView.self, original) {
            method_exchangeImplementations(theirs, ours)
        }
    }
}

extension NSScrollView {
    @objc fileprivate func ff_viewDidMoveToWindow() {
        ff_viewDidMoveToWindow()
        guard window != nil else { return }
        scrollerStyle = .overlay
        verticalScroller?.controlSize = .small
        horizontalScroller?.controlSize = .small
    }
}
