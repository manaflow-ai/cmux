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

        let matches = try await service.search(query: "cmuxterm", seedPaths: [])
        #expect(matches.count == 1)
        #expect(matches.first?.hasSuffix("/Dev/Manaflow/cmuxterm-hq") == true)
        #expect(matches.first.map(FileManager.default.fileExists(atPath:)) == true)
        #expect(try await service.search(query: "hidden-project", seedPaths: []).isEmpty)
    }

    @Test func filesystemInspectionStopsAtItsIndependentEntryBudget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-directory-budget-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<32 {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("candidate-\(index)", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let service = MobileTaskDirectorySearchService(
            homeDirectory: root,
            configuration: .init(
                maximumDirectories: 200,
                maximumDepth: 6,
                cacheLifetime: 30,
                maximumFilesystemEntries: 1
            )
        )

        #expect(try await service.search(query: "candidate", seedPaths: []).isEmpty)
    }

    @Test func seededHomeDirectorySurvivesGlobalEntryBudget() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-seeded-home-\(UUID().uuidString)", isDirectory: true)
        let project = home.appendingPathComponent(
            "Dev/Manaflow/cmuxterm-hq/worktrees/feat-ios-task-composer",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let service = MobileTaskDirectorySearchService(
            homeDirectory: home,
            configuration: .init(
                maximumDirectories: 200,
                maximumDepth: 6,
                cacheLifetime: 30,
                maximumFilesystemEntries: 1
            )
        )

        let matches = try await service.search(
            query: "feat-ios-task-composer",
            seedPaths: [project.path]
        )

        #expect(matches == [project.standardizedFileURL.path])
    }

    @Test func matchingSeedBypassesColdIndexBuild() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-seed-fast-path-\(UUID().uuidString)", isDirectory: true)
        let project = home.appendingPathComponent("Dev/seeded-project", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let builder = ImmediateDirectoryIndexBuilder()
        let service = MobileTaskDirectorySearchService(
            homeDirectory: home,
            configuration: .init(maximumDirectories: 200, maximumDepth: 6, cacheLifetime: 30),
            indexBuilder: { _, _ in await builder.run() }
        )

        let matches = try await service.search(query: "seeded-project", seedPaths: [project.path])

        #expect(matches == [project.standardizedFileURL.path])
        #expect(await builder.count == 0)
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
        let initialMatches = try await service.search(query: "removed-root-project", seedPaths: [project.path])
        #expect(
            initialMatches.contains { $0.hasSuffix("/external/removed-root-project") },
            "Initial matches: \(initialMatches)"
        )
        #expect(try await service.search(query: "removed-root-project", seedPaths: []).isEmpty)
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

    @Test func newerQueryCancelsAndDrainsPriorRankBeforeStarting() async throws {
        let ranker = ControlledDirectoryRanker()
        let service = MobileTaskDirectorySearchService(
            configuration: .init(maximumDirectories: 1, maximumDepth: 0, cacheLifetime: 30),
            indexBuilder: { _, _ in [] },
            rankOperation: { _, query, _ in await ranker.run(query: query) }
        )
        let first = Task { try await service.search(query: "first", seedPaths: []) }
        await ranker.waitForCount(1)
        let second = Task { try await service.search(query: "second", seedPaths: []) }
        await ranker.waitForCount(2)

        #expect((try await first.value).isEmpty)
        #expect(try await second.value == ["latest"])
        #expect(await ranker.maximumActiveCount == 1)
    }

    @Test func timedOutIndexBuildIsQuarantinedAtConfiguredCapacity() async {
        let builder = ControlledDirectoryIndexBuilder()
        let deadlines = ControlledDirectorySearchDeadlines()
        let service = MobileTaskDirectorySearchService(
            configuration: .init(
                maximumDirectories: 1,
                maximumDepth: 0,
                cacheLifetime: 30,
                maximumFilesystemEntries: 1,
                indexBuildTimeout: .seconds(1),
                maximumConcurrentIndexBuilds: 1
            ),
            indexBuilder: { _, _ in await builder.run() },
            deadlineSleep: { _ in await deadlines.suspendUntilFired() }
        )
        let first = Task {
            await Self.searchError(from: service, query: "first")
        }
        await builder.waitForCount(1)
        await deadlines.waitForCount(1)
        await deadlines.fireAll()

        #expect(await first.value == .indexTimedOut)
        #expect(await Self.searchError(from: service, query: "second") == .busy)
        #expect(await builder.count == 1)
        await builder.complete()
    }

    @Test func filesystemRootNeverNormalizesToDotDot() {
        let root = MobileTaskDirectorySearchService.parentSearchRoot(
            for: URL(fileURLWithPath: "/", isDirectory: true)
        )

        #expect(root.path == "/")
    }

    private static func searchError(
        from service: MobileTaskDirectorySearchService,
        query: String
    ) async -> MobileTaskDirectorySearchService.SearchError? {
        do {
            _ = try await service.search(query: query, seedPaths: [])
            return nil
        } catch let error as MobileTaskDirectorySearchService.SearchError {
            return error
        } catch {
            return nil
        }
    }
}

private actor ImmediateDirectoryIndexBuilder {
    private(set) var count = 0

    func run() -> [MobileTaskDirectorySearchService.SearchablePath] {
        count += 1
        return []
    }
}

private actor ControlledDirectoryRanker {
    private(set) var count = 0
    private(set) var activeCount = 0
    private(set) var maximumActiveCount = 0
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func run(query: String) async -> [String] {
        count += 1
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        resumeCountWaiters()
        defer { activeCount -= 1 }
        if query == "first" {
            try? await Task.sleep(for: .seconds(60))
            return []
        }
        return ["latest"]
    }

    func waitForCount(_ expected: Int) async {
        if count >= expected { return }
        await withCheckedContinuation { countWaiters.append((expected, $0)) }
    }

    private func resumeCountWaiters() {
        let ready = countWaiters.filter { count >= $0.0 }
        countWaiters.removeAll { count >= $0.0 }
        for waiter in ready { waiter.1.resume() }
    }
}

private actor ControlledDirectoryIndexBuilder {
    private(set) var count = 0
    private var continuation: CheckedContinuation<[MobileTaskDirectorySearchService.SearchablePath], Never>?
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func run() async -> [MobileTaskDirectorySearchService.SearchablePath] {
        count += 1
        let ready = countWaiters.filter { count >= $0.0 }
        countWaiters.removeAll { count >= $0.0 }
        for waiter in ready { waiter.1.resume() }
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitForCount(_ expected: Int) async {
        if count >= expected { return }
        await withCheckedContinuation { countWaiters.append((expected, $0)) }
    }

    func complete() {
        continuation?.resume(returning: [])
        continuation = nil
    }
}

private actor ControlledDirectorySearchDeadlines {
    private var count = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func suspendUntilFired() async {
        count += 1
        let ready = countWaiters.filter { count >= $0.0 }
        countWaiters.removeAll { count >= $0.0 }
        for waiter in ready { waiter.1.resume() }
        await withCheckedContinuation { continuations.append($0) }
    }

    func waitForCount(_ expected: Int) async {
        if count >= expected { return }
        await withCheckedContinuation { countWaiters.append((expected, $0)) }
    }

    func fireAll() {
        let pending = continuations
        continuations = []
        for continuation in pending { continuation.resume() }
    }
}
