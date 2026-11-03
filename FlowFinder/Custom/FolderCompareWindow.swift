import SwiftUI
import AppKit

// MARK: - Opening

@MainActor
enum FolderCompareLauncher {
    /// The menu command: the two panes of a split tab, else two selected folders, else the folder
    /// shown and one the user picks.
    static func open(from viewModel: FileBrowserViewModel) {
        if let (left, right) = panes(of: viewModel),
           let leftURL = folder(of: left), let rightURL = folder(of: right),
           leftURL.standardizedFileURL != rightURL.standardizedFileURL {
            FolderCompareWindowController.show(left: leftURL, right: rightURL, viewModel: viewModel, panes: [left, right])
            return
        }
        let folders = selectedFolders(of: viewModel)
        if folders.count == 2 {
            FolderCompareWindowController.show(left: folders[0], right: folders[1], viewModel: viewModel, panes: [viewModel])
            return
        }
        guard let leftURL = folder(of: viewModel) else {
            NSSound.beep()
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = leftURL.deletingLastPathComponent()
        panel.message = String(localized: "Choose a folder to compare with “\(FileOperationAlerts.displayName(leftURL))”.")
        panel.prompt = String(localized: "Compare")
        panel.begin { [weak viewModel] response in
            guard response == .OK, let rightURL = panel.url else { return }
            FolderCompareWindowController.show(left: leftURL, right: rightURL, viewModel: viewModel, panes: viewModel.map { [$0] } ?? [])
        }
    }

    /// Two folders selected in a pane (the context menu command).
    static func selectedFolders(of viewModel: FileBrowserViewModel) -> [URL] {
        let items = viewModel.filteredItems.filter { viewModel.selectedItems.contains($0) }
        guard items.count == 2,
              items.allSatisfy({ $0.isDirectory && !$0.isPackage && !$0.isFromArchive && $0.url.isFileURL }) else { return [] }
        return items.map(\.url)
    }

    /// Left and right pane of the split tab (or dual pane view) showing `viewModel`.
    private static func panes(of viewModel: FileBrowserViewModel) -> (FileBrowserViewModel, FileBrowserViewModel)? {
        if let store = TabSession.store(containing: viewModel),
           let tab = store.tabs.first(where: { $0.split != nil && $0.allViewModels.contains { $0 === viewModel } }),
           let split = tab.split {
            return (tab.viewModel, split.rightViewModel)
        }
        if let other = SwipeNavigator.shared.otherPane(of: viewModel) {
            return (viewModel, other)
        }
        return nil
    }

    private static func folder(of viewModel: FileBrowserViewModel) -> URL? {
        guard !viewModel.isInsideArchive, viewModel.currentPath.isFileURL, viewModel.currentPath.path != "/Network" else { return nil }
        return viewModel.currentPath
    }
}

// MARK: - Window

@MainActor
final class FolderCompareWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [FolderCompareWindowController] = []
    private let session: FolderCompareSession

    static func show(left: URL, right: URL, viewModel: FileBrowserViewModel?, panes: [FileBrowserViewModel]) {
        let session = FolderCompareSession(left: left, right: right, viewModel: viewModel, panes: panes)
        let controller = FolderCompareWindowController(session: session)
        open.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        session.compare()
    }

    private init(session: FolderCompareSession) {
        self.session = session
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = String(localized: "Compare Folders")
        window.minSize = NSSize(width: 760, height: 420)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: FolderCompareView(session: session))
        window.center()
        super.init(window: window)
        window.delegate = self
        session.window = window
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        session.cancelScan()
        Self.open.removeAll { $0 === self }
    }
}

// MARK: - Session

@MainActor
final class FolderCompareSession: ObservableObject {
    @Published var leftURL: URL
    @Published var rightURL: URL
    @Published var options = FolderCompareOptions()
    @Published var mode: FolderSyncMode = .leftToRight {
        didSet { resetActions() }
    }
    @Published var deleteExtras = false {
        didSet { resetActions() }
    }
    @Published var entries: [FolderCompareEntry] = []
    @Published var differencesOnly = true
    @Published var showsTree = true
    @Published var collapsed: Set<String> = []
    @Published private(set) var isScanning = false
    @Published private(set) var scannedCount = 0
    @Published private(set) var scanningPath = ""
    @Published private(set) var syncProgress: Progress?
    @Published private(set) var syncFraction: Double = 0

