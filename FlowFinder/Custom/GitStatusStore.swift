import Foundation
import Combine
import CoreServices

/// Runs the real git binary: the one inside the selected developer directory, never the
/// /usr/bin/git shim (which offers to install the command line tools when they're missing).
enum GitCommand {
    static let executable: URL? = {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
              let output = run(URL(fileURLWithPath: "/usr/bin/xcode-select"), ["-p"], in: nil, timeout: 5),
              let developerDir = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !developerDir.isEmpty else { return nil }
        return [developerDir + "/usr/bin/git", developerDir + "/Toolchains/XcodeDefault.xctoolchain/usr/bin/git"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }()

    /// stdout, or nil when git is unavailable, fails or takes longer than `timeout`. Blocks; call off the main thread.
    static func git(_ arguments: [String], in directory: String, timeout: TimeInterval) -> Data? {
        guard let executable else { return nil }
        return run(executable, ["--no-optional-locks"] + arguments, in: directory, timeout: timeout)
    }

    private static func run(_ executable: URL, _ arguments: [String], in directory: String?, timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return data
    }
}

/// Git status of the repositories the browser shows, loaded in the background and refreshed on
/// file-system changes. Nothing runs for folders outside a repository.
@MainActor
final class GitStatusStore: ObservableObject {
    static let shared = GitStatusStore()
    static let didChange = Notification.Name("GitStatusStore.didChange")

    /// Bumped whenever any repository's status (or a folder's repository) becomes known
    @Published private(set) var generation = 0

    private final class Repository {
        var snapshot: GitStatusSnapshot?
        var isLoading = false
        var needsReload = false
        var limitUntracked = false
        var watcher: GitRepoWatcher?
        var reloadWork: DispatchWorkItem?
        var lastAccess = Date()
    }

    private struct RootLookup {
        let root: String?
        let resolvedAt: Date
    }

    private var roots: [String: RootLookup] = [:]
    private var resolving: Set<String> = []
    private var scheduledLoads: Set<String> = []
    private var repositories: [String: Repository] = [:]
    private var settingsObserver: AnyCancellable?
    private var gitAvailable: Bool?
    private let queue = DispatchQueue(label: "com.flowfinder.gitstatus", qos: .utility, attributes: .concurrent)

    nonisolated private static let maxEntriesWithAllUntracked = 20_000
    nonisolated private static let statusTimeout: TimeInterval = 10
    private static let maxWatchedRepositories = 6
    private static let negativeLookupLifetime: TimeInterval = 30

