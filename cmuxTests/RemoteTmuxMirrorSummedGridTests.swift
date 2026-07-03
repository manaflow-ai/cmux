import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the remote-tmux mirror's window-sizing math.
///
/// The stranded-"%" failure mode: sizing the remote tmux client from the outer
/// SwiftUI content area divided by cell size counts each local split divider as
/// a grid column, so tmux gets a window ~1 column WIDER per split than the
/// ghostty surfaces actually render. zsh's PROMPT_SP "%" filler is then painted
/// past the surface's last column, wraps, and strands a lone "%" (and misplaces
/// the cursor) in split panes.
///
/// Fix: size tmux by folding the ACTUAL rendered leaf grids through the layout
/// tree with tmux's own 1-cell pane separators — a horizontal split's width is
/// the sum of child widths plus one separator column between each (height = max
/// child height); a vertical split is the transpose. ``summedGridCells`` reports
/// the window size whose tmux split-back yields per-pane widths that equal each
/// surface's rendered width, so live `%output` paints faithfully.
///
/// These tests pin the separator/transpose math (the "we do Y now" guard):
/// removing the `+ (count - 1)` separator term makes every split case go red.
@MainActor
@Suite struct RemoteTmuxMirrorSummedGridTests {
    /// Builds a leaf-grid lookup from a `[paneId: (cols, rows)]` map; missing
    /// panes return `nil` (mimicking a surface that isn't live yet).
    private func leaves(_ map: [Int: (cols: Int, rows: Int)]) -> (Int) -> (cols: Int, rows: Int)? {
        { map[$0] }
    }

    private func node(_ content: RemoteTmuxLayoutContent) -> RemoteTmuxLayoutNode {
        // Geometry fields are unused by summedGridCells (it reads leaf grids, not
        // tmux's reported node width/height) — set them to obviously-distinct
        // values so a regression that accidentally reads node.width/height fails.
        RemoteTmuxLayoutNode(width: -1, height: -1, x: -1, y: -1, content: content)
    }

    @Test func singleLeafPassesThroughItsGrid() {
        let result = RemoteTmuxWindowMirror.summedGridCells(
            of: node(.pane(1)),
            leafGrid: leaves([1: (80, 24)])
        )
        #expect(result?.cols == 80)
        #expect(result?.rows == 24)
    }

    @Test func horizontalSplitSumsWidthsPlusOneSeparatorAndTakesMaxHeight() {
        // Two panes side by side, 40 | 39 cells → window is 40 + 39 + 1 = 80 wide
        // (NOT 79): the +1 is tmux's divider column. Heights differ → max.
        let result = RemoteTmuxWindowMirror.summedGridCells(
            of: node(.horizontal([node(.pane(1)), node(.pane(2))])),
            leafGrid: leaves([1: (40, 24), 2: (39, 23)])
        )
        #expect(result?.cols == 80)
        #expect(result?.rows == 24)
    }

    @Test func verticalSplitSumsHeightsPlusOneSeparatorAndTakesMaxWidth() {
        // Transpose of the horizontal case: 12 / 11 rows stacked → 12 + 11 + 1 = 24.
        let result = RemoteTmuxWindowMirror.summedGridCells(
            of: node(.vertical([node(.pane(1)), node(.pane(2))])),
            leafGrid: leaves([1: (80, 12), 2: (79, 11)])
        )
        #expect(result?.cols == 80)
        #expect(result?.rows == 24)
    }

    @Test func threeWayHorizontalSplitAddsTwoSeparators() {
        // Matches a double right-split (3 panes): 26 * 3 + 2 separators = 80.
        let result = RemoteTmuxWindowMirror.summedGridCells(
            of: node(.horizontal([node(.pane(1)), node(.pane(2)), node(.pane(3))])),
            leafGrid: leaves([1: (26, 24), 2: (26, 24), 3: (26, 24)])
        )
        #expect(result?.cols == 80)
        #expect(result?.rows == 24)
    }

    @Test func nestedSplitFoldsRecursively() {
        // horizontal[ pane(1)=40x24, vertical[ pane(2)=39x12, pane(3)=39x11 ] ]
        //   right child (vertical): max width 39, heights 12 + 11 + 1 = 24 → 39x24
        //   root (horizontal):      40 + 39 + 1 = 80 cols, max(24, 24) = 24 rows
        let tree = node(.horizontal([
            node(.pane(1)),
            node(.vertical([node(.pane(2)), node(.pane(3))])),
        ]))
        let result = RemoteTmuxWindowMirror.summedGridCells(
            of: tree,
            leafGrid: leaves([1: (40, 24), 2: (39, 12), 3: (39, 11)])
        )
        #expect(result?.cols == 80)
        #expect(result?.rows == 24)
    }