    weak var window: NSWindow?
    private weak var viewModel: FileBrowserViewModel?
    private var panes: [WeakViewModel]
    private var scanProgress: FolderCompareProgress?
    private var timer: Timer?

    private struct WeakViewModel {
        weak var viewModel: FileBrowserViewModel?
    }

    init(left: URL, right: URL, viewModel: FileBrowserViewModel?, panes: [FileBrowserViewModel]) {
        leftURL = left
        rightURL = right
        self.viewModel = viewModel
        self.panes = panes.map { WeakViewModel(viewModel: $0) }
    }

    var isBusy: Bool { isScanning || syncProgress != nil }

    // MARK: Comparing

    func compare() {
        cancelScan()
        let left = leftURL, right = rightURL
        let leftPath = FileOperationEngine.canonicalPath(left)
        let rightPath = FileOperationEngine.canonicalPath(right)
        guard !FileOperationEngine.isPath(leftPath, sameAsOrInside: rightPath),
              !FileOperationEngine.isPath(rightPath, sameAsOrInside: leftPath) else {
            entries = []
            FileOperationAlerts.showMessage(
                String(localized: "These folders can’t be compared."),
                information: String(localized: "Choose two folders that aren’t the same and aren’t inside each other."),
                in: window
            )
            return
        }
        let progress = FolderCompareProgress()
        scanProgress = progress
        isScanning = true
        scannedCount = 0
        scanningPath = ""
        startTimer()
        let options = options, mode = mode, deleteExtras = deleteExtras
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try FolderCompareEngine.compare(left: left, right: right, options: options, mode: mode, deleteExtras: deleteExtras, progress: progress) }
            DispatchQueue.main.async {
                guard let self, self.scanProgress === progress else { return }
                self.scanProgress = nil
                self.isScanning = false
                self.stopTimerIfIdle()
                if case .success(let entries) = result {
                    self.entries = entries
                }
            }
        }
    }

    func cancelScan() {
        scanProgress?.cancel()
        scanProgress = nil
        isScanning = false
        stopTimerIfIdle()
    }

    func swapSides() {
        swap(&leftURL, &rightURL)
        compare()
    }

    func choose(_ side: SplitSide) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = side == .left ? leftURL : rightURL
        panel.prompt = String(localized: "Choose")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            if side == .left { self.leftURL = url } else { self.rightURL = url }
            self.compare()
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopTimerIfIdle() {
        guard !isBusy else { return }
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        if let scanProgress {
            scannedCount = scanProgress.scannedCount
            scanningPath = scanProgress.currentPath
        }
        if let syncProgress {
            syncFraction = min(max(syncProgress.fractionCompleted, 0), 1)
        }
    }

    // MARK: Rows

    var visibleRows: [FolderCompareEntry] {
        var rows: [FolderCompareEntry] = []
        var hiddenBelow: Int?
        for entry in entries {
            if let depth = hiddenBelow {
                if entry.depth > depth { continue }
                hiddenBelow = nil
            }
            if differencesOnly, !entry.status.isDifference {
                if entry.isFolderRow { hiddenBelow = entry.depth }
                continue
            }
            if showsTree {
                rows.append(entry)
                if entry.isFolderRow, collapsed.contains(entry.id) { hiddenBelow = entry.depth }
            } else if !entry.isFolderRow {
                rows.append(entry)
            }
        }
        return rows
    }

    func toggleCollapsed(_ entry: FolderCompareEntry) {
        if collapsed.contains(entry.id) { collapsed.remove(entry.id) } else { collapsed.insert(entry.id) }
    }

    func setAction(_ action: FolderSyncAction, for entry: FolderCompareEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].action = action
    }

    func resetActions() {
        entries = FolderCompareEngine.applyDefaultActions(entries, mode: mode, deleteExtras: deleteExtras)
    }

    var plan: FolderSyncPlan {
        FolderSyncPlan.make(from: entries, leftRoot: leftURL, rightRoot: rightURL)
    }

    var differenceCount: Int {
        entries.filter { !$0.isFolderRow && $0.status.isDifference }.count
    }

    // MARK: Synchronizing

    func synchronize() {
        let plan = plan
        guard !plan.isEmpty else {
            FileOperationAlerts.showMessage(String(localized: "Nothing to synchronize."), information: String(localized: "Every item is set to Skip."), in: window)
            return
        }
        guard let viewModel = viewModel ?? panes.lazy.compactMap(\.viewModel).first else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Synchronize the folders?")
        alert.informativeText = Self.summary(of: plan)
        alert.addButton(withTitle: String(localized: "Synchronize"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        FileOperationAlerts.show(alert, in: window) { [weak self, weak viewModel] response in
            guard response == .alertFirstButtonReturn, let self, let viewModel else { return }
            self.run(plan, with: viewModel)
        }
    }

    static func summary(of plan: FolderSyncPlan) -> String {
        var lines: [String] = []
        if plan.copiesToRight > 0 { lines.append(String(localized: "Copy \(plan.copiesToRight) items to the right")) }
        if plan.copiesToLeft > 0 { lines.append(String(localized: "Copy \(plan.copiesToLeft) items to the left")) }
        if !plan.copies.isEmpty {
            lines.append(String(localized: "Size to copy: \(ByteCountFormatter.string(fromByteCount: plan.bytesToCopy, countStyle: .file))"))
        }
        if plan.replacedCount > 0 { lines.append(String(localized: "\(plan.replacedCount) existing items are replaced (the old ones go to the Trash)")) }
        if !plan.trash.isEmpty { lines.append(String(localized: "Move \(plan.trash.count) items to the Trash")) }
        lines.append(String(localized: "You can undo this with Edit > Undo in the browser window."))
        return lines.joined(separator: "\n")
    }

    private func run(_ plan: FolderSyncPlan, with viewModel: FileBrowserViewModel) {
        let transfers = plan.copies.map {
            FileTransferItem(source: $0.source, destination: $0.destination, kind: .copy, placement: $0.replaces ? .replace : .exact)
        }
        let trash = plan.trash
        viewModel.runFileOperation(
            actionName: String(localized: "Synchronize"),
            failureVerb: String(localized: "synchronized"),
            title: String(localized: "Synchronizing Folders"),
            window: window,
            work: { [weak self] journal, progress in
                DispatchQueue.main.async {
                    guard let self, FileOperationEngine.isRunning(progress) else { return }
                    self.syncProgress = progress
                    self.syncFraction = 0
                    self.startTimer()
                }
                return Self.perform(transfers: transfers, trash: trash, journal: journal, progress: progress)
            },
            completion: { [weak self] _, _ in
                guard let self else { return }
                self.syncProgress = nil
                self.stopTimerIfIdle()
                self.panes.compactMap(\.viewModel).forEach { $0.refresh() }
                self.compare()
            }
        )
    }

    /// Runs on the file-operation queue: Trash first, then the copies (replacing puts the old item
    /// in the Trash too), all in one journal so one Undo reverses the whole sync.
    nonisolated private static func perform(transfers: [FileTransferItem], trash: [URL], journal: FileOperationJournal, progress: Progress) -> FileOperationResult {
        progress.totalUnitCount = 100
        let trashShare: Int64 = trash.isEmpty ? 0 : (transfers.isEmpty ? 100 : 10)
        var result = FileOperationResult()
        if !trash.isEmpty {
            let child = Progress(totalUnitCount: 1, parent: progress, pendingUnitCount: trashShare)
            let trashed = FileOperationEngine.trash(trash, journal: journal, progress: child)
            result.failures += trashed.failures
            for url in trashed.trashUnsupported + trashed.volumes {
                let error = FileOperationEngine.makeError(String(localized: "“\(FileOperationEngine.displayName(url))” wasn’t deleted because it can’t be moved to the Trash."))
                result.failures.append(FileOperationFailure(url: url, error: error))
            }
            result.wasCancelled = trashed.wasCancelled
        }
        if !transfers.isEmpty, !result.wasCancelled, !progress.isCancelled {
            let child = Progress(totalUnitCount: 1, parent: progress, pendingUnitCount: 100 - trashShare)
            let copied = FileOperationEngine.transfer(transfers, journal: journal, progress: child)
            result.failures += copied.failures
            result.wasCancelled = copied.wasCancelled
        }
        return result
    }

    func stopSync() {
        syncProgress?.cancel()
    }
}

// MARK: - Labels

extension FolderCompareStatus {
    var title: String {
        switch self {
        case .leftOnly: String(localized: "Left Only")
        case .rightOnly: String(localized: "Right Only")
        case .same: String(localized: "Same")
        case .leftNewer: String(localized: "Left Is Newer")
        case .rightNewer: String(localized: "Right Is Newer")
        case .sizeDiffers: String(localized: "Different Size")
        case .contentDiffers: String(localized: "Different Contents")
        case .kindDiffers: String(localized: "Different Kind")
        case .folder(let hasDifferences): hasDifferences ? String(localized: "Contains Differences") : String(localized: "Same")
        }
    }

    var color: Color {
        switch self {
        case .same, .folder(false): .secondary
        case .leftOnly, .leftNewer: .blue
        case .rightOnly, .rightNewer: .purple
        case .sizeDiffers, .contentDiffers, .kindDiffers: .orange
        case .folder(true): .primary
        }
    }
}

extension FolderSyncAction {
    var title: String {
        switch self {
        case .copyToRight: String(localized: "Copy to Right")
        case .copyToLeft: String(localized: "Copy to Left")
        case .deleteLeft: String(localized: "Move Left Item to Trash")
        case .deleteRight: String(localized: "Move Right Item to Trash")
        case .skip: String(localized: "Skip")
        }
    }

    var symbol: String {
        switch self {
        case .copyToRight: "arrow.right"
        case .copyToLeft: "arrow.left"
        case .deleteLeft: "trash"
        case .deleteRight: "trash"
        case .skip: "minus"
        }
    }

    var color: Color {
        switch self {
        case .copyToRight, .copyToLeft: .accentColor
        case .deleteLeft, .deleteRight: .red
        case .skip: .secondary
        }
    }
}

extension FolderSyncMode {
    var title: String {
        switch self {
        case .leftToRight: String(localized: "Left to Right")
        case .rightToLeft: String(localized: "Right to Left")
        case .bidirectional: String(localized: "Both Ways")
        }
    }
}

extension FolderCompareMethod {
    var title: String {
        switch self {
        case .dateAndSize: String(localized: "Date and Size")
        case .content: String(localized: "Contents (Slow)")
        }
    }
}

// MARK: - Views

struct FolderCompareView: View {
    @ObservedObject var session: FolderCompareSession

    private let sizeWidth: CGFloat = 72
    private let dateWidth: CGFloat = 128
    private let statusWidth: CGFloat = 132
    private let actionWidth: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            columnHeader
            Divider()
            list
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 420)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                folderField(.left, url: session.leftURL)
                Button {
                    session.swapSides()
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .help(String(localized: "Swap Left and Right"))
                .disabled(session.isBusy)
                folderField(.right, url: session.rightURL)
            }
            HStack(spacing: 12) {
                Picker("Compare by", selection: $session.options.method) {
                    ForEach(FolderCompareMethod.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .fixedSize()
                Menu("Exclude") {
                    Toggle("Hidden Files", isOn: $session.options.excludeHidden)
                    Toggle(isOn: $session.options.excludeDSStore) { Text(verbatim: ".DS_Store") }
                    Toggle(".git Folders", isOn: $session.options.excludeGit)
                }
                .fixedSize()
                Button("Compare Again") { session.compare() }
                    .disabled(session.syncProgress != nil)
                Spacer()
                Toggle("Differences Only", isOn: $session.differencesOnly)
                Picker("", selection: $session.showsTree) {
                    Text("Tree").tag(true)
                    Text("Flat").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .disabled(session.syncProgress != nil)
            HStack(spacing: 12) {
                Picker("Sync", selection: $session.mode) {
                    ForEach(FolderSyncMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Toggle("Delete items that aren’t in the source", isOn: $session.deleteExtras)
                    .disabled(session.mode == .bidirectional)
                Spacer()
                Button("Reset Actions") { session.resetActions() }
            }
            .disabled(session.isBusy)
        }
        .padding(12)
        .onChange(of: session.options) { _, _ in session.compare() }
    }

    private func folderField(_ side: SplitSide, url: URL) -> some View {
        HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 16, height: 16)
            Text(verbatim: (url.path as NSString).abbreviatingWithTildeInPath)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Choose…") { session.choose(side) }
                .disabled(session.isBusy)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: List

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("Left").frame(width: sizeWidth + dateWidth + 8, alignment: .leading)
            Text("Status").frame(width: statusWidth, alignment: .leading)
            Text("Action").frame(width: actionWidth)
            Text("Right").frame(width: sizeWidth + dateWidth + 8, alignment: .leading)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private var list: some View {
        let rows = session.visibleRows
        return ZStack {
            List(rows) { entry in
                row(entry)
                    .contextMenu { actionMenuItems(entry) }
            }
            .listStyle(.plain)
            if rows.isEmpty, !session.isScanning {
                Text(session.entries.isEmpty ? String(localized: "No items.") : String(localized: "No differences."))
                    .foregroundStyle(.secondary)
            }
            if session.isScanning {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Comparing… \(session.scannedCount) items")
                    Text(verbatim: session.scanningPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 420)
                    Button("Stop") { session.cancelScan() }
                }
                .padding(20)
                .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
            }
        }
    }

    private func row(_ entry: FolderCompareEntry) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                if session.showsTree {
                    Color.clear.frame(width: CGFloat(entry.depth) * 16, height: 1)
                    if entry.isFolderRow {
                        Button {
                            session.toggleCollapsed(entry)
                        } label: {
                            Image(systemName: session.collapsed.contains(entry.id) ? "chevron.right" : "chevron.down")
                                .font(.caption2)
                                .frame(width: 12)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear.frame(width: 12, height: 1)
                    }
                }
                Image(nsImage: NSWorkspace.shared.icon(forFile: (entry.left ?? entry.right)!.url.path))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(verbatim: session.showsTree ? entry.name : entry.relativePath)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            info(entry.left, isFolderRow: entry.isFolderRow)
            Text(entry.status.title)
                .foregroundStyle(entry.status.color)
                .lineLimit(1)
                .frame(width: statusWidth, alignment: .leading)
            actionControl(entry)
                .frame(width: actionWidth)
            info(entry.right, isFolderRow: entry.isFolderRow)
        }
        .font(.callout)
    }

    private func info(_ item: FolderCompareItemInfo?, isFolderRow: Bool) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: item.map { isFolderRow ? "--" : ByteCountFormatter.string(fromByteCount: $0.size, countStyle: .file) } ?? "")
                .frame(width: sizeWidth, alignment: .trailing)
            Text(verbatim: item?.modified?.formatted(date: .numeric, time: .shortened) ?? "")
                .frame(width: dateWidth, alignment: .leading)
        }
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
    }

    @ViewBuilder
    private func actionControl(_ entry: FolderCompareEntry) -> some View {
        if entry.isFolderRow {
            Color.clear.frame(height: 1)
        } else {
            Menu {
                actionMenuItems(entry)
            } label: {
                Image(systemName: entry.action.symbol)
                    .foregroundStyle(entry.action.color)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(entry.action.title)
            .disabled(session.isBusy)
        }
    }

    @ViewBuilder
    private func actionMenuItems(_ entry: FolderCompareEntry) -> some View {
        ForEach(entry.allowedActions, id: \.self) { action in
            Button {
                session.setAction(action, for: entry)
            } label: {
                Label(action.title, systemImage: action == entry.action ? "checkmark" : action.symbol)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if let progress = session.syncProgress {
                ProgressView(value: session.syncFraction)
                    .frame(maxWidth: 260)
                Text("Synchronizing…")
                Button("Stop") { session.stopSync() }
                    .disabled(progress.isCancelled)
            } else {
                let plan = session.plan
                Text(footerSummary(plan))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Synchronize…") { session.synchronize() }
                .keyboardShortcut(.defaultAction)
                .disabled(session.isBusy || session.entries.isEmpty)
        }
        .padding(12)
    }

    private func footerSummary(_ plan: FolderSyncPlan) -> String {
        let size = ByteCountFormatter.string(fromByteCount: plan.bytesToCopy, countStyle: .file)
        return String(localized: "\(session.differenceCount) differences · \(plan.copies.count) to copy (\(size)) · \(plan.trash.count) to Trash")
    }
}
