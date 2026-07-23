// Behavior tests for the Find-sidebar re-ranker.

import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class FileSearchRankingTests: XCTestCase {
    func testStemEqualBeatsContains() {
        let results = [
            hit("docs/gameplay.md", line: 12),
            hit("src/Game.ts", line: 7),
        ]
        let ranked = FileSearchRanking.apply(to: results, query: "game")
        XCTAssertEqual(ranked.map(\.relativePath), ["src/Game.ts", "docs/gameplay.md"])
    }

    func testContainsBeatsBodyOnly() {
        let results = [
            hit("README.md", line: 3),
            hit("src/gamepiece.tsx", line: 42),
        ]
        let ranked = FileSearchRanking.apply(to: results, query: "game")
        XCTAssertEqual(ranked.map(\.relativePath), ["src/gamepiece.tsx", "README.md"])
    }

    func testHitsClusterPerFileAndSortByLine() {
        let results = [
            hit("a/Game.ts", line: 5),
            hit("a/README.md", line: 2),
            hit("a/Game.ts", line: 1),
            hit("a/README.md", line: 9),
            hit("a/Game.ts", line: 3),
        ]
        let ranked = FileSearchRanking.apply(to: results, query: "game")
        XCTAssertEqual(
            ranked.map { "\($0.relativePath):\($0.lineNumber)" },
            ["a/Game.ts:1", "a/Game.ts:3", "a/Game.ts:5", "a/README.md:2", "a/README.md:9"]
        )
    }

    func testAlphaSortWithinTierIsCaseInsensitive() {
        // `Dab.md` vs `cab.md` distinguishes case-insensitive ordering (c < d)
        // from raw ASCII byte order (D=68 < c=99). The other paths add a wider
        // alphabetic spread so a regression to ASCII order fails loudly.
        let results = [
            hit("src/zoo.ts", line: 1),
            hit("src/aardvark.md", line: 1),
            hit("src/Bear.swift", line: 1),
            hit("src/Dab.md", line: 1),
            hit("src/cab.md", line: 1),
        ]
        let ranked = FileSearchRanking.apply(to: results, query: "missing")
        XCTAssertEqual(
            ranked.map(\.relativePath),
            ["src/aardvark.md", "src/Bear.swift", "src/cab.md", "src/Dab.md", "src/zoo.ts"]
        )
    }

    func testEmptyQueryReturnsInputUnchanged() {
        let results = [hit("a.ts", line: 1), hit("b.ts", line: 1)]
        XCTAssertEqual(FileSearchRanking.apply(to: results, query: ""), results)
    }

    func testSingleResultShortCircuits() {
        let results = [hit("a.ts", line: 1)]
        XCTAssertEqual(FileSearchRanking.apply(to: results, query: "anything"), results)
    }

    func testCaseInsensitiveBasenameMatch() {
        let results = [
            hit("UPPER/HIT.TS", line: 1),
            hit("body/note.md", line: 1),
        ]
        let ranked = FileSearchRanking.apply(to: results, query: "hit")
        XCTAssertEqual(ranked.first?.relativePath, "UPPER/HIT.TS")
    }

    /// Regression: ranker must keep hits sorted by line number when rg
    /// happens to emit them out of order (e.g. multiline matches, reordering
    /// inside parallelism). Earlier optimization paths skipped the per-file
    /// sort entirely as a fast-path; this asserts the sort still runs when
    /// arrival order isn't monotonic.
    func testHitsResortedWhenNotMonotonic() {
        let results = [
            hit("a/Game.ts", line: 9),
            hit("a/Game.ts", line: 2),
            hit("a/Game.ts", line: 5),
        ]
        let ranked = FileSearchRanking.apply(to: results, query: "game")
        XCTAssertEqual(ranked.map(\.lineNumber), [2, 5, 9])
    }

    func testHitsAlreadyMonotonicStayInArrivalOrder() {
        let results = [
            hit("a/Game.ts", line: 1),
            hit("a/Game.ts", line: 2),
            hit("a/Game.ts", line: 3),
        ]
        let ranked = FileSearchRanking.apply(to: results, query: "game")
        XCTAssertEqual(ranked.map(\.lineNumber), [1, 2, 3])
    }

    /// Perf guardrail, a page of ~500 streamed results across ~50 files must
    /// rank in well under a frame. `FileSearchController.appendNewlyBufferedToDisplay`
    /// calls into this on every pipeline emit during streaming, so a
    /// regression that reintroduced O(n²) work or chained sort allocations
    /// would surface here.
    func testRankPageSizedInputIsCheap() {
        var results: [FileSearchResult] = []
        results.reserveCapacity(500)
        for fileIndex in 0..<50 {
            let basename = (fileIndex % 7 == 0) ? "Game.ts" : "module\(fileIndex).ts"
            for line in 1...10 {
                results.append(hit("src/dir\(fileIndex)/\(basename)", line: line))
            }
        }
        measure {
            for _ in 0..<200 {
                _ = FileSearchRanking.apply(to: results, query: "game")
            }
        }
    }

    private func hit(_ relativePath: String, line: Int) -> FileSearchResult {
        FileSearchResult(
            path: "/abs/" + relativePath,
            relativePath: relativePath,
            lineNumber: line,
            columnNumber: 1,
            preview: "preview"
        )
    }
}
