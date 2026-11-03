import SwiftUI
import AppKit

extension UI {
    /// Backgrounds of the window's areas, from system colours so light and dark both follow the system.
    /// chrome: the bands around the content (tab bar, path bar, status bar); content: the lists and grids;
    /// panel: the Cover Flow panel, `panelBottom` being where its gradient ends (the info below continues it).
    enum Colors {
        enum Role {
            case chrome, content, panel, panelBottom

            /// With "Translucent window" on everything shows the sidebar's material as is, so the window reads as one surface.
            fileprivate var translucentAlpha: CGFloat { 0 }

            /// The colour for `translucent` (the "Translucent window" setting) or not.
            func nsColor(translucent: Bool) -> NSColor {
                let base = opaqueColor
                guard translucent else { return base }
                return NSColor(name: nil) { appearance in
                    var color = base
                    appearance.performAsCurrentDrawingAppearance {
                        color = base.withAlphaComponent(translucentAlpha)
                    }
                    return color
                }
            }

            private var opaqueColor: NSColor {
                switch self {
                case .chrome:
                    return .windowBackgroundColor
                case .content:
                    return .controlBackgroundColor
                case .panel:
                    return Self.panelColor
                case .panelBottom:
                    return Self.panelBottomColor
                }
            }

            private static let panelColor = NSColor(name: nil) { appearance in
                var color = NSColor.windowBackgroundColor
                appearance.performAsCurrentDrawingAppearance {
                    color = NSColor.windowBackgroundColor.blended(withFraction: 0.35, of: .controlBackgroundColor)
                        ?? NSColor.windowBackgroundColor
                }
                return color
            }

            private static let panelBottomColor = NSColor(name: nil) { appearance in
                var color = NSColor.windowBackgroundColor
                appearance.performAsCurrentDrawingAppearance {
                    let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    let panel = NSColor.windowBackgroundColor.blended(withFraction: 0.35, of: .controlBackgroundColor)
                        ?? NSColor.windowBackgroundColor
                    color = panel.blended(withFraction: isDark ? 0.12 : 0.05, of: .black) ?? panel
                }
                return color
            }
        }

        static let translucencyChanged = Notification.Name("uiColorsTranslucencyChanged")

        @MainActor static var isTranslucent: Bool { AppSettings.shared.translucentWindow }

        @MainActor static func nsColor(_ role: Role) -> NSColor { role.nsColor(translucent: isTranslucent) }
    }
}

private struct UIBackgroundModifier: ViewModifier {
    @EnvironmentObject private var settings: AppSettings
    let role: UI.Colors.Role

    func body(content: Content) -> some View {
        content.background(Color(nsColor: role.nsColor(translucent: settings.translucentWindow)))
    }
}

extension View {
    func uiBackground(_ role: UI.Colors.Role) -> some View {
        modifier(UIBackgroundModifier(role: role))
    }

    /// With "Translucent window" on, the window shows the desktop through a blur behind the bands and lists.
    func translucentWindowBackground() -> some View {
        modifier(TranslucentWindowModifier())
    }

    /// The detail column's backdrop: on macOS 26+ the sidebar is a Liquid Glass pane tinted by the desktop, which
    /// the plain material behind the window doesn't match, so the detail side gets the same glass.
    func translucentDetailBackground() -> some View {
        modifier(TranslucentDetailModifier())
    }
}

private struct TranslucentWindowModifier: ViewModifier {
    @EnvironmentObject private var settings: AppSettings

    func body(content: Content) -> some View {
        content
            .background {
                WindowMaterialView(enabled: settings.translucentWindow)
                    .ignoresSafeArea()
            }
            .toolbarBackgroundVisibility(settings.translucentWindow ? .hidden : .automatic, for: .windowToolbar)
            .onChange(of: settings.translucentWindow) { _, _ in
                NotificationCenter.default.post(name: UI.Colors.translucencyChanged, object: nil)
            }
    }
}

private struct TranslucentDetailModifier: ViewModifier {
    @EnvironmentObject private var settings: AppSettings

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), settings.translucentWindow {
            content.background {
                SidebarGlassView()
                    .ignoresSafeArea(edges: [.top, .bottom, .trailing])
            }
        } else {
            content
        }
    }
}

@available(macOS 26.0, *)
private struct SidebarGlassView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        // The variant NavigationSplitView uses for its sidebar; there's no public API for it.
        let variant = NSSelectorFromString("set_variant:")
        if view.responds(to: variant) {
            view.setValue(17, forKey: "_variant")
        }
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {}
}

private struct WindowMaterialView: NSViewRepresentable {
    let enabled: Bool

    func makeNSView(context: Context) -> MaterialView {
        let view = MaterialView()
        // The sidebar's own material, so the whole window reads as one surface.
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEnabled = enabled
        return view
    }

    func updateNSView(_ view: MaterialView, context: Context) {
        view.isEnabled = enabled
    }

    final class MaterialView: NSVisualEffectView {
        var isEnabled = false {
            didSet { apply() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() {
            isHidden = !isEnabled
            guard let window else { return }
            window.isOpaque = !isEnabled
            window.backgroundColor = isEnabled ? .clear : .windowBackgroundColor
        }
    }
}

extension FileTableCoordinator {
    @objc func applyBackground() {
        guard let tableView, let scrollView = tableView.enclosingScrollView else { return }
        let translucent = UI.Colors.isTranslucent
        scrollView.drawsBackground = !translucent
        tableView.usesAlternatingRowBackgroundColors = !translucent
        tableView.backgroundColor = translucent ? .clear : UI.Colors.nsColor(.content)
    }
}

extension UI.Colors {
    /// Zebra stripes for the list while the window is translucent: the system's alternating colours are opaque and
    /// would hide the material. Returns false when the table should draw its usual background.
    @MainActor
    static func drawTranslucentStripes(in tableView: NSTableView, clipRect: NSRect) -> Bool {
        guard isTranslucent else { return false }
        let stripe = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.045)
                : NSColor.black.withAlphaComponent(0.035)
        }
        stripe.setFill()
        func fill(_ rect: NSRect) {
            rect.intersection(clipRect).fill(using: .sourceOver)
        }
        // Follow the rows' real frames; past the last row, keep its pitch so the stripes run on to the bottom.
        let visible = tableView.rows(in: clipRect)
        for row in visible.location..<(visible.location + visible.length) where row % 2 == 1 {
            fill(tableView.rect(ofRow: row))
        }
        let count = tableView.numberOfRows
        var next = count
        var y: CGFloat = 0
        var pitch = tableView.rowHeight + tableView.intercellSpacing.height
        if count > 0 {
            let last = tableView.rect(ofRow: count - 1)
            y = last.maxY
            pitch = last.height
        }
        guard pitch > 0, y < clipRect.maxY else { return true }
        if y < clipRect.minY {
            let skip = Int(floor((clipRect.minY - y) / pitch))
            y += CGFloat(skip) * pitch
            next += skip
        }
        while y < clipRect.maxY {
            if next % 2 == 1 {
                fill(NSRect(x: clipRect.minX, y: y, width: clipRect.width, height: pitch))
            }
            y += pitch
            next += 1
        }
        return true
    }
}
