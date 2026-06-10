import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


final class CommandPaletteFuzzyMatcherTests: XCTestCase {
    func testExactMatchScoresHigherThanPrefixAndContains() {
        let exact = CommandPaletteFuzzyMatcher.score(query: "rename tab", candidate: "rename tab")
        let prefix = CommandPaletteFuzzyMatcher.score(query: "rename tab", candidate: "rename tab now")
        let contains = CommandPaletteFuzzyMatcher.score(query: "rename tab", candidate: "command rename tab flow")

        XCTAssertNotNil(exact)
        XCTAssertNotNil(prefix)
        XCTAssertNotNil(contains)
        XCTAssertGreaterThan(exact ?? 0, prefix ?? 0)
        XCTAssertGreaterThan(prefix ?? 0, contains ?? 0)
    }

    func testInitialismMatchReturnsScore() {
        let score = CommandPaletteFuzzyMatcher.score(query: "ocdi", candidate: "open current directory in ide")
        XCTAssertNotNil(score)
        XCTAssertGreaterThan(score ?? 0, 0)
    }

    func testLongTokenLooseSubsequenceDoesNotMatch() {
        let score = CommandPaletteFuzzyMatcher.score(query: "rename", candidate: "open current directory in ide")
        XCTAssertNil(score)
    }

    func testStitchedWordPrefixMatchesRetabForRenameTab() {
        let score = CommandPaletteFuzzyMatcher.score(query: "retab", candidate: "Rename Tab…")
        XCTAssertNotNil(score)
        XCTAssertGreaterThan(score ?? 0, 0)
    }

    func testRetabPrefersRenameTabOverDistantTabWord() {
        let renameTabScore = CommandPaletteFuzzyMatcher.score(query: "retab", candidate: "Rename Tab…")
        let reopenTabScore = CommandPaletteFuzzyMatcher.score(query: "retab", candidate: "Reopen Closed Browser Tab")

        XCTAssertNotNil(renameTabScore)
        XCTAssertNotNil(reopenTabScore)
        XCTAssertGreaterThan(renameTabScore ?? 0, reopenTabScore ?? 0)
    }

    func testRenameScoresHigherThanUnrelatedCommandWhenUnrelatedStillMatches() {
        let renameScore = CommandPaletteFuzzyMatcher.score(
            query: "rename",
            candidates: ["Rename Tab…", "Tab • Terminal 1", "rename", "tab", "title"]
        )
        let unrelatedScore = CommandPaletteFuzzyMatcher.score(
            query: "rename",
            candidates: [
                "Open Current Directory in IDE",
                "Terminal • Terminal 1",
                "terminal",
                "directory",
                "open",
                "ide",
                "code",
                "default app"
            ]
        )

        XCTAssertNotNil(renameScore)
        if let unrelatedScore {
            XCTAssertGreaterThan(renameScore ?? 0, unrelatedScore)
        }
    }

    func testTokenMatchingRequiresAllTokens() {
        let match = CommandPaletteFuzzyMatcher.score(
            query: "rename workspace",
            candidates: ["Rename Workspace", "Workspace settings"]
        )
        let miss = CommandPaletteFuzzyMatcher.score(
            query: "rename workspace",
            candidates: ["Rename Tab", "Tab settings"]
        )

        XCTAssertNotNil(match)
        XCTAssertNil(miss)
    }

    func testEmptyQueryReturnsZeroScore() {
        let score = CommandPaletteFuzzyMatcher.score(query: "   ", candidate: "anything")
        XCTAssertEqual(score, 0)
    }

    func testMatchCharacterIndicesForContainsMatch() {
        let indices = CommandPaletteFuzzyMatcher.matchCharacterIndices(
            query: "workspace",
            candidate: "New Workspace"
        )
        XCTAssertTrue(indices.contains(4))
        XCTAssertTrue(indices.contains(12))
        XCTAssertFalse(indices.contains(0))
    }

    func testMatchCharacterIndicesForSubsequenceMatch() {
        let indices = CommandPaletteFuzzyMatcher.matchCharacterIndices(
            query: "nws",
            candidate: "New Workspace"
        )
        XCTAssertTrue(indices.contains(0))
        XCTAssertTrue(indices.contains(2))
        XCTAssertTrue(indices.contains(8))
    }

    func testMatchCharacterIndicesForStitchedWordPrefixMatch() {
        let indices = CommandPaletteFuzzyMatcher.matchCharacterIndices(
            query: "retab",
            candidate: "Rename Tab…"
        )
        XCTAssertTrue(indices.contains(0))
        XCTAssertTrue(indices.contains(1))
        XCTAssertTrue(indices.contains(7))
        XCTAssertTrue(indices.contains(8))
        XCTAssertTrue(indices.contains(9))
    }

    func testMatchCharacterIndicesPreferStitchedWordsOverSingleEditPrefix() {
        let indices = CommandPaletteFuzzyMatcher.matchCharacterIndices(
            query: "wunr",
            candidate: "Mark Workspace as Unread"
        )

        XCTAssertTrue(indices.contains(5))
        XCTAssertTrue(indices.contains(18))
        XCTAssertTrue(indices.contains(19))
        XCTAssertTrue(indices.contains(20))
    }
}

