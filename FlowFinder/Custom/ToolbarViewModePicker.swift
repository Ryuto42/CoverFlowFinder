import AppKit
import SwiftUI

/// The toolbar's view mode switch: six segments, or one menu button when combined or when the window is too narrow.
struct ToolbarViewModePicker: View {
    @Binding var selection: ViewMode
    @EnvironmentObject private var settings: AppSettings
    @State private var windowWidth: CGFloat = .infinity

    /// Below this window width the six segments no longer fit beside the other toolbar items.
    private static let narrowWidth: CGFloat = 960

    private var modes: [ViewMode] { ViewMode.allCases.filter { $0 != .dualPane } }

    var body: some View {
        Group {
            if settings.compactViewModePicker || windowWidth < Self.narrowWidth {
                compact
            } else {
                segmented
            }
        }
        .background(WindowWidthReader(width: $windowWidth))
    }

    private var segmented: some View {
        Picker("View", selection: $selection) {
            ForEach(modes, id: \.self) { mode in
                Image(systemName: mode.systemImage)
                    .tag(mode)
                    .help(mode.localizedName)
                    .accessibilityLabel(mode.localizedName)
            }
        }
        .pickerStyle(.segmented)
        // Always the control's natural width: a narrower fixed frame was honoured on some toolbar layouts only.
        .fixedSize()
        .help("Change view mode")
    }

    private var compact: some View {
        Menu {
            Picker("View", selection: $selection) {
                ForEach(modes, id: \.self) { mode in
                    Label(mode.localizedName, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: selection.systemImage)
        }
        .help("Change view mode")
    }
}

private struct WindowWidthReader: NSViewRepresentable {
    @Binding var width: CGFloat

    final class Reader: NSView {
        var onChange: (CGFloat) -> Void = { _ in }
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            report(window)
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                self?.report(window)
            }
        }

        private func report(_ window: NSWindow) {
            let w = window.frame.width
            DispatchQueue.main.async { [weak self] in self?.onChange(w) }
        }

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }

    func makeNSView(context: Context) -> Reader {
        let view = Reader()
        view.onChange = { width = $0 }
        return view
    }

    func updateNSView(_ nsView: Reader, context: Context) {}
}
