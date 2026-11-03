import Foundation

enum GitFileState: Equatable {
    case modified, added, untracked, deleted, renamed, conflicted, ignored

    var letter: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .untracked: "?"
        case .deleted: "D"
        case .renamed: "R"
        case .conflicted: "U"
        case .ignored: "!"
        }
    }

    var localizedDescription: String {
        switch self {
        case .modified: String(localized: "Changed")
        case .added: String(localized: "Added")
        case .untracked: String(localized: "Untracked")
        case .deleted: String(localized: "Deleted")
        case .renamed: String(localized: "Renamed")
        case .conflicted: String(localized: "Conflicted")
        case .ignored: String(localized: "Ignored")
        }
    }
}

/// What a file list shows for an item in a repository.
enum GitBadge: Equatable {
    case file(GitFileState)
    /// A folder with changes somewhere inside
    case folderChanges
}

/// `git status --porcelain=v2 -z --branch` output, keyed by repo-relative paths (NFC, no trailing "/").
struct GitStatusSnapshot {
    var branch: String?
    var oid: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    var entries: [String: GitFileState] = [:]
    /// Untracked or ignored directories ("? dir/", "! dir/"): everything below has that state
    var directoryStates: [String: GitFileState] = [:]
    /// Ancestor folders of changed (not ignored) entries
    var changedFolders: Set<String> = []
    var changeCount = 0
    var remoteURLs: [String: String] = [:]

    static func normalize(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
    }

    func badge(forRelativePath relativePath: String, isDirectory: Bool) -> GitBadge? {
        let path = Self.normalize(relativePath)
        if let state = entries[path] ?? directoryStates[path] { return .file(state) }
        if !directoryStates.isEmpty {
            var ancestor = Substring(path)
            while let slash = ancestor.lastIndex(of: "/") {
                ancestor = ancestor[..<slash]
                if let state = directoryStates[String(ancestor)] { return .file(state) }
            }
        }
        if isDirectory, changedFolders.contains(path) { return .folderChanges }
        return nil
    }

    var githubURL: URL? {
        let remote = upstream.flatMap { up in up.split(separator: "/").first.map(String.init) }
        guard let raw = remote.flatMap({ remoteURLs[$0] }) ?? remoteURLs["origin"] ?? remoteURLs.values.sorted().first
        else { return nil }
        return Self.githubWebURL(fromRemote: raw)
    }

    /// `git@github.com:o/r.git`, `ssh://git@github.com/o/r`, `https://github.com/o/r.git` → https://github.com/o/r
    static func githubWebURL(fromRemote remote: String) -> URL? {
        var rest: String
        if remote.hasPrefix("git@github.com:") {
            rest = String(remote.dropFirst("git@github.com:".count))
        } else if let url = URL(string: remote), url.host?.lowercased() == "github.com" {
            rest = String(url.path.drop(while: { $0 == "/" }))
        } else {
            return nil
        }
        if rest.hasSuffix(".git") { rest.removeLast(4) }
        if rest.hasSuffix("/") { rest.removeLast() }
        guard !rest.isEmpty else { return nil }
        return URL(string: "https://github.com/" + rest)
    }

    static func parse(_ data: Data) -> GitStatusSnapshot {
        var snapshot = GitStatusSnapshot()
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
        var index = 0
        while index < records.count {
            let line = String(decoding: records[index], as: UTF8.self)
            index += 1
            guard let kind = line.first else { continue }
            switch kind {
            case "#":
                snapshot.parseHeader(line)
            case "1":
                // 1 XY sub mH mI mW hH hI path
                let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count == 9 else { continue }
                snapshot.add(String(fields[8]), state: Self.state(forXY: fields[1]))
            case "2":
                // 2 XY sub mH mI mW hH hI Xscore path, then the original path as its own record
                let fields = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                index += 1
                guard fields.count == 10 else { continue }
                let xy = fields[1]
                snapshot.add(String(fields[9]), state: xy.contains("D") ? .deleted : .renamed)
            case "u":
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                let fields = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count == 11 else { continue }
                snapshot.add(String(fields[10]), state: .conflicted)
            case "?":
                snapshot.add(String(line.dropFirst(2)), state: .untracked)
            case "!":
                snapshot.add(String(line.dropFirst(2)), state: .ignored)
            default:
                continue
            }
        }
        return snapshot
    }

    private static func state(forXY xy: Substring) -> GitFileState {
        let x = xy.first ?? "."
        let y = xy.dropFirst().first ?? "."
        if x == "D" || y == "D" { return .deleted }
        if x == "A" { return .added }
        if x == "R" || x == "C" { return .renamed }
        return .modified
    }

    private mutating func parseHeader(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 2)
        guard parts.count == 3 else { return }
        let value = String(parts[2])
        switch parts[1] {
        case "branch.oid": oid = value == "(initial)" ? nil : value
        case "branch.head": branch = value == "(detached)" ? nil : value
        case "branch.upstream": upstream = value
        case "branch.ab":
            for token in value.split(separator: " ") {
                if token.hasPrefix("+") { ahead = Int(token.dropFirst()) ?? 0 }
                if token.hasPrefix("-") { behind = Int(token.dropFirst()) ?? 0 }
            }
        default: break
        }
    }

    private mutating func add(_ rawPath: String, state: GitFileState) {
        let isDirectory = rawPath.hasSuffix("/")
        let path = Self.normalize(isDirectory ? String(rawPath.dropLast()) : rawPath)
        guard !path.isEmpty else { return }
        if isDirectory {
            directoryStates[path] = state
        } else {
            entries[path] = state
        }
        guard state != .ignored else { return }
        changeCount += 1
        var ancestor = Substring(path)
        while let slash = ancestor.lastIndex(of: "/") {
            ancestor = ancestor[..<slash]
            guard changedFolders.insert(String(ancestor)).inserted else { break }
        }
    }
}
