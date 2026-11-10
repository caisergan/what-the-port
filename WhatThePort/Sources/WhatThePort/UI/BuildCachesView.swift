import AppKit
import SwiftUI

/// Build output, dependencies and caches in your project folders, with what
/// deleting each frees. Laid out like Servers: a summary over a bar of the
/// whole disk, selectable rows, and a destructive footer.
struct BuildCachesView: View {
    @ObservedObject var monitor: ServerMonitor
    @ObservedObject var store: BuildCacheStore
    let back: () -> Void
    let openSettings: () -> Void

    private let maxVisibleRows = 7
    /// Selected artifact paths.
    @State private var selection: Set<String>
    /// Expanded row ids.
    @State private var expanded: Set<String> = []
    /// The segment under the pointer in the disk bar.
    @State private var focus: CacheFocus?
    @State private var hoveredRow: String?
    @State private var confirming = false
    /// Suggestions are made once, from the first results there are.
    @State private var hasSuggested: Bool
    @State private var disk = DiskSpace.current()
    private let expandQueue: Bool

    /// Snapshot mode passes `expandFirst`, `confirm` and `expandQueue` to render those states.
    init(monitor: ServerMonitor, expandFirst: Bool = false, confirm: Bool = false, expandQueue: Bool = false,
         back: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.expandQueue = expandQueue
        self.monitor = monitor
        self.store = monitor.caches
        self.back = back
        self.openSettings = openSettings
        let ready = !monitor.caches.projects.isEmpty
        _selection = State(initialValue: ready ? Self.suggestedSelection(monitor) : [])
        _hasSuggested = State(initialValue: ready)
        _expanded = State(initialValue: expandFirst ? Set(CacheRowItem.items(monitor.caches.projects).prefix(1).map(\.id)) : [])
        _confirming = State(initialValue: confirm)
    }

    var body: some View {
        VStack(spacing: 0) {
            summary
            SectionDivider()
            if store.projects.isEmpty {
                emptyState
            } else if rowItems.count > maxVisibleRows || !expanded.isEmpty {
                ScrollView { rows }.frame(height: CGFloat(maxVisibleRows) * 52 + 12)
            } else {
                rows
            }
            SectionDivider()
            footer
        }
        .onAppear { store.scanIfStale(maxAge: 600) }
        .onChange(of: store.isScanning) { _, scanning in
            guard !scanning else { return }
            disk = DiskSpace.current()
            let paths = Set(store.projects.flatMap(\.artifacts).map(\.path))
            if hasSuggested {
                selection.formIntersection(paths)
            } else {
                hasSuggested = true
                selection = Self.suggestedSelection(monitor)
            }
        }
        .onChange(of: store.cleanup?.finished) { _, _ in disk = DiskSpace.current() }
    }

    private var artifacts: [BuildArtifact] { store.projects.flatMap(\.artifacts) }

    private var selectedArtifacts: [BuildArtifact] { artifacts.filter { selection.contains($0.path) } }

    private var selectedBytes: UInt64 { selectedArtifacts.reduce(0) { $0 + $1.reclaimable } }

