import SwiftUI
import AppKit

extension Notification.Name {
    /// Posted with `object:` the view model of the pane whose path bar should start editing (⌘L).
    static let pathBarBeginEditing = Notification.Name("pathBarBeginEditing")
}

@MainActor
enum PathBarActions {
    static func copyPath(of viewModel: FileBrowserViewModel) {
        PathCopy.copy([viewModel.currentPath], style: .path)
    }

    static func goToClipboardPath(in viewModel: FileBrowserViewModel) {
        let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty || !PathEntryResolver.navigate(viewModel, to: text) {
            NSSound.beep()
        }
    }
}

struct PathBarCopyButton: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    @State private var copied = false

    var body: some View {
        Button {
            PathBarActions.copyPath(of: viewModel)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption)
                .foregroundColor(copied ? .green : .secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Copy Path"))
    }
}

extension View {
    func pathBarExtras(viewModel: FileBrowserViewModel, startEditing: @escaping () -> Void) -> some View {
        self
            .contextMenu {
                Button("Copy Path") { PathBarActions.copyPath(of: viewModel) }
                Button("Go to Path in Clipboard") { PathBarActions.goToClipboardPath(in: viewModel) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .pathBarBeginEditing)) { notification in
                if (notification.object as? FileBrowserViewModel) === viewModel { startEditing() }
            }
    }
}

// MARK: - Inline path editing

enum PathCompletion {
    /// Completes the last path component of `text` by folder-name prefix: a single match is finished
    /// with "/", several matches extend to their common prefix. Nil when nothing changes.
    static func complete(_ text: String, relativeTo base: URL?) -> String? {
        let head: String
        let prefix: String
        if let slash = text.lastIndex(of: "/") {
            head = String(text[...slash])
            prefix = String(text[text.index(after: slash)...])
        } else {
            head = ""
            prefix = text
        }
        if head.isEmpty && prefix.hasPrefix("~") { return nil }
        guard let dir = head.isEmpty ? base : PathEntryResolver.expandedURL(for: head, relativeTo: base),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        else { return nil }
        let names = entries.compactMap { url -> String? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let name = url.lastPathComponent
            if name.hasPrefix(".") && !prefix.hasPrefix(".") { return nil }
            return name.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil ? name : nil
        }
        guard let first = names.first else { return nil }
        if names.count == 1 { return head + first + "/" }
        let common = names.dropFirst().reduce(first) { acc, name in
            String(acc.commonPrefix(with: name, options: .caseInsensitive))
        }
        return common.count > prefix.count ? head + common : nil
    }
}

private final class PathTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
            self.currentEditor()?.selectAll(nil)
        }
    }
}

private struct PathEditField: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let complete: (String) -> String?
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = PathTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize)
        field.lineBreakMode = .byClipping
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.stringValue = text
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PathEditField
        init(_ parent: PathEditField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onCancel()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            case #selector(NSResponder.insertTab(_:)):
                if let completed = parent.complete(textView.string) {
                    textView.string = completed
                    textView.setSelectedRange(NSRange(location: (completed as NSString).length, length: 0))
                    parent.text = completed
                } else {
                    NSSound.beep()
                }
                return true
            default:
                return false
            }
        }
    }
}

/// The path bar turned into a text field: validates as you type and only accepts a location that exists.
struct InlinePathEditor: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    let fontSize: CGFloat
    let onFinish: () -> Void

    @State private var text: String

    init(viewModel: FileBrowserViewModel, fontSize: CGFloat, onFinish: @escaping () -> Void) {
        self.viewModel = viewModel
        self.fontSize = fontSize
        self.onFinish = onFinish
        _text = State(initialValue: viewModel.currentPath.path)
    }

    private var base: URL? { viewModel.isInsideArchive ? nil : viewModel.currentPath }

    private var isValid: Bool {
        PathEntryResolver.resolve(text, relativeTo: base) != .notFound
    }

    var body: some View {
        HStack(spacing: 6) {
            PathEditField(
                text: $text,
                fontSize: fontSize,
                complete: { PathCompletion.complete($0, relativeTo: base) },
                onSubmit: submit,
                onCancel: onFinish
            )
            if !isValid {
                Text("Can't go there")
                    .font(.system(size: max(fontSize - 1, 9)))
                    .foregroundColor(.red)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .stroke(isValid ? Color.accentColor.opacity(0.6) : Color.red, lineWidth: 1)
        )
    }

    private func submit() {
        if PathEntryResolver.navigate(viewModel, to: text) {
            onFinish()
        } else {
            NSSound.beep()
        }
    }
}

/// A breadcrumb in the path bar as a drop target: files dropped on it go into that folder, and a
/// drag resting on it spring-loads the folder (except the one already shown).
struct PathComponentDropDelegate: DropDelegate {
    let url: URL
    let viewModel: FileBrowserViewModel
    @Binding var targetedURL: URL?
    let open: () -> Void

    private var isCurrentFolder: Bool {
        url.standardizedFileURL == viewModel.currentPath.standardizedFileURL && !viewModel.isInsideArchive
    }

    private func isUsefulDrop() -> Bool {
        let flags = NSEvent.modifierFlags
        if DropHelper.isAliasDrop(modifierFlags: flags) { return true }
        let sources = DropHelper.dragSourceURLs()
        if DropHelper.isSelfOrDescendantDrop(sources: sources, destination: url) { return false }
        return !DropHelper.isNoOpDrop(sources: sources, destination: url, operation: FileDropOperation(modifierFlags: flags))
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: DropHelper.acceptedDropTypes) && !DropHelper.isSidebarFavoriteDrag()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if !isCurrentFolder {
            setTargeted()
            let open = open
            SpringLoader.shared.hover(url, open: open)
        }
        guard isUsefulDrop() else { return DropProposal(operation: .forbidden) }
        let operation = FileDropOperation(modifierFlags: NSEvent.modifierFlags)
        return DropProposal(operation: DropHelper.dropOperation(
            for: operation,
            sources: DropHelper.dragSourceURLs(),
            destination: url
        ))
    }

    func dropExited(info: DropInfo) {
        SpringLoader.shared.cancel(key: url)
        if targetedURL == url { targetedURL = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        SpringLoader.shared.cancel(key: url)
        if targetedURL == url { targetedURL = nil }
        defer { InternalDragState.shared.endDrag() }
        guard isUsefulDrop() else { return false }
        let flags = NSEvent.modifierFlags
        let providers = info.itemProviders(for: [.fileURL])
        if DropHelper.isAliasDrop(modifierFlags: flags) {
            return DropHelper.performAliasDrop(providers: providers, into: url, viewModel: viewModel)
        }
        return DropHelper.performDrop(providers: providers, into: url, viewModel: viewModel, operation: FileDropOperation(modifierFlags: flags))
    }

    private func setTargeted() {
        guard targetedURL != url else { return }
        targetedURL = url
        let binding = $targetedURL
        let url = url
        DropHighlightReset.shared.clearWhenDragEnds {
            if binding.wrappedValue == url { binding.wrappedValue = nil }
        }
    }
}

/// Makes a breadcrumb a drop target when it is a real folder (not a location inside an archive).
struct PathComponentDropTarget: ViewModifier {
    let url: URL?
    let viewModel: FileBrowserViewModel
    @Binding var targetedURL: URL?
    let open: () -> Void

    func body(content: Content) -> some View {
        if let url {
            content.onDrop(of: DropHelper.acceptedDropTypes, delegate: PathComponentDropDelegate(
                url: url, viewModel: viewModel, targetedURL: $targetedURL, open: open
            ))
        } else {
            content
        }
    }
}
