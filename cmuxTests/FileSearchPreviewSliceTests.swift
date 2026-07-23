// Behavior tests for FileSearchPreviewSlicer.

import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class FileSearchPreviewSliceTests: XCTestCase {
    func testMatchAtStartLeavesPreviewIntact() {
        let result = FileSearchPreviewSlicer.slice(preview: "game engine init", query: "game")
        XCTAssertEqual(result.text, "game engine init")
        XCTAssertFalse(result.leadingEllipsis)
        XCTAssertEqual(result.matchRanges, [NSRange(location: 0, length: 4)])
    }

    func testMatchWithinBudgetLeavesPreviewIntact() {
        // Match at offset 7 (≤ explicit budget of 12)
        let result = FileSearchPreviewSlicer.slice(preview: "import game from 'engine'", query: "game", leadingBudget: 12)
        XCTAssertFalse(result.leadingEllipsis)
        XCTAssertEqual(result.text, "import game from 'engine'")
        XCTAssertEqual(result.matchRanges.first, NSRange(location: 7, length: 4))
    }

    func testMatchBeyondBudgetPrependsEllipsis() {
        let preview = "the quick brown fox jumps over the lazy dog and the game starts"
        let result = FileSearchPreviewSlicer.slice(preview: preview, query: "game", leadingBudget: 12)
        XCTAssertTrue(result.leadingEllipsis)
        XCTAssertTrue(result.text.hasPrefix("\u{2026}"))
        // 12 chars of context before match + ellipsis prefix → match starts at index 13.
        XCTAssertEqual(result.matchRanges.first, NSRange(location: 13, length: 4))
        XCTAssertTrue(result.text.contains("game starts"))
    }

    func testNoMatchReturnsPreviewUnchanged() {
        let result = FileSearchPreviewSlicer.slice(preview: "no match here", query: "missing")
        XCTAssertEqual(result.text, "no match here")
        XCTAssertFalse(result.leadingEllipsis)
        XCTAssertTrue(result.matchRanges.isEmpty)
    }

    func testEmptyQueryReturnsPreviewUnchanged() {
        let result = FileSearchPreviewSlicer.slice(preview: "anything", query: "")
        XCTAssertEqual(result.text, "anything")
        XCTAssertFalse(result.leadingEllipsis)
        XCTAssertTrue(result.matchRanges.isEmpty)
    }

    func testCaseInsensitiveMatch() {
        let result = FileSearchPreviewSlicer.slice(preview: "Game over", query: "game")
        XCTAssertEqual(result.matchRanges, [NSRange(location: 0, length: 4)])
    }

    func testMultipleMatchesHighlightedInOrder() {
        // After slicing (match at offset 0 keeps preview as-is) all three matches are present.
        let result = FileSearchPreviewSlicer.slice(preview: "game game game", query: "game")
        XCTAssertEqual(result.matchRanges, [
            NSRange(location: 0, length: 4),
            NSRange(location: 5, length: 4),
            NSRange(location: 10, length: 4),
        ])
    }

    func testMultipleMatchesAfterEllipsisAreRebased() {
        let preview = String(repeating: "x", count: 30) + " game and game"
        let result = FileSearchPreviewSlicer.slice(preview: preview, query: "game", leadingBudget: 12)
        XCTAssertTrue(result.leadingEllipsis)
        XCTAssertEqual(result.matchRanges.count, 2)
        XCTAssertEqual(result.matchRanges[0].location, 13)
        // Second match is 9 chars after the first ("game and ").
        XCTAssertEqual(result.matchRanges[1].location, 22)
    }

    func testQueryLongerThanPreviewReturnsUnchanged() {
        let result = FileSearchPreviewSlicer.slice(preview: "hi", query: "needle")
        XCTAssertEqual(result.text, "hi")
        XCTAssertTrue(result.matchRanges.isEmpty)
    }

    func testEmptyPreviewReturnsUnchanged() {
        let result = FileSearchPreviewSlicer.slice(preview: "", query: "game")
        XCTAssertEqual(result.text, "")
        XCTAssertTrue(result.matchRanges.isEmpty)
        XCTAssertFalse(result.leadingEllipsis)
    }

    /// Regression: an earlier implementation used `String.removeFirst()` /
    /// `removeLast()` in a loop, which is O(n) per call and O(n²) over a long
    /// whitespace run. Source-file previews of minified/blob lines with deep
    /// leading indentation could push this into a visible cliff during scroll.
    /// Verifies behaviour matches the original semantics: leading whitespace
    /// dropped after the ellipsis, trailing whitespace stripped, match
    /// rebased into the trimmed string.
    func testLongLeadingWhitespacePrefixIsTrimmedAfterEllipsis() {
        // 200 leading spaces + 'foo bar baz qux match' with trailing spaces.
        let leading = String(repeating: " ", count: 200)
        let preview = leading + "foo bar baz qux match" + String(repeating: " ", count: 50)
        let result = FileSearchPreviewSlicer.slice(preview: preview, query: "match", leadingBudget: 12)
        XCTAssertTrue(result.leadingEllipsis)
        XCTAssertTrue(result.text.hasPrefix("\u{2026}"))
        // Whitespace between ellipsis and visible text must be stripped.
        let afterEllipsis = String(result.text.dropFirst())
        XCTAssertFalse(afterEllipsis.first?.isWhitespace ?? true, "Whitespace after ellipsis was not trimmed")
        // Trailing whitespace must be stripped too.
        XCTAssertFalse(result.text.last?.isWhitespace ?? true, "Trailing whitespace was not trimmed")
        XCTAssertEqual(result.matchRanges.count, 1)
    }

    func testTrailingWhitespaceTrimmedWhenNoEllipsis() {
        let result = FileSearchPreviewSlicer.slice(preview: "match here    ", query: "match")
        XCTAssertFalse(result.leadingEllipsis)
        XCTAssertEqual(result.text, "match here")
    }

    func testUnicodeWhitespaceIsTrimmed() {
        // U+2003 EM SPACE, U+00A0 NO-BREAK SPACE, then a regular ASCII match.
        let leading = String(repeating: "\u{2003}", count: 50) + String(repeating: "\u{00A0}", count: 50)
        let preview = leading + "foo bar baz qux match"
        let result = FileSearchPreviewSlicer.slice(preview: preview, query: "match", leadingBudget: 12)
        XCTAssertTrue(result.leadingEllipsis)
        let afterEllipsis = String(result.text.dropFirst())
        XCTAssertFalse(afterEllipsis.first?.isWhitespace ?? true, "Unicode whitespace after ellipsis was not trimmed")
    }

    /// Perf guardrail, slicing a single visible hit cell must stay fast even
    /// with a worst-case long-line preview. The Find sidebar's
    /// `refreshVisibleHitCells()` walks every visible row on snapshot apply,
    /// so a regression that reintroduced quadratic trim would show up here as
    /// a 100×+ slowdown.
    func testLongLineSliceIsCheap() {
        let leading = String(repeating: " ", count: 200)
        let body = String(repeating: "foo bar baz ", count: 25)
        let trailing = String(repeating: " ", count: 100)
        let preview = leading + body + "needle" + trailing
        measure {
            for _ in 0..<2000 {
                _ = FileSearchPreviewSlicer.slice(preview: preview, query: "needle")
            }
        }
    }
}
