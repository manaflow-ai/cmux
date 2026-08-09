import CmuxTerminalCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Terminal command-click arbitrator")
struct TerminalCommandClickArbitratorTests {
    private static let candidate = TerminalWrappedPathResolution(
        path: "/Users/dev/project/TMLlaboratory",
        nativeMatchKeys: [
            "/Users/dev/project/TMLlaborator" + "y",
            "/Users/dev/project/TMLlaborator",
            "y",
        ]
    )

    private static let otherCandidate = TerminalWrappedPathResolution(
        path: "/Users/dev/project/other",
        nativeMatchKeys: ["/Users/dev/project/other-token"]
    )

    // MARK: openURLCallbackResult

    @Test("An explicit scheme always passes through, even with a prepared candidate")
    func explicitSchemePassesThroughOverPreparedCandidate() {
        let result = TerminalCommandClickArbitrator.openURLCallbackResult(
            currentState: .prepared(Self.candidate),
            hasExplicitScheme: true,
            matchKey: Self.candidate.nativeMatchKeys[0]
        )
        #expect(result.nextState == .nativePassthrough)
        #expect(result.shouldClaim == false)
    }

    @Test("file: scheme passes through like any other explicit scheme")
    func fileSchemePassesThrough() {
        let result = TerminalCommandClickArbitrator.openURLCallbackResult(
            currentState: nil,
            hasExplicitScheme: true,
            matchKey: "file:///Users/dev/project/TMLlaboratory"
        )
        #expect(result.nextState == .nativePassthrough)
        #expect(result.shouldClaim == false)
    }

    // Any of the finite `nativeMatchKeys` claims — not just the first
    // (full-candidate) entry. Ghostty's own hard-wrap link continuation can
    // report either the whole joined match or just one row's independent
    // fragment for the same click, and both are legitimate native shapes
    // for the winning direction.
    @Test("An exact match against any of a prepared candidate's finite keys claims the URL", arguments: [0, 1, 2])
    func exactMatchAgainstAnyPreparedKeyClaims(keyIndex: Int) {
        let result = TerminalCommandClickArbitrator.openURLCallbackResult(
            currentState: .prepared(Self.candidate),
            hasExplicitScheme: false,
            matchKey: Self.candidate.nativeMatchKeys[keyIndex]
        )
        #expect(result.nextState == .overridePending(Self.candidate))
        #expect(result.shouldClaim == true)
    }

    @Test("A mismatched key against a prepared candidate passes through")
    func mismatchedKeyPassesThrough() {
        let result = TerminalCommandClickArbitrator.openURLCallbackResult(
            currentState: .prepared(Self.candidate),
            hasExplicitScheme: false,
            matchKey: Self.otherCandidate.nativeMatchKeys[0]
        )
        #expect(result.nextState == .nativePassthrough)
        #expect(result.shouldClaim == false)
    }

    // A fourth, unrelated target and any partial (substring/suffix) variant
    // of a real key must never claim — only an exact match against one of
    // the finite keys does.
    @Test(
        "Unknown or partial targets never claim",
        arguments: [
            "/Users/dev/project/unrelated-fourth-target",
            // A genuine suffix of key[0] that isn't itself equal to any key.
            String("/Users/dev/project/TMLlaboratory".dropFirst(5)),
        ]
    )
    func unknownOrPartialTargetsNeverClaim(matchKey: String) {
        #expect(!Self.candidate.nativeMatchKeys.contains(matchKey))
        let result = TerminalCommandClickArbitrator.openURLCallbackResult(
            currentState: .prepared(Self.candidate),
            hasExplicitScheme: false,
            matchKey: matchKey
        )
        #expect(result.nextState == .nativePassthrough)
        #expect(result.shouldClaim == false)
    }

    @Test("No prepared state and no scheme still passes through (substring matching is never attempted)")
    func noPreparedStatePassesThrough() {
        let result = TerminalCommandClickArbitrator.openURLCallbackResult(
            currentState: nil,
            hasExplicitScheme: false,
            matchKey: "/Users/dev/project/TMLlaboratory"
        )
        #expect(result.nextState == .nativePassthrough)
        #expect(result.shouldClaim == false)
    }

    @Test("nativePassthrough state never re-claims a later callback")
    func nativePassthroughStateDoesNotClaim() {
        let result = TerminalCommandClickArbitrator.openURLCallbackResult(
            currentState: .nativePassthrough,
            hasExplicitScheme: false,
            matchKey: Self.candidate.nativeMatchKeys[0]
        )
        #expect(result.nextState == .nativePassthrough)
        #expect(result.shouldClaim == false)
    }

    // MARK: releaseAction

    @Test("nil final state defers to the existing word-under-cursor logic")
    func nilFinalStateDefers() {
        #expect(
            TerminalCommandClickArbitrator.releaseAction(finalState: nil, ghosttyConsumed: false) == .none
        )
        #expect(
            TerminalCommandClickArbitrator.releaseAction(finalState: nil, ghosttyConsumed: true) == .none
        )
    }

    @Test("nativePassthrough final state never opens the wrapped candidate")
    func nativePassthroughFinalStateOpensNothing() {
        #expect(
            TerminalCommandClickArbitrator.releaseAction(finalState: .nativePassthrough, ghosttyConsumed: false) == .none
        )
        #expect(
            TerminalCommandClickArbitrator.releaseAction(finalState: .nativePassthrough, ghosttyConsumed: true) == .none
        )
    }

    @Test("overridePending opens the candidate regardless of ghosttyConsumed")
    func overridePendingAlwaysOpens() {
        #expect(
            TerminalCommandClickArbitrator.releaseAction(
                finalState: .overridePending(Self.candidate),
                ghosttyConsumed: false
            ) == .openWrappedCandidate(Self.candidate)
        )
        #expect(
            TerminalCommandClickArbitrator.releaseAction(
                finalState: .overridePending(Self.candidate),
                ghosttyConsumed: true
            ) == .openWrappedCandidate(Self.candidate)
        )
    }

    @Test("prepared opens the candidate only when Ghostty didn't consume the release")
    func preparedOpensOnlyWhenNotConsumed() {
        #expect(
            TerminalCommandClickArbitrator.releaseAction(
                finalState: .prepared(Self.candidate),
                ghosttyConsumed: false
            ) == .openWrappedCandidate(Self.candidate)
        )
        #expect(
            TerminalCommandClickArbitrator.releaseAction(
                finalState: .prepared(Self.candidate),
                ghosttyConsumed: true
            ) == .none
        )
    }

    @Test("prepared and overridePending open through the same action for the same candidate")
    func preparedAndOverridePendingAgreeOnPolicy() {
        // This is the regression this arbitrator exists to prevent: clicking
        // either wrapped row must open exactly once under the same policy,
        // whether or not Ghostty's own link detection fired for the other
        // row.
        let fromTopRowClick = TerminalCommandClickArbitrator.releaseAction(
            finalState: .prepared(Self.candidate),
            ghosttyConsumed: false
        )
        let fromBottomRowClickThatGhosttyPartiallyMatched = TerminalCommandClickArbitrator.releaseAction(
            finalState: .overridePending(Self.candidate),
            ghosttyConsumed: true
        )
        #expect(fromTopRowClick == fromBottomRowClickThatGhosttyPartiallyMatched)
    }

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
        #expect(candidate.cellSpans == .unavailableNonASCIIRow)
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
