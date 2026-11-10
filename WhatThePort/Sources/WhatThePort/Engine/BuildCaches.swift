import Darwin
import Foundation

/// Folders that package managers and build tools recreate on their own.
/// Anything not listed here is never offered for deletion.
enum ArtifactKind: String, Codable, CaseIterable {
    case nodeModules, next, turbo, webBuild, rust, swift, xcode, java, cocoaPods, pythonEnv, pythonCache, cache

    var label: String {
        switch self {
        case .nodeModules: return "node_modules"
        case .next: return ".next"
        case .turbo: return ".turbo"
        case .webBuild: return L10n.text("Web builds")
        case .rust: return "Rust"
        case .swift: return "SwiftPM"
        case .xcode: return "Xcode"
        case .java: return "Gradle & Maven"
        case .cocoaPods: return "CocoaPods"
        case .pythonEnv: return L10n.text("Python envs")
        case .pythonCache: return L10n.text("Python caches")
        case .cache: return L10n.text("Caches")
        }
    }

    /// Stable colour per kind, from the same palette as ports.
    var colorIndex: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// One regenerable folder, e.g. `…/my-app/node_modules`.
struct BuildArtifact: Codable, Identifiable, Equatable {
    let path: String
    let kind: ArtifactKind
    /// Allocated on disk.
    var size: UInt64
    /// What deleting it frees: blocks not shared with APFS clones. pnpm clones
    /// node_modules from its store, so those free far less than they occupy.
    var reclaimable: UInt64
    var modified: Date

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

/// A linked worktree's own files: the checkout and anything else in it that
/// isn't a build cache. Deleting caches never touches it; removing the
/// worktree with git frees it.
struct WorktreeCheckout: Codable, Equatable {
    /// What removing the worktree would free on top of its caches.
    var reclaimable: UInt64
    /// When the worktree last changed, as far as a rescan can tell cheaply.
    var stamp: Date?
}

/// What removing a linked worktree would lose, from git. Checked before a
/// worktree can be picked and again right before it's removed.
struct WorktreeStatus: Equatable {
    enum Blocker: Equatable {
        /// Tracked files with changes, staged or not.
        case changes(Int)
        /// A detached HEAD with commits on no branch, remote or tag.
        case orphaned
        case locked
    }

    var changes = 0
    /// Untracked files and folders outside the caches, as git lists them. Removing deletes them.
    var untracked: [String] = []
    /// Ignored files that look like secrets or local settings, such as `.env`. Removing deletes them.
    var secrets: [String] = []
    /// Commits on HEAD that are on no remote. The branch keeps them. Nil without remotes.
    var unpushed: Int?
    var orphaned = false
    var locked = false

    /// Why the worktree is kept, if it is.
    var blocker: Blocker? {
        if changes > 0 { return .changes(changes) }
        if orphaned { return .orphaned }
        if locked { return .locked }
        return nil
    }

    var hasWarnings: Bool { !untracked.isEmpty || !secrets.isEmpty || (unpushed ?? 0) > 0 }
}

/// A repository, worktree or top-level folder and the artifacts inside it.
struct CacheProject: Codable, Identifiable, Equatable {
    let root: String
    var name: String
    /// The main repository's folder name, for linked worktrees.
    var repository: String?
    /// The main repository's path, for linked worktrees.
    var repositoryRoot: String?
    var branch: String?
    var lastUsed: Date
    var artifacts: [BuildArtifact]
    /// Measured for linked worktrees only.
    var checkout: WorktreeCheckout?

    var id: String { root }
    var isWorktree: Bool { repository != nil }
    var size: UInt64 { artifacts.reduce(0) { $0 + $1.size } }
    var reclaimable: UInt64 { artifacts.reduce(0) { $0 + $1.reclaimable } }
    var checkoutBytes: UInt64 { checkout?.reclaimable ?? 0 }
    /// Still worth listing: it has caches, or it's a worktree taking up space.
    var isListed: Bool { !artifacts.isEmpty || checkoutBytes > 0 }