    // MARK: - Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let focus {
                HStack(spacing: 6) {
                    Circle().fill(focus.color).frame(width: 6, height: 6)
                    Text(focus.label).font(Theme.bodyMedium).foregroundStyle(Theme.text1)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 20)
            } else {
                PageHeader(title: L10n.text("Build caches"), back: back)
            }
            HStack(alignment: .center) {
                let amount = Format.total(focus.map(total(of:)) ?? store.reclaimable)
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(amount.number).font(Theme.display).foregroundStyle(Theme.text1)
                        .contentTransition(.numericText())
                    Text(amount.unit).font(Theme.mono).foregroundStyle(Theme.text3)
                }
                .help(focus == nil ? sharedHelp(size: artifacts.reduce(0) { $0 + $1.size }, reclaimable: store.reclaimable) : "")
                Spacer()
                summaryDetail
            }
            CacheDiskBar(store: store, disk: disk, focus: $focus, highlighted: hoveredRow.flatMap(item(id:))?.segments) { kind in
                toggle(artifacts.filter { $0.kind == kind })
            }
            .frame(height: 16)
            CacheLegend(store: store, disk: disk)
            if let cleanup = store.cleanup {
                CleanupCard(cleanup: cleanup, isExpanded: expandQueue, cancel: store.cancelQueued)
                    .padding(.top, 4)
                    .transition(.opacity)
            }
        }
        .padding(EdgeInsets(top: 12, leading: Theme.inset, bottom: 16, trailing: Theme.inset))
        .animation(.snappy(duration: 0.25), value: store.cleanup == nil)
    }

    @ViewBuilder private var summaryDetail: some View {
        if case .kind(let kind) = focus {
            let count = artifacts.filter { $0.kind == kind }.count
            Text(L10n.format("%d %@", count, L10n.counted("folder", "folders", count: count)))
                .font(Theme.body).foregroundStyle(Theme.text2)
        } else if focus == .worktrees {
            let count = store.worktreeCount
            Text(L10n.format("%d %@", count, L10n.counted("worktree", "worktrees", count: count)))
                .font(Theme.body).foregroundStyle(Theme.text2)
        } else if let cleanup = store.cleanup, !cleanup.isFinished {
            HStack(spacing: 7) {
                ProgressRing(fraction: cleanup.progress)
                Text(L10n.format("Freed %@ of %@", Format.diskBytes(cleanup.freed), Format.diskBytes(cleanup.total)))
                    .font(Theme.body).foregroundStyle(Theme.text2)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.2), value: cleanup.freed)
            }
        } else if let progress = store.progress {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(progress.total == 0 ? L10n.text("Scanning…") : L10n.format("Scanning %d of %d", progress.measured, progress.total))
                    .font(Theme.body).foregroundStyle(Theme.text2)
                    .contentTransition(.numericText())
            }
        } else if let cleanup = store.cleanup {
            HStack(spacing: 5) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                Text(L10n.format("Freed %@", Format.diskBytes(cleanup.freed)))
            }
            .font(Theme.body).foregroundStyle(Theme.text2)
        } else if let scannedAt = store.scannedAt {
            let age = Date().timeIntervalSince(scannedAt)
            Button {
                store.scan(force: true)
            } label: {
                HStack(spacing: 6) {
                    Text(age < 60 ? L10n.text("Scanned just now") : L10n.format("Scanned %@ ago", L10n.duration(age, short: true)))
                        .font(Theme.body).foregroundStyle(Theme.text3)
                    Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.text("Scan again"))
        }
    }

    private func total(of focus: CacheFocus) -> UInt64 {
        switch focus {
        case .kind(let kind): artifacts.filter { $0.kind == kind }.reduce(0) { $0 + $1.reclaimable }
        case .worktrees: store.checkouts
        }
    }

    private func item(id: String) -> CacheRowItem? {
        rowItems.first { $0.id == id }
    }

    // MARK: - Rows

    private var rowItems: [CacheRowItem] { CacheRowItem.items(store.projects) }

    private var rows: some View {
        LazyVStack(spacing: 0) {
            let ports = serverPorts
            ForEach(rowItems) { item in
                let id = item.id
                let onHover: (Bool) -> Void = { hovering in
                    if hovering { hoveredRow = id } else if hoveredRow == id { hoveredRow = nil }
                }
                let expand = {
                    withAnimation(.snappy(duration: 0.2)) {
                        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
                    }
                }
                let isDimmed = focus.map { !item.segments.contains($0) } ?? false
                switch item {
                case .project(let project):
                    CacheProjectRow(project: project, selection: selection, ports: ports[project.root] ?? [],
                                    isStale: store.isStale(project), isExpanded: expanded.contains(id),
                                    isDimmed: isDimmed, onHover: onHover, toggle: toggle, expand: expand)
                case .worktrees(let group):
                    WorktreeGroupRow(group: group, selection: selection, ports: ports, staleAfter: store.staleAfter,
                                     isExpanded: expanded.contains(id), isDimmed: isDimmed,
                                     onHover: onHover, toggle: toggle, expand: expand)
                }
            }
        }
        .padding(6)
    }

    /// Ports of running servers by project, matched to the innermost project
    /// so a worktree's server doesn't mark its main repository.
    private var serverPorts: [String: [Int]] {
        let roots = store.projects.map(\.root).sorted { $0.count > $1.count }
        var ports: [String: [Int]] = [:]
        for server in monitor.servers {
            guard let cwd = server.cwd ?? server.project.root,
                  let root = roots.first(where: { cwd == $0 || cwd.hasPrefix($0 + "/") }) else { continue }
            ports[root, default: []].append(server.port)
        }
        return ports.mapValues { $0.sorted() }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            DotGridView(glyph: .idle, size: 48)
            if store.folders.isEmpty {
                Text(L10n.text("No project folders")).font(Theme.body).foregroundStyle(Theme.text2)
                Text(L10n.text("Add the folder where you keep your projects.")).font(Theme.caption).foregroundStyle(Theme.text3)
                Button(L10n.text("Add Folder…"), action: addFolder).buttonStyle(PillButtonStyle())
            } else {
                Text(store.isScanning ? L10n.text("Scanning…") : L10n.text("Nothing to clean"))
                    .font(Theme.body).foregroundStyle(Theme.text2)
                Text(L10n.format(store.isScanning ? "Looking in %@" : "No build caches in %@", folderNames))
                    .font(Theme.caption).foregroundStyle(Theme.text3)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, Theme.inset)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var folderNames: String {
        let names = store.folders.map { ($0 as NSString).abbreviatingWithTildeInPath }
        return names.count > 2 ? L10n.format("%@ and %d more", names[0], names.count - 1) : names.joined(separator: ", ")
    }

    // MARK: - Footer

    @ViewBuilder private var footer: some View {
        if confirming {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text("Deleted folders are gone for good. Your tools recreate them on the next install or build."))
                    .font(Theme.caption).foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(L10n.text("Cancel")) { withAnimation(.snappy(duration: 0.2)) { confirming = false } }
                        .buttonStyle(PillButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button {
                        Usage.record(.deleteCaches)
                        store.delete(selection)
                        withAnimation(.snappy(duration: 0.25)) {
                            selection = []
                            confirming = false
                        }
                    } label: {
                        Text(L10n.format("Delete %d %@", selectedArtifacts.count, L10n.counted("folder", "folders", count: selectedArtifacts.count)))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle(kind: .destructive))
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
            .transition(.opacity)
        } else {
            HStack(spacing: 8) {
                if selection.isEmpty {
                    let count = Self.suggestedSelection(monitor).count
                    Button(L10n.text("Select unused")) {
                        withAnimation(.snappy(duration: 0.15)) { selection = Self.suggestedSelection(monitor) }
                    }
                    .buttonStyle(PillButtonStyle())
                    .disabled(count == 0)
                    .help(L10n.format("Caches in projects untouched for %d days, without a running server", Int(store.staleAfter / 86_400)))
                } else {
                    Button(L10n.text("Clear")) { withAnimation(.snappy(duration: 0.15)) { selection = [] } }
                        .buttonStyle(PillButtonStyle())
                }
                Button {
                    withAnimation(.snappy(duration: 0.2)) { confirming = true }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "trash").font(.system(size: 11, weight: .medium))
                        Text(selection.isEmpty ? L10n.text("Delete caches") : L10n.format("Free %@", Format.diskBytes(selectedBytes)))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(kind: .destructive))
                .disabled(selection.isEmpty)
                .opacity(selection.isEmpty ? 0.5 : 1)
                .help(L10n.format("Delete %d %@", selectedArtifacts.count, L10n.counted("folder", "folders", count: selectedArtifacts.count)))

                Menu {
                    Button(L10n.text("Scan again")) { store.scan(force: true) }
                        .disabled(store.isScanning)
                    Button(L10n.text("Add Folder…"), action: addFolder)
                    Divider()
                    Button(L10n.text("Build caches settings…"), action: openSettings)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                        .frame(width: 30, height: 30)
                        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(12)
            .transition(.opacity)
        }
    }

    // MARK: - Selection

    private func toggle(_ items: [BuildArtifact]) {
        let paths = Set(items.map(\.path))
        guard !paths.isEmpty else { return }
        withAnimation(.snappy(duration: 0.15)) {
            if paths.isSubset(of: selection) { selection.subtract(paths) } else { selection.formUnion(paths) }
        }
    }

    /// Everything in projects untouched for a while, except where a dev server is running.
    private static func suggestedSelection(_ monitor: ServerMonitor) -> Set<String> {
        let store = monitor.caches
        let running = monitor.servers.compactMap { $0.cwd ?? $0.project.root }
        return Set(store.projects.filter { project in
            store.isStale(project) && !running.contains { $0 == project.root || $0.hasPrefix(project.root + "/") }
        }.flatMap(\.artifacts).map(\.path))
    }

    private func addFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = L10n.text("Add")
        panel.message = L10n.text("Choose the folders where you keep your projects.")
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { store.addFolder($0.path) }
        store.scan()
    }
}

