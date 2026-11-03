import AppKit
import SevenZipKit

// MARK: - Formats and levels

enum CustomArchiveFormat: String, CaseIterable, Hashable {
    case zip
    case sevenZip = "7z"
    case tarGz = "tar.gz"
    case tarXz = "tar.xz"
    case tarBz2 = "tar.bz2"
    case tar

    var title: String {
        switch self {
        case .zip: "ZIP"
        case .sevenZip: "7z"
        default: rawValue
        }
    }

    var supportsPassword: Bool { self == .zip || self == .sevenZip }

    /// The single-file compressor wrapped around a tar, if any.
    var outerFormatName: String? {
        switch self {
        case .tarGz: "gzip"
        case .tarXz: "xz"
        case .tarBz2: "bzip2"
        default: nil
        }
    }

    func archiveName(for items: [FileItem]) -> String {
        (items.count == 1 ? items[0].name : "Archive") + "." + rawValue
    }
}

enum CompressionLevel: String, CaseIterable, Identifiable {
    case normal, maximum, store

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: String(localized: "Normal")
        case .maximum: String(localized: "Maximum")
        case .store: String(localized: "No Compression")
        }
    }

    static var current: CompressionLevel {
        CompressionLevel(rawValue: UserDefaults.standard.string(forKey: "settings.compressionLevel") ?? "") ?? .normal
    }
}

struct ArchiveCreationRequest {
    var format: CustomArchiveFormat
    var level: CompressionLevel
    var password: String?

    /// The `-m` properties for the engine format `formatName` (the archive or a tar's outer compressor).
    func properties(for formatName: String) -> [SZUpdateProperty] {
        let p = { SZUpdateProperty(name: $0, value: $1) }
        let x = level == .maximum ? "9" : "5"
        switch formatName {
        case "zip":
            var list = level == .store ? [p("m", "Copy")] : [p("x", x), p("m", "Deflate"), p("mt", "on")]
            if password != nil { list.append(p("em", "AES256")) }
            return list
        case "7z":
            var list = level == .store ? [p("x", "0")] : [p("x", x), p("0", "LZMA2"), p("mt", "on")]
            if password != nil { list.append(p("he", "on")) }
            return list
        case "gzip", "bzip2": return [p("x", level == .store ? "1" : x)]
        case "xz": return [p("x", level == .store ? "0" : x), p("mt", "on")]
        default: return []
        }
    }
}

// MARK: - Engine