    /// What deleting its caches and removing the worktree would free together.
    var footprint: UInt64 { reclaimable + checkoutBytes }

    /// Whatever takes the most space first, then the most freeable caches.
    static func largerFirst(_ a: CacheProject, _ b: CacheProject) -> Bool {
        if a.footprint != b.footprint { return a.footprint > b.footprint }
        if a.reclaimable != b.reclaimable { return a.reclaimable > b.reclaimable }
        return a.root < b.root
    }

    /// Path below the project root, e.g. `apps/web/.next`.
    func relativePath(of artifact: BuildArtifact) -> String {
        artifact.path.hasPrefix(root + "/") ? String(artifact.path.dropFirst(root.count + 1)) : artifact.name
    }
}

/// Finds and measures build artifacts. Everything here is synchronous and
/// thread-safe; `BuildCacheStore` runs it off the main thread.
enum BuildCacheScanner {
    struct Candidate {
        let path: String
        let kind: ArtifactKind
        let project: String
        /// Generic names like `dist` only count when git ignores them.
        let needsIgnoreCheck: Bool
    }

    static let maxDepth = 12

    // MARK: - Scan

    /// Walks `roots`, then measures every artifact in parallel, then the
    /// checkout of every linked worktree found. Artifacts in `reuse` whose
    /// folder hasn't changed keep their size instead of being measured again,
    /// and so do checkouts in `reuseCheckouts`. `progress` is called from
    /// worker threads, with the artifact measured or nil for a checkout.
    static func scan(roots: [String], reuse: [String: BuildArtifact] = [:], reuseCheckouts: [String: WorktreeCheckout] = [:],
                     progress: (_ artifact: (artifact: BuildArtifact, project: String)?, _ total: Int) -> Void = { _, _ in }) -> [CacheProject] {
        let found = discoverAll(roots: roots)
        let candidates = gitFilter(found.candidates)
        let worktrees = found.repositories.filter(isLinkedWorktree)
        let total = candidates.count + worktrees.count
        let artifacts = measure(candidates, reuse: reuse) { artifact, project in progress((artifact, project), total) }
        let checkouts = measureCheckouts(worktrees, excluding: artifacts.map(\.artifact.path) + found.repositories,
                                         reuse: reuseCheckouts) { progress(nil, total) }
        return group(artifacts, checkouts: checkouts)
    }

    static func group(_ artifacts: [(artifact: BuildArtifact, project: String)],
                      checkouts: [String: WorktreeCheckout] = [:]) -> [CacheProject] {
        var byProject = Dictionary(grouping: artifacts, by: \.project).mapValues { $0.map(\.artifact) }
        for root in checkouts.keys where byProject[root] == nil { byProject[root] = [] }
        return byProject.map { root, entries in
            var project = project(root: root, artifacts: entries.sorted { $0.reclaimable > $1.reclaimable })
            project.checkout = checkouts[root]
            return project
        }
        .filter(\.isListed)
        .sorted(by: CacheProject.largerFirst)
    }

    // MARK: - Discovery

    static func discover(roots: [String]) -> [Candidate] {
        discoverAll(roots: roots).candidates
    }

    /// Artifacts, plus every repository and worktree passed on the way.
    static func discoverAll(roots: [String]) -> (candidates: [Candidate], repositories: [String]) {
        var seen = Set<String>()
        let roots = roots.map { ($0 as NSString).standardizingPath }.filter { seen.insert($0).inserted }
        // Split each root by its top-level folders so big projects walk in parallel.
        var starts: [(path: String, depth: Int, project: String)] = []
        var found: [Candidate] = []
        var repositories: [String] = []
        let lister = DirectoryLister()
        for root in roots where !roots.contains(where: { $0 != root && root.hasPrefix($0 + "/") }) {
            guard let entries = lister.list(root) else { continue }
            let names = Set(entries.map(\.name))
            let rootProject = names.contains(".git") ? root : nil
            if let rootProject { repositories.append(rootProject) }
            for entry in entries where entry.isDirectory && !entry.isDataless && !skipped(entry.name) {
                let path = root + "/" + entry.name
                let project = rootProject ?? path
                if let rule = classify(entry.name, path: path, siblings: names) {
                    found.append(Candidate(path: path, kind: rule.kind, project: rootProject ?? root, needsIgnoreCheck: rule.needsIgnoreCheck))
                } else {
                    starts.append((path, 1, project))
                }
            }
        }
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: starts.count) { index in
            let start = starts[index]
            let walked = walk(start.path, depth: start.depth, project: start.project)
            lock.lock()
            found.append(contentsOf: walked.candidates)
            repositories.append(contentsOf: walked.repositories)
            lock.unlock()
        }
        return (found, repositories)
    }

