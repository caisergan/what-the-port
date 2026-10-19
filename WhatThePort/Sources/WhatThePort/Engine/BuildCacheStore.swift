import Foundation

/// The last build-cache scan, kept on disk so the page opens instantly.
/// Rescans run in the background; deleting is optimistic and works through
/// a queue in the background.
@MainActor
final class BuildCacheStore: ObservableObject {
    struct Progress: Equatable {
        var measured: Int
        var total: Int
    }

    @Published private(set) var projects: [CacheProject] = []
    @Published private(set) var scannedAt: Date?
    /// The folders the last scan covered; a different list means it's out of date.
    private var scannedFolders: [String] = []
    @Published private(set) var progress: Progress?
    /// The deletion queue, kept briefly after it finishes to show what it freed.
    @Published private(set) var cleanup: Cleanup?

    var isScanning: Bool { progress != nil }
    var reclaimable: UInt64 { projects.reduce(0) { $0 + $1.reclaimable } }

    private let queue = DispatchQueue(label: "com.whattheport.caches", qos: .utility)
    private var learnedRoots = Set<String>()
    private let deleteQueue = DispatchQueue(label: "com.whattheport.caches.delete", qos: .utility)
    private var cleanupReset: DispatchWorkItem?

    nonisolated private static let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("WhatThePort/BuildCaches.json")
    }()

    private struct Saved: Codable {
        let scannedAt: Date
        let folders: [String]
        let projects: [CacheProject]
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            projects = saved.projects
            scannedAt = saved.scannedAt
            scannedFolders = saved.folders
        }
    }

    // MARK: - Folders

    private var defaults: UserDefaults { .standard }

    /// Folders to scan: your own list once you've edited it, otherwise the
    /// usual project folders plus wherever your dev servers have run.
    var folders: [String] {
        defaults.stringArray(forKey: Preferences.cacheFolders) ?? automaticFolders
    }

    var isAutomatic: Bool { defaults.object(forKey: Preferences.cacheFolders) == nil }

    var automaticFolders: [String] {
        let home = NSHomeDirectory()
        let usual = ["Developer", "Projects", "Code", "src", "dev", "repos", "GitHub", "Documents/GitHub", "Sites", "Workspace",
                     ".codex/worktrees", "conductor/workspaces"].map { home + "/" + $0 }
        let detected = defaults.stringArray(forKey: Preferences.cacheDetectedFolders) ?? []
        return Self.outermost((usual + detected).filter { FileManager.default.fileExists(atPath: $0) })
    }

    func setFolders(_ folders: [String]) {
        defaults.set(Self.outermost(folders), forKey: Preferences.cacheFolders)
        objectWillChange.send()
    }

    func useAutomaticFolders() {
        defaults.removeObject(forKey: Preferences.cacheFolders)
        objectWillChange.send()
    }

    func addFolder(_ folder: String) {
        setFolders(folders + [folder])
    }

    func removeFolder(_ folder: String) {
        setFolders(folders.filter { $0 != folder })
        projects.removeAll { !Self.isInside($0.root, folders) }
        save()
    }

    /// Remembers the folder that holds each dev server's project, e.g.
    /// `~/Desktop/personal-projects` for a server running in one of its repos.
    func learnFolders(from servers: [Server]) {
        let roots = Set(servers.compactMap { $0.project.root }).subtracting(learnedRoots)
        guard !roots.isEmpty else { return }
        learnedRoots.formUnion(roots)
        let detected = defaults.stringArray(forKey: Preferences.cacheDetectedFolders) ?? []
        let containers = Self.containers(of: Array(roots))
        guard !Set(containers).isSubset(of: detected) else { return }
        defaults.set(Self.outermost(detected + containers), forKey: Preferences.cacheDetectedFolders)
    }

    private static func containers(of roots: [String]) -> [String] {
        let home = NSHomeDirectory()
        return roots.map { (mainRepository(of: $0) as NSString).deletingLastPathComponent }
            .filter { $0.hasPrefix(home + "/") && !$0.hasPrefix(home + "/Library") }
    }

    /// The repository holding a project (which may be a package inside it).
    /// For a linked worktree that's the main repository, so the folder found
    /// is the one with your repositories rather than `.worktrees`.
    private static func mainRepository(of root: String) -> String {
        var directory = root
        while directory.count > 1, access(directory + "/.git", F_OK) != 0 {
            directory = (directory as NSString).deletingLastPathComponent
        }
        guard directory.count > 1 else { return root }
        guard let contents = try? String(contentsOfFile: directory + "/.git", encoding: .utf8),
              let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }),
              let range = line.range(of: "/.git/worktrees/") else { return directory }
        return line[..<range.lowerBound].dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
    }

    /// Drops folders inside other folders in the list, and duplicates that differ only in case.
    static func outermost(_ folders: [String]) -> [String] {
        var seen = Set<String>()
        let unique = folders.map { ($0 as NSString).standardizingPath }.filter { seen.insert($0.lowercased()).inserted }
        return unique.filter { folder in !unique.contains { $0 != folder && folder.lowercased().hasPrefix($0.lowercased() + "/") } }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func isInside(_ path: String, _ folders: [String]) -> Bool {
        folders.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    // MARK: - Suggestions

    var staleAfter: TimeInterval {
        TimeInterval(max(defaults.integer(forKey: Preferences.cacheStaleDays), 1)) * 86_400
    }

    func isStale(_ project: CacheProject) -> Bool {
        Date().timeIntervalSince(project.lastUsed) >= staleAfter
    }

    // MARK: - Scanning

    /// Rescans if the last scan is older than `maxAge` or covered other folders.
    func scanIfStale(maxAge: TimeInterval) {
        if let scannedAt, Date().timeIntervalSince(scannedAt) < maxAge, scannedFolders == folders { return }
        scan()
    }

    /// Scans synchronously without saving anything. Used by snapshot mode,
    /// which also looks where the current servers run.
    func scanNow(servers: [Server]) {
        let roots = Self.outermost(folders + Self.containers(of: servers.compactMap { $0.project.root }))
        projects = BuildCacheScanner.scan(roots: roots)
        scannedAt = Date()
        scannedFolders = folders
    }

    /// Unchanged folders keep their last size unless `force` is set, so
    /// routine rescans take seconds; Rescan measures everything again.
    func scan(force: Bool = false) {
        guard progress == nil else { return }
        let roots = folders
        guard !roots.isEmpty else {
            projects = []
            return
        }
        progress = Progress(measured: 0, total: 0)
        let reuse = force ? [:] : Dictionary(projects.flatMap(\.artifacts).map { ($0.path, $0) }) { first, _ in first }
        // A first scan fills the list as it goes; later ones swap in when done.
        let showsPartial = projects.isEmpty
        queue.async {
            let lock = NSLock()
            var measured: [(artifact: BuildArtifact, project: String)] = []
            var published = Date.distantPast
            let result = BuildCacheScanner.scan(roots: roots, reuse: reuse) { artifact, project, total in
                lock.lock()
                measured.append((artifact, project))
                let count = measured.count
                let snapshot = Date().timeIntervalSince(published) > 0.3 ? measured : nil
                if snapshot != nil { published = Date() }
                lock.unlock()
                guard let snapshot else { return }
                let partial = showsPartial ? BuildCacheScanner.group(snapshot) : nil
                DispatchQueue.main.async {
                    guard self.progress != nil else { return }
                    self.progress = Progress(measured: count, total: total)
                    if let partial { self.projects = self.withoutPending(partial) }
                }
            }
            DispatchQueue.main.async {
                self.projects = self.withoutPending(result)
                self.scannedAt = Date()
                self.scannedFolders = roots
                self.progress = nil
                self.save()
            }
        }
    }

    private func save() {
        guard let scannedAt else { return }
        let saved = Saved(scannedAt: scannedAt, folders: scannedFolders, projects: projects)
        queue.async {
            try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(saved).write(to: Self.fileURL, options: .atomic)
        }
    }

    // MARK: - Deleting

    /// A folder waiting to be deleted, being deleted, or done.
    struct CleanupJob: Identifiable, Equatable {
        enum State { case queued, deleting, done, failed }
        let artifact: BuildArtifact
        /// The project it came from, to put it back if the job is cancelled.
        let project: CacheProject
        var state = State.queued

        var id: String { artifact.path }
    }

    /// Everything deleted since the page last went quiet, in queue order.
    struct Cleanup: Equatable {
        var jobs: [CleanupJob] = []
        /// How far the folder being deleted has got, 0–1.
        var fraction: Double = 0

        var total: UInt64 { jobs.reduce(0) { $0 + $1.artifact.reclaimable } }
        /// Bytes freed so far, including part of the folder being deleted.
        var freed: UInt64 {
            jobs.reduce(0) { sum, job in
                switch job.state {
                case .done: sum + job.artifact.reclaimable
                case .deleting: sum + UInt64(Double(job.artifact.reclaimable) * fraction)
                case .queued, .failed: sum
                }
            }
        }
        var progress: Double { total == 0 ? (isFinished ? 1 : 0) : min(Double(freed) / Double(total), 1) }
        var current: CleanupJob? { jobs.first { $0.state == .deleting } }
        var queued: Int { jobs.filter { $0.state == .queued }.count }
        var finished: Int { jobs.filter { $0.state == .done || $0.state == .failed }.count }
        var failed: Int { jobs.filter { $0.state == .failed }.count }
        var isFinished: Bool { finished == jobs.count }
    }

    /// Takes the artifacts off the list right away and queues them, largest
    /// first. Folders are deleted one at a time in the background, so picking
    /// more while it runs adds to the queue. Anything that fails its safety
    /// re-check stays on disk, and a rescan brings it back.
    func delete(_ paths: Set<String>) {
        let jobs = projects.flatMap { project in
            project.artifacts.filter { paths.contains($0.path) }.map { CleanupJob(artifact: $0, project: project) }
        }
        guard !jobs.isEmpty else { return }
        for index in projects.indices { projects[index].artifacts.removeAll { paths.contains($0.path) } }
        projects.removeAll { $0.artifacts.isEmpty }
        projects.sort { $0.reclaimable > $1.reclaimable }
        cleanupReset?.cancel()
        // A finished cleanup still on screen makes way for the new one.
        if cleanup?.isFinished ?? true { cleanup = Cleanup() }
        cleanup?.jobs += jobs
        save()
        deleteNext()
    }

    /// Snapshot mode: a queue part-way through, without deleting anything.
    func previewCleanup() {
        let jobs = projects.prefix(4).flatMap { project in project.artifacts.prefix(2).map { CleanupJob(artifact: $0, project: project) } }
        guard jobs.count > 2 else { return }
        let paths = Set(jobs.map(\.id))
        for index in projects.indices { projects[index].artifacts.removeAll { paths.contains($0.path) } }
        projects.removeAll { $0.artifacts.isEmpty }
        var cleanup = Cleanup(jobs: jobs, fraction: 0.4)
        cleanup.jobs[0].state = .done
        cleanup.jobs[1].state = .deleting
        self.cleanup = cleanup
    }

    /// Puts the folders still waiting back in the list. The one being
    /// deleted has already left its project, so it finishes.
    func cancelQueued() {
        guard let cancelled = cleanup?.jobs.filter({ $0.state == .queued }), !cancelled.isEmpty else { return }
        cleanup?.jobs.removeAll { $0.state == .queued }
        for job in cancelled {
            if let index = projects.firstIndex(where: { $0.root == job.project.root }) {
                projects[index].artifacts.append(job.artifact)
                projects[index].artifacts.sort { $0.reclaimable > $1.reclaimable }
            } else {
                var project = job.project
                project.artifacts = [job.artifact]
                projects.append(project)
            }
        }
        projects.sort { $0.reclaimable == $1.reclaimable ? $0.root < $1.root : $0.reclaimable > $1.reclaimable }
        save()
    }

    private func deleteNext() {
        guard let cleanup, cleanup.current == nil else { return }
        guard let index = cleanup.jobs.firstIndex(where: { $0.state == .queued }) else { return finishCleanup() }
        self.cleanup?.jobs[index].state = .deleting
        self.cleanup?.fraction = 0
        let artifact = cleanup.jobs[index].artifact
        let roots = folders
        deleteQueue.async {
            var published = Date.distantPast
            let ok = BuildCacheScanner.remove(artifact, roots: roots) { fraction in
                guard Date().timeIntervalSince(published) > 0.1 else { return }
                published = Date()
                DispatchQueue.main.async {
                    guard self.cleanup?.current?.id == artifact.path else { return }
                    self.cleanup?.fraction = fraction
                }
            }
            DispatchQueue.main.async {
                if let index = self.cleanup?.jobs.firstIndex(where: { $0.id == artifact.path }) {
                    self.cleanup?.jobs[index].state = ok ? .done : .failed
                }
                self.deleteNext()
            }
        }
    }

    /// Leaves the result on screen for a moment; failed folders come back with a rescan.
    private func finishCleanup() {
        guard let cleanup else { return }
        guard !cleanup.jobs.isEmpty else {
            self.cleanup = nil
            return
        }
        if cleanup.failed > 0 { scan() }
        let reset = DispatchWorkItem { [weak self] in self?.cleanup = nil }
        cleanupReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: reset)
    }

    /// Leaves out folders waiting to be deleted, so a rescan doesn't bring them back.
    private func withoutPending(_ projects: [CacheProject]) -> [CacheProject] {
        let pending = Set(cleanup?.jobs.filter { $0.state == .queued || $0.state == .deleting }.map(\.id) ?? [])
        guard !pending.isEmpty else { return projects }
        return projects.compactMap { project in
            var project = project
            project.artifacts.removeAll { pending.contains($0.path) }
            return project.artifacts.isEmpty ? nil : project
        }
    }
}
