import Foundation

// MARK: - Model

enum FolderCompareMethod: String, CaseIterable, Hashable {
    case dateAndSize
    case content
}

enum FolderSyncMode: String, CaseIterable, Hashable {
    case leftToRight
    case rightToLeft
    case bidirectional
}

enum FolderCompareStatus: Hashable {
    case leftOnly
    case rightOnly
    case same
    case leftNewer
    case rightNewer
    case sizeDiffers
    /// Same size and date (or no newer side) but different contents.
    case contentDiffers
    /// A file on one side, a folder on the other.
    case kindDiffers
    /// A folder on both sides; its rows below say what differs.
    case folder(hasDifferences: Bool)

    var isDifference: Bool {
        switch self {
        case .same: false
        case .folder(let hasDifferences): hasDifferences
        default: true
        }
    }
}

enum FolderSyncAction: Hashable, CaseIterable {
    case copyToRight
    case copyToLeft
    case deleteLeft
    case deleteRight
    case skip
}

struct FolderCompareOptions: Hashable {
    var method: FolderCompareMethod = .dateAndSize
    var excludeHidden = false
    var excludeDSStore = true
    var excludeGit = true
    /// Differences in modification dates up to this are ignored (FAT and SMB round them).
    var dateTolerance: TimeInterval = 2

    func excludes(_ name: String, isHidden: Bool) -> Bool {
        if excludeDSStore, name == ".DS_Store" { return true }
        if excludeGit, name == ".git" { return true }
        if excludeHidden, isHidden || name.hasPrefix(".") { return true }
        return false
    }
}

struct FolderCompareItemInfo: Hashable {
    let url: URL
    let isDirectory: Bool
    /// For a folder found on one side only: the total of the files in it.
    let size: Int64
    let modified: Date?
    /// Files inside a folder found on one side only.
    let fileCount: Int
}

struct FolderCompareEntry: Identifiable, Hashable {
    let relativePath: String
    let name: String
    let depth: Int
    let left: FolderCompareItemInfo?
    let right: FolderCompareItemInfo?
    var status: FolderCompareStatus
    var action: FolderSyncAction

    var id: String { relativePath }

    var isFolderRow: Bool {
        if case .folder = status { return true }
        return false
    }

    /// The actions that make sense for this row (none for a folder on both sides).
    var allowedActions: [FolderSyncAction] {
        guard !isFolderRow else { return [] }
        var actions: [FolderSyncAction] = []
        if left != nil { actions.append(.copyToRight) }
        if right != nil { actions.append(.copyToLeft) }
        if left != nil { actions.append(.deleteLeft) }
        if right != nil { actions.append(.deleteRight) }
        actions.append(.skip)
        return actions
    }
}

/// Shared between the scan (any thread) and the UI. Lock-protected.
final class FolderCompareProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled = false
    private var _scanned = 0
    private var _currentPath = ""

    var isCancelled: Bool { lock.withLock { _isCancelled } }
    var scannedCount: Int { lock.withLock { _scanned } }
    var currentPath: String { lock.withLock { _currentPath } }

    func cancel() { lock.withLock { _isCancelled = true } }

    func advance(_ path: String) {
        lock.withLock {
            _scanned += 1
            _currentPath = path
        }
    }
}

// MARK: - Comparing

