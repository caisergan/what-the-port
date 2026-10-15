import Foundation

/// The last build-cache scan, kept on disk so the page opens instantly.
/// Rescans run in the background; deleting is optimistic and frees space
/// in the background.
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
    /// Bytes still being deleted in the background.
    @Published private(set) var freeing: UInt64 = 0
    /// What the last delete freed, shown briefly in the footer.
    @Published private(set) var freed: UInt64?

    var isScanning: Bool { progress != nil }
    var reclaimable: UInt64 { projects.reduce(0) { $0 + $1.reclaimable } }

    private let queue = DispatchQueue(label: "com.whattheport.caches", qos: .utility)
    private var learnedRoots = Set<String>()
    private var freedReset: DispatchWorkItem?

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
                    if let partial { self.projects = partial }
                }
            }
            DispatchQueue.main.async {
                self.projects = result
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

    /// Removes the artifacts from the list right away, then deletes them in
    /// the background. Anything that fails its safety re-check stays on disk,
    /// and a rescan brings it back.
    func delete(_ paths: Set<String>) {
        let artifacts = projects.flatMap(\.artifacts).filter { paths.contains($0.path) }
        guard !artifacts.isEmpty else { return }
        let roots = folders
        let bytes = artifacts.reduce(0) { $0 + $1.reclaimable }
        for index in projects.indices { projects[index].artifacts.removeAll { paths.contains($0.path) } }
        projects.removeAll { $0.artifacts.isEmpty }
        projects.sort { $0.reclaimable > $1.reclaimable }
        freeing += bytes
        freed = nil
        save()
        DispatchQueue.global(qos: .utility).async {
            let lock = NSLock()
            var failed = 0
            var removed: UInt64 = 0
            DispatchQueue.concurrentPerform(iterations: artifacts.count) { index in
                let ok = BuildCacheScanner.remove(artifacts[index], roots: roots)
                lock.lock()
                if ok { removed += artifacts[index].reclaimable } else { failed += 1 }
                lock.unlock()
            }
            DispatchQueue.main.async {
                self.freeing -= min(bytes, self.freeing)
                self.showFreed(removed)
                if failed > 0 { self.scan() }
            }
        }
    }

    private func showFreed(_ bytes: UInt64) {
        freed = (freed ?? 0) + bytes
        freedReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in self?.freed = nil }
        freedReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: reset)
    }
}
