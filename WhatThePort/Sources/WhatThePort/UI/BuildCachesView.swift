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
    @State private var expanded: Set<String> = []
    /// The kind under the pointer in the disk bar.
    @State private var focus: ArtifactKind?
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
        _expanded = State(initialValue: expandFirst ? Set(monitor.caches.projects.prefix(1).map(\.root)) : [])
        _confirming = State(initialValue: confirm)
    }

    var body: some View {
        VStack(spacing: 0) {
            summary
            SectionDivider()
            if store.projects.isEmpty {
                emptyState
            } else if store.projects.count > maxVisibleRows || !expanded.isEmpty {
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
                    Circle().fill(Theme.portColor(at: focus.colorIndex)).frame(width: 6, height: 6)
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
                Spacer()
                summaryDetail
            }
            CacheDiskBar(store: store, disk: disk, focus: $focus, highlighted: hoveredRow.flatMap(project(root:))) { kind in
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
        if let focus {
            let count = artifacts.filter { $0.kind == focus }.count
            Text(L10n.format("%d %@", count, L10n.counted("folder", "folders", count: count)))
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

    private func total(of kind: ArtifactKind) -> UInt64 {
        artifacts.filter { $0.kind == kind }.reduce(0) { $0 + $1.reclaimable }
    }

    private func project(root: String) -> CacheProject? {
        store.projects.first { $0.root == root }
    }

    // MARK: - Rows

    private var rows: some View {
        LazyVStack(spacing: 0) {
            let ports = serverPorts
            ForEach(store.projects) { project in
                CacheProjectRow(project: project, selection: selection, ports: ports[project.root] ?? [],
                                isStale: store.isStale(project), isExpanded: expanded.contains(project.root),
                                isDimmed: focus != nil && !project.artifacts.contains { $0.kind == focus },
                                onHover: { hovering in
                                    if hovering { hoveredRow = project.root } else if hoveredRow == project.root { hoveredRow = nil }
                                },
                                toggle: toggle,
                                expand: {
                                    withAnimation(.snappy(duration: 0.2)) {
                                        if expanded.contains(project.root) { expanded.remove(project.root) } else { expanded.insert(project.root) }
                                    }
                                })
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Checkbox(isOn: selectedCount == project.artifacts.count, isMixed: selectedCount > 0 && selectedCount < project.artifacts.count)
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

                Text(Format.diskBytes(project.reclaimable))
                    .font(Theme.mono)
                    .foregroundStyle(Theme.text1.opacity(0.85))
                    .frame(width: 64, alignment: .trailing)
                    .help(sharedHelp(size: project.size, reclaimable: project.reclaimable))

                Button(action: expand) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.text3)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? L10n.text("Less") : L10n.text("Show folders"))
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .onTapGesture { toggle(project.artifacts) }

            if isExpanded {
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

    /// The worktree's repository, then the kinds inside, largest first.
    private var kindText: String {
        var totals: [ArtifactKind: UInt64] = [:]
        for artifact in project.artifacts { totals[artifact.kind, default: 0] += artifact.reclaimable }
        let labels = totals.sorted { $0.value == $1.value ? $0.key.colorIndex < $1.key.colorIndex : $0.value > $1.value }.map(\.key.label)
        let kinds = labels.count > 3 ? labels.prefix(2).joined(separator: ", ") + " +\(labels.count - 2)" : labels.joined(separator: ", ")
        guard let repository = project.repository else { return kinds }
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

    private func sharedHelp(size: UInt64, reclaimable: UInt64) -> String {
        guard size > reclaimable + 1_048_576 else { return L10n.format("Frees %@", Format.diskBytes(reclaimable)) }
        return L10n.format("Frees %@ of %@ on disk. The rest is shared with copies elsewhere, like the pnpm store.",
                           Format.diskBytes(reclaimable), Format.diskBytes(size))
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

/// The Mac's disk, like the memory bar: build caches by kind as raised
/// segments, everything else as a thin baseline, free space as the track.
struct CacheDiskBar: View {
    @ObservedObject var store: BuildCacheStore
    let disk: DiskSpace?
    @Binding var focus: ArtifactKind?
    /// A project whose row is hovered: its kinds stay bright.
    var highlighted: CacheProject?
    let activate: (ArtifactKind) -> Void

    private let spacing: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            let kinds = kindTotals
            let caches = kinds.reduce(0) { $0 + $1.bytes }
            let used = max(disk?.used ?? caches, caches)
            let capacity = max(disk?.total ?? used, used, 1)
            let rest = used - caches
            let segments = kinds.count + (rest > 0 ? 1 : 0)
            let unit = max(geometry.size.width - CGFloat(max(segments - 1, 0)) * spacing, 0) / CGFloat(capacity)
            let lit = highlighted.map { Set($0.artifacts.map(\.kind)) }
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.memoryTrack)
                    .frame(height: 4)
                    .help(L10n.format("Free · %@", Format.diskBytes(disk?.free ?? 0)))
                HStack(spacing: spacing) {
                    ForEach(kinds, id: \.kind) { entry in
                        let isFocused = focus == entry.kind
                        let isDimmed = (focus != nil && !isFocused) || (lit.map { !$0.contains(entry.kind) } ?? false)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Theme.portColor(at: entry.kind.colorIndex))
                            .frame(height: isFocused ? 10 : 8)
                            .opacity(isDimmed ? 0.35 : 1)
                            .frame(width: max(unit * CGFloat(entry.bytes), 2), height: geometry.size.height)
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                if hovering { focus = entry.kind } else if focus == entry.kind { focus = nil }
                            }
                            .onTapGesture { activate(entry.kind) }
                            .help(L10n.format("%@ · %@. Click to select them all.", entry.kind.label, Format.diskBytes(entry.bytes)))
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
            .animation(.easeOut(duration: 0.12), value: highlighted?.root)
        }
    }

    private var kindTotals: [(kind: ArtifactKind, bytes: UInt64)] {
        var totals: [ArtifactKind: UInt64] = [:]
        for artifact in store.projects.flatMap(\.artifacts) { totals[artifact.kind, default: 0] += artifact.reclaimable }
        return totals.filter { $0.value > 0 }.map { ($0.key, $0.value) }.sorted { $0.bytes > $1.bytes }
    }
}

/// Caches · Other · Free of the disk's total.
struct CacheLegend: View {
    @ObservedObject var store: BuildCacheStore
    let disk: DiskSpace?

    var body: some View {
        HStack(spacing: 10) {
            item(swatch: Theme.text1.opacity(0.95), tall: true, label: L10n.text("Caches"), value: amount(store.reclaimable))
                .fixedSize()
            if let disk {
                // The only item that may truncate, so long translations never widen the popover.
                item(swatch: Theme.text1.opacity(0.12), tall: false, label: L10n.text("Other"),
                     value: amount(disk.used > store.reclaimable ? disk.used - store.reclaimable : 0))
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(-1)
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
