import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct MobileTaskDirectorySearchServiceTests {
    @Test func dispatchRejectsAnEmptyDirectoryQuery() async {
        #expect(MobileHostService.mobileHostCapabilities.contains("workspace.directory_search.v1"))
        #expect(MobileHostService.mobileHostCapabilities.contains("workspace.directory_search.v2"))

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

    @MainActor
    @Test func metadataPredicateMatchesDirectoryTypeTreesAcrossPathTokens() {
        let predicate = MobileTaskDirectoryMetadataQueryRunner.makePredicate(query: "Manaflow cmux")

        #expect(predicate.evaluate(with: [
            NSMetadataItemContentTypeTreeKey: ["public.item", "public.directory"],
            NSMetadataItemFSNameKey: "cmuxterm-hq",
            NSMetadataItemPathKey: "/Users/test/Dev/Manaflow/cmuxterm-hq",
        ]))
        #expect(!predicate.evaluate(with: [
            NSMetadataItemContentTypeTreeKey: ["public.item", "public.data"],
            NSMetadataItemFSNameKey: "cmuxterm-hq",
            NSMetadataItemPathKey: "/Users/test/Dev/Manaflow/cmuxterm-hq",
        ]))
    }

    @Test func mergesContextualAndIndexedMatchesWithoutEarlyReturningOneExactPath() async throws {
        let service = MobileTaskDirectorySearchService(
            homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true),
            metadataSearchOperation: { _, _, _ in
                MobileTaskDirectoryMetadataQueryRunner.Snapshot(
                    paths: [
                        "/Users/test/Dev/cmux",
                        "/Volumes/External/cmux",
                    ],
                    gatheringComplete: true,
                    totalMatchCount: 2,
                    truncated: false
                )
            },
            directoryExists: { _ in true }
        )

        let result = try await service.search(
            query: "cmux",
            seedPaths: ["/Users/test/Open/cmux"]
        )

        #expect(Set(result.directories) == Set([
            "/Users/test/Open/cmux",
            "/Users/test/Dev/cmux",
            "/Volumes/External/cmux",
        ]))
        #expect(result.scope == .allIndexedVolumes)
        #expect(result.gatheringComplete)
        #expect(!result.filesystemComplete)
        #expect(!result.truncated)
        #expect(result.indexedMatchCount == 2)
    }

    @Test func reportsPartialAndTruncatedIndexedCoverage() async throws {
        let service = MobileTaskDirectorySearchService(
            configuration: .init(maximumMetadataResults: 3, maximumWireResults: 2),
            metadataSearchOperation: { _, _, _ in
                MobileTaskDirectoryMetadataQueryRunner.Snapshot(
                    paths: [
                        "/Volumes/A/project",
                        "/Volumes/B/project",
                        "/Volumes/C/project",
                    ],
                    gatheringComplete: false,
                    totalMatchCount: 100,
                    truncated: true
                )
            },
            directoryExists: { _ in true }
        )

        let result = try await service.search(query: "project", seedPaths: [])

        #expect(result.directories.count == 2)
        #expect(result.scope == .allIndexedVolumes)
        #expect(!result.gatheringComplete)
        #expect(!result.filesystemComplete)
        #expect(result.truncated)
        #expect(result.indexedMatchCount == 100)
    }

    @Test func metadataUnavailabilityFallsBackWithExplicitContextOnlyCoverage() async throws {
        let service = MobileTaskDirectorySearchService(
            homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true),
            metadataSearchOperation: { _, _, _ in
                throw MobileTaskDirectoryMetadataQueryRunner.QueryError.unavailable
            },
            directoryExists: { _ in true }
        )

        let result = try await service.search(
            query: "project",
            seedPaths: ["/Users/test/Open/project"]
        )

        #expect(result.directories == ["/Users/test/Open/project"])
        #expect(result.scope == .contextualCandidatesOnly)
        #expect(!result.gatheringComplete)
        #expect(!result.filesystemComplete)
        #expect(!result.truncated)
        #expect(result.indexedMatchCount == 0)
    }

    @Test func concurrentClientsDoNotCancelEachOthersSearches() async {
        let service = MobileTaskDirectorySearchService(
            metadataSearchOperation: { query, _, _ in
                await Task.yield()
                return MobileTaskDirectoryMetadataQueryRunner.Snapshot(
                    paths: ["/Volumes/Projects/\(query)"],
                    gatheringComplete: true,
                    totalMatchCount: 1,
                    truncated: false
                )
            },
            directoryExists: { _ in true }
        )

        let results = await withTaskGroup(
            of: MobileTaskDirectorySearchResult?.self,
            returning: [MobileTaskDirectorySearchResult?].self
        ) { group in
            for index in 0..<16 {
                group.addTask {
                    try? await service.search(query: "project-\(index)", seedPaths: [])
                }
            }
            var values: [MobileTaskDirectorySearchResult?] = []
            for await value in group {
                values.append(value)
            }
            return values
        }

        #expect(results.count == 16)
        #expect(results.allSatisfy { $0?.directories.count == 1 })
    }
}
