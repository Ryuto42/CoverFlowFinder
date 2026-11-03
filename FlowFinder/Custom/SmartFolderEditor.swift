import AppKit
import SwiftUI

/// The smart folder criteria sheet (Finder's search bar with its rule rows, as a sheet).
struct SmartFolderEditorView: View {
    @State private var name: String
    @State private var criteria: SmartFolderCriteria
    @State private var errorMessage: String?
    @StateObject private var counter = SmartFolderCountQuery()
    let isNew: Bool
    /// Returns an error message when saving failed.
    let onSave: (String, SmartFolderCriteria) -> String?
    let onCancel: () -> Void

    init(name: String, criteria: SmartFolderCriteria, isNew: Bool,
         onSave: @escaping (String, SmartFolderCriteria) -> String?, onCancel: @escaping () -> Void) {
        _name = State(initialValue: name)
        _criteria = State(initialValue: criteria)
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var canSave: Bool {
        !SmartFolderActions.fileName(for: name).isEmpty && criteria.rawQuery != nil
    }

    private var folderTitle: String {
        guard let path = criteria.folderPath, !path.isEmpty else { return String(localized: "Current Folder") }
        let url = URL(fileURLWithPath: path)
        return "“\(url.localizedFolderName ?? FileManager.default.displayName(atPath: path))”"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New Smart Folder" : "Edit Smart Folder").font(.headline)
            HStack {
                Text("Name:")
                TextField("", text: $name).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 12) {
                Text("Search:")
                Picker("", selection: $criteria.scope) {
                    Text("This Mac").tag(SmartFolderCriteria.Scope.thisMac)
                    if criteria.folderPath != nil {
                        Text(folderTitle).tag(SmartFolderCriteria.Scope.folder)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Picker("", selection: $criteria.match) {
                    Text("Match all conditions").tag(SmartFolderCriteria.Match.all)
                    Text("Match any condition").tag(SmartFolderCriteria.Match.any)
                }
                .labelsHidden()
                .fixedSize()
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach($criteria.rules) { $rule in
                        SmartFolderRuleRow(
                            rule: $rule,
                            canRemove: criteria.rules.count > 1,
                            onAdd: { addRule(after: rule.id) },
                            onRemove: { criteria.rules.removeAll { $0.id == rule.id } }
                        )
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 120, maxHeight: 320)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                if criteria.rawQuery == nil {
                    Text("Add at least one condition.").foregroundStyle(.secondary)
                } else if let count = counter.count {
                    Text("Matching items: \(count)").foregroundStyle(.secondary)
                    if counter.isGathering {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") {
                    errorMessage = onSave(name, criteria)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 640)
        .onAppear { counter.update(criteria) }
        .onChange(of: criteria) { _, newValue in counter.update(newValue) }
        .onDisappear { counter.stop() }
    }

    private func addRule(after id: UUID) {
        let index = criteria.rules.firstIndex { $0.id == id }.map { $0 + 1 } ?? criteria.rules.count
        criteria.rules.insert(SmartFolderRule(attribute: .name), at: index)
    }
}

private struct SmartFolderRuleRow: View {
    @Binding var rule: SmartFolderRule
    let canRemove: Bool
    let onAdd: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Picker("", selection: $rule.attribute) {
                ForEach(SmartFolderRule.Attribute.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)
            details
            Spacer(minLength: 0)
            Button(action: onRemove) { Image(systemName: "minus") }
                .disabled(!canRemove)
                .help("Remove this condition")
            Button(action: onAdd) { Image(systemName: "plus") }
                .help("Add a condition")
        }
    }

    @ViewBuilder
    private var details: some View {
        switch rule.attribute {
        case .kind:
            Picker("", selection: $rule.kindID) {
                ForEach(SmartFolderKind.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
            }
            .labelsHidden()
            .frame(width: 150)
            if rule.kindID == SmartFolderKind.other.rawValue {
                TextField("", text: $rule.text, prompt: Text(verbatim: "public.image, com.adobe.pdf"))
                    .textFieldStyle(.roundedBorder)
            }
        case .name, .contents, .whereFrom:
            Text("contains").foregroundStyle(.secondary)
            TextField("", text: $rule.text).textFieldStyle(.roundedBorder)
        case .tag:
            Text("is").foregroundStyle(.secondary)
            TextField("", text: $rule.text, prompt: Text("Red")).textFieldStyle(.roundedBorder)
        case .fileExtension:
            Text("is").foregroundStyle(.secondary)
            TextField("", text: $rule.text, prompt: Text(verbatim: "jpg, png")).textFieldStyle(.roundedBorder)
        case .created, .modified, .lastOpened:
            Picker("", selection: $rule.dateRange) {
                ForEach(SmartFolderRule.DateRange.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)
            switch rule.dateRange {
            case .lastDays:
                TextField("", value: $rule.days, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                Text("days").foregroundStyle(.secondary)
            case .after, .before:
                DatePicker("", selection: $rule.date, displayedComponents: .date).labelsHidden()
            default:
                EmptyView()
            }
        case .size:
            Picker("", selection: $rule.sizeComparison) {
                Text("is greater than").tag(SmartFolderRule.SizeComparison.greaterThan)
                Text("is less than").tag(SmartFolderRule.SizeComparison.lessThan)
            }
            .labelsHidden()
            .frame(width: 150)
            TextField("", value: $rule.size, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
            Picker("", selection: $rule.sizeUnit) {
                ForEach(SmartFolderRule.SizeUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        case .rawQuery:
            TextField("", text: $rule.text, prompt: Text(verbatim: "kMDItemFSName == \"*.pdf\"c"), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1...4)
        }
    }
}

/// Counts the criteria's results for the sheet, rerunning shortly after each change.
@MainActor
final class SmartFolderCountQuery: ObservableObject {
    @Published private(set) var count: Int?
    @Published private(set) var isGathering = false
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var pending: DispatchWorkItem?

    func update(_ criteria: SmartFolderCriteria) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.run(criteria)
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func stop() {
        pending?.cancel()
        pending = nil
        query?.stop()
        query = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        isGathering = false
    }

    private func run(_ criteria: SmartFolderCriteria) {
        stop()
        guard let raw = criteria.rawQuery, let predicate = SmartFolderQuery.predicate(for: raw) else {
            count = nil
            return
        }
        let query = NSMetadataQuery()
        query.predicate = predicate
        query.searchScopes = SmartFolderSearch.scopes(for: criteria.scopeStrings)
        query.notificationBatchingInterval = 0.5
        let refresh: @Sendable (Notification) -> Void = { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let query = notification.object as? NSMetadataQuery, query === self.query else { return }
                self.count = query.resultCount
                if notification.name == .NSMetadataQueryDidFinishGathering {
                    self.isGathering = false
                }
            }
        }
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryGatheringProgress, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main, using: refresh))
        }
        self.query = query
        isGathering = true
        if count == nil { count = 0 }
        if !query.start() {
            stop()
            count = nil
        }
    }
}

// MARK: - Titles

extension SmartFolderRule.Attribute {
    var title: String {
        switch self {
        case .kind: return String(localized: "Kind")
        case .name: return String(localized: "Name")
        case .contents: return String(localized: "Contents")
        case .created: return String(localized: "Date Created")
        case .modified: return String(localized: "Date Modified")
        case .lastOpened: return String(localized: "Last Opened Date")
        case .size: return String(localized: "Size")
        case .tag: return String(localized: "Tags")
        case .fileExtension: return String(localized: "File Extension")
        case .whereFrom: return String(localized: "Where From")
        case .rawQuery: return String(localized: "Raw Query")
        }
    }
}

extension SmartFolderRule.DateRange {
    var title: String {
        switch self {
        case .today: return String(localized: "Today")
        case .yesterday: return String(localized: "Yesterday")
        case .thisWeek: return String(localized: "This Week")
        case .lastDays: return String(localized: "Within Last")
        case .after: return String(localized: "On or After")
        case .before: return String(localized: "Before")
        }
    }
}

extension SmartFolderKind {
    var title: String {
        switch self {
        case .application: return String(localized: "Application")
        case .archive: return String(localized: "Archive")
        case .document: return String(localized: "Document")
        case .folder: return String(localized: "Folder")
        case .image: return String(localized: "Image")
        case .movie: return String(localized: "Movie")
        case .music: return String(localized: "Music")
        case .pdf: return String(localized: "PDF")
        case .presentation: return String(localized: "Presentation")
        case .text: return String(localized: "Text")
        case .sourceCode: return String(localized: "Source Code")
        case .other: return String(localized: "Other…")
        }
    }
}
