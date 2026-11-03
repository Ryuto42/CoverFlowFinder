import SwiftUI
import AppKit

// BEGIN PLANNER

struct BatchRenameInput {
    let url: URL
    /// The name on disk.
    let name: String
    /// A plain folder has no extension to keep apart.
    let hasExtension: Bool

    var stem: String { hasExtension ? (name as NSString).deletingPathExtension : name }
    var pathExtension: String { hasExtension ? (name as NSString).pathExtension : "" }
}

struct BatchRenameOptions {
    enum Mode: Hashable { case replace, add, format }
    enum Position: Hashable { case before, after }
    enum FormatKind: Hashable { case index, counter, date }
    enum CaseStyle: Hashable { case unchanged, lowercase, uppercase, capitalized }

    var mode = Mode.replace

    var find = ""
    var replacement = ""
    var caseSensitive = false
    var useRegex = false
    var includeExtension = false

    var addedText = ""
    var addPosition = Position.after

    var formatKind = FormatKind.index
    var customName = ""
    var startNumber = 1
    var digits = 3
    var separator = " "
    var formatPosition = Position.after

    var caseStyle = CaseStyle.unchanged
    var changeExtension = false
    var newExtension = ""

    var isRegexValid: Bool {
        guard mode == .replace, useRegex, !find.isEmpty else { return true }
        return (try? NSRegularExpression(pattern: find)) != nil
    }
}

struct BatchRenameEntry: Identifiable {
    let id: Int
    let input: BatchRenameInput
    let newName: String
    /// Why this can't be applied; nil when fine.
    let problem: String?

    var isChange: Bool { newName != input.name }
}

enum BatchRenamePlanner {
    static func plan(
        _ inputs: [BatchRenameInput],
        options: BatchRenameOptions,
        now: Date = Date(),
        exists: (URL) -> Bool
    ) -> [BatchRenameEntry] {
        let names = inputs.enumerated().map { index, input in
            fileSystemName(newName(for: input, index: index, options: options, now: now))
        }
        func key(_ directory: URL, _ name: String) -> String {
            directory.standardizedFileURL.path.lowercased() + "\u{0}" + name.lowercased()
        }
        let sourceKeys = Set(inputs.map { key($0.url.deletingLastPathComponent(), $0.name) })
        var counts: [String: Int] = [:]
        for (input, name) in zip(inputs, names) {
            counts[key(input.url.deletingLastPathComponent(), name), default: 0] += 1
        }

        let regexProblem = options.isRegexValid ? nil : String(localized: "Invalid regular expression")
        return inputs.enumerated().map { index, input in
            let name = names[index]
            var problem: String?
            if name != input.name {
                let directory = input.url.deletingLastPathComponent()
                let destinationKey = key(directory, name)
                if let regexProblem {
                    problem = regexProblem
                } else if name.isEmpty || name == "." || name == ".." || name.contains("\0") || name.utf8.count > 255 {
                    problem = String(localized: "Invalid name")
                } else if name.hasPrefix("."), !input.name.hasPrefix(".") {
                    problem = String(localized: "A name can’t begin with a dot")
                } else if counts[destinationKey, default: 0] > 1 {
                    problem = String(localized: "Duplicate name")
                } else if !sourceKeys.contains(destinationKey), exists(directory.appendingPathComponent(name)) {
                    problem = String(localized: "The name is already taken")
                }
            }
            return BatchRenameEntry(id: index, input: input, newName: name, problem: problem)
        }
    }

    private static func fileSystemName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: ":")
    }

    static func newName(for input: BatchRenameInput, index: Int, options: BatchRenameOptions, now: Date) -> String {
        var stem = input.stem
        var ext = input.pathExtension

        switch options.mode {
        case .replace:
            if options.includeExtension {
                let replaced = replacing(in: input.name, options: options)
                let url = replaced as NSString
                if input.hasExtension {
                    stem = url.deletingPathExtension
                    ext = url.pathExtension
                } else {
                    stem = replaced
                }
            } else {
                stem = replacing(in: stem, options: options)
            }
        case .add:
            if !options.addedText.isEmpty {
                stem = options.addPosition == .before ? options.addedText + stem : stem + options.addedText
            }
        case .format:
            let base = options.customName.isEmpty ? stem : options.customName
            let token: String
            switch options.formatKind {
            case .index:
                token = String(options.startNumber + index)
            case .counter:
                let number = String(options.startNumber + index)
                token = String(repeating: "0", count: max(0, options.digits - number.count)) + number
            case .date:
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd"
                token = formatter.string(from: now)
            }
            stem = options.formatPosition == .before ? token + options.separator + base : base + options.separator + token
        }

        switch options.caseStyle {
        case .unchanged: break
        case .lowercase: stem = stem.lowercased()
        case .uppercase: stem = stem.uppercased()
        case .capitalized: stem = stem.prefix(1).uppercased() + stem.dropFirst().lowercased()
        }

        if options.changeExtension, input.hasExtension {
            ext = options.newExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        }
        return ext.isEmpty ? stem : stem + "." + ext
    }

    private static func replacing(in text: String, options: BatchRenameOptions) -> String {
        guard !options.find.isEmpty else { return text }
        if options.useRegex {
            guard let regex = try? NSRegularExpression(pattern: options.find, options: options.caseSensitive ? [] : [.caseInsensitive]) else { return text }
            let range = NSRange(text.startIndex..., in: text)
            return regex.stringByReplacingMatches(in: text, range: range, withTemplate: options.replacement)
        }
        return text.replacingOccurrences(of: options.find, with: options.replacement, options: options.caseSensitive ? [] : [.caseInsensitive])
    }
}