enum FolderCompareEngine {
    struct Cancelled: Error {}

    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey
    ]

    /// Compares the two folders recursively. The rows are in tree order (a folder, then what's in
    /// it); a folder that's on one side only is one row. Each row gets the action `mode` suggests.
    static func compare(
        left: URL,
        right: URL,
        options: FolderCompareOptions,
        mode: FolderSyncMode,
        deleteExtras: Bool,
        progress: FolderCompareProgress? = nil
    ) throws -> [FolderCompareEntry] {
        var entries: [FolderCompareEntry] = []
        try compareDirectory(left: left, right: right, relative: "", depth: 0, options: options, progress: progress, into: &entries)
        return applyDefaultActions(entries, mode: mode, deleteExtras: deleteExtras)
    }

    private struct Child {
        let url: URL
        let name: String
        let isDirectory: Bool
        let size: Int64
        let modified: Date?
    }

    private static func children(of directory: URL, options: FolderCompareOptions) -> [String: Child] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [])) ?? []
        var result: [String: Child] = [:]
        for url in urls {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: Set(keys))
            if options.excludes(name, isHidden: values?.isHidden == true) { continue }
            let isLink = values?.isSymbolicLink == true
            let child = Child(
                url: url,
                name: name,
                isDirectory: !isLink && values?.isDirectory == true,
                size: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate
            )
            result[matchKey(name)] = child
        }
        return result
    }

    /// Names match the way the (usually case-insensitive) file system matches them.
    static func matchKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func compareDirectory(
        left: URL, right: URL, relative: String, depth: Int,
        options: FolderCompareOptions, progress: FolderCompareProgress?,
        into entries: inout [FolderCompareEntry]
    ) throws {
        let leftChildren = children(of: left, options: options)
        let rightChildren = children(of: right, options: options)
        let keys = Set(leftChildren.keys).union(rightChildren.keys).sorted { lhs, rhs in
            let l = leftChildren[lhs] ?? rightChildren[lhs]!
            let r = leftChildren[rhs] ?? rightChildren[rhs]!
            return l.name.localizedStandardCompare(r.name) == .orderedAscending
        }
        for key in keys {
            if progress?.isCancelled == true { throw Cancelled() }
            let l = leftChildren[key]
            let r = rightChildren[key]
            let name = (l ?? r)!.name
            let path = relative.isEmpty ? name : relative + "/" + name
            progress?.advance(path)

            if let l, let r, l.isDirectory, r.isDirectory {
                let index = entries.count
                entries.append(FolderCompareEntry(
                    relativePath: path, name: name, depth: depth,
                    left: info(l, totals: nil), right: info(r, totals: nil),
                    status: .folder(hasDifferences: false), action: .skip
                ))
                try compareDirectory(left: l.url, right: r.url, relative: path, depth: depth + 1, options: options, progress: progress, into: &entries)
                let hasDifferences = entries[(index + 1)...].contains { $0.depth == depth + 1 && $0.status.isDifference }
                entries[index].status = .folder(hasDifferences: hasDifferences)
                continue
            }

            let leftInfo = try l.map { info($0, totals: $0.isDirectory ? try totals(of: $0.url, progress: progress) : nil) }
            let rightInfo = try r.map { info($0, totals: $0.isDirectory ? try totals(of: $0.url, progress: progress) : nil) }
            let status = try self.status(left: leftInfo, right: rightInfo, options: options, progress: progress)
            entries.append(FolderCompareEntry(
                relativePath: path, name: name, depth: depth,
                left: leftInfo, right: rightInfo, status: status, action: .skip
            ))
        }
    }

    private static func info(_ child: Child, totals: (size: Int64, files: Int)?) -> FolderCompareItemInfo {
        FolderCompareItemInfo(
            url: child.url, isDirectory: child.isDirectory,
            size: totals?.size ?? (child.isDirectory ? 0 : child.size),
            modified: child.modified, fileCount: totals?.files ?? (child.isDirectory ? 0 : 1)
        )
    }

    /// Everything in a folder that's copied or trashed as a whole (exclusions don't apply).
    private static func totals(of folder: URL, progress: FolderCompareProgress?) throws -> (size: Int64, files: Int) {
        var size: Int64 = 0
        var files = 0
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [])
        while let url = enumerator?.nextObject() as? URL {
            if progress?.isCancelled == true { throw Cancelled() }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory != true {
                files += 1
                size += Int64(values?.fileSize ?? 0)
            }
        }
        return (size, files)
    }

    static func status(left: FolderCompareItemInfo?, right: FolderCompareItemInfo?, options: FolderCompareOptions, progress: FolderCompareProgress? = nil) throws -> FolderCompareStatus {
        guard let left else { return .rightOnly }
        guard let right else { return .leftOnly }
        if left.isDirectory != right.isDirectory { return .kindDiffers }
        let newer = newerSide(left.modified, right.modified, tolerance: options.dateTolerance)
        switch options.method {
        case .dateAndSize:
            if let newer { return newer }
            return left.size == right.size ? .same : .sizeDiffers
        case .content:
            if left.size != right.size { return newer ?? .sizeDiffers }
            if try contentsEqual(left.url, right.url, progress: progress) { return .same }
            return newer ?? .contentDiffers
        }
    }

    private static func newerSide(_ left: Date?, _ right: Date?, tolerance: TimeInterval) -> FolderCompareStatus? {
        guard let left, let right else { return nil }
        let difference = left.timeIntervalSince(right)
        if difference > tolerance { return .leftNewer }
        if difference < -tolerance { return .rightNewer }
        return nil
    }

    static func contentsEqual(_ lhs: URL, _ rhs: URL, progress: FolderCompareProgress? = nil) throws -> Bool {
        guard let a = FileHandle(forReadingAtPath: lhs.path), let b = FileHandle(forReadingAtPath: rhs.path) else {
            // Unreadable (or a symbolic link to nothing): compare where the links point.
            let la = try? FileManager.default.destinationOfSymbolicLink(atPath: lhs.path)
            let lb = try? FileManager.default.destinationOfSymbolicLink(atPath: rhs.path)
            return la != nil && la == lb
        }
        defer {
            try? a.close()
            try? b.close()
        }
        let chunk = 1 << 20
        while true {
            if progress?.isCancelled == true { throw Cancelled() }
            let da = (try? a.read(upToCount: chunk)) ?? nil
            let db = (try? b.read(upToCount: chunk)) ?? nil
            if da != db { return false }
            if da == nil || da?.isEmpty == true { return true }
        }
    }

    // MARK: Actions

    static func defaultAction(for entry: FolderCompareEntry, mode: FolderSyncMode, deleteExtras: Bool) -> FolderSyncAction {
        switch (entry.status, mode) {
        case (.folder, _), (.same, _):
            return .skip
        case (.leftOnly, .leftToRight), (.leftOnly, .bidirectional):
            return .copyToRight
        case (.leftOnly, .rightToLeft):
            return deleteExtras ? .deleteLeft : .skip
        case (.rightOnly, .rightToLeft), (.rightOnly, .bidirectional):
            return .copyToLeft
        case (.rightOnly, .leftToRight):
            return deleteExtras ? .deleteRight : .skip
        case (_, .leftToRight):
            return .copyToRight
        case (_, .rightToLeft):
            return .copyToLeft
        case (.leftNewer, .bidirectional):
            return .copyToRight
        case (.rightNewer, .bidirectional):
            return .copyToLeft
        case (_, .bidirectional):
            // No newer side to go by: the user decides.
            return .skip
        }
    }

    static func applyDefaultActions(_ entries: [FolderCompareEntry], mode: FolderSyncMode, deleteExtras: Bool) -> [FolderCompareEntry] {
        entries.map { entry in
            var entry = entry
            entry.action = defaultAction(for: entry, mode: mode, deleteExtras: deleteExtras)
            return entry
        }
    }
}

