import Foundation
import Testing
@testable import WhatThePort

/// Serialized: the store tests share the folders preference.
@Suite(.serialized) struct BuildCacheTests {
    @Test func classifiesByNameAndManifest() {
        let cases: [(String, Set<String>, ArtifactKind?)] = [
            ("node_modules", [], .nodeModules), (".next", [], .next), (".turbo", [], .turbo),
            ("target", ["Cargo.toml"], .rust), ("target", ["pom.xml"], .java), ("target", ["README.md"], nil),
            (".build", ["Package.swift"], .swift), (".build", [], nil),
            ("Pods", ["Podfile"], .cocoaPods), ("Pods", [], nil),
            ("DerivedData", [], .xcode), ("__pycache__", [], .pythonCache),
            ("dist", ["package.json"], .webBuild), ("dist", [], nil), ("vendor", ["composer.json"], nil),
            ("build", ["build.gradle.kts"], .java), ("build", ["App.xcodeproj"], .xcode), ("src", ["package.json"], nil),
        ]
        for (name, siblings, expected) in cases {
            #expect(BuildCacheScanner.classify(name, path: "/nonexistent/\(name)", siblings: siblings)?.kind == expected, "\(name) beside \(siblings)")
        }
    }

    @Test func findsArtifactsAndSkipsWhatIsntOne() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let found = Set(BuildCacheScanner.gitFilter(BuildCacheScanner.discover(roots: [fixture.root])).map(\.path))
        let expected = ["web/node_modules", "web/.next", "rusty/target", "tagged/cache-store", "py/__pycache__", "py/.venv"]
        for path in expected { #expect(found.contains(fixture.root + "/" + path), "missing \(path)") }
        for path in ["web/src", "web/linked", "py/venv", "web/node_modules/pkg/node_modules"] {
            #expect(!found.contains(fixture.root + "/" + path), "unexpected \(path)")
        }
        if BuildCacheScanner.gitPath != nil {
            #expect(found.contains(fixture.root + "/web/dist"), "dist is ignored by git")
            #expect(!found.contains(fixture.root + "/web/build"), "build is not ignored, so it may be committed output")
        }
    }