    @Test func returnsNilUntilEveryLeafHasALiveGrid() {
        // One pane's surface isn't live yet → the whole fold is nil, so the caller
        // retries instead of reporting a partial (too-narrow) window to tmux.
        let result = RemoteTmuxWindowMirror.summedGridCells(
            of: node(.horizontal([node(.pane(1)), node(.pane(2))])),
            leafGrid: leaves([1: (40, 24)]) // pane 2 missing
        )
        #expect(result == nil)
    }
}

/// Pins the client-size RE-ARM contract for mirrored multi-pane windows.
///
/// The summed rendered grids that feed
/// ``RemoteTmuxWindowMirror/updateClientSize()`` are downstream of tmux's own
/// layout: the split container divides pixels proportionally to tmux's cell
/// weights, and each leaf grid quantizes that. Every `refresh-client -C` we
/// send therefore comes back as a geometry-only `%layout-change` (tmux
/// reflowing the window to the size we just pushed). At pixel widths where
/// cmux's pixel division and tmux's integer cell division disagree by a
/// column, a push triggered by that echo has no fixed point — the client size
/// alternates ±1 column indefinitely, SIGWINCH-storming every pane in the
/// session.
///
/// The contract under test — three cooperating rules:
/// 1. ``RemoteTmuxWindowMirror/layoutStructureVersion`` advances exactly on
///    STRUCTURE changes (pane set / split nesting — ``structureSignature(of:)``):
///    splits, closes, and re-nests must re-push (their separator arithmetic
///    changes the summed grid) and refill the correction budget.
/// 2. Geometry-only reflows advance ``sizingCorrectionVersion`` at most
///    twice between local/structural triggers: enough for a genuinely foreign
///    change (a co-attached client's resize-pane, another writer moving the
///    shared size) to heal in one bounded pass, while an echo storm burns the
///    budget and goes quiet instead of oscillating without a fixed point.
/// 3. ``updateClientSize()`` dedups against the CONNECTION's last-requested
///    size (shared state), never a mirror-local cache — after a foreign writer
///    moves the client, the mirror's next trigger must actually send.
@MainActor
@Suite struct RemoteTmuxMirrorSizingEchoGateTests {
    private func node(
        _ content: RemoteTmuxLayoutContent, w: Int = -1, h: Int = -1, x: Int = -1, y: Int = -1
    ) -> RemoteTmuxLayoutNode {
        RemoteTmuxLayoutNode(width: w, height: h, x: x, y: y, content: content)
    }

    /// The echo pair: tmux's reflow of a 3-pane side-by-side window at client
    /// width 123 (panes 41+40+40 + 2 separators) vs 122 (40+40+40 + 2). Same
    /// panes, same nesting — geometry only. These are the two quantization-
    /// consistent widths between which an echo-triggered push would alternate.
    private var reflow123: RemoteTmuxLayoutNode {
        node(.horizontal([
            node(.pane(1), w: 41, h: 35, x: 0, y: 0),
            node(.pane(2), w: 40, h: 35, x: 42, y: 0),
            node(.pane(3), w: 40, h: 35, x: 83, y: 0),
        ]), w: 123, h: 35, x: 0, y: 0)
    }
    private var reflow122: RemoteTmuxLayoutNode {
        node(.horizontal([
            node(.pane(1), w: 40, h: 35, x: 0, y: 0),
            node(.pane(2), w: 40, h: 35, x: 41, y: 0),
            node(.pane(3), w: 40, h: 35, x: 82, y: 0),
        ]), w: 122, h: 35, x: 0, y: 0)
    }