    /// Depth-first walk that stops at artifacts, so their contents are never listed here.
    private static func walk(_ start: String, depth: Int, project: String) -> (candidates: [Candidate], repositories: [String]) {
        let lister = DirectoryLister()
        var found: [Candidate] = []
        var repositories: [String] = []
        var stack = [(path: start, depth: depth, project: project)]
        while let current = stack.popLast() {
            guard let entries = lister.list(current.path) else { continue }
            let names = Set(entries.map(\.name))
            let isRepository = names.contains(".git")
            if !isRepository, names.contains("CACHEDIR.TAG"), hasCacheTag(current.path) {
                let name = (current.path as NSString).lastPathComponent
                let kind: ArtifactKind = name == "target" ? .rust : name == ".build" ? .swift : .cache
                found.append(Candidate(path: current.path, kind: kind, project: current.project, needsIgnoreCheck: false))
                continue
            }
            if isRepository { repositories.append(current.path) }
            let project = isRepository ? current.path : current.project
            for entry in entries where entry.isDirectory && !entry.isDataless && !skipped(entry.name) {
                let path = current.path + "/" + entry.name
                if let rule = classify(entry.name, path: path, siblings: names) {
                    found.append(Candidate(path: path, kind: rule.kind, project: project, needsIgnoreCheck: rule.needsIgnoreCheck))
                } else if current.depth < maxDepth {
                    stack.append((path, current.depth + 1, project))
                }
            }
        }
        return (found, repositories)
    }

    private static let skippedSuffixes = [".app", ".xcodeproj", ".xcworkspace", ".xcassets", ".framework", ".photoslibrary", ".lproj"]

    private static func skipped(_ name: String) -> Bool {
        name == ".git" || name == ".hg" || name == ".svn" || name == ".Trash" || skippedSuffixes.contains { name.hasSuffix($0) }
    }

    /// Decides from a folder's name and its siblings whether it's an artifact.
    static func classify(_ name: String, path: String, siblings: Set<String>) -> (kind: ArtifactKind, needsIgnoreCheck: Bool)? {
        let gradle = siblings.contains("build.gradle") || siblings.contains("build.gradle.kts")
            || siblings.contains("settings.gradle") || siblings.contains("settings.gradle.kts") || siblings.contains("gradlew")
        switch name {
        case "node_modules": return (.nodeModules, false)
        case ".next": return (.next, false)
        case ".turbo": return (.turbo, false)
        case ".nuxt", ".svelte-kit", ".parcel-cache", ".angular", ".docusaurus", ".expo", ".astro", ".vinxi":
            return (.webBuild, false)
        case "DerivedData": return (.xcode, false)
        case "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox", ".hypothesis": return (.pythonCache, false)
        case ".venv", "venv":
            return access(path + "/pyvenv.cfg", F_OK) == 0 ? (.pythonEnv, false) : nil
        case "target":
            if siblings.contains("Cargo.toml") { return (.rust, false) }
            if siblings.contains("pom.xml") { return (.java, false) }
            return nil
        case ".build": return siblings.contains("Package.swift") ? (.swift, false) : nil
        case "Pods": return siblings.contains("Podfile") ? (.cocoaPods, false) : nil
        case ".gradle": return gradle ? (.java, false) : nil
        case "build":
            if gradle { return (.java, true) }
            if siblings.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) { return (.xcode, true) }
            return siblings.contains("package.json") ? (.webBuild, true) : nil
        case "dist", "out", "coverage", "storybook-static", ".output":
            return siblings.contains("package.json") ? (.webBuild, true) : nil
        default:
            return nil
        }
    }

