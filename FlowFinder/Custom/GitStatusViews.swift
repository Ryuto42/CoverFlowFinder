import SwiftUI
import AppKit

extension GitFileState {
    var color: NSColor {
        switch self {
        case .modified: .systemOrange
        case .added: .systemGreen
        case .untracked, .ignored: .systemGray
        case .deleted, .conflicted: .systemRed
        case .renamed: .systemBlue
        }
    }
}

extension GitBadge {
    var description: String {
        switch self {
        case .file(let state): state.localizedDescription
        case .folderChanges: String(localized: "Contains changes")
        }
    }

    /// Ignored items are shown dimmed instead of with a badge
    var isVisible: Bool { self != .file(.ignored) }
}

// MARK: - AppKit badge (list rows)

/// The Git badge of one list row; updates itself when the repository's status changes.
final class GitStatusBadgeNSView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()
    private var url: URL?
    private var isDirectory = false
    private(set) var badge: GitBadge?
    /// Called when the badge changes (the row re-dims ignored names)
    var onChange: (() -> Void)?

    var isIgnored: Bool { badge == .file(.ignored) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        label.alignment = .center
        addSubview(label)
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        addSubview(dot)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 12),
            heightAnchor.constraint(equalToConstant: 14),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.centerXAnchor.constraint(equalTo: centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
        ])
        isHidden = true
        NotificationCenter.default.addObserver(self, selector: #selector(statusChanged), name: GitStatusStore.didChange, object: nil)
    }

    func show(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
        update()
    }

    @objc private func statusChanged() {
        update()
    }

    private func update() {
        let newBadge = url.flatMap { GitStatusStore.shared.badge(for: $0, isDirectory: isDirectory) }
        guard newBadge != badge || (newBadge == nil && !isHidden) else { return }
        badge = newBadge
        switch newBadge {
        case .file(let state) where state != .ignored:
            label.stringValue = state.letter
            label.textColor = state.color
            label.isHidden = false
            dot.isHidden = true
        case .folderChanges:
            label.isHidden = true
            dot.isHidden = false
        default:
            label.isHidden = true
            dot.isHidden = true
        }
        isHidden = !(newBadge?.isVisible ?? false)
        toolTip = newBadge?.description
        onChange?()
    }
}

// MARK: - SwiftUI badge (icon, column and Cover Flow views)

struct GitStatusBadge: View {
    let url: URL
    let isDirectory: Bool
    var onIcon = false
    @ObservedObject private var store = GitStatusStore.shared

    var body: some View {
        if let badge = store.badge(for: url, isDirectory: isDirectory), badge.isVisible {
            content(badge)
                .padding(onIcon ? 2 : 0)
                .background(onIcon ? Color(nsColor: .windowBackgroundColor).opacity(0.9) : .clear)
                .clipShape(Circle())
                .help(badge.description)
        }
    }

    @ViewBuilder
    private func content(_ badge: GitBadge) -> some View {
        switch badge {
        case .file(let state):
            Text(verbatim: state.letter)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(nsColor: state.color))
                .frame(minWidth: 10)
        case .folderChanges:
            Circle()
                .fill(Color(nsColor: .systemOrange))
                .frame(width: 6, height: 6)
                .padding(2)
        }
    }
}

private struct GitIgnoredDimming: ViewModifier {
    let url: URL
    let isDirectory: Bool
    @ObservedObject private var store = GitStatusStore.shared

    func body(content: Content) -> some View {
        content.opacity(store.badge(for: url, isDirectory: isDirectory) == .file(.ignored) ? 0.5 : 1)
    }
}

extension View {
    /// Names of Git-ignored items at half opacity
    func gitIgnoredDimming(url: URL, isDirectory: Bool) -> some View {
        modifier(GitIgnoredDimming(url: url, isDirectory: isDirectory))
    }
}

// MARK: - Path bar