// MARK: - Row

struct CacheProjectRow: View {
    let project: CacheProject
    let selection: Set<String>
    /// Ports of dev servers running in this project.
    let ports: [Int]
    let isStale: Bool
    let isExpanded: Bool
    var isDimmed = false
    var onHover: (Bool) -> Void = { _ in }
    let toggle: ([BuildArtifact]) -> Void
    let expand: () -> Void
    @State private var isHovered = false

    private var selectedCount: Int { project.artifacts.filter { selection.contains($0.path) }.count }
    private var hasCaches: Bool { !project.artifacts.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Checkbox(isOn: hasCaches && selectedCount == project.artifacts.count,
                         isMixed: selectedCount > 0 && selectedCount < project.artifacts.count)
                    .opacity(hasCaches ? 1 : 0.3)
                    .padding(.trailing, 12)

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(Theme.bodyMedium)
                        .foregroundStyle(Theme.text1)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(project.root)
                    caption
                }
                .padding(.trailing, 10)

                Spacer(minLength: 0)

                if isHovered {
                    IconButton(systemName: "folder", background: .clear, size: 22, help: L10n.text("Reveal in Finder")) {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.root)
                    }
                }

                CacheSize(reclaimable: project.reclaimable, size: project.size, checkout: project.checkout, hasCaches: hasCaches)

                if hasCaches {
                    Button(action: expand) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.text3)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? L10n.text("Less") : L10n.text("Show folders"))
                } else {
                    Color.clear.frame(width: 22, height: 22)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .onTapGesture { toggle(project.artifacts) }

            if isExpanded && hasCaches {
                VStack(spacing: 0) {
                    ForEach(groups, id: \.name) { group in
                        groupRow(group)
                    }
                }
                .padding(.bottom, 6)
                .transition(.opacity)
            }
        }
        .opacity(isDimmed ? 0.35 : 1)
        .hoverHighlight(isHovered)
        .animation(.easeOut(duration: 0.12), value: isDimmed)
        .onHover { hovering in
            isHovered = hovering
            onHover(hovering)
        }
    }

    @ViewBuilder private var caption: some View {
        HStack(spacing: 5) {
            if !ports.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill").font(.system(size: 8))
                    Text(L10n.format("Server on %@", ports.map { ":\($0)" }.joined(separator: " "))).fixedSize()
                }
                .foregroundStyle(Theme.amber)
                .environment(\.layoutDirection, .leftToRight)
                Text("·")
            }
            Text(kindText).lineLimit(1).truncationMode(.tail)
            Text("·")
            Text(ageText).fixedSize()
        }
        .font(Theme.caption)
        .foregroundStyle(Theme.text2)
        .help(kindText + " · " + ageText)
    }

    private var ageText: String {
        let age = Date().timeIntervalSince(project.lastUsed)
        return isStale ? L10n.format("untouched %@", L10n.duration(age, short: true)) : L10n.format("used %@ ago", L10n.duration(age, short: true))
    }

    /// The worktree's repository, then the kinds inside, largest first, or
    /// the checkout's size when it has no caches.
    private var kindText: String {
        let kinds = cacheKinds(project.artifacts)
        guard let repository = project.repository else { return kinds }
        // Without caches, the checkout's size is the point, so it goes first.
        if project.artifacts.isEmpty, project.checkout != nil {
            return L10n.format("%@ checkout", Format.diskBytes(project.checkoutBytes)) + " · " + L10n.format("%@ worktree", repository)
        }
        return L10n.format("%@ worktree", repository) + " · " + kinds
    }

    /// Artifacts with the same folder name, e.g. every `node_modules` in a monorepo.
    private struct Group {
        let name: String
        let items: [BuildArtifact]
        var size: UInt64 { items.reduce(0) { $0 + $1.size } }
        var reclaimable: UInt64 { items.reduce(0) { $0 + $1.reclaimable } }
    }

    private var groups: [Group] {
        Dictionary(grouping: project.artifacts, by: \.name)
            .map { Group(name: $0.key, items: $0.value) }
            .sorted { $0.reclaimable == $1.reclaimable ? $0.name < $1.name : $0.reclaimable > $1.reclaimable }
    }

    private func groupRow(_ group: Group) -> some View {
        let selected = group.items.filter { selection.contains($0.path) }.count
        let label = group.items.count == 1
            ? project.relativePath(of: group.items[0])
            : L10n.format("%@ · %d folders", group.name, group.items.count)
        return HStack(spacing: 0) {
            Checkbox(isOn: selected == group.items.count, isMixed: selected > 0 && selected < group.items.count, size: 12)
                .padding(.trailing, 10)
            Text(label)
                .font(Theme.monoCaption)
                .foregroundStyle(Theme.text1.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(group.items.map(\.path).joined(separator: "\n"))
            Spacer(minLength: 8)
            if group.size > group.reclaimable * 2, group.size - group.reclaimable > 50 * 1_048_576 {
                Text(L10n.format("%@ shared", Format.diskBytes(group.size - group.reclaimable)))
                    .font(Theme.caption).foregroundStyle(Theme.text3)
                    .fixedSize()
                    .padding(.trailing, 8)
            }
            Text(Format.diskBytes(group.reclaimable))
                .font(Theme.monoCaption)
                .foregroundStyle(Theme.text2)
                .frame(width: 64, alignment: .trailing)
                .help(sharedHelp(size: group.size, reclaimable: group.reclaimable))
        }
        .padding(.leading, 38)
        .padding(.trailing, 30)
        .frame(height: 24)
        .contentShape(Rectangle())
        .onTapGesture { toggle(group.items) }
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// The kinds of cache among `artifacts`, largest first: "node_modules, .next +2".
func cacheKinds(_ artifacts: [BuildArtifact]) -> String {
    var totals: [ArtifactKind: UInt64] = [:]
    for artifact in artifacts { totals[artifact.kind, default: 0] += artifact.reclaimable }
    let labels = totals.sorted { $0.value == $1.value ? $0.key.colorIndex < $1.key.colorIndex : $0.value > $1.value }.map(\.key.label)
    return labels.count > 3 ? labels.prefix(2).joined(separator: ", ") + " +\(labels.count - 2)" : labels.joined(separator: ", ")
}

/// What deleting caches frees, and how much of what they take is shared.
func sharedHelp(size: UInt64, reclaimable: UInt64) -> String {
    guard size > reclaimable + 1_048_576 else { return L10n.format("Frees %@", Format.diskBytes(reclaimable)) }
    return L10n.format("Frees %@ of %@ on disk. The rest is shared with copies elsewhere, like the pnpm store.",
                       Format.diskBytes(reclaimable), Format.diskBytes(size))
}

/// A row's size column: what its caches free, or a dash when it has none.
/// Its tooltip adds what's shared and what the worktree's checkout takes.
struct CacheSize: View {
    let reclaimable: UInt64
    let size: UInt64
    let checkout: WorktreeCheckout?
    let hasCaches: Bool
    var font = Theme.mono
    var color = Theme.text1.opacity(0.85)

    var body: some View {
        Text(hasCaches ? Format.diskBytes(reclaimable) : "–")
            .font(font)
            .foregroundStyle(hasCaches ? color : Theme.text3)
            .frame(width: 64, alignment: .trailing)
            .help(help)
    }

    private var help: String {
        let caches = hasCaches ? sharedHelp(size: size, reclaimable: reclaimable) : L10n.text("No build caches")
        guard let checkout else { return caches }
        return caches + "\n" + L10n.format("Its checkout takes another %@: the worktree's own files. Deleting caches leaves them; removing the worktree frees them.",
                                            Format.diskBytes(checkout.reclaimable))
    }
}

// MARK: - Worktrees

/// A repository and its linked worktrees, listed in one row.
struct WorktreeGroup: Equatable {
    let repositoryRoot: String
    let name: String
    /// The main repository, when it has caches of its own.
    let main: CacheProject?
    let worktrees: [CacheProject]

    /// The main repository first, then its worktrees.
    var members: [CacheProject] { (main.map { [$0] } ?? []) + worktrees }
    var artifacts: [BuildArtifact] { members.flatMap(\.artifacts) }
    var size: UInt64 { members.reduce(0) { $0 + $1.size } }
    var reclaimable: UInt64 { members.reduce(0) { $0 + $1.reclaimable } }
    var checkoutBytes: UInt64 { worktrees.reduce(0) { $0 + $1.checkoutBytes } }
    var lastUsed: Date { members.map(\.lastUsed).max() ?? .distantPast }
}

/// A row on the page: a project, or every worktree of a repository that has several.
enum CacheRowItem: Identifiable {
    case project(CacheProject)
    case worktrees(WorktreeGroup)

    var id: String {
        switch self {
        case .project(let project): project.root
        case .worktrees(let group): "worktrees:" + group.repositoryRoot
        }
    }

    var artifacts: [BuildArtifact] {
        switch self {
        case .project(let project): project.artifacts
        case .worktrees(let group): group.artifacts
        }
    }

    private var reclaimable: UInt64 { artifacts.reduce(0) { $0 + $1.reclaimable } }

    private var checkoutBytes: UInt64 {
        switch self {
        case .project(let project): project.checkoutBytes
        case .worktrees(let group): group.checkoutBytes
        }
    }

    /// The disk bar segments this row contributes to.
    var segments: Set<CacheFocus> {
        var segments = Set(artifacts.map { CacheFocus.kind($0.kind) })
        if checkoutBytes > 0 { segments.insert(.worktrees) }
        return segments
    }

    /// A repository with worktrees collapses into one row with them, once
    /// there are two or more to list. Rows go by what they take in all,
    /// caches and checkouts together.
    static func items(_ projects: [CacheProject]) -> [CacheRowItem] {
        let roots = Dictionary(projects.map { ($0.root, $0) }) { first, _ in first }
        let byRepository = Dictionary(grouping: projects.filter { $0.checkout != nil && $0.repositoryRoot != nil }) { $0.repositoryRoot! }
            .filter { $0.value.count + (roots[$0.key] == nil ? 0 : 1) > 1 }
        var placed = Set<String>()
        var items: [CacheRowItem] = []
        for project in projects {
            let repository = project.checkout != nil ? project.repositoryRoot : project.root
            guard let repository, let worktrees = byRepository[repository] else {
                items.append(.project(project))
                continue
            }
            guard placed.insert(repository).inserted else { continue }
            items.append(.worktrees(WorktreeGroup(repositoryRoot: repository, name: (repository as NSString).lastPathComponent,
                                                  main: roots[repository], worktrees: worktrees.sorted(by: CacheProject.largerFirst))))
        }
        return items.enumerated().sorted { a, b in
            let first = a.element.reclaimable + a.element.checkoutBytes, second = b.element.reclaimable + b.element.checkoutBytes
            if first != second { return first > second }
            if a.element.reclaimable != b.element.reclaimable { return a.element.reclaimable > b.element.reclaimable }
            return a.offset < b.offset
        }.map(\.element)
    }
}

/// A part of the disk bar: one kind of cache, or the worktrees' checkouts.
enum CacheFocus: Hashable {
    case kind(ArtifactKind)
    case worktrees

    var label: String {
        switch self {
        case .kind(let kind): kind.label
        case .worktrees: L10n.text("Worktree checkouts")
        }
    }

    var color: Color {
        switch self {
        case .kind(let kind): Theme.portColor(at: kind.colorIndex)
        case .worktrees: Theme.worktreeCheckout
        }
    }
}

/// Every worktree of a repository: what their caches free, and what their
/// checkouts take on top. Expands to one line per worktree.
struct WorktreeGroupRow: View {
    let group: WorktreeGroup
    let selection: Set<String>
    /// Ports of dev servers by project root.
    let ports: [String: [Int]]
    let staleAfter: TimeInterval
    let isExpanded: Bool
    var isDimmed = false
    var onHover: (Bool) -> Void = { _ in }
    let toggle: ([BuildArtifact]) -> Void
    let expand: () -> Void
    @State private var isHovered = false

    private var artifacts: [BuildArtifact] { group.artifacts }
    private var selectedCount: Int { artifacts.filter { selection.contains($0.path) }.count }
    private var runningPorts: [Int] { group.members.flatMap { ports[$0.root] ?? [] }.sorted() }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Checkbox(isOn: !artifacts.isEmpty && selectedCount == artifacts.count,
                         isMixed: selectedCount > 0 && selectedCount < artifacts.count)
                    .opacity(artifacts.isEmpty ? 0.3 : 1)
                    .padding(.trailing, 12)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(Theme.bodyMedium)
                        .foregroundStyle(Theme.text1)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(group.repositoryRoot)
                    caption
                }
                .padding(.trailing, 10)

                Spacer(minLength: 0)

                if isHovered {
                    IconButton(systemName: "folder", background: .clear, size: 22, help: L10n.text("Reveal in Finder")) {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: group.repositoryRoot)
                    }
                }

                CacheSize(reclaimable: group.reclaimable, size: group.size, checkout: nil, hasCaches: !artifacts.isEmpty)

                Button(action: expand) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.text3)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? L10n.text("Less") : L10n.text("Show worktrees"))
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .onTapGesture { toggle(artifacts) }

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(group.members) { member in
                        memberRow(member)
                    }
                }
                .padding(.bottom, 6)
                .transition(.opacity)
            }
        }
        .opacity(isDimmed ? 0.35 : 1)
        .hoverHighlight(isHovered)
        .animation(.easeOut(duration: 0.12), value: isDimmed)
        .onHover { hovering in
            isHovered = hovering
            onHover(hovering)
        }
    }

    private var caption: some View {
        let count = group.worktrees.count
        let worktrees = L10n.format("%@ in %d %@", Format.diskBytes(group.checkoutBytes), count, L10n.counted("worktree", "worktrees", count: count))
        return HStack(spacing: 5) {
            if !runningPorts.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill").font(.system(size: 8))
                    Text(L10n.format("Server on %@", runningPorts.map { ":\($0)" }.joined(separator: " "))).lineLimit(1)
                }
                .foregroundStyle(Theme.amber)
                .environment(\.layoutDirection, .leftToRight)
                Text("·")
            }
            Text(worktrees).fixedSize()
            Text("·")
            Text(ageText).lineLimit(1).truncationMode(.tail)
        }
        .font(Theme.caption)
        .foregroundStyle(Theme.text2)
        .help(L10n.format("Checkouts take %@: the worktrees' own files. Deleting caches leaves them; removing worktrees you no longer need frees them.",
                                              Format.diskBytes(group.checkoutBytes)))
    }

    private var ageText: String {
        let age = Date().timeIntervalSince(group.lastUsed)
        return age >= staleAfter ? L10n.format("untouched %@", L10n.duration(age, short: true)) : L10n.format("used %@ ago", L10n.duration(age, short: true))
    }

    /// One line per worktree with its checkout; the main repository's line names its caches instead.
    private func memberRow(_ worktree: CacheProject) -> some View {
        let selected = worktree.artifacts.filter { selection.contains($0.path) }.count
        let hasCaches = !worktree.artifacts.isEmpty
        let running = !(ports[worktree.root] ?? []).isEmpty
        return HStack(spacing: 0) {
            Checkbox(isOn: hasCaches && selected == worktree.artifacts.count,
                     isMixed: selected > 0 && selected < worktree.artifacts.count, size: 12)
                .opacity(hasCaches ? 1 : 0.3)
                .padding(.trailing, 10)
            Text(worktree.name)
                .font(Theme.monoCaption)
                .foregroundStyle(Theme.text1.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
                .help([worktree.root, worktree.branch].compactMap { $0 }.joined(separator: "\n"))
            if running {
                Image(systemName: "bolt.fill").font(.system(size: 8)).foregroundStyle(Theme.amber)
                    .padding(.leading, 5)
                    .help(L10n.format("Server on %@", (ports[worktree.root] ?? []).map { ":\($0)" }.joined(separator: " ")))
            }
            Spacer(minLength: 8)
            Text(worktree.checkout == nil ? cacheKinds(worktree.artifacts) : L10n.format("%@ checkout", Format.diskBytes(worktree.checkoutBytes)))
                .font(Theme.caption).foregroundStyle(Theme.text3)
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, 8)
            CacheSize(reclaimable: worktree.reclaimable, size: worktree.size, checkout: worktree.checkout, hasCaches: hasCaches,
                      font: Theme.monoCaption, color: Theme.text2)
        }
        .padding(.leading, 38)
        .padding(.trailing, 30)
        .frame(height: 24)
        .contentShape(Rectangle())
        .onTapGesture { toggle(worktree.artifacts) }
        .contextMenu {
            Button(L10n.text("Reveal in Finder")) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: worktree.root) }
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