    @Test func groupsByProjectAndMeasures() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let projects = BuildCacheScanner.scan(roots: [fixture.root])
        let web = try #require(projects.first { $0.root == fixture.root + "/web" })
        let modules = try #require(web.artifacts.first { $0.kind == .nodeModules })
        #expect(modules.size >= 64 * 1024)
        #expect(modules.reclaimable <= modules.size)
        #expect(web.relativePath(of: modules) == "node_modules")
        // Folders without a repository group under their top-level folder.
        #expect(projects.contains { $0.root == fixture.root + "/rusty" && $0.artifacts.contains { $0.kind == .rust } })
    }

    @Test func reusesUnchangedMeasurements() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = BuildCacheScanner.scan(roots: [fixture.root]).flatMap(\.artifacts)
        var reuse: [String: BuildArtifact] = [:]
        for var artifact in first {
            artifact.size = 42
            reuse[artifact.path] = artifact
        }
        let second = BuildCacheScanner.scan(roots: [fixture.root], reuse: reuse).flatMap(\.artifacts)
        #expect(!second.isEmpty && second.allSatisfy { $0.size == 42 })
    }

    @Test func deletesOnlyArtifactsInsideScannedFolders() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let artifacts = BuildCacheScanner.scan(roots: [fixture.root]).flatMap(\.artifacts)
        let modules = try #require(artifacts.first { $0.path == fixture.root + "/web/node_modules" })

        // Outside the scanned folders.
        #expect(!BuildCacheScanner.remove(modules, roots: [fixture.root + "/rusty"]))
        // Replaced by a symlink since the scan.
        let moved = fixture.root + "/web/modules-real"
        try FileManager.default.moveItem(atPath: modules.path, toPath: moved)
        try FileManager.default.createSymbolicLink(atPath: modules.path, withDestinationPath: moved)
        #expect(!BuildCacheScanner.remove(modules, roots: [fixture.root]))
        #expect(FileManager.default.fileExists(atPath: moved + "/pkg/index.js"))
        try FileManager.default.removeItem(atPath: modules.path)
        try FileManager.default.moveItem(atPath: moved, toPath: modules.path)
        // Turned into a repository of its own.
        try FileManager.default.createDirectory(atPath: modules.path + "/.git", withIntermediateDirectories: true)
        #expect(!BuildCacheScanner.remove(modules, roots: [fixture.root]))
        try FileManager.default.removeItem(atPath: modules.path + "/.git")

        #expect(BuildCacheScanner.remove(modules, roots: [fixture.root]))
        #expect(!FileManager.default.fileExists(atPath: modules.path))
        #expect(FileManager.default.fileExists(atPath: fixture.root + "/web/package.json"))
        #expect(FileManager.default.fileExists(atPath: fixture.root + "/web/src/index.ts"))
    }

    /// The page's flow: scan in the background, delete what's picked, free the space.
    @MainActor @Test func storeScansAndDeletes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let saved = UserDefaults.standard.object(forKey: Preferences.cacheFolders)
        defer { UserDefaults.standard.set(saved, forKey: Preferences.cacheFolders) }
        let store = BuildCacheStore()
        store.setFolders([fixture.root])
        store.scan(force: true)
        for _ in 0..<200 where store.isScanning { try await Task.sleep(for: .milliseconds(25)) }
        #expect(!store.isScanning)
        let modules = fixture.root + "/web/node_modules", next = fixture.root + "/web/.next"
        #expect(store.projects.flatMap(\.artifacts).contains { $0.path == modules })

        store.delete([modules, next])
        #expect(!store.projects.flatMap(\.artifacts).contains { $0.path == modules || $0.path == next })
        #expect(store.cleanup?.jobs.map(\.id).sorted() == [next, modules].sorted())
        for _ in 0..<200 where store.cleanup?.isFinished == false { try await Task.sleep(for: .milliseconds(25)) }
        let cleanup = try #require(store.cleanup)
        #expect(cleanup.isFinished && cleanup.failed == 0)
        #expect(cleanup.freed > 0 && cleanup.freed == cleanup.total && cleanup.progress == 1)
        #expect(!FileManager.default.fileExists(atPath: modules) && !FileManager.default.fileExists(atPath: next))
        #expect(FileManager.default.fileExists(atPath: fixture.root + "/rusty/target"))
        #expect(FileManager.default.fileExists(atPath: fixture.root + "/web/src/index.ts"))
    }

    /// Deleting works through a queue one folder at a time; cancelling puts
    /// the folders that haven't started back in the list, untouched.
    @MainActor @Test func cancelsQueuedDeletes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let saved = UserDefaults.standard.object(forKey: Preferences.cacheFolders)
        defer { UserDefaults.standard.set(saved, forKey: Preferences.cacheFolders) }
        let store = BuildCacheStore()
        store.setFolders([fixture.root])
        store.scan(force: true)
        for _ in 0..<200 where store.isScanning { try await Task.sleep(for: .milliseconds(25)) }
        let paths = ["/web/node_modules", "/rusty/target", "/py/__pycache__"].map { fixture.root + $0 }
        #expect(Set(paths).isSubset(of: store.projects.flatMap(\.artifacts).map(\.path)))

        store.delete(Set(paths))
        let jobs = try #require(store.cleanup?.jobs)
        #expect(jobs.count == 3 && jobs.filter { $0.state == .deleting }.count == 1 && store.cleanup?.queued == 2)
        let started = try #require(store.cleanup?.current?.id)
        store.cancelQueued()
        #expect(store.cleanup?.jobs.map(\.id) == [started])
        let restored = paths.filter { $0 != started }
        #expect(Set(restored).isSubset(of: store.projects.flatMap(\.artifacts).map(\.path)))

        for _ in 0..<200 where store.cleanup?.isFinished == false { try await Task.sleep(for: .milliseconds(25)) }
        #expect(store.cleanup?.isFinished == true)
        #expect(!FileManager.default.fileExists(atPath: started))
        #expect(restored.allSatisfy { FileManager.default.fileExists(atPath: $0) })
    }

    @Test func reportsProgressWhileRemoving() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let modules = try #require(BuildCacheScanner.scan(roots: [fixture.root]).flatMap(\.artifacts).first { $0.name == "node_modules" })
        var reported: [Double] = []
        #expect(BuildCacheScanner.remove(modules, roots: [fixture.root]) { reported.append($0) })
        #expect(!reported.isEmpty && reported == reported.sorted() && reported.last == 1)
        #expect(!FileManager.default.fileExists(atPath: modules.path))
    }

    @MainActor @Test func keepsOutermostFolders() {
        #expect(BuildCacheStore.outermost(["/a/b", "/a", "/c/", "/A", "/ab"]) == ["/a", "/ab", "/c"])
    }

    /// A folder of small projects in the temporary folder.
    private struct Fixture {
        let root: String

        init() throws {
            root = (NSTemporaryDirectory() as NSString).appendingPathComponent("wtp-caches-\(UUID().uuidString)")
            try file("web/package.json", "{}")
            try file("web/.gitignore", "dist/\n")
            try file("web/src/index.ts", "export {}\n")
            try file("web/node_modules/pkg/index.js", String(repeating: "x", count: 64 * 1024))
            try file("web/node_modules/pkg/node_modules/inner/index.js", "x")
            try file("web/.next/cache/data", String(repeating: "y", count: 8 * 1024))
            try file("web/dist/bundle.js", "z")
            try file("web/build/index.html", "<p>")
            try file("rusty/Cargo.toml", "[package]\nname = \"rusty\"\n")
            try file("rusty/target/debug/rusty", String(repeating: "r", count: 4096))
            try file("tagged/cache-store/CACHEDIR.TAG", "Signature: 8a477f597d28d172789f06886806bc55\n")
            try file("tagged/cache-store/blob", "b")
            try file("py/__pycache__/main.cpython-312.pyc", "c")
            try file("py/.venv/pyvenv.cfg", "home = /usr/bin\n")
            try file("py/venv/notes.txt", "Not a virtual environment")
            try FileManager.default.createSymbolicLink(atPath: root + "/web/linked", withDestinationPath: root + "/web/src")
            if let git = BuildCacheScanner.gitPath {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: git)
                process.arguments = ["init", "-q", root + "/web"]
                try process.run()
                process.waitUntilExit()
            }
        }

        private func file(_ path: String, _ contents: String) throws {
            let url = URL(fileURLWithPath: root + "/" + path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: false, encoding: .utf8)
        }

        func remove() {
            try? FileManager.default.removeItem(atPath: root)
        }
    }
}
