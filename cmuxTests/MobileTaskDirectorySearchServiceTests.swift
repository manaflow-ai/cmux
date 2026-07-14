import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct MobileTaskDirectorySearchServiceTests {
    @Test func advertisesAndDispatchesDirectorySearch() async {
        #expect(MobileHostService.mobileHostCapabilities.contains("workspace.directory_search.v1"))

        let request = MobileHostRPCRequest(
            id: "directory-search",
            method: "mobile.directory.search",
            params: ["query": ""],
            auth: nil
        )
        let result = await TerminalController.shared.mobileHostHandleRPC(request)
        guard case let .failure(error) = result else {
            return #expect(Bool(false), "An empty directory query must be rejected")
        }
        #expect(error.code == "invalid_params")
    }

    @Test func ranksStrictAndComponentMatchesBeforeLenientMatches() {
        let paths = [
            "/Users/test/Dev/Manaflow/cmuxterm-hq",
            "/Users/test/Dev/Manaflow/cmixterm-hq",
            "/Users/test/Documents/cmux-notes",
        ]

        let strict = MobileTaskDirectorySearchService.rank(paths: paths, query: "cmux", limit: 8)
        #expect(strict.first == "/Users/test/Documents/cmux-notes")
        #expect(strict.contains("/Users/test/Dev/Manaflow/cmuxterm-hq"))

        let components = MobileTaskDirectorySearchService.rank(paths: paths, query: "mana cmu", limit: 8)
        #expect(components == ["/Users/test/Dev/Manaflow/cmuxterm-hq"])

        let fuzzy = MobileTaskDirectorySearchService.rank(paths: paths, query: "manaflw", limit: 8)
        #expect(fuzzy.prefix(2).contains("/Users/test/Dev/Manaflow/cmuxterm-hq"))
    }

    @Test func scansARealHierarchyWithoutDescendingIntoDependencyTrees() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-directory-search-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Dev/Manaflow/cmuxterm-hq", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Dev/node_modules/hidden-project", isDirectory: true),
            withIntermediateDirectories: true
        )
        let service = MobileTaskDirectorySearchService(
            homeDirectory: root,
            configuration: .init(maximumDirectories: 200, maximumDepth: 6, cacheLifetime: 30)
        )

        let matches = await service.search(query: "cmuxterm", seedPaths: [])
        #expect(matches.count == 1)
        #expect(matches.first?.hasSuffix("/Dev/Manaflow/cmuxterm-hq") == true)
        #expect(matches.first.map(FileManager.default.fileExists(atPath:)) == true)
        #expect(await service.search(query: "hidden-project", seedPaths: []).isEmpty)
    }

    @Test func removingAnExternalSeedDoesNotReuseItsCachedPaths() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-directory-roots-\(UUID().uuidString)", isDirectory: true)
        let home = base.appendingPathComponent("home", isDirectory: true)
        let external = base.appendingPathComponent("external", isDirectory: true)
        let project = external.appendingPathComponent("removed-root-project", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let service = MobileTaskDirectorySearchService(
            homeDirectory: home,
            configuration: .init(maximumDirectories: 200, maximumDepth: 6, cacheLifetime: 30)
        )
        let initialMatches = await service.search(query: "removed-root-project", seedPaths: [project.path])
        #expect(
            initialMatches.contains { $0.hasSuffix("/external/removed-root-project") },
            "Initial matches: \(initialMatches)"
        )
        #expect(await service.search(query: "removed-root-project", seedPaths: []).isEmpty)
    }

    @Test func cancelledRankStopsBeforeReturningStaleResults() async {
        let paths = (0..<12_000).map { "/Users/test/Dev/project-\($0)" }
        let task = Task.detached {
            do { try await Task.sleep(for: .seconds(60)) } catch {}
            return MobileTaskDirectorySearchService.rank(paths: paths, query: "project", limit: 64)
        }
        task.cancel()

        #expect(await task.value.isEmpty)
    }

    @Test func filesystemRootNeverNormalizesToDotDot() {
        let root = MobileTaskDirectorySearchService.parentSearchRoot(
            for: URL(fileURLWithPath: "/", isDirectory: true)
        )

        #expect(root.path == "/")
    }
}