// MARK: - Cleanup

/// The deletion queue under the disk bar: the folder being deleted and how
/// many are left, expanding to every folder in the queue.
struct CleanupCard: View {
    let cleanup: BuildCacheStore.Cleanup
    let cancel: () -> Void
    @State private var isExpanded: Bool
    @State private var isHovered = false

    init(cleanup: BuildCacheStore.Cleanup, isExpanded: Bool = false, cancel: @escaping () -> Void) {
        self.cleanup = cleanup
        self.cancel = cancel
        _isExpanded = State(initialValue: isExpanded)
    }

    private let maxVisibleJobs = 6
    private let jobHeight: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    headline
                    Spacer(minLength: 8)
                    Text(countText)
                        .font(Theme.monoCaption).foregroundStyle(Theme.text3)
                        .fixedSize()
                        .contentTransition(.numericText())
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.text3)
                        .frame(width: 12)
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? L10n.text("Less") : L10n.text("Show folders"))

            if isExpanded {
                SectionDivider().padding(.horizontal, 10)
                Group {
                    if cleanup.jobs.count > maxVisibleJobs {
                        ScrollView { jobs }.frame(height: CGFloat(maxVisibleJobs) * jobHeight + 8)
                    } else {
                        jobs
                    }
                }
                if cleanup.queued > 0 {
                    HStack {
                        Spacer()
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { cancel() }
                        } label: {
                            Text(L10n.format("Cancel %d queued", cleanup.queued))
                                .font(Theme.caption).foregroundStyle(Theme.text1)
                                .padding(.horizontal, 10)
                                .frame(height: 22)
                                .background(Theme.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(L10n.text("Puts the folders that haven't started back in the list."))
                    }
                    .padding(EdgeInsets(top: 2, leading: 10, bottom: 10, trailing: 10))
                }
            }
        }
        .background(isHovered && !isExpanded ? Theme.fill : Theme.subtleFill,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.2), value: cleanup.jobs.map(\.state))
    }

    @ViewBuilder private var headline: some View {
        if let job = cleanup.current {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini).frame(width: 12)
                jobLabel(job)
            }
        } else if cleanup.isFinished {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text2).frame(width: 12)
                Text(L10n.format("Freed %@", Format.diskBytes(cleanup.freed))).font(Theme.body).foregroundStyle(Theme.text1)
                if cleanup.failed > 0 {
                    Text(L10n.format("%d kept", cleanup.failed))
                        .font(Theme.caption).foregroundStyle(Theme.amber)
                        .help(L10n.text("Changed since the scan, so it was kept."))
                }
            }
        }
    }

    private var countText: String {
        if cleanup.isFinished {
            let count = cleanup.jobs.count - cleanup.failed
            return L10n.format("%d %@", count, L10n.counted("folder", "folders", count: count))
        }
        return L10n.format("%d of %d", min(cleanup.finished + 1, cleanup.jobs.count), cleanup.jobs.count)
    }

    private func jobLabel(_ job: BuildCacheStore.CleanupJob) -> some View {
        HStack(spacing: 6) {
            Text(job.project.relativePath(of: job.artifact))
                .font(Theme.monoCaption).foregroundStyle(Theme.text1.opacity(0.85))
                .lineLimit(1).truncationMode(.middle)
                .layoutPriority(1)
            Text(job.project.name)
                .font(Theme.caption).foregroundStyle(Theme.text3)
                .lineLimit(1).truncationMode(.tail)
        }
        .help(job.artifact.path)
        .environment(\.layoutDirection, .leftToRight)
    }

    private var jobs: some View {
        VStack(spacing: 0) {
            ForEach(cleanup.jobs) { job in
                HStack(spacing: 8) {
                    icon(job.state).frame(width: 12)
                    jobLabel(job)
                    Spacer(minLength: 8)
                    Text(Format.diskBytes(job.artifact.reclaimable))
                        .font(Theme.monoCaption).foregroundStyle(Theme.text2)
                        .fixedSize()
                }
                .frame(height: jobHeight)
                .opacity(job.state == .done ? 0.55 : 1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    @ViewBuilder private func icon(_ state: BuildCacheStore.CleanupJob.State) -> some View {
        switch state {
        case .queued:
            Circle().strokeBorder(Theme.text3, style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(width: 10, height: 10)
        case .deleting:
            ProgressView().controlSize(.mini)
        case .done:
            Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.text2)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(Theme.amber)
                .help(L10n.text("Changed since the scan, so it was kept."))
        }
    }
}

/// How much of the queue is done, by bytes.
struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(Theme.text1.opacity(0.15), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(fraction, 0.03))
                .stroke(Theme.text1.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 12, height: 12)
        .animation(.easeOut(duration: 0.25), value: fraction)
    }
}

// MARK: - Disk bar

/// The Mac's disk, like the memory bar: build caches by kind and worktree
/// checkouts as raised segments, everything else as a thin baseline, free
/// space as the track.
struct CacheDiskBar: View {
    @ObservedObject var store: BuildCacheStore
    let disk: DiskSpace?
    @Binding var focus: CacheFocus?
    /// The segments of the row under the pointer stay bright.
    var highlighted: Set<CacheFocus>?
    let activate: (ArtifactKind) -> Void

    private let spacing: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            let kinds = kindTotals
            let checkouts = store.checkouts
            let shown = kinds.reduce(0) { $0 + $1.bytes } + checkouts
            let used = max(disk?.used ?? shown, shown)
            let capacity = max(disk?.total ?? used, used, 1)
            let rest = used - shown
            let segments = kinds.count + (checkouts > 0 ? 1 : 0) + (rest > 0 ? 1 : 0)
            let unit = max(geometry.size.width - CGFloat(max(segments - 1, 0)) * spacing, 0) / CGFloat(capacity)
            let lit = highlighted
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.memoryTrack)
                    .frame(height: 4)
                    .help(L10n.format("Free · %@", Format.diskBytes(disk?.free ?? 0)))
                HStack(spacing: spacing) {
                    ForEach(kinds, id: \.kind) { entry in
                        let isFocused = focus == .kind(entry.kind)
                        let isDimmed = (focus != nil && !isFocused) || (lit.map { !$0.contains(.kind(entry.kind)) } ?? false)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Theme.portColor(at: entry.kind.colorIndex))
                            .frame(height: isFocused ? 10 : 8)
                            .opacity(isDimmed ? 0.35 : 1)
                            .frame(width: max(unit * CGFloat(entry.bytes), 2), height: geometry.size.height)
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                if hovering { focus = .kind(entry.kind) } else if focus == .kind(entry.kind) { focus = nil }
                            }
                            .onTapGesture { activate(entry.kind) }
                            .help(L10n.format("%@ · %@. Click to select them all.", entry.kind.label, Format.diskBytes(entry.bytes)))
                    }
                    if checkouts > 0 {
                        let isFocused = focus == .worktrees
                        let isDimmed = (focus != nil && !isFocused) || (lit.map { !$0.contains(.worktrees) } ?? false)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Theme.worktreeCheckout)
                            .frame(height: isFocused ? 10 : 8)
                            .opacity(isDimmed ? 0.35 : 1)
                            .frame(width: max(unit * CGFloat(checkouts), 2), height: geometry.size.height)
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                if hovering { focus = .worktrees } else if focus == .worktrees { focus = nil }
                            }
                            .help(L10n.format("Worktree checkouts · %@. Removing a worktree frees it; deleting caches doesn't.", Format.diskBytes(checkouts)))
                    }
                    if rest > 0 {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Theme.text1.opacity(0.12))
                            .frame(width: max(unit * CGFloat(rest), 1), height: 4)
                            .frame(height: geometry.size.height)
                            .help(L10n.format("Everything else · %@", Format.diskBytes(rest)))
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.easeOut(duration: 0.12), value: focus)
            .animation(.easeOut(duration: 0.12), value: highlighted)
        }
    }

    private var kindTotals: [(kind: ArtifactKind, bytes: UInt64)] {
        var totals: [ArtifactKind: UInt64] = [:]
        for artifact in store.projects.flatMap(\.artifacts) { totals[artifact.kind, default: 0] += artifact.reclaimable }
        return totals.filter { $0.value > 0 }.map { ($0.key, $0.value) }.sorted { $0.bytes > $1.bytes }
    }
}