// END PLANNER

// MARK: - Applying

@MainActor
enum BatchRename {
    static func canRename(_ items: [FileItem]) -> Bool {
        items.count > 1 && items.allSatisfy { !$0.isFromArchive && $0.url.isFileURL }
    }

    static func present(items: [FileItem], viewModel: FileBrowserViewModel) {
        guard canRename(items), let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            NSSound.beep()
            return
        }
        let inputs = items.map { BatchRenameInput(url: $0.url, name: $0.url.lastPathComponent, hasExtension: !$0.isDirectory || $0.isPackage) }
        var sheetWindow: NSWindow?
        let close = {
            if let sheetWindow { window.endSheet(sheetWindow) }
            sheetWindow = nil
        }
        let view = BatchRenameSheet(inputs: inputs, onCancel: close) { [weak viewModel] renames in
            close()
            viewModel?.renameItemsAsBatch(renames)
        }
        let controller = NSHostingController(rootView: view)
        let panel = NSWindow(contentViewController: controller)
        panel.styleMask = [.titled]
        sheetWindow = panel
        window.beginSheet(panel)
    }

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path.lowercased() }

    /// Renames in an order that works when names are exchanged or shifted among the items
    /// (those go through a temporary name first). `finished` gets the journal of the moves made and
    /// the renames that took effect, and registers the one Undo.
    static func perform(
        _ renames: [(from: URL, to: URL)],
        finished: (FileOperationJournal, [(from: URL, to: URL)]) -> Void
    ) -> [FileOperationFailure] {
        let sourceKeys = Set(renames.map { key($0.from) })
        let journal = FileOperationJournal()
        var failures: [FileOperationFailure] = []
        var done: [(from: URL, to: URL)] = []
        var viaTemporary: [(from: URL, temporary: URL, to: URL)] = []
        var direct: [(from: URL, to: URL)] = []

        for rename in renames {
            if sourceKeys.contains(key(rename.to)), !FileOperationEngine.isSameItem(rename.from, rename.to) {
                let temporary = rename.from.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).flowfinder-batch")
                viaTemporary.append((rename.from, temporary, rename.to))
            } else {
                direct.append(rename)
            }
        }

        var parked: [(from: URL, temporary: URL, to: URL)] = []
        for entry in viaTemporary {
            do {
                try FileOperationEngine.renameItem(at: entry.from, to: entry.temporary, caseOnly: false)
                journal.steps.append(.moved(from: entry.from, to: entry.temporary))
                parked.append(entry)
            } catch {
                failures.append(FileOperationFailure(url: entry.from, error: error))
            }
        }
        for rename in direct {
            let caseOnly = FileOperationEngine.isSameItem(rename.from, rename.to)
            do {
                try FileOperationEngine.renameItem(at: rename.from, to: rename.to, caseOnly: caseOnly)
                journal.steps.append(.moved(from: rename.from, to: rename.to))
                done.append(rename)
            } catch {
                failures.append(FileOperationFailure(url: rename.from, error: error))
            }
        }
        for entry in parked {
            do {
                try FileOperationEngine.renameItem(at: entry.temporary, to: entry.to, caseOnly: false)
                journal.steps.append(.moved(from: entry.temporary, to: entry.to))
                done.append((entry.from, entry.to))
            } catch {
                failures.append(FileOperationFailure(url: entry.from, error: error))
                if (try? FileOperationEngine.renameItem(at: entry.temporary, to: entry.from, caseOnly: false)) != nil {
                    journal.steps.append(.moved(from: entry.temporary, to: entry.from))
                }
            }
        }
        if !journal.steps.isEmpty {
            finished(journal, done)
        }
        return failures
    }
}