    /// https://bford.info/cachedir/: the file must start with this signature.
    private static func hasCacheTag(_ directory: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: directory + "/CACHEDIR.TAG") else { return false }
        defer { try? handle.close() }
        let signature = "Signature: 8a477f597d28d172789f06886806bc55"
        return handle.readData(ofLength: signature.utf8.count) == Data(signature.utf8)
    }

    // MARK: - Git

    /// Keeps generic names (`dist`, `build`, `out`) only where git ignores them,
    /// so committed output is never offered. Outside git, only folders with a
    /// build-tool marker (Gradle, Xcode) stay.
    static func gitFilter(_ candidates: [Candidate]) -> [Candidate] {
        let ambiguous = Dictionary(grouping: candidates.filter(\.needsIgnoreCheck), by: \.project)
        guard !ambiguous.isEmpty else { return candidates }
        var ignored = Set<String>()
        let repositories = ambiguous.filter { FileManager.default.fileExists(atPath: $0.key + "/.git") }.map { ($0.key, $0.value) }
        if let git = gitPath {
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: repositories.count) { index in
                let (project, entries) = repositories[index]
                let relative = entries.map { String($0.path.dropFirst(project.count + 1)) }
                let lines = run(git, ["-C", project, "-c", "core.fsmonitor=false", "check-ignore", "--stdin"],
                                input: relative.joined(separator: "\n") + "\n")
                lock.lock()
                lines.forEach { ignored.insert(project + "/" + $0) }
                lock.unlock()
            }
        }
        return candidates.filter { candidate in
            guard candidate.needsIgnoreCheck else { return true }
            if FileManager.default.fileExists(atPath: candidate.project + "/.git") { return ignored.contains(candidate.path) }
            return candidate.kind != .webBuild
        }
    }

    /// Never `/usr/bin/git`: without the developer tools it asks to install them.
    static let gitPath: String? = {
        ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/Library/Developer/CommandLineTools/usr/bin/git",
         "/Applications/Xcode.app/Contents/Developer/usr/bin/git"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    private static func run(_ executable: String, _ arguments: [String], input: String) -> [String] {
        let process = Process()
        let stdin = Pipe(), stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        // Read-only: never refresh the index while someone else uses the repository.
        process.environment = ProcessInfo.processInfo.environment.merging(["GIT_OPTIONAL_LOCKS": "0"]) { $1 }
        do { try process.run() } catch { return [] }
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try? stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    }

    /// Runs git and returns its exit status and lines, untrimmed. Hooks and
    /// optional locks are off, so it never touches anything but what it's asked.
    @discardableResult
    static func git(_ arguments: [String], in directory: String) -> (status: Int32, lines: [String]) {
        guard let gitPath else { return (-1, []) }
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = ["-C", directory, "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.environment = ProcessInfo.processInfo.environment.merging(["GIT_OPTIONAL_LOCKS": "0"]) { $1 }
        do { try process.run() } catch { return (-1, []) }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return (process.terminationStatus, lines)
    }

    // MARK: - Worktrees

    /// What removing the worktree at `root` would lose. `artifacts` are its
    /// caches, which never count as untracked work. Nil if it isn't a linked
    /// worktree or git can't read it.
    static func worktreeStatus(_ root: String, artifacts: [String]) -> WorktreeStatus? {
        guard gitPath != nil, let gitDir = gitDirectory(root), mainRepository(gitDirectory: gitDir) != nil else { return nil }
        let status = git(["status", "--porcelain"], in: root)
        guard status.status == 0 else { return nil }
        let caches = artifacts.compactMap { $0.hasPrefix(root + "/") ? String($0.dropFirst(root.count + 1)) : nil }
        let isCache = { (path: String) in caches.contains { path == $0 || path.hasPrefix($0 + "/") } }
        var result = WorktreeStatus()
        for line in status.lines where line.count > 3 {
            let code = line.prefix(2), path = String(line.dropFirst(3)).trimmingCharacters(in: CharacterSet(charactersIn: "/\""))
            if code == "??" {
                if !isCache(path) { result.untracked.append(path) }
            } else if code != "!!" {
                result.changes += 1
            }
        }
        result.secrets = git(["ls-files", "--others", "--ignored", "--exclude-standard", "--directory"], in: root).lines
            .filter { !$0.hasSuffix("/") && !isCache($0) && looksSecret(($0 as NSString).lastPathComponent) }
        if !git(["remote"], in: root).lines.isEmpty {
            result.unpushed = git(["rev-list", "--count", "HEAD", "--not", "--remotes"], in: root).lines.first.flatMap { Int($0) }
        }
        if git(["symbolic-ref", "-q", "HEAD"], in: root).status != 0 {
            let lost = git(["rev-list", "--count", "HEAD", "--not", "--branches", "--remotes", "--tags"], in: root).lines.first.flatMap { Int($0) }
            result.orphaned = (lost ?? 1) > 0
        }
        result.locked = access(gitDir + "/locked", F_OK) == 0
        return result
    }

    /// `.env`, keys and local settings: ignored, so git won't keep them, and not recreated by any tool.
    static func looksSecret(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasPrefix(".env") {
            return ![".example", ".sample", ".template", ".dist", ".defaults"].contains { lower.hasSuffix($0) }
        }
        let extensions = ["pem", "key", "p12", "p8", "pfx", "jks", "keystore", "mobileprovision", "cer"]
        if extensions.contains((lower as NSString).pathExtension) { return true }
        return [".npmrc", ".netrc", ".pypirc", "credentials.json", "service-account.json"].contains(lower) || lower.contains("secret")
    }

    /// Removes a linked worktree for good: checks it again, deletes its caches
    /// (the bulk of it, with progress), then has git remove the rest and its
    /// administrative files. The branch stays in the repository. Anything
    /// with tracked changes, a detached HEAD's own commits or a lock is kept.
    static func removeWorktree(_ project: CacheProject, roots: [String], progress: (Double) -> Void = { _ in }) -> Bool {
        let root = (project.root as NSString).standardizingPath
        var info = stat()
        guard root == project.root, lstat(root, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              roots.contains(where: { root.hasPrefix(($0 as NSString).standardizingPath + "/") }),
              let gitDir = gitDirectory(root), let repository = mainRepository(gitDirectory: gitDir),
              let status = worktreeStatus(root, artifacts: project.artifacts.map(\.path)), status.blocker == nil else { return false }
        let caches = project.artifacts.filter { isStillArtifact($0, roots: roots) }
        let cacheBytes = Double(caches.reduce(0) { $0 + $1.reclaimable })
        let total = max(cacheBytes + Double(project.checkoutBytes), 1)
        var done = 0.0
        for artifact in caches {
            let share = Double(artifact.reclaimable) / total
            _ = remove(artifact, roots: roots) { progress(done + $0 * share) }
            done += share
        }
        // Untracked files and nested caches git doesn't know about need --force; tracked changes were ruled out above.
        git(["worktree", "remove", "--force", root], in: repository)
        progress(1)
        return access(root, F_OK) != 0
    }

    // MARK: - Projects

    static func project(root: String, artifacts: [BuildArtifact]) -> CacheProject {
        var project = CacheProject(root: root, name: (root as NSString).lastPathComponent, repository: nil, branch: nil,
                                   lastUsed: artifacts.map(\.modified).max() ?? .distantPast, artifacts: artifacts)
        guard let gitDir = gitDirectory(root) else { return project }
        if let repository = mainRepository(gitDirectory: gitDir) {
            project.repositoryRoot = repository
            project.repository = (repository as NSString).lastPathComponent
        }
        if let head = try? String(contentsOfFile: gitDir + "/HEAD", encoding: .utf8) {
            let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("ref: refs/heads/") { project.branch = String(trimmed.dropFirst("ref: refs/heads/".count)) }
        }
        // Git touches the index on every checkout, commit and status.
        if let index = modified(gitDir + "/index") { project.lastUsed = max(project.lastUsed, index) }
        return project
    }

    /// The main repository of a linked worktree, from its git directory
    /// (`<repository>/.git/worktrees/<name>`).
    private static func mainRepository(gitDirectory: String) -> String? {
        gitDirectory.range(of: "/.git/worktrees/").map { String(gitDirectory[..<$0.lowerBound]) }
    }

    static func isLinkedWorktree(_ root: String) -> Bool {
        gitDirectory(root).flatMap { mainRepository(gitDirectory: $0) } != nil
    }

    private static func gitDirectory(_ root: String) -> String? {
        let git = root + "/.git"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: git, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return git }
        guard let contents = try? String(contentsOfFile: git, encoding: .utf8),
              let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        return path.hasPrefix("/") ? path : ((root + "/" + path) as NSString).standardizingPath
    }

    static func modified(_ path: String) -> Date? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
    }

    // MARK: - Measuring

    /// Measures candidates in parallel, largest kinds first so totals settle early.
    static func measure(_ candidates: [Candidate], reuse: [String: BuildArtifact] = [:],
                        each: (BuildArtifact, String) -> Void = { _, _ in }) -> [(artifact: BuildArtifact, project: String)] {
        let order: [ArtifactKind] = [.nodeModules, .rust, .xcode, .next, .swift, .java, .pythonEnv, .cocoaPods, .webBuild, .turbo, .cache, .pythonCache]
        let queue = candidates.sorted { (order.firstIndex(of: $0.kind) ?? 0) < (order.firstIndex(of: $1.kind) ?? 0) }
        let lock = NSLock()
        var next = 0
        var results: [(artifact: BuildArtifact, project: String)] = []
        // APFS stops getting faster past about four concurrent walks; more only burns CPU.
        let workers = min(4, max(ProcessInfo.processInfo.activeProcessorCount, 1), max(queue.count, 1))
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            let sizer = DirectorySizer()
            while true {
                lock.lock()
                let index = next
                next += 1
                lock.unlock()
                guard index < queue.count else { return }
                let candidate = queue[index]
                guard let modified = modified(candidate.path) else { continue }
                let artifact: BuildArtifact
                if let previous = reuse[candidate.path], previous.kind == candidate.kind, previous.modified == modified {
                    artifact = previous
                } else {
                    guard let totals = sizer.measure(candidate.path) else { continue }
                    artifact = BuildArtifact(path: candidate.path, kind: candidate.kind, size: totals.size,
                                             reclaimable: totals.reclaimable, modified: modified)
                }
                lock.lock()
                results.append((artifact, candidate.project))
                lock.unlock()
                each(artifact, candidate.project)
            }
        }
        return results
    }

    /// Measures each worktree's own files, leaving out the artifacts and
    /// nested repositories inside it, which are counted on their own. A
    /// checkout in `reuse` keeps its size while the worktree's folder and git
    /// index are unchanged.
    static func measureCheckouts(_ worktrees: [String], excluding: [String], reuse: [String: WorktreeCheckout] = [:],
                                 each: () -> Void = {}) -> [String: WorktreeCheckout] {
        let excluded = excluding.sorted()
        let lock = NSLock()
        var next = 0
        var results: [String: WorktreeCheckout] = [:]
        let workers = min(4, max(ProcessInfo.processInfo.activeProcessorCount, 1), max(worktrees.count, 1))
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            let sizer = DirectorySizer()
            while true {
                lock.lock()
                let index = next
                next += 1
                lock.unlock()
                guard index < worktrees.count else { return }
                let root = worktrees[index]
                let stamp = [modified(root), gitDirectory(root).flatMap { modified($0 + "/index") }].compactMap { $0 }.max()
                var checkout: WorktreeCheckout?
                if let previous = reuse[root], let stamp, previous.stamp == stamp {
                    checkout = previous
                } else {
                    let inside = Set(within(root, excluded))
                    checkout = sizer.measure(root, excluding: inside).map { WorktreeCheckout(reclaimable: $0.reclaimable, stamp: stamp) }
                }
                lock.lock()
                if let checkout { results[root] = checkout }
                lock.unlock()
                each()
            }
        }
        return results
    }

    /// The paths in sorted `paths` that sit below `root`.
    private static func within(_ root: String, _ paths: [String]) -> ArraySlice<String> {
        let prefix = root + "/"
        var low = 0, high = paths.count
        while low < high {
            let middle = (low + high) / 2
            if paths[middle] < prefix { low = middle + 1 } else { high = middle }
        }
        var end = low
        while end < paths.count, paths[end].hasPrefix(prefix) { end += 1 }
        return paths[low..<end]
    }

    // MARK: - Deleting

    /// Deletes an artifact for good. The folder is first renamed into a
    /// temporary folder on the same volume, so it disappears instantly and a
    /// half-finished delete never leaves a broken folder in the project.
    /// `progress` reports the share deleted, one call at a time.
    static func remove(_ artifact: BuildArtifact, roots: [String], progress: (Double) -> Void = { _ in }) -> Bool {
        guard isStillArtifact(artifact, roots: roots) else { return false }
        let fileManager = FileManager.default
        let url = URL(fileURLWithPath: artifact.path)
        if let staging = try? fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true) {
            let staged = staging.appendingPathComponent(url.lastPathComponent)
            if (try? fileManager.moveItem(at: url, to: staged)) != nil {
                removeContents(of: staged.path, progress: progress)
                try? fileManager.removeItem(at: staging)
                return true
            }
            try? fileManager.removeItem(at: staging)
        }
        return (try? fileManager.removeItem(at: url)) != nil
    }

    /// Deletes a folder's contents a piece at a time, several in parallel.
    /// Folders like `target` hold a few huge subfolders, so those are split
    /// a level or two further to keep the progress moving.
    private static func removeContents(of path: String, progress: (Double) -> Void) {
        var pieces = [path]
        for _ in 0..<3 where pieces.count < 64 {
            pieces = pieces.flatMap { piece -> [String] in
                var info = stat()
                guard lstat(piece, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                      let names = try? FileManager.default.contentsOfDirectory(atPath: piece), !names.isEmpty else { return [piece] }
                return names.map { piece + "/" + $0 }
            }
        }
        let lock = NSLock()
        var removed = 0
        DispatchQueue.concurrentPerform(iterations: pieces.count) { index in
            try? FileManager.default.removeItem(atPath: pieces[index])
            lock.lock()
            removed += 1
            progress(Double(removed) / Double(pieces.count))
            lock.unlock()
        }
    }

    /// Re-checks right before deleting: still a real folder (not a symlink)
    /// inside a scanned folder, with an artifact's name and no repository of its own.
    static func isStillArtifact(_ artifact: BuildArtifact, roots: [String]) -> Bool {
        var info = stat()
        guard lstat(artifact.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
        let home = NSHomeDirectory()
        let path = (artifact.path as NSString).standardizingPath
        guard path == artifact.path, path.split(separator: "/").count >= 4, path != home, !path.hasPrefix(home + "/Library/"),
              roots.contains(where: { path.hasPrefix(($0 as NSString).standardizingPath + "/") }),
              // Someone's own repository, never output.
              access(path + "/.git", F_OK) != 0 else { return false }
        if artifact.kind == .cache { return hasCacheTag(path) }
        let parent = (path as NSString).deletingLastPathComponent
        let siblings = Set((try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? [])
        if let rule = classify(artifact.name, path: path, siblings: siblings) { return rule.kind == artifact.kind }
        // A tagged `target` or `.build` without its manifest beside it.
        return hasCacheTag(path)
    }
}

// MARK: - Directory reading

/// Lists a directory's entries with `getattrlistbulk`, one system call per
/// batch of entries instead of one `stat` per file.
private final class DirectoryLister {
    struct Entry {
        let name: String
        let isDirectory: Bool
        /// An iCloud placeholder; listing it would download it.
        let isDataless: Bool
    }

    private let capacity = 128 * 1024
    private let buffer: UnsafeMutableRawPointer
    private var attributes = attrlist()

    init() {
        buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_FLAGS)
    }

    deinit { buffer.deallocate() }

    func list(_ path: String) -> [Entry]? {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var entries: [Entry] = []
        while true {
            let count = getattrlistbulk(fd, &attributes, buffer, capacity, UInt64(FSOPT_PACK_INVAL_ATTRS))
            guard count > 0 else { break }
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(entry.load(as: UInt32.self))
                var field = entry + 4 + MemoryLayout<attribute_set_t>.size
                let reference = field.loadUnaligned(as: attrreference_t.self)
                let name = String(cString: (field + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
                field += MemoryLayout<attrreference_t>.size
                let type = field.loadUnaligned(as: UInt32.self)
                let flags = (field + 4).loadUnaligned(as: UInt32.self)
                entries.append(Entry(name: name, isDirectory: type == VDIR.rawValue, isDataless: flags & UInt32(SF_DATALESS) != 0))
                entry += length
            }
        }
        return entries
    }
}

/// Adds up a folder tree's allocated and private (unshared) sizes with
/// `getattrlistbulk`. Hard-linked files count once.
private final class DirectorySizer {
    private let capacity = 256 * 1024
    private let buffer: UnsafeMutableRawPointer
    private var attributes = attrlist()

    init() {
        buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_FLAGS | ATTR_CMN_FILEID)
        attributes.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE)
        attributes.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
    }

    deinit { buffer.deallocate() }

    /// Folders in `excluding` are left out, along with everything in them.
    func measure(_ root: String, excluding: Set<String> = []) -> (size: UInt64, reclaimable: UInt64)? {
        var size: UInt64 = 0, reclaimable: UInt64 = 0
        var linked = Set<UInt64>()
        var stack = [root]
        var openedRoot = false
        while let directory = stack.popLast() {
            let fd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard fd >= 0 else { continue }
            openedRoot = true
            while true {
                let count = getattrlistbulk(fd, &attributes, buffer, capacity, UInt64(FSOPT_PACK_INVAL_ATTRS | FSOPT_ATTR_CMN_EXTENDED))
                guard count > 0 else { break }
                var entry = UnsafeRawPointer(buffer)
                for _ in 0..<count {
                    let length = Int(entry.load(as: UInt32.self))
                    var field = entry + 4
                    let returned = field.loadUnaligned(as: attribute_set_t.self)
                    field += MemoryLayout<attribute_set_t>.size
                    let reference = field.loadUnaligned(as: attrreference_t.self)
                    let namePointer = field + Int(reference.attr_dataoffset)
                    field += MemoryLayout<attrreference_t>.size
                    let type = field.loadUnaligned(as: UInt32.self)
                    let flags = (field + 4).loadUnaligned(as: UInt32.self)
                    field += 8
                    let fileID = field.loadUnaligned(as: UInt64.self)
                    field += 8
                    if type == VDIR.rawValue {
                        let path = directory + "/" + String(cString: namePointer.assumingMemoryBound(to: CChar.self))
                        guard flags & UInt32(SF_DATALESS) == 0, !excluding.contains(path) else { entry += length; continue }
                        stack.append(path)
                    } else {
                        var links: UInt32 = 1, allocated: UInt64 = 0
                        if returned.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 {
                            links = field.loadUnaligned(as: UInt32.self)
                            field += 4
                        }
                        if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
                            allocated = UInt64(max(field.loadUnaligned(as: off_t.self), 0))
                            field += 8
                        }
                        // Not every volume reports it; then the whole allocation counts.
                        var unshared = allocated
                        if returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 {
                            unshared = UInt64(max(field.loadUnaligned(as: off_t.self), 0))
                        }
                        if links <= 1 || linked.insert(fileID).inserted {
                            size += allocated
                            reclaimable += min(unshared, allocated)
                        }
                    }
                    entry += length
                }
            }
            close(fd)
        }
        return openedRoot ? (size, reclaimable) : nil
    }
}