    /// A mirror plus the connection it writes to. The connection is never
    /// started (its init only stores fields; `setClientSize` records the
    /// requested size without sending while unconnected) and `makePanel` yields
    /// nil, so the pair exercises exactly the layout/version/sizing logic under
    /// test. The caller must hold the connection — the mirror only keeps a weak
    /// reference, mirroring production ownership.
    private func makeMirror(
        layout: RemoteTmuxLayoutNode
    ) -> (mirror: RemoteTmuxWindowMirror, connection: RemoteTmuxControlConnection) {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "test-host", port: nil, identityFile: nil),
            sessionName: "test"
        )
        let mirror = RemoteTmuxWindowMirror(
            windowId: 0,
            panelId: UUID(),
            connection: connection,
            layout: layout,
            makePanel: { _ in nil }
        )
        return (mirror, connection)
    }

    // MARK: structureSignature

    @Test func signatureIgnoresGeometry() {
        #expect(
            RemoteTmuxWindowMirror.structureSignature(of: reflow123)
                == RemoteTmuxWindowMirror.structureSignature(of: reflow122)
        )
    }

    @Test func signatureChangesWhenAPaneIsAddedOrRemoved() {
        let two = node(.horizontal([node(.pane(1)), node(.pane(2))]))
        let three = node(.horizontal([node(.pane(1)), node(.pane(2)), node(.pane(3))]))
        #expect(
            RemoteTmuxWindowMirror.structureSignature(of: two)
                != RemoteTmuxWindowMirror.structureSignature(of: three)
        )
    }

    @Test func signatureChangesWhenPaneIdsChange() {
        // Same shape, different pane: a pane replaced by a new tmux pane id is a
        // structural event (new surface, fresh seed) even though the tree shape
        // matches.
        let a = node(.horizontal([node(.pane(1)), node(.pane(2))]))
        let b = node(.horizontal([node(.pane(1)), node(.pane(9))]))
        #expect(
            RemoteTmuxWindowMirror.structureSignature(of: a)
                != RemoteTmuxWindowMirror.structureSignature(of: b)
        )
    }

    @Test func signatureChangesWhenNestingFlips() {
        // Same pane set, horizontal vs vertical arrangement: the separator moves
        // from a column to a row, so the summed grid changes → must re-push.
        let horizontal = node(.horizontal([node(.pane(1)), node(.pane(2))]))
        let vertical = node(.vertical([node(.pane(1)), node(.pane(2))]))
        #expect(
            RemoteTmuxWindowMirror.structureSignature(of: horizontal)
                != RemoteTmuxWindowMirror.structureSignature(of: vertical)
        )
    }

    @Test func signatureSeesNestedStructure() {
        // h[1, v[2,3]] vs h[1, 2, 3]: same pane ids, different nesting.
        let nested = node(.horizontal([
            node(.pane(1)),
            node(.vertical([node(.pane(2)), node(.pane(3))])),
        ]))
        let flat = node(.horizontal([node(.pane(1)), node(.pane(2)), node(.pane(3))]))
        #expect(
            RemoteTmuxWindowMirror.structureSignature(of: nested)
                != RemoteTmuxWindowMirror.structureSignature(of: flat)
        )
    }

    // MARK: reconcile → versions & budget

    @Test func initDoesNotBumpVersions() {
        let (mirror, _) = makeMirror(layout: reflow123)
        #expect(mirror.layoutStructureVersion == 0)
        #expect(mirror.sizingCorrectionVersion == 0)
    }

    @Test func geometryOnlyReflowNeverBumpsStructureAndCorrectionIsBudgeted() {
        // Replay tmux's alternating reflow echoes. The structure version staying
        // flat keeps the size authority from chasing its own echo between two
        // quantization-consistent widths; the correction version advancing at
        // most twice (the budget) is what makes foreign geometry changes
        // healable without re-opening the unbounded loop.
        let (mirror, _) = makeMirror(layout: reflow123)
        for i in 0..<10 {
            mirror.reconcile(layout: i.isMultiple(of: 2) ? reflow122 : reflow123)
        }
        #expect(mirror.layoutStructureVersion == 0)
        #expect(mirror.sizingCorrectionVersion == 2) // budget-capped, not 10
        #expect(mirror.layout == reflow123)
    }

    @Test func localTriggerRefillsTheCorrectionBudget() {
        let (mirror, _) = makeMirror(layout: reflow123)
        for i in 0..<6 { mirror.reconcile(layout: i.isMultiple(of: 2) ? reflow122 : reflow123) }
        #expect(mirror.sizingCorrectionVersion == 2)
        mirror.noteLocalSizingTrigger() // mount / outer resize / tab shown
        mirror.reconcile(layout: reflow122)
        #expect(mirror.sizingCorrectionVersion == 3)
    }

    @Test func structuralChangeRefillsTheCorrectionBudget() {
        let (mirror, _) = makeMirror(layout: reflow123)
        for i in 0..<6 { mirror.reconcile(layout: i.isMultiple(of: 2) ? reflow122 : reflow123) }
        #expect(mirror.sizingCorrectionVersion == 2)
        let two = node(.horizontal([node(.pane(1), w: 61, h: 35), node(.pane(2), w: 61, h: 35)]), w: 123, h: 35)
        mirror.reconcile(layout: two) // structural: refills budget
        mirror.reconcile(layout: node(.horizontal([node(.pane(1), w: 60, h: 35), node(.pane(2), w: 62, h: 35)]), w: 123, h: 35))
        #expect(mirror.sizingCorrectionVersion == 3)
    }

    @Test func structureVersionIsMonotonicAcrossRepeatedStructuralChanges() {
        // Pins the counter semantics the view's re-arm depends on: every
        // structural change advances it (a set-to-constant or bump-once
        // implementation would break re-arm for the second and later splits).
        let (mirror, _) = makeMirror(layout: reflow123)
        let two = node(.horizontal([node(.pane(1), w: 61, h: 35), node(.pane(2), w: 61, h: 35)]), w: 123, h: 35)
        mirror.reconcile(layout: two)
        mirror.reconcile(layout: reflow123)
        #expect(mirror.layoutStructureVersion == 2)
    }

    @Test func splitBumpsVersionOnce() {
        let two = node(.horizontal([node(.pane(1), w: 61, h: 35), node(.pane(2), w: 61, h: 35)]), w: 123, h: 35)
        let (mirror, _) = makeMirror(layout: two)
        mirror.reconcile(layout: reflow123) // pane 3 split off
        #expect(mirror.layoutStructureVersion == 1)
        // tmux's follow-up geometry-only reflow of the SAME 3-pane shape bumps
        // only the (budgeted) correction version, never the structure version.
        mirror.reconcile(layout: reflow122)
        #expect(mirror.layoutStructureVersion == 1)
    }

    @Test func paneCloseBumpsVersion() {
        let (mirror, _) = makeMirror(layout: reflow123)
        let two = node(.horizontal([node(.pane(1), w: 61, h: 35), node(.pane(3), w: 61, h: 35)]), w: 123, h: 35)
        mirror.reconcile(layout: two) // pane 2 closed
        #expect(mirror.layoutStructureVersion == 1)
    }

    @Test func renestBumpsVersion() {
        let (mirror, _) = makeMirror(layout: reflow123)
        let renested = node(.horizontal([
            node(.pane(1), w: 61, h: 35),
            node(.vertical([node(.pane(2), w: 61, h: 17), node(.pane(3), w: 61, h: 17)]), w: 61, h: 35),
        ]), w: 123, h: 35)
        mirror.reconcile(layout: renested)
        #expect(mirror.layoutStructureVersion == 1)
    }

    // MARK: sizing stays out of reconcile

    /// `reconcile` must never push a size itself — not for geometry-only reflows
    /// and not for structural changes. Sizing belongs exclusively to the
    /// trigger-owned `updateClientSize()` path; a push from inside reconcile
    /// would run on every `%layout-change`, which is the geometry-echo loop.
    /// The grids are stubbed LIVE here so a rogue push would actually record a
    /// size rather than bailing on missing grids.
    @Test func reconcileNeverPushesASizeItself() {
        let (mirror, connection) = makeMirror(layout: reflow123)
        mirror.leafGridOverrideForTesting = { _ in (cols: 40, rows: 35) }
        for i in 0..<6 {
            mirror.reconcile(layout: i.isMultiple(of: 2) ? reflow122 : reflow123)
        }
        let two = node(.horizontal([node(.pane(1), w: 61, h: 35), node(.pane(2), w: 61, h: 35)]), w: 123, h: 35)
        mirror.reconcile(layout: two) // structural — bumps versions, still no push
        #expect(mirror.layoutStructureVersion == 1)
        #expect(connection.lastRequestedClientSize == nil)
    }

    // MARK: updateClientSize contract (shared dedup)

    @Test func updateClientSizePushesTheSummedGridAndDedups() {
        let (mirror, connection) = makeMirror(layout: reflow123)
        mirror.leafGridOverrideForTesting = { _ in (cols: 40, rows: 35) }
        #expect(mirror.updateClientSize())
        #expect(connection.lastRequestedClientSize?.columns == 122) // 40*3 + 2 separators
        #expect(connection.lastRequestedClientSize?.rows == 35)
        // Idempotent on unchanged grids: still true, same recorded size.
        #expect(mirror.updateClientSize())
        #expect(connection.lastRequestedClientSize?.columns == 122)
    }

    @Test func mirrorRecoversTheClientSizeAfterAForeignWriterMovesIt() {
        // The starvation regression: dedup must compare against the SHARED
        // last-requested size, not a mirror-local cache. After a foreign writer
        // (a single-pane tab, a reconnect re-apply) moves the client, the
        // mirror's next trigger must actually send — a private "what I last
        // pushed" cache would swallow it and the window would stay mismatched
        // with no recovery path.
        let (mirror, connection) = makeMirror(layout: reflow123)
        mirror.leafGridOverrideForTesting = { _ in (cols: 40, rows: 35) }
        #expect(mirror.updateClientSize())
        #expect(connection.lastRequestedClientSize?.columns == 122)
        connection.setClientSize(columns: 140, rows: 40) // foreign writer wins
        #expect(mirror.updateClientSize()) // mirror trigger reclaims
        #expect(connection.lastRequestedClientSize?.columns == 122)
        #expect(connection.lastRequestedClientSize?.rows == 35)
    }

    @Test func updateClientSizePicksUpSettledGridsAfterAGeometryOnlyReflow() {
        // The settle-confirm path: a reflow re-divides the local pixels, the
        // grids change, and the next explicit updateClientSize (trigger-scoped,
        // not echo-triggered) must push the new sum even though reconcile
        // itself stayed passive.
        let (mirror, connection) = makeMirror(layout: reflow123)
        var width = 40
        mirror.leafGridOverrideForTesting = { _ in (cols: width, rows: 35) }
        #expect(mirror.updateClientSize())
        #expect(connection.lastRequestedClientSize?.columns == 122)
        mirror.reconcile(layout: reflow122) // geometry-only: no push by itself
        width = 41                          // grids settle differently
        #expect(connection.lastRequestedClientSize?.columns == 122)
        #expect(mirror.updateClientSize())
        #expect(connection.lastRequestedClientSize?.columns == 125) // 41*3 + 2
    }

    @Test func updateClientSizeRespondsToRowsOnlyChanges() {
        let (mirror, connection) = makeMirror(layout: reflow123)
        var rows = 35
        mirror.leafGridOverrideForTesting = { _ in (cols: 40, rows: rows) }
        #expect(mirror.updateClientSize())
        rows = 30
        #expect(mirror.updateClientSize())
        #expect(connection.lastRequestedClientSize?.rows == 30)
        #expect(connection.lastRequestedClientSize?.columns == 122)
    }

    @Test func updateClientSizeWaitsForEveryLeafToGoLive() {
        let (mirror, connection) = makeMirror(layout: reflow123)
        mirror.leafGridOverrideForTesting = { paneId in
            paneId == 2 ? nil : (cols: 40, rows: 35) // pane 2 not live yet
        }
        #expect(!mirror.updateClientSize())
        #expect(connection.lastRequestedClientSize == nil)
    }

    @Test func sliverPaneFallsBackToItsTmuxDimsInsteadOfBlockingSizing() {
        // A co-attached client can squeeze a pane to 1-2 cells; such a sliver
        // may never report a live grid. It must contribute its tmux dims rather
        // than turning the whole window's sizing into a permanent outage.
        let layout = node(.horizontal([
            node(.pane(1), w: 2, h: 35, x: 0, y: 0),   // sliver: no live grid
            node(.pane(2), w: 60, h: 35, x: 3, y: 0),
            node(.pane(3), w: 60, h: 35, x: 64, y: 0),
        ]), w: 123, h: 35)
        let (mirror, connection) = makeMirror(layout: layout)
        mirror.leafGridOverrideForTesting = { paneId in
            paneId == 1 ? nil : (cols: 60, rows: 35)
        }
        #expect(mirror.updateClientSize())
        #expect(connection.lastRequestedClientSize?.columns == 124) // 2 + 60 + 60 + 2 separators
    }

    // MARK: per-pane pins (tmux's deal vs the rendered grids)

    @Test func panePinsAreEmptyWhenTmuxDealMatchesTheRender() {
        let pins = RemoteTmuxWindowMirror.panePins(of: reflow123) { _ in (cols: 41, rows: 35) }
        // reflow123 deals 41/40/40; a uniform 41 render mismatches panes 2 and 3
        // — but with the exact per-pane grids it deals, no pins:
        let exact = RemoteTmuxWindowMirror.panePins(of: reflow123) { paneId in
            paneId == 1 ? (cols: 41, rows: 35) : (cols: 40, rows: 35)
        }
        #expect(exact.isEmpty)
        #expect(!pins.isEmpty)
    }

    @Test func panePinsFlagOnlyTheMisdealtPaneAndDimension() {
        // tmux dealt 41/40/40 but the surfaces render 40/41/40: tmux gave the
        // odd column to pane 1 while pane 2 has the pixels for it. Exactly two
        // pins, width-only.
        let pins = RemoteTmuxWindowMirror.panePins(of: reflow123) { paneId in
            switch paneId {
            case 1: return (cols: 40, rows: 35)
            case 2: return (cols: 41, rows: 35)
            default: return (cols: 40, rows: 35)
            }
        }
        #expect(pins == [
            RemoteTmuxWindowMirror.PanePin(paneId: 1, cols: 40, rows: nil),
            RemoteTmuxWindowMirror.PanePin(paneId: 2, cols: 41, rows: nil),
        ])
    }

    @Test func panePinsSkipLeavesWithNoLiveGrid() {
        let pins = RemoteTmuxWindowMirror.panePins(of: reflow123) { paneId in
            paneId == 1 ? nil : (cols: 40, rows: 35)
        }
        #expect(pins.allSatisfy { $0.paneId != 1 })
    }

    @Test func dedupHitPassPinsTheMisdealtPane() {
        // The user-visible stuck state: the client TOTAL is already right
        // (dedup hit) but tmux dealt the odd column to the wrong pane. The
        // pass must emit pins instead of doing nothing.
        let (mirror, connection) = makeMirror(layout: reflow123) // deals 41/40/40
        mirror.leafGridOverrideForTesting = { paneId in
            paneId == 2 ? (cols: 41, rows: 35) : (cols: 40, rows: 35) // render 40/41/40
        }
        // total = 40+41+40+2 = 123 — prime the connection so it's a dedup hit.
        connection.setClientSize(columns: 123, rows: 35)
        #expect(mirror.updateClientSize())
        #expect(mirror.lastPanePinsForTesting == [
            RemoteTmuxWindowMirror.PanePin(paneId: 1, cols: 40, rows: nil),
            RemoteTmuxWindowMirror.PanePin(paneId: 2, cols: 41, rows: nil),
        ])
        // And once the deal matches the render, the same pass pins nothing.
        mirror.leafGridOverrideForTesting = { paneId in
            paneId == 1 ? (cols: 41, rows: 35) : (cols: 40, rows: 35)
        }
        #expect(mirror.updateClientSize())
        #expect(mirror.lastPanePinsForTesting.isEmpty)
    }

    // MARK: closed-loop convergence (tmux as an adversary)

    /// The bug class every open-loop truth table misses: the sizing authority
    /// and tmux form a LOOP (render → total → tmux's deal → re-render), and
    /// tmux's deal of a new total follows its own remainder rule — verified on
    /// tmux 3.7 to be proportional-with-fixup from the current shape, not any
    /// simple "first pane wins" rule. So this test does not model tmux's exact
    /// dealer; it proves convergence against ANY consistent dealer, hostile
    /// ones included: within a bounded number of rounds, the total dedups AND
    /// the per-pane pins empty out (pane-exact), for every dealer and every
    /// pixel geometry tried. Pin application uses the neighbor semantics
    /// measured on real tmux (a pin moves the difference to the right
    /// neighbor; the last pane takes from the left).
    @Test func closedLoopConvergesPaneExactUnderAnyDealer() {
        // Pixel model: 3 side-by-side panes, 2pt dividers, cellW 8pt, 3pt of
        // horizontal chrome per pane — chosen so pixel quantization disagrees
        // with integer deals at some widths (the hostile geometries).
        func renders(_ deal: [Int], windowPx: Double) -> [Int] {
            let usable = windowPx - 2.0 * 2.0
            let total = Double(deal.reduce(0, +))
            return deal.map { w in
                max(1, Int(((usable * Double(w) / total) - 3.0) / 8.0))
            }
        }
        // Dealers: given a new total (content cols = total - separators) and
        // the previous deal, produce a new deal. All consistent (sum matches),
        // all with different remainder placement.
        typealias Dealer = (_ contentCols: Int, _ previous: [Int]) -> [Int]
        let dealers: [(String, Dealer)] = [
            ("firstGetsRemainder", { c, p in
                let base = c / p.count, r = c % p.count
                return (0..<p.count).map { base + ($0 < r ? 1 : 0) }
            }),
            ("lastGetsRemainder", { c, p in
                let base = c / p.count, r = c % p.count
                return (0..<p.count).map { base + ($0 >= p.count - r ? 1 : 0) }
            }),
            ("proportionalFixup", { c, p in
                let old = p.reduce(0, +)
                var deal = p.map { Int((Double($0) * Double(c) / Double(old)).rounded(.down)) }
                var i = 0
                while deal.reduce(0, +) < c { deal[i % deal.count] += 1; i += 1 }
                while deal.reduce(0, +) > c { deal[i % deal.count] -= 1; i += 1 }
                return deal
            }),
            ("adversarialRotate", { c, p in
                let base = c / p.count, r = c % p.count
                // Rotate the remainder to a different pane every deal.
                let start = (p.firstIndex(of: p.max() ?? 0) ?? 0 + 1) % p.count
                return (0..<p.count).map { base + (($0 + start) % p.count < r ? 1 : 0) }
            }),
        ]
        func layoutNode(deal: [Int]) -> RemoteTmuxLayoutNode {
            var x = 0
            var children: [RemoteTmuxLayoutNode] = []
            for (i, w) in deal.enumerated() {
                children.append(node(.pane(i + 1), w: w, h: 35, x: x, y: 0))
                x += w + 1
            }
            return node(.horizontal(children), w: deal.reduce(0, +) + deal.count - 1, h: 35)
        }
        for (name, dealer) in dealers {
            for windowPx in stride(from: 900.0, through: 1300.0, by: 37.0) {
                var deal = [40, 40, 40]
                var client = deal.reduce(0, +) + 2
                var converged = false
                for _ in 0..<6 {
                    let r = renders(deal, windowPx: windowPx)
                    let grids = Dictionary(uniqueKeysWithValues: r.enumerated().map { ($0.offset + 1, (cols: $0.element, rows: 35)) })
                    let total = RemoteTmuxWindowMirror.summedGridCells(
                        of: layoutNode(deal: deal), leafGrid: { grids[$0] }
                    )!.cols
                    if total != client {
                        client = total
                        deal = dealer(total - (deal.count - 1), deal)
                        continue
                    }
                    let pins = RemoteTmuxWindowMirror.panePins(
                        of: layoutNode(deal: deal), leafGrid: { grids[$0] }
                    )
                    if pins.isEmpty { converged = true; break }
                    // Apply pins with the measured neighbor semantics: the
                    // delta moves to the right neighbor (left for the last).
                    for pin in pins {
                        guard let target = pin.cols else { continue }
                        let idx = pin.paneId - 1
                        let delta = deal[idx] - target
                        deal[idx] = target
                        let neighbor = idx == deal.count - 1 ? idx - 1 : idx + 1
                        deal[neighbor] += delta
                    }
                }
                #expect(converged, "dealer \(name) at \(windowPx)px never converged pane-exact")
                // Pane-exact: tmux's deal equals every pane's rendered width.
                let finalRenders = renders(deal, windowPx: windowPx)
                #expect(deal == finalRenders, "dealer \(name) at \(windowPx)px: deal \(deal) != renders \(finalRenders)")
            }
        }
    }

    @Test func updateClientSizeFloorsDegenerateGrids() {
        // A transient near-zero grid (mid-layout) must never push a tiny client
        // size at tmux: floors are 20 cols x 5 rows.
        let single = node(.pane(1), w: 5, h: 2)
        let (mirror, connection) = makeMirror(layout: single)
        mirror.leafGridOverrideForTesting = { _ in (cols: 5, rows: 2) }
        #expect(mirror.updateClientSize())
        #expect(connection.lastRequestedClientSize?.columns == 20)
        #expect(connection.lastRequestedClientSize?.rows == 5)
    }
}