// MARK: - Plan

struct FolderSyncPlan: Equatable {
    struct Copy: Equatable {
        let source: URL
        let destination: URL
        /// Something is at the destination: it goes to the Trash first.
        let replaces: Bool
        let size: Int64
        let files: Int
    }

    var trash: [URL] = []
    var copies: [Copy] = []
    var copiesToRight = 0
    var copiesToLeft = 0
    var bytesToCopy: Int64 = 0
    var trashedFiles = 0
    var replacedCount = 0

    var isEmpty: Bool { trash.isEmpty && copies.isEmpty }

    static func make(from entries: [FolderCompareEntry], leftRoot: URL, rightRoot: URL) -> FolderSyncPlan {
        var plan = FolderSyncPlan()
        for entry in entries where !entry.isFolderRow {
            switch entry.action {
            case .copyToRight:
                guard let source = entry.left else { continue }
                let destination = entry.right?.url ?? rightRoot.appendingPathComponent(entry.relativePath, isDirectory: source.isDirectory)
                plan.add(Copy(source: source.url, destination: destination, replaces: entry.right != nil, size: source.size, files: source.fileCount))
                plan.copiesToRight += 1
            case .copyToLeft:
                guard let source = entry.right else { continue }
                let destination = entry.left?.url ?? leftRoot.appendingPathComponent(entry.relativePath, isDirectory: source.isDirectory)
                plan.add(Copy(source: source.url, destination: destination, replaces: entry.left != nil, size: source.size, files: source.fileCount))
                plan.copiesToLeft += 1
            case .deleteLeft:
                guard let item = entry.left else { continue }
                plan.trash.append(item.url)
                plan.trashedFiles += item.fileCount
            case .deleteRight:
                guard let item = entry.right else { continue }
                plan.trash.append(item.url)
                plan.trashedFiles += item.fileCount
            case .skip:
                continue
            }
        }
        return plan
    }

    private mutating func add(_ copy: Copy) {
        copies.append(copy)
        bytesToCopy += copy.size
        if copy.replaces { replacedCount += 1 }
    }
}
