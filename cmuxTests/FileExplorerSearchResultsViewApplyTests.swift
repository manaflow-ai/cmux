import AppKit
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class FileExplorerSearchResultsViewApplyTests: XCTestCase {
    // MARK: - Identity short-circuit (duplicate-emit coalescing)

    /// The controller pipeline emits a settled `.matches` update on the
    /// first-page boundary and again from `finish()` when `rg` exits; in the
    /// common fast-rg case both emissions carry the same underlying results
    /// buffer. The view must skip the second apply entirely, otherwise the
    /// grouper + outline diff + visible-cell refresh run twice per query.
    func testDuplicateEmitIsNoOp() {
        let view = FileExplorerSearchResultsView()
        let sharedResults: [FileSearchResult] = makeResults(fileCount: 5, hitsPerFile: 3)
        let snapshot = settledSnapshot(query: "foo", results: sharedResults)

        view.apply(snapshot)
        XCTAssertEqual(view.debugAppliedWorkCount, 1)

        // Same buffer, same scalar fields → must short-circuit.
        view.apply(snapshot)
        XCTAssertEqual(view.debugAppliedWorkCount, 1, "Duplicate snapshot must skip apply")

        // And again, to confirm the cache stays warm.
        view.apply(snapshot)
        XCTAssertEqual(view.debugAppliedWorkCount, 1)
    }

    /// A new query against the SAME results buffer must NOT short-circuit:
    /// match highlights depend on `query`, so the visible-cell refresh has to
    /// run. (This is unusual in practice since `setFindQuery` precedes a
    /// search, but we still want the guard correct.)
    func testQueryChangeForcesApplyEvenIfResultsBufferUnchanged() {
        let view = FileExplorerSearchResultsView()
        let sharedResults: [FileSearchResult] = makeResults(fileCount: 5, hitsPerFile: 3)

        view.apply(settledSnapshot(query: "foo", results: sharedResults))
        XCTAssertEqual(view.debugAppliedWorkCount, 1)

        view.apply(settledSnapshot(query: "foob", results: sharedResults))
        XCTAssertEqual(view.debugAppliedWorkCount, 2, "Query change must re-run apply")
    }

    /// Changing `hasMore` while keeping the results buffer reflects a state
    /// transition the view exposes via the load-more gate; it must invalidate
    /// the cache.
    func testHasMoreChangeForcesApply() {
        let view = FileExplorerSearchResultsView()
        let sharedResults: [FileSearchResult] = makeResults(fileCount: 5, hitsPerFile: 3)

        view.apply(settledSnapshot(query: "foo", results: sharedResults, hasMore: true))
        XCTAssertEqual(view.debugAppliedWorkCount, 1)

        view.apply(settledSnapshot(query: "foo", results: sharedResults, hasMore: false))
        XCTAssertEqual(view.debugAppliedWorkCount, 2)
    }

    /// A status transition can ride the same results buffer. The status field
    /// participates in the short-circuit guard, so the second apply must run.
    func testStatusChangeForcesApply() {
        let view = FileExplorerSearchResultsView()
        let sharedResults: [FileSearchResult] = makeResults(fileCount: 5, hitsPerFile: 3)

        view.apply(settledSnapshot(query: "foo", results: sharedResults, status: .matches))
        XCTAssertEqual(view.debugAppliedWorkCount, 1)

        view.apply(settledSnapshot(query: "foo", results: sharedResults, status: .failed("boom")))
        XCTAssertEqual(view.debugAppliedWorkCount, 2, "Status change must re-run apply")
    }

    func testTotalMatchCountChangeForcesApply() {
        let view = FileExplorerSearchResultsView()
        let sharedResults = makeResults(fileCount: 5, hitsPerFile: 3)
        view.apply(settledSnapshot(query: "foo", results: sharedResults, totalMatchCount: 15))
        view.apply(settledSnapshot(query: "foo", results: sharedResults, totalMatchCount: 20))
        XCTAssertEqual(view.debugAppliedWorkCount, 2)
    }

    func testIsTruncatedChangeForcesApply() {
        let view = FileExplorerSearchResultsView()
        let sharedResults = makeResults(fileCount: 5, hitsPerFile: 3)
        view.apply(settledSnapshot(query: "foo", results: sharedResults, isTruncated: false))
        view.apply(settledSnapshot(query: "foo", results: sharedResults, isTruncated: true))
        XCTAssertEqual(view.debugAppliedWorkCount, 2)
    }

    /// Two snapshots built from independently-allocated arrays with byte-equal
    /// contents will NOT share a buffer pointer. We accept the false-negative
    /// (run the apply) because checking real content equality is O(n) and
    /// would defeat the optimization in the actual duplicate-emit case (which
    /// always shares a buffer thanks to COW).
    func testIndependentResultsAreNotShortCircuited() {
        let view = FileExplorerSearchResultsView()
        let first = makeResults(fileCount: 5, hitsPerFile: 3)
        let second = makeResults(fileCount: 5, hitsPerFile: 3) // distinct allocation, equal contents

        view.apply(settledSnapshot(query: "foo", results: first))
        view.apply(settledSnapshot(query: "foo", results: second))
        XCTAssertEqual(view.debugAppliedWorkCount, 2)
    }

    // MARK: - Group / row count behavior

    /// Apply with N files × M hits → rowCount = N groups + (N × M) hits
    /// (groups auto-expand on insert).
    func testApplyPopulatesRowsForExpandedGroups() {
        let view = FileExplorerSearchResultsView()
        view.apply(settledSnapshot(
            query: "foo",
            results: makeResults(fileCount: 4, hitsPerFile: 3)
        ))
        // 4 group headers + 4*3 hits = 16 rows when all groups expanded.
        XCTAssertEqual(view.rowCount, 16)
    }

    /// Empty results → empty rows. Earlier regressions left stale rows after
    /// the user cleared the query.
    func testEmptyResultsClearsRows() {
        let view = FileExplorerSearchResultsView()
        view.apply(settledSnapshot(
            query: "foo",
            results: makeResults(fileCount: 4, hitsPerFile: 3)
        ))
        XCTAssertGreaterThan(view.rowCount, 0)

        view.apply(settledSnapshot(query: "", results: [], status: .idle))
        XCTAssertEqual(view.rowCount, 0)
    }

    /// Pin the empty-state label visibility contract: `.noMatches` shows it,
    /// every other terminal status hides it. Otherwise a future change that
    /// moves the label update past the short-circuit guard would silently
    /// leave the wrong text onscreen.
    func testEmptyStateLabelTracksStatus() {
        let view = FileExplorerSearchResultsView()

        view.apply(settledSnapshot(query: "foo", results: [], status: .noMatches))
        XCTAssertFalse(view.debugEmptyStateLabelHidden, "noMatches must show empty-state label")

        view.apply(settledSnapshot(
            query: "foo",
            results: makeResults(fileCount: 2, hitsPerFile: 1),
            status: .matches
        ))
        XCTAssertTrue(view.debugEmptyStateLabelHidden, "matches with rows must hide empty-state label")

        view.apply(settledSnapshot(query: "", results: [], status: .idle))
        XCTAssertTrue(view.debugEmptyStateLabelHidden, "idle must hide empty-state label")
    }

    /// Prefix narrowing (typing one more character) is the common keystroke
    /// path: most groups stay, some drop, some get fewer hits. The incremental
    /// update must converge to the expected row count without falling back to
    /// reloadData (we can't observe the fallback directly here, but row count
    /// being correct is the behavioral contract).
    func testPrefixNarrowingProducesExpectedRows() {
        let view = FileExplorerSearchResultsView()
        let wide = makeResults(fileCount: 8, hitsPerFile: 4) // 8 groups, 32 hits, 40 rows
        let narrow = makeResults(fileCount: 3, hitsPerFile: 4) // 3 groups, 12 hits, 15 rows

        view.apply(settledSnapshot(query: "f", results: wide))
        XCTAssertEqual(view.rowCount, 8 + 8 * 4)

        view.apply(settledSnapshot(query: "fo", results: narrow))
        XCTAssertEqual(view.rowCount, 3 + 3 * 4)
    }

    func testPageAppendExtendsExistingGroupAndAddsNewGroup() {
        let view = FileExplorerSearchResultsView()
        let firstPage = makeResults(fileCount: 2, hitsPerFile: 2)
        var nextPage = firstPage
        nextPage.append(FileSearchResult(
            path: "/abs/src/dir1/file1.ts",
            relativePath: "src/dir1/file1.ts",
            lineNumber: 3,
            columnNumber: 1,
            preview: "appended hit in file1"
        ))
        nextPage.append(FileSearchResult(
            path: "/abs/src/dir2/file2.ts",
            relativePath: "src/dir2/file2.ts",
            lineNumber: 1,
            columnNumber: 1,
            preview: "first hit in file2"
        ))

        view.apply(settledSnapshot(query: "foo", results: firstPage, hasMore: true))
        view.apply(settledSnapshot(query: "foo", results: nextPage))

        XCTAssertEqual(view.rowCount, 9)
    }

    func testPreviewPayloadChangeRefreshesRetainedVisibleHitCell() throws {
        let view = FileExplorerSearchResultsView()
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        let original = FileSearchResult(
            path: "/abs/src/example.swift",
            relativePath: "src/example.swift",
            lineNumber: 1,
            columnNumber: 5,
            preview: "let needle = old"
        )
        view.apply(settledSnapshot(query: "needle", results: [original]))
        view.layoutSubtreeIfNeeded()

        let outline = try XCTUnwrap(view.documentView as? NSOutlineView)
        let retainedItem = try XCTUnwrap(outline.item(atRow: 1) as? SearchResultHitItem)
        let cell = try XCTUnwrap(
            outline.view(atColumn: 0, row: 1, makeIfNecessary: true) as? SearchResultHitCellView
        )
        let previewLabel = try XCTUnwrap(cell.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertTrue(previewLabel.stringValue.contains("old"))

        let updated = FileSearchResult(
            path: original.path,
            relativePath: original.relativePath,
            lineNumber: original.lineNumber,
            columnNumber: original.columnNumber,
            preview: "let needle = new"
        )
        view.apply(settledSnapshot(query: "needle", results: [updated]))

        XCTAssertTrue(outline.item(atRow: 1) as? SearchResultHitItem === retainedItem)
        XCTAssertEqual(retainedItem.hit.preview, updated.preview)
        XCTAssertTrue(previewLabel.stringValue.contains("new"))
    }

    // MARK: - Perf guardrails

    /// Simulates rapid typing: 20 queries (e.g. progressive prefix narrowing
    /// then expansion) applied in sequence. This is the path FileExplorerView
    /// drives on every settled snapshot during burst typing. A regression
    /// that reintroduced per-snapshot reloadData() or O(n²) diff work would
    /// surface as a multi-x slowdown here.
    ///
    /// We build a fresh `FileExplorerSearchResultsView` inside the `measure {}` block
    /// so every iteration is a cold-start burst, otherwise XCTest's 10
    /// iterations would average iteration-1 (all-inserts) against iterations
    /// 2–10 (incremental-diff over a populated outline), and the baseline
    /// would track a hybrid no human ever observes.
    func testRapidTypingSequencePerf() {
        let cohorts: [[FileSearchResult]] = (0..<20).map { i in
            // Vary file count between 5–25 across the sequence to exercise
            // the insert/remove batched-update path.
            let fileCount = 5 + (i % 10) * 2
            return makeResults(fileCount: fileCount, hitsPerFile: 4)
        }
        measure {
            let view = FileExplorerSearchResultsView()
            for (i, cohort) in cohorts.enumerated() {
                view.apply(settledSnapshot(query: "q\(i)", results: cohort))
            }
        }
    }

    /// Duplicate-emit burst: same snapshot replayed 200 times. The
    /// short-circuit must make this essentially free. No `measure {}` here,
    /// the short-circuited path bottoms out below XCTest's noise floor, so
    /// the perf baseline can't reliably catch a regression. The behavioral
    /// assert below IS the regression guard: if `shouldShortCircuitApply` is
    /// weakened or removed, `debugAppliedWorkCount` will climb past 1.
    func testDuplicateEmitBurstIsFree() {
        let view = FileExplorerSearchResultsView()
        let snapshot = settledSnapshot(
            query: "foo",
            results: makeResults(fileCount: 10, hitsPerFile: 5)
        )
        view.apply(snapshot)
        let workBefore = view.debugAppliedWorkCount
        for _ in 0..<200 {
            view.apply(snapshot)
        }
        XCTAssertEqual(view.debugAppliedWorkCount, workBefore, "All duplicates must short-circuit")
    }

    // MARK: - Test fixtures

    /// Build a deterministic [FileSearchResult] of the requested size. The
    /// returned array is freshly allocated; calling this twice yields arrays
    /// with byte-equal contents but distinct buffers (used to test the
    /// false-negative branch of the identity short-circuit).
    private func makeResults(fileCount: Int, hitsPerFile: Int) -> [FileSearchResult] {
        var results: [FileSearchResult] = []
        results.reserveCapacity(fileCount * hitsPerFile)
        for fileIndex in 0..<fileCount {
            let relativePath = "src/dir\(fileIndex % 4)/file\(fileIndex).ts"
            for hit in 0..<hitsPerFile {
                results.append(FileSearchResult(
                    path: "/abs/" + relativePath,
                    relativePath: relativePath,
                    lineNumber: hit + 1,
                    columnNumber: 1,
                    preview: "preview for hit \(hit) in file\(fileIndex)"
                ))
            }
        }
        return results
    }

    private func settledSnapshot(
        query: String,
        results: [FileSearchResult],
        status: FileSearchSnapshot.Status = .matches,
        hasMore: Bool = false,
        totalMatchCount: Int? = nil,
        isTruncated: Bool = false
    ) -> FileSearchSnapshot {
        FileSearchSnapshot(
            query: query,
            results: results,
            status: status,
            isSearching: false,
            hasMore: hasMore,
            totalMatchCount: totalMatchCount ?? results.count,
            isTruncated: isTruncated
        )
    }
}
