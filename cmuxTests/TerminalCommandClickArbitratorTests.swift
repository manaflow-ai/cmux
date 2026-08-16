import CmuxTerminalCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Terminal command-click composition")
struct TerminalCommandClickCompositionTests {
    // MARK: - review R2-B3/B4: production-shared click composition

    // review §R2-B3 — `GhosttyNSView.resolveCommandClickWrappedCandidate`
    // now takes a `TerminalPhysicalViewportSnapshot` + `TerminalGridCell`,
    // not a loose `columns: Int` — there is no longer a second place a
    // caller (production OR this test) could thread in a different
    // column count for seed construction vs. the shared resolve; both
    // read `snapshot.columns`. This test constructs the snapshot exactly
    // as `readPhysicalViewportSnapshot` would (one coherent `lines` +
    // `columns` pair) and shows: (a) the real grid width keeps a
    // fullness-rejected coincidental match closed, and (b) mutating
    // ONLY `snapshot.columns` — never a second, independent parameter —
    // is what would defeat the fullness guard, proving `columns` truly
    // is this composition's single source of truth.
    @Test("The shared click composition never falls back for a fullness-rejected, all-ASCII coincidental match")
    func sharedClickCompositionRejectsAFullnessRejectedCandidate() throws {
        let cwd = "/tmp"
        // `notes/report` (unlike a bare `short`) already contains `/`,
        // so the leading-piece-shape guard alone would happily pass this
        // — fullness is the ONLY guard standing between this and the
        // coincidental match, isolating exactly what a wrong `columns`
        // would defeat.
        let clickedRow = "notes/report"
        let nextRow = ".md"
        let coincidental = "/tmp/notes/report.md"
        let resolver = TerminalPathResolver(fileExists: { $0 == coincidental })
        let cell = GhosttyNSView.TerminalGridCell(row: 0, column: 0)

        // The real grid width (80) — `notes/report` is nowhere near the
        // strict right edge, so this must stay nil.
        let realSnapshot = GhosttyNSView.TerminalPhysicalViewportSnapshot(
            lines: [clickedRow, nextRow], columns: 80
        )
        #expect(
            GhosttyNSView.resolveCommandClickWrappedCandidate(
                resolver: resolver, snapshot: realSnapshot, cell: cell, cwd: cwd
            ) == nil
        )
        // `columns: 1` on the snapshot itself — simulating a stale/
        // placeholder grid read reaching this adapter. Both the seed's
        // own tokenization AND the shared resolve read this SAME field,
        // so this single mutation is what would defeat the fullness
        // guard and wrongly open the coincidental match end to end —
        // never two independently-drifting parameters.
        let staleColumnsSnapshot = GhosttyNSView.TerminalPhysicalViewportSnapshot(
            lines: [clickedRow, nextRow], columns: 1
        )
        #expect(
            GhosttyNSView.resolveCommandClickWrappedCandidate(
                resolver: resolver, snapshot: staleColumnsSnapshot, cell: cell, cwd: cwd
            )?.path == coincidental
        )
    }

    // review §R2-B3 — a strict-full, genuinely-wrapped 2-row candidate
    // resolves through this exact composition (not merely "some wrong
    // columns fails to resolve", the mirror-image required assertion).
    @Test("The shared click composition resolves a strict-full genuinely-wrapped candidate")
    func sharedClickCompositionResolvesAStrictFullCandidate() throws {
        let cwd = "/tmp"
        let previousRow = "/Users/dev/project/"
        let clickedRow = "notes/2026-report.md"
        let existingFile = previousRow + clickedRow
        let resolver = TerminalPathResolver(fileExists: { $0 == existingFile })
        let snapshot = GhosttyNSView.TerminalPhysicalViewportSnapshot(
            lines: [previousRow, clickedRow], columns: previousRow.count
        )
        let cell = GhosttyNSView.TerminalGridCell(row: 1, column: 0)

        let candidate = try #require(GhosttyNSView.resolveCommandClickWrappedCandidate(
            resolver: resolver, snapshot: snapshot, cell: cell, cwd: cwd
        ))
        #expect(candidate.path == existingFile)
    }

    @Test("The shared click composition resolves a bullet-prefixed leading row")
    func sharedClickCompositionResolvesBulletPrefixedLeadingRow() throws {
        let cwd = "/Users/yosuke/workspace/github.com/TMLlaboratory/s-code"
        let clickedRow = "● research/docs/notes/2026-07-31_key_cost_volume_price"
        let nextRow = "_and_probability_floor.md"
        let expectedPath = cwd + "/research/docs/notes/2026-07-31_key_cost_volume_price_and_probability_floor.md"
        let resolver = TerminalPathResolver(fileExists: { path in path == expectedPath })
        let snapshot = GhosttyNSView.TerminalPhysicalViewportSnapshot(
            lines: [clickedRow, nextRow],
            columns: 56
        )
        let cell = GhosttyNSView.TerminalGridCell(row: 0, column: 19)

        let candidate = try #require(
            GhosttyNSView.resolveCommandClickWrappedCandidate(
                resolver: resolver,
                snapshot: snapshot,
                cell: cell,
                cwd: cwd
            )
        )
        #expect(candidate.path == expectedPath)
        #expect(candidate.cellSpans == .available([
            TerminalWrappedPathCellSpan(
                rowOffsetFromClicked: 0,
                startColumn: 2,
                endColumn: clickedRow.count
            ),
            TerminalWrappedPathCellSpan(
                rowOffsetFromClicked: 1,
                startColumn: 0,
                endColumn: nextRow.count
            ),
        ]))
    }

    // review §R2-B3/B4 closing requirement — connects this composition's
    // OUTPUT to the existing arbitrator tests above: a candidate this
    // function resolves, wrapped in `.prepared` exactly as
    // `prepareCommandClickContext` does, opens exactly once through the
    // SAME `releaseAction` this whole suite already exercises. Read
    // ordering (`prepareCommandClickContext` runs before
    // `ghostty_surface_mouse_button(RELEASE)`, per
    // `performCommandClickRelease`'s own doc) is a source-level property
    // of that unchanged method, not something this pure-value test can
    // execute directly.
    @Test("A candidate this composition resolves opens exactly once through the existing releaseAction")
    func sharedClickCompositionConnectsToReleaseActionOpenExactlyOnce() throws {
        let cwd = "/tmp"
        let previousRow = "/Users/dev/project/"
        let clickedRow = "notes/2026-report.md"
        let existingFile = previousRow + clickedRow
        let resolver = TerminalPathResolver(fileExists: { $0 == existingFile })
        let snapshot = GhosttyNSView.TerminalPhysicalViewportSnapshot(
            lines: [previousRow, clickedRow], columns: previousRow.count
        )
        let cell = GhosttyNSView.TerminalGridCell(row: 1, column: 0)

        let candidate = try #require(GhosttyNSView.resolveCommandClickWrappedCandidate(
            resolver: resolver, snapshot: snapshot, cell: cell, cwd: cwd
        ))
        #expect(candidate.path == existingFile)
        #expect(
            TerminalCommandClickArbitrator.releaseAction(
                finalState: .prepared(candidate),
                ghosttyConsumed: false
            ) == .openWrappedCandidate(candidate)
        )
    }
}
