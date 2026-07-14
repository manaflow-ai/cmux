import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct MobileTaskDirectorySearchServiceTests {
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
}