// MARK: - Sheet

struct BatchRenameSheet: View {
    let inputs: [BatchRenameInput]
    let onCancel: () -> Void
    let onRename: ([(from: URL, to: URL)]) -> Void

    @State private var options = BatchRenameOptions()
    private let now = Date()

    private var entries: [BatchRenameEntry] {
        BatchRenamePlanner.plan(inputs, options: options, now: now) { FileOperationEngine.itemExists(at: $0) }
    }

    var body: some View {
        let entries = entries
        let changes = entries.filter(\.isChange)
        let hasProblem = entries.contains { $0.problem != nil }
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $options.mode) {
                Text("Replace Text").tag(BatchRenameOptions.Mode.replace)
                Text("Add Text").tag(BatchRenameOptions.Mode.add)
                Text("Format").tag(BatchRenameOptions.Mode.format)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch options.mode {
                case .replace: replaceFields
                case .add: addFields
                case .format: formatFields
                }
            }
            .frame(minHeight: 112, alignment: .top)

            Divider()
            HStack {
                Picker("Change Case", selection: $options.caseStyle) {
                    Text("Don’t Change").tag(BatchRenameOptions.CaseStyle.unchanged)
                    Text("Lowercase").tag(BatchRenameOptions.CaseStyle.lowercase)
                    Text("Uppercase").tag(BatchRenameOptions.CaseStyle.uppercase)
                    Text("Capitalize").tag(BatchRenameOptions.CaseStyle.capitalized)
                }
                .fixedSize()
                Spacer()
                Toggle("Change Extension", isOn: $options.changeExtension)
                TextField("", text: $options.newExtension)
                    .frame(width: 80)
                    .disabled(!options.changeExtension)
            }

            Text("Preview").font(.headline)
            List(entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: entry.input.name)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                        Text(verbatim: entry.newName)
                            .foregroundStyle(entry.problem != nil ? Color.red : (entry.isChange ? Color.primary : Color.secondary))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let problem = entry.problem {
                        Text(verbatim: problem).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .frame(height: 190)
            .border(Color.secondary.opacity(0.3))

            HStack {
                Text("\(changes.count) of \(entries.count) items will be renamed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    onRename(changes.map { ($0.input.url, $0.input.url.deletingLastPathComponent().appendingPathComponent($0.newName)) })
                }
                .keyboardShortcut(.defaultAction)
                .disabled(hasProblem || changes.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var replaceFields: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Find:").gridColumnAlignment(.trailing)
                TextField("", text: $options.find)
            }
            GridRow {
                Text("Replace With:")
                TextField("", text: $options.replacement)
            }
            GridRow {
                Color.clear.frame(width: 0, height: 0)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Case Sensitive", isOn: $options.caseSensitive)
                    Toggle("Regular Expression", isOn: $options.useRegex)
                    Toggle("Include Extension", isOn: $options.includeExtension)
                }
            }
        }
    }

    private var addFields: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Text:").gridColumnAlignment(.trailing)
                TextField("", text: $options.addedText)
            }
            GridRow {
                Text("Where:")
                positionPicker($options.addPosition)
            }
        }
    }

    private var formatFields: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Name Format:").gridColumnAlignment(.trailing)
                Picker("", selection: $options.formatKind) {
                    Text("Name and Index").tag(BatchRenameOptions.FormatKind.index)
                    Text("Name and Counter").tag(BatchRenameOptions.FormatKind.counter)
                    Text("Name and Date").tag(BatchRenameOptions.FormatKind.date)
                }
                .labelsHidden()
                .fixedSize()
            }
            GridRow {
                Text("Custom Name:")
                TextField("", text: $options.customName)
            }
            GridRow {
                Text("Where:")
                positionPicker($options.formatPosition)
            }
            GridRow {
                Text("Start Numbers At:")
                HStack {
                    TextField("", value: $options.startNumber, format: .number.grouping(.never))
                        .frame(width: 60)
                    Text("Digits:")
                    TextField("", value: $options.digits, format: .number.grouping(.never))
                        .frame(width: 40)
                        .disabled(options.formatKind != .counter)
                    Text("Separator:")
                    TextField("", text: $options.separator)
                        .frame(width: 50)
                }
            }
        }
    }

    private func positionPicker(_ selection: Binding<BatchRenameOptions.Position>) -> some View {
        Picker("", selection: selection) {
            Text("Before Name").tag(BatchRenameOptions.Position.before)
            Text("After Name").tag(BatchRenameOptions.Position.after)
        }
        .pickerStyle(.radioGroup)
        .horizontalRadioGroupLayout()
        .labelsHidden()
    }
}