/// Branch, ahead/behind and change count at the right of the path bar, with a menu.
struct GitPathBarAccessory: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    @ObservedObject private var store = GitStatusStore.shared

    var body: some View {
        HStack(spacing: 0) {
            if !viewModel.isInsideArchive, let repo = store.repository(containing: viewModel.currentPath) {
                Menu {
                    menuItems(root: repo.root, snapshot: repo.snapshot)
                } label: {
                    label(repo.snapshot)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(helpText(repo.snapshot))
            }
        }
        .onChange(of: viewModel.currentPath) { _, _ in
            if viewModel.gitChangesFilter != nil { viewModel.gitChangesFilter = nil }
        }
        .onReceive(store.$generation) { _ in
            DispatchQueue.main.async { updateFilter() }
        }
        .onReceive(viewModel.$items) { _ in
            DispatchQueue.main.async { updateFilter() }
        }
    }

    private func label(_ snapshot: GitStatusSnapshot) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch")
            Text(verbatim: snapshot.branch ?? snapshot.oid.map { String($0.prefix(7)) } ?? "HEAD")
                .lineLimit(1)
            if snapshot.ahead > 0 { Text(verbatim: "↑\(snapshot.ahead)") }
            if snapshot.behind > 0 { Text(verbatim: "↓\(snapshot.behind)") }
            if snapshot.changeCount > 0 {
                Text(verbatim: "●\(snapshot.changeCount)")
                    .foregroundStyle(Color(nsColor: .systemOrange))
            }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(viewModel.gitChangesFilter != nil ? Color.accentColor : Color.secondary)
    }

    private func helpText(_ snapshot: GitStatusSnapshot) -> String {
        let branch = snapshot.branch ?? String(localized: "Detached HEAD")
        return String(localized: "Branch: \(branch), \(snapshot.changeCount) changes")
    }

    @ViewBuilder
    private func menuItems(root: String, snapshot: GitStatusSnapshot) -> some View {
        Button("Open in Terminal") { TerminalLauncher.open(viewModel.currentPath) }
        Toggle("Show Changed Files Only", isOn: Binding(
            get: { viewModel.gitChangesFilter != nil },
            set: { on in viewModel.gitChangesFilter = on ? changedItemURLs() : nil }
        ))
        if let github = snapshot.githubURL {
            Button("Open on GitHub") { NSWorkspace.shared.open(github) }
        }
        Divider()
        Button("Reload") { store.reload(root: root) }
    }

    private func changedItemURLs() -> Set<URL> {
        Set(viewModel.items.filter { item in
            store.badge(for: item.url, isDirectory: item.isDirectory)?.isVisible == true
        }.map(\.url))
    }

    private func updateFilter() {
        guard viewModel.gitChangesFilter != nil else { return }
        if store.repository(containing: viewModel.currentPath) == nil {
            viewModel.gitChangesFilter = nil
            return
        }
        let urls = changedItemURLs()
        if urls != viewModel.gitChangesFilter { viewModel.gitChangesFilter = urls }
    }
}

// MARK: - Info panel

/// Git status and last commit of the item shown in the Cover Flow info panel.
struct GitInfoRows: View {
    let url: URL
    let isDirectory: Bool
    @ObservedObject private var store = GitStatusStore.shared
    @State private var commit: GitStatusStore.LastCommit?
    @State private var commitPath: String?

    private var repo: (root: String, snapshot: GitStatusSnapshot)? {
        store.repository(containing: isDirectory ? url : url.deletingLastPathComponent())
    }

    var body: some View {
        if let repo {
            let relative = store.relativePath(of: url, inRoot: repo.root)
            VStack(alignment: .leading, spacing: 8) {
                if relative == nil {
                    row("Branch", repo.snapshot.branch ?? String(localized: "Detached HEAD"))
                }
                row("Git", statusText(relative: relative, snapshot: repo.snapshot))
                if let commit, commitPath == url.path {
                    row("Last Commit", commitText(commit))
                }
            }
            .task(id: "\(url.path)|\(store.generation)") {
                let result = await GitStatusStore.lastCommit(root: repo.root, relativePath: relative ?? ".")
                if !Task.isCancelled {
                    commit = result
                    commitPath = url.path
                }
            }
        }
    }

    private func statusText(relative: String?, snapshot: GitStatusSnapshot) -> String {
        guard let relative else {
            return snapshot.changeCount == 0 ? String(localized: "No changes") : String(localized: "\(snapshot.changeCount) changes")
        }
        if let badge = snapshot.badge(forRelativePath: relative, isDirectory: isDirectory) { return badge.description }
        return String(localized: "Unmodified")
    }

    private func commitText(_ commit: GitStatusStore.LastCommit) -> String {
        var lines = ["\(commit.hash) \(commit.subject)"]
        var meta = commit.author
        if let date = commit.date {
            meta += " · " + date.formatted(date: .abbreviated, time: .shortened)
        }
        lines.append(meta)
        return lines.joined(separator: "\n")
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