extension SevenZipArchiveBackend {
    /// Creates a fresh archive in caller-owned staging, like `createArchive(at:sources:format:progress:)`.
    func createArchive(at url: URL, sources: [URL], request: ArchiveCreationRequest, progress: Progress) throws {
        guard let outer = request.format.outerFormatName else {
            try update(url, formatName: request.format == .tar ? "tar" : request.format.rawValue,
                       specs: sources.map { SZPathSpec.literal($0.path) }, request: request, excludeMac: true, progress: progress)
            return
        }
        // tar first, then the single tar file through the compressor.
        let work = url.deletingLastPathComponent().appendingPathComponent(".tar-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let tar = work.appendingPathComponent(url.deletingPathExtension().lastPathComponent)
        progress.totalUnitCount = 100
        let tarProgress = Progress(totalUnitCount: 1)
        progress.addChild(tarProgress, withPendingUnitCount: 30)
        let packProgress = Progress(totalUnitCount: 1)
        progress.addChild(packProgress, withPendingUnitCount: 70)
        try update(tar, formatName: "tar", specs: sources.map { SZPathSpec.literal($0.path) },
                   request: request, excludeMac: true, progress: tarProgress)
        try update(url, formatName: outer, specs: [SZPathSpec.literal(tar.path)],
                   request: request, excludeMac: false, progress: packProgress)
    }

    private func update(_ url: URL, formatName: String, specs: [SZPathSpec], request: ArchiveCreationRequest,
                        excludeMac: Bool, progress: Progress) throws {
        try queue.sync {
            let delegate = EngineProgress(progress: progress, allowPasswordPrompt: true, passwordProvider: nil, reportsProgress: true)
            do {
                guard !FileOperationEngine.itemExists(at: url), !specs.isEmpty else {
                    throw FileOperationEngine.makeError(String(localized: "Choose files or folders and a new archive name."))
                }
                if delegate.progressCheckBreak() { throw CocoaError(.userCancelled) }
                let options = SZUpdateOptions(archivePath: url.path)
                options.formatName = formatName
                options.nameMode = .exact
                options.pathMode = .relative
                options.workingDirectory = ""
                options.deleteAfterCompressing = false
                options.stopAfterOpenError = true
                options.storeSymLinks = true
                options.properties = request.properties(for: formatName)
                if let password = request.password, !password.isEmpty, request.format.supportsPassword {
                    options.password = password
                }
                var allSpecs = specs
                if excludeMac, UserDefaults.standard.object(forKey: "settings.compressExcludeMacFiles") as? Bool ?? true {
                    allSpecs += Self.macMetadataPatterns.map {
                        SZPathSpec.spec(path: $0, include: false, recursedType: .recursed, wildcardMatching: true, markMode: .fileOrDir)
                    }
                }
                let result = try SZUpdater.update(with: options, pathSpecs: allSpecs, progress: delegate)
                if delegate.cancelled { throw CocoaError(.userCancelled) }
                guard result.errorCount == 0, result.failedPaths.isEmpty else {
                    let detail = result.failedPaths.prefix(5).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
                    throw FileOperationEngine.makeError(String(localized: "Some items could not be read. The archive was not created.") + (detail.isEmpty ? "" : "\n" + detail))
                }
                guard FileOperationEngine.itemExists(at: url) else {
                    throw FileOperationEngine.makeError(String(localized: "The compression engine did not create the requested archive."))
                }
            } catch {
                if delegate.cancelled { throw CocoaError(.userCancelled) }
                throw error
            }
        }
    }
}

// MARK: - Commands

@MainActor
enum CustomCompression {
    static func compress(_ items: [FileItem], format: CustomArchiveFormat, password: String? = nil, viewModel: FileBrowserViewModel) {
        let sources = viewModel.itemsForCompression(items)
        guard !sources.isEmpty else {
            NSSound.beep()
            return
        }
        let destination = viewModel.currentPath
        let request = ArchiveCreationRequest(format: format, level: CompressionLevel.current, password: password)
        let name = format.archiveName(for: sources)
        viewModel.runCreatingOperation(
            actionName: String(localized: "Compress"),
            failureVerb: String(localized: "compressed"),
            title: sources.count == 1 ? String(localized: "Compressing “\(sources[0].name)”") : String(localized: "Compressing \(sources.count) items")
        ) { journal, progress in
            ArchiveCompressionEngine.compress(sources, archiveName: name, destination: destination, journal: journal, progress: progress) {
                try SevenZipArchiveBackend.shared.createArchive(at: $0, sources: $1, request: request, progress: $2)
            }
        }
    }

    /// Asks for the password (twice) in a sheet, then compresses.
    static func compressWithPassword(_ items: [FileItem], format: CustomArchiveFormat, viewModel: FileBrowserViewModel) {
        guard !viewModel.itemsForCompression(items).isEmpty else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Compress with Password")
        alert.informativeText = String(localized: "The archive is encrypted with AES-256. You need the password to open it.")
        alert.addButton(withTitle: String(localized: "Compress"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let password = NSSecureTextField()
        let verify = NSSecureTextField()
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: String(localized: "Password:")), password],
            [NSTextField(labelWithString: String(localized: "Verify:")), verify]
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 220
        grid.frame = NSRect(x: 0, y: 0, width: 300, height: 56)
        alert.accessoryView = grid
        alert.window.initialFirstResponder = password

        let finish: (NSApplication.ModalResponse) -> Void = { [weak viewModel] response in
            guard response == .alertFirstButtonReturn, let viewModel else { return }
            guard !password.stringValue.isEmpty, password.stringValue == verify.stringValue else {
                NSSound.beep()
                FileOperationAlerts.showMessage(String(localized: "The passwords don’t match."),
                                                information: String(localized: "Enter the same password in both fields."))
                return
            }
            compress(items, format: format, password: password.stringValue, viewModel: viewModel)
        }
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// The "Compress" submenu. `targets` resolves the items when a command runs.
    static func menuEntry(viewModel: FileBrowserViewModel, targets: @escaping () -> [FileItem]) -> CustomMenuEntry {
        var children: [CustomMenuEntry] = CustomArchiveFormat.allCases.map { format in
            .action(format.title, enabled: true) { [weak viewModel] in
                guard let viewModel else { return }
                compress(targets(), format: format, viewModel: viewModel)
            }
        }
        children.append(.separator)
        for format in CustomArchiveFormat.allCases where format.supportsPassword {
            children.append(.action(String(localized: "\(format.title) with Password…"), enabled: true) { [weak viewModel] in
                guard let viewModel else { return }
                compressWithPassword(targets(), format: format, viewModel: viewModel)
            })
        }
        return .submenu(String(localized: "Compress"), enabled: !viewModel.itemsForCompression(targets()).isEmpty, children)
    }
}