    private init() {
        settingsObserver = AppSettings.shared.$showGitStatus
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.reset() }
            }
    }

    private var isEnabled: Bool { AppSettings.shared.showGitStatus && gitAvailable != false }

    // MARK: Lookups

    func badge(for url: URL, isDirectory: Bool) -> GitBadge? {
        guard url.isFileURL, isEnabled else { return nil }
        let path = url.standardizedFileURL.path
        let parent = (path as NSString).deletingLastPathComponent
        guard let root = root(forDirectory: parent), let snapshot = snapshot(forRoot: root),
              path.count > root.count + 1 else { return nil }
        return snapshot.badge(forRelativePath: String(path.dropFirst(root.count + 1)), isDirectory: isDirectory)
    }

    /// The repository the folder is in, once its status is loaded.
    func repository(containing folder: URL) -> (root: String, snapshot: GitStatusSnapshot)? {
        guard folder.isFileURL, isEnabled else { return nil }
        guard let root = root(forDirectory: folder.standardizedFileURL.path),
              let snapshot = snapshot(forRoot: root) else { return nil }
        return (root, snapshot)
    }

    func relativePath(of url: URL, inRoot root: String) -> String? {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    func reload(root: String) {
        roots = roots.filter { $0.value.root != nil }
        load(root)
    }

    private func root(forDirectory directory: String) -> String? {
        if let lookup = roots[directory] {
            if lookup.root == nil, Date().timeIntervalSince(lookup.resolvedAt) > Self.negativeLookupLifetime {
                roots[directory] = nil
                resolveRoot(for: directory)
            }
            return lookup.root
        }
        resolveRoot(for: directory)
        return nil
    }

    private func snapshot(forRoot root: String) -> GitStatusSnapshot? {
        guard let repository = repositories[root] else {
            if scheduledLoads.insert(root).inserted {
                DispatchQueue.main.async { [weak self] in
                    self?.scheduledLoads.remove(root)
                    if self?.repositories[root] == nil { self?.load(root) }
                }
            }
            return nil
        }
        repository.lastAccess = Date()
        return repository.snapshot
    }

    private func resolveRoot(for directory: String) {
        guard resolving.insert(directory).inserted else { return }
        let checkGit = gitAvailable == nil
        queue.async { [weak self] in
            let available = checkGit ? GitCommand.executable != nil : true
            let root = available ? Self.findRoot(from: directory) : nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.resolving.remove(directory)
                if checkGit { self.gitAvailable = available }
                if self.roots.count > 5_000 { self.roots.removeAll() }
                self.roots[directory] = RootLookup(root: root, resolvedAt: Date())
                if root != nil { self.announce() }
            }
        }
    }

    nonisolated private static func findRoot(from directory: String) -> String? {
        var current = directory
        while !current.isEmpty {
            if FileManager.default.fileExists(atPath: current + "/.git") { return current }
            if current == "/" { break }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    // MARK: Loading

    private func load(_ root: String) {
        guard isEnabled else { return }
        let repository: Repository
        if let existing = repositories[root] {
            repository = existing
        } else {
            repository = Repository()
            repositories[root] = repository
            repository.watcher = GitRepoWatcher(path: root) { [weak self] paths in
                MainActor.assumeIsolated { self?.filesChanged(paths, inRoot: root) }
            }
            pruneRepositories()
        }
        guard !repository.isLoading else {
            repository.needsReload = true
            return
        }
        repository.isLoading = true
        repository.needsReload = false
        let limitUntracked = repository.limitUntracked
        queue.async { [weak self] in
            let result = Self.fetch(root: root, limitUntracked: limitUntracked)
            DispatchQueue.main.async {
                guard let self, let repository = self.repositories[root], repository.isLoading else { return }
                repository.isLoading = false
                repository.limitUntracked = result.limitUntracked
                repository.snapshot = result.snapshot
                self.announce()
                if repository.needsReload { self.load(root) }
            }
        }
    }

    nonisolated private static func fetch(root: String, limitUntracked: Bool) -> (snapshot: GitStatusSnapshot?, limitUntracked: Bool) {
        func status(_ untracked: String) -> Data? {
            GitCommand.git(["status", "--porcelain=v2", "-z", "--branch", "--ignored=matching", "--untracked-files=\(untracked)"],
                           in: root, timeout: statusTimeout)
        }
        var limited = limitUntracked
        var snapshot: GitStatusSnapshot?
        if !limited {
            if let data = status("all") {
                let parsed = GitStatusSnapshot.parse(data)
                if parsed.entries.count > maxEntriesWithAllUntracked { limited = true } else { snapshot = parsed }
            } else {
                limited = true
            }
        }
        if limited, snapshot == nil {
            snapshot = status("normal").map(GitStatusSnapshot.parse)
        }
        if snapshot != nil,
           let data = GitCommand.git(["config", "--get-regexp", "^remote\\..*\\.url$"], in: root, timeout: 5),
           let text = String(data: data, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let name = parts[0].dropFirst("remote.".count).dropLast(".url".count)
                snapshot?.remoteURLs[String(name)] = String(parts[1])
            }
        }
        return (snapshot, limited)
    }

    private func filesChanged(_ paths: [String], inRoot root: String) {
        guard let repository = repositories[root] else { return }
        guard paths.contains(where: { Self.isRelevant($0, root: root, watcher: repository.watcher, snapshot: repository.snapshot) })
        else { return }
        repository.reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.load(root) }
        repository.reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private static func isRelevant(_ path: String, root: String, watcher: GitRepoWatcher?, snapshot: GitStatusSnapshot?) -> Bool {
        let relative: String
        if path.hasPrefix(root + "/") {
            relative = String(path.dropFirst(root.count + 1))
        } else if let real = watcher?.resolvedPath, path.hasPrefix(real + "/") {
            relative = String(path.dropFirst(real.count + 1))
        } else {
            return true
        }
        if relative == ".git" { return true }
        if relative.hasPrefix(".git/") {
            let inside = relative.dropFirst(5)
            return ["index", "HEAD", "packed-refs", "MERGE_HEAD", "info/exclude"].contains(String(inside))
                || inside.hasPrefix("refs/")
        }
        return snapshot?.badge(forRelativePath: relative, isDirectory: false) != .file(.ignored)
    }

    private func pruneRepositories() {
        guard repositories.count > Self.maxWatchedRepositories else { return }
        let oldest = repositories.sorted { $0.value.lastAccess < $1.value.lastAccess }
            .prefix(repositories.count - Self.maxWatchedRepositories)
        for (root, repository) in oldest {
            repository.watcher?.stop()
            repository.reloadWork?.cancel()
            repositories[root] = nil
        }
    }

    private func reset() {
        for repository in repositories.values {
            repository.watcher?.stop()
            repository.reloadWork?.cancel()
        }
        repositories.removeAll()
        roots.removeAll()
        announce()
    }

    private func announce() {
        generation &+= 1
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: Last commit

    struct LastCommit: Equatable {
        let hash: String
        let author: String
        let date: Date?
        let subject: String
    }

    nonisolated static func lastCommit(root: String, relativePath: String) async -> LastCommit? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard let data = GitCommand.git(["log", "-1", "--format=%h%x1f%an%x1f%ct%x1f%s", "--", relativePath],
                                                in: root, timeout: 5),
                      let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines) else {
                    continuation.resume(returning: nil)
                    return
                }
                let fields = text.components(separatedBy: "\u{1f}")
                guard fields.count == 4 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: LastCommit(
                    hash: fields[0], author: fields[1],
                    date: TimeInterval(fields[2]).map(Date.init(timeIntervalSince1970:)), subject: fields[3]))
            }
        }
    }
}

/// FSEvents on a repository's working tree (file-level events, delivered on the main queue).
final class GitRepoWatcher {
    private var stream: FSEventStreamRef?
    private let handler: ([String]) -> Void
    /// The watched path with symlinks resolved, as FSEvents reports it
    let resolvedPath: String

    init?(path: String, handler: @escaping ([String]) -> Void) {
        self.handler = handler
        resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<GitRepoWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            watcher.handler(list)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
