import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


final class CommandPaletteSwitcherSearchIndexerTests: XCTestCase {
    func testKeywordsIncludeDirectoryBranchAndPortMetadata() {
        let metadata = CommandPaletteSwitcherSearchMetadata(
            directories: ["/Users/example/dev/cmuxterm-hq/worktrees/feat-cmd-palette"],
            branches: ["feature/cmd-palette-indexing"],
            ports: [3000, 9222]
        )

        let keywords = CommandPaletteSwitcherSearchIndexer.keywords(
            baseKeywords: ["workspace", "switch"],
            metadata: metadata
        )

        XCTAssertTrue(keywords.contains("/Users/example/dev/cmuxterm-hq/worktrees/feat-cmd-palette"))
        XCTAssertTrue(keywords.contains("feat-cmd-palette"))
        XCTAssertTrue(keywords.contains("feature/cmd-palette-indexing"))
        XCTAssertTrue(keywords.contains("cmd-palette-indexing"))
        XCTAssertTrue(keywords.contains("3000"))
        XCTAssertTrue(keywords.contains(":9222"))
    }

    func testFuzzyMatcherMatchesDirectoryBranchAndPortMetadata() {
        let metadata = CommandPaletteSwitcherSearchMetadata(
            directories: ["/tmp/cmuxterm/worktrees/issue-123-switcher-search"],
            branches: ["fix/switcher-metadata"],
            ports: [4317]
        )

        let candidates = CommandPaletteSwitcherSearchIndexer.keywords(
            baseKeywords: ["workspace"],
            metadata: metadata
        )

        XCTAssertNotNil(CommandPaletteFuzzyMatcher.score(query: "switcher-search", candidates: candidates))
        XCTAssertNotNil(CommandPaletteFuzzyMatcher.score(query: "switcher-metadata", candidates: candidates))
        XCTAssertNotNil(CommandPaletteFuzzyMatcher.score(query: "4317", candidates: candidates))
    }

    func testWorkspaceDetailOmitsSplitDirectoryAndBranchTokens() {
        let metadata = CommandPaletteSwitcherSearchMetadata(
            directories: ["/Users/example/dev/cmuxterm-hq/worktrees/feat-cmd-palette"],
            branches: ["feature/cmd-palette-indexing"],
            ports: [3000]
        )

        let keywords = CommandPaletteSwitcherSearchIndexer.keywords(
            baseKeywords: ["workspace"],
            metadata: metadata,
            detail: .workspace
        )

        XCTAssertTrue(keywords.contains("/Users/example/dev/cmuxterm-hq/worktrees/feat-cmd-palette"))
        XCTAssertTrue(keywords.contains("feature/cmd-palette-indexing"))
        XCTAssertTrue(keywords.contains("3000"))
        XCTAssertFalse(keywords.contains("feat-cmd-palette"))
        XCTAssertFalse(keywords.contains("cmd-palette-indexing"))
    }

    func testSurfaceDetailOutranksWorkspaceDetailForPathToken() throws {
        let metadata = CommandPaletteSwitcherSearchMetadata(
            directories: ["/tmp/worktrees/cmux"],
            branches: ["feature/cmd-palette"],
            ports: []
        )

        let workspaceKeywords = CommandPaletteSwitcherSearchIndexer.keywords(
            baseKeywords: ["workspace"],
            metadata: metadata,
            detail: .workspace
        )
        let surfaceKeywords = CommandPaletteSwitcherSearchIndexer.keywords(
            baseKeywords: ["surface"],
            metadata: metadata,
            detail: .surface
        )

        let workspaceScore = try XCTUnwrap(
            CommandPaletteFuzzyMatcher.score(query: "cmux", candidates: workspaceKeywords)
        )
        let surfaceScore = try XCTUnwrap(
            CommandPaletteFuzzyMatcher.score(query: "cmux", candidates: surfaceKeywords)
        )

        XCTAssertGreaterThan(
            surfaceScore,
            workspaceScore,
            "Surface rows should rank ahead of workspace rows for directory-token matches."
        )
    }
}