/// Caches · Worktrees · Other · Free of the disk's total.
struct CacheLegend: View {
    @ObservedObject var store: BuildCacheStore
    let disk: DiskSpace?

    var body: some View {
        // With worktrees there may be no room for Other; it's the least useful item.
        ViewThatFits(in: .horizontal) {
            legend(showsOther: true)
            legend(showsOther: false)
        }
    }

    private func legend(showsOther: Bool) -> some View {
        let shown = store.reclaimable + store.checkouts
        return HStack(spacing: 10) {
            item(swatch: Theme.text1.opacity(0.95), tall: true, label: L10n.text("Caches"), value: amount(store.reclaimable))
                .fixedSize()
            if store.checkouts > 0 {
                item(swatch: Theme.worktreeCheckout, tall: true, label: L10n.text("Worktrees"), value: amount(store.checkouts))
                    .fixedSize()
                    .help(L10n.format("Checkouts take %@: the worktrees' own files. Deleting caches leaves them; removing worktrees you no longer need frees them.",
                                      Format.diskBytes(store.checkouts)))
            }
            if let disk {
                if showsOther {
                    item(swatch: Theme.text1.opacity(0.12), tall: false, label: L10n.text("Other"),
                         value: amount(disk.used > shown ? disk.used - shown : 0))
                        .fixedSize()
                }
                item(swatch: Theme.memoryTrack, tall: false, label: L10n.text("Free"),
                     value: L10n.format("%@ of %@", number(disk.free), amount(disk.total)))
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
    }

    /// Disks are big: whole gigabytes from 100 GB up.
    private func number(_ bytes: UInt64) -> String {
        let value = Format.total(bytes)
        guard value.unit == "GB", let gigabytes = Double(value.number), gigabytes >= 100 else { return value.number }
        return String(Int(gigabytes.rounded()))
    }

    private func amount(_ bytes: UInt64) -> String {
        "\(number(bytes)) \(Format.total(bytes).unit)"
    }

    private func item(swatch: Color, tall: Bool, label: String, value: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5).fill(swatch).frame(width: 8, height: tall ? 8 : 4)
            Text(label).font(Theme.caption).foregroundStyle(Theme.text2).lineLimit(1)
            Text(value).font(Theme.monoCaption).foregroundStyle(Theme.text3).lineLimit(1)
        }
    }
}

/// Capacity of the volume holding the home folder, as Finder counts it.
struct DiskSpace: Equatable {
    let total: UInt64
    let free: UInt64
    var used: UInt64 { total > free ? total - free : 0 }

    static func current() -> DiskSpace? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return DiskSpace(total: UInt64(total), free: UInt64(max(free, 0)))
    }
}
