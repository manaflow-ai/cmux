import CmuxRemoteSession
import AppKit
import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Contract coverage for the feed-forward mirror sizing pipeline around
/// ``RemoteTmuxWindowMirror``: the pushed size is a pure function of container
/// pixels + BASE-tree structure + measured constants (never of tmux-assigned geometry
/// or rendered grids), pushes are per-window and deduped on the connection,
/// hidden mirrors never write, reconcile never pushes, and zoom flows through
/// the visible tree without touching panel lifecycle or the pushed size.
@MainActor
@Suite struct RemoteTmuxMirrorFeedForwardTests {
    private func node(
        _ content: RemoteTmuxLayoutContent, w: Int = -1, h: Int = -1, x: Int = -1, y: Int = -1
    ) -> RemoteTmuxLayoutNode {
        RemoteTmuxLayoutNode(width: w, height: h, x: x, y: y, content: content)
    }

    /// A 3-pane side-by-side layout at client width 123 (41+40+40 + 2 separators)
    /// and its 122-wide re-divide — same structure, geometry only.
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

    /// Calibrated 2× terminal constants (cell 16×34 px, padding 8×0 px).
    private var calibratedGeometry: RemoteTmuxMirrorGeometry {
        RemoteTmuxMirrorGeometry(
            cellWidthPx: 16, cellHeightPx: 34,
            surfacePadWidthPx: 8, surfacePadHeightPx: 0,
            scale: 2
        )
    }

    /// Mirror + retained connection (the mirror holds it weakly). `makePanel`
    /// returns nil (no live surfaces exist here), so the measured render
    /// constants are injected through the mirror's `geometrySource` init
    /// parameter — dependency injection, not a debug seam.
    private func makeMirror(
        layout: RemoteTmuxLayoutNode,
        geometry: RemoteTmuxMirrorGeometry? = nil,
        hostingContentSizeSource: (() -> CGSize?)? = {
            CGSize(width: 10_000, height: 10_000)
        }
    ) -> (RemoteTmuxWindowMirror, RemoteTmuxControlConnection) {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"), sessionName: "work"
        )
        let mirror = RemoteTmuxWindowMirror(
            windowId: 0,
            panelId: UUID(),
            connection: connection,
            layout: layout,
            geometrySource: geometry.map { g in { g } },
            hostingContentSizeSource: hostingContentSizeSource,
            makePanel: { _ in nil }
        )
        return (mirror, connection)
    }

    /// A mirror fully readied for sizing: calibrated constants injected + an
    /// 800×620pt container at 2× (native chrome + padding → 100×34).
    private func readyMirror(
        layout: RemoteTmuxLayoutNode
    ) -> (RemoteTmuxWindowMirror, RemoteTmuxControlConnection) {
        let pair = makeMirror(layout: layout, geometry: calibratedGeometry)
        pair.0.noteContainerSize(pointSize: CGSize(width: 800, height: 620), scale: 2)
        return pair
    }

    /// The size the mirror pushed to the connection for window 0, read the
    /// same way tests read any connection state (via `@testable import`).
    private func pushed(_ connection: RemoteTmuxControlConnection) -> (cols: Int, rows: Int)? {
        connection.lastWindowSizes[0].map { (cols: $0.0, rows: $0.1) }
    }

    // MARK: structure signature

    @Test func signatureIgnoresGeometry() {
        #expect(
            RemoteTmuxWindowMirror.structureSignature(of: reflow123)
                == RemoteTmuxWindowMirror.structureSignature(of: reflow122)
        )
    }

    @Test func signatureChangesWhenPaneIdsChange() {
        let renumbered = node(.horizontal([
            node(.pane(1), w: 41, h: 35), node(.pane(2), w: 40, h: 35), node(.pane(9), w: 40, h: 35),
        ]), w: 123, h: 35)
        #expect(
            RemoteTmuxWindowMirror.structureSignature(of: reflow123)
                != RemoteTmuxWindowMirror.structureSignature(of: renumbered)
        )
    }

    @Test func signatureChangesWhenNestingFlips() {
        let nested = node(.horizontal([
            node(.pane(1), w: 41, h: 35),
            node(.vertical([node(.pane(2), w: 40, h: 17), node(.pane(3), w: 40, h: 17)]), w: 40, h: 35),
        ]), w: 123, h: 35)
        #expect(
            RemoteTmuxWindowMirror.structureSignature(of: reflow123)
                != RemoteTmuxWindowMirror.structureSignature(of: nested)
        )
    }

    // MARK: reconcile → structure version

    @Test func initDoesNotBumpVersions() {
        let (mirror, _) = makeMirror(layout: reflow123)
        #expect(mirror.layoutStructureVersion == 0)
    }

    @Test func geometryOnlyReflowNeverBumpsStructure() {
        let (mirror, _) = makeMirror(layout: reflow123)
        for i in 0..<10 {
            mirror.reconcile(layout: i.isMultiple(of: 2) ? reflow122 : reflow123)
        }
        #expect(mirror.layoutStructureVersion == 0)
        #expect(mirror.layout == reflow123)
    }

    @Test func structureVersionIsMonotonicAcrossRepeatedStructuralChanges() {
        let (mirror, _) = makeMirror(layout: reflow123)
        let two = node(.horizontal([node(.pane(1), w: 61, h: 35), node(.pane(2), w: 61, h: 35)]), w: 123, h: 35)
        mirror.reconcile(layout: two)
        mirror.reconcile(layout: reflow123)
        #expect(mirror.layoutStructureVersion == 2)
    }

    @Test func reconcilePrunesSizingHistoryForRemovedPaneIDs() {
        let (mirror, _) = makeMirror(layout: reflow123)
        mirror.lastRenderedGrids = [1: (10, 10), 2: (10, 10), 3: (10, 10)]
        let two = node(.horizontal([
            node(.pane(1), w: 61, h: 35), node(.pane(2), w: 61, h: 35),
        ]), w: 123, h: 35)
        mirror.reconcile(layout: two)
        #expect(Set(mirror.lastRenderedGrids.keys) == [1, 2])
        mirror.teardown()
        #expect(mirror.lastRenderedGrids.isEmpty)
    }

    // MARK: feed-forward push contract

    @Test func updateClientSizeWaitsForConstantsAndContainer() {
        // No constants: not ready (caller retries), nothing sent.
        let (noGeo, noGeoConn) = makeMirror(layout: reflow123)
        noGeo.noteContainerSize(pointSize: CGSize(width: 800, height: 620), scale: 2)
        #expect(noGeo.updateClientSize() == false)
        #expect(pushed(noGeoConn) == nil)
        // Constants present, no container yet: still not ready.
        let (mirror, connection) = makeMirror(layout: reflow123, geometry: calibratedGeometry)
        #expect(mirror.updateClientSize() == false)
        #expect(pushed(connection) == nil)
        // Both present: ready, and it lands per-window.
        mirror.noteContainerSize(pointSize: CGSize(width: 800, height: 620), scale: 2)
        #expect(mirror.updateClientSize())
        // Claims remove only real chrome; rail-rounding slack belongs to the
        // native plan: (800 − 3 × pad 4 − 2 × (divider 1 − cell 8)) / 8 → 100.
        #expect(pushed(connection)?.cols == 100)
        #expect(pushed(connection)?.rows == 34) // 620pt − the native 30pt pane tab bar
        #expect(connection.lastWindowSizes[0] != nil)
        // A pass already queued on the main actor must not resurrect the
        // claim after the window mirror is removed.
        mirror.setNeedsSizingPass()
        mirror.teardown()
        mirror.performSizingPassNow()
        #expect(connection.lastWindowSizes[0] == nil)
    }

    @Test func pushIsAPureFunctionOfPixelsAndStructureNotTheAssignment() {
        // The SAME pixels with a re-dividet (geometry-only) tree push the SAME
        // size — the mechanical form of the no-feedback-loop theorem: tmux's
        // echo of our own push can never change what we push next.
        let (mirror, connection) = readyMirror(layout: reflow123)
        #expect(mirror.updateClientSize())
        let first = pushed(connection)
        mirror.reconcile(layout: reflow122) // echo-shaped: geometry only
        #expect(mirror.updateClientSize())
        let second = pushed(connection)
        #expect(first?.cols == second?.cols)
        #expect(first?.rows == second?.rows)
    }

    @Test func detachedMeasurementWaitsForAVisibleHostThenAdoptsItsBound() {
        let initialBound = CGSize(width: 640, height: 500)
        var hostingBound: CGSize? = initialBound
        let (mirror, connection) = makeMirror(
            layout: reflow123,
            geometry: calibratedGeometry,
            hostingContentSizeSource: { hostingBound }
        )
        mirror.isVisibleForSizing = true
        mirror.noteContainerSize(pointSize: initialBound, scale: 2)
        mirror.performSizingPassNow()
        let attachedClaim = pushed(connection)
        #expect(mirror.containerSizePt == hostingBound)
        #expect(attachedClaim != nil)

        // A detached portal can briefly report full-display geometry. Retain
        // the later resize without letting it poison the validated claim.
        hostingBound = nil
        mirror.noteContainerSize(pointSize: CGSize(width: 1_000, height: 700), scale: 2)
        // Portal teardown can report a final 1x1 after the useful detached
        // measurement. It must not overwrite the pending reattach size.
        mirror.noteContainerSize(pointSize: CGSize(width: 1, height: 1), scale: 2)
        mirror.performSizingPassNow()
        #expect(pushed(connection)?.cols == attachedClaim?.cols)

        // The next attached pass adopts that pending measurement, bounded by
        // the real host, even if attachment emits no new geometry callback.
        hostingBound = CGSize(width: 1_000, height: 700)
        mirror.performSizingPassNow()
        #expect(mirror.containerSizePt == hostingBound)
        #expect((pushed(connection)?.cols ?? 0) > (attachedClaim?.cols ?? 0))
        #expect((pushed(connection)?.rows ?? 0) > (attachedClaim?.rows ?? 0))
    }

    @Test func bottomPaneTitleRowsRemainSizingChrome() {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"), sessionName: "work"
        )
        let pipe = Pipe()
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-bottom-title-test",
            maxPendingBytes: 1 << 16,
            onFailure: {}
        )
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        connection.installStdinWriterForTesting(writer)
        connection.handleMessageForTesting(.enter)
        connection.handleMessageForTesting(.commandResult(commandNumber: 0, lines: [], isError: false))
        connection.handleMessageForTesting(.commandResult(
            commandNumber: 0,
            lines: ["@1 f92f,80x24,0,0,0 f92f,80x24,0,0,0 [] one"],
            isError: false
        ))
        connection.handleMessageForTesting(.commandResult(
            commandNumber: 0,
            lines: ["%0 0 0 80 23 1 bottom :0 \"ejc3-mac\""],
            isError: false
        ))

        // Bottom placement changes where tmux draws the row, not whether the
        // pane loses one grid row to that chrome.
        #expect(connection.windowTitleRowPlacements[1] == .bottom)
    }

    @Test func reconcileClaimsOnceThenNeverChangesThePushedSize() {
        // Reconcile drives the ONE-TIME claim (a hidden window would
        // otherwise deadlock: tmux won't resize an unclaimed window, and
        // without a resize its surfaces never produce the sample the claim
        // needs). After that, tmux's own layout events must never alter the
        // pushed size — f reads pixels + structure only, so an echo
        // recomputes the identical value and dedups to silence.
        let (mirror, connection) = readyMirror(layout: reflow123)
        mirror.reconcile(layout: reflow122)
        let claim = pushed(connection)
        #expect(claim?.cols == 100)
        mirror.reconcile(layout: reflow123)
        mirror.reconcile(layout: reflow122)
        #expect(pushed(connection)?.cols == claim?.cols)
        #expect(pushed(connection)?.rows == claim?.rows)
    }

    @Test func containerResizeReimposesDividerFractions() {
        // A container-only resize produces no tmux layout echo, so the
        // mirror itself must recompute the divider plan. In the normal case
        // the imposed point extents don't change (points don't scale with
        // the container — that staleness was a fraction disease), so the
        // observable is the overconstrained case: a container too small for
        // the assigned cells must rescale every imposed extent evenly.
        let (mirror, _) = readyMirror(layout: reflow123)
        mirror.isVisibleForSizing = true
        mirror.reconcile(layout: reflow123)
        // Triggers only schedule; the coalesced pass does the work.
        mirror.performSizingPassNow()
        let before = Self.imposedExtents(of: mirror.bonsplitController.treeSnapshot())
        #expect(!before.isEmpty, "the sizing pass must impose exact extents")
        // Shrink far below the layout's ideal width: extents must rescale.
        mirror.noteContainerSize(pointSize: CGSize(width: 400, height: 620), scale: 2)
        mirror.performSizingPassNow()
        let after = Self.imposedExtents(of: mirror.bonsplitController.treeSnapshot())
        #expect(Set(before.keys) == Set(after.keys))
        for (id, extent) in after {
            let original = before[id] ?? 0
            #expect(
                extent < original,
                "imposed extent must rescale with the container: \(extent) vs \(original)"
            )
        }
    }

    private static func imposedExtents(of node: ExternalTreeNode) -> [String: Double] {
        switch node {
        case .pane:
            return [:]
        case .split(let split):
            var extents = imposedExtents(of: split.first)
                .merging(imposedExtents(of: split.second)) { first, _ in first }
            if let imposed = split.imposedFirstExtent { extents[split.id] = imposed }
            return extents
        }
    }

    @Test func hiddenMirrorWritesOnlyTheInitialClaim() {
        // The first per-window size on a connection drops every unclaimed
        // window to tmux's 80×24 default, so a hidden mirror claims its size
        // once at attach — and then never writes again while hidden (its
        // geometry callbacks report collapsed sizes).
        let (mirror, connection) = readyMirror(layout: reflow123)
        mirror.isVisibleForSizing = false
        #expect(mirror.updateClientSize())
        let claim = pushed(connection)
        #expect(claim != nil) // the initial claim goes through
        mirror.noteContainerSize(pointSize: CGSize(width: 40, height: 30), scale: 2)
        #expect(mirror.updateClientSize()) // collapsed hidden geometry arrives
        #expect(pushed(connection)?.cols == claim?.cols) // no re-write
        #expect(pushed(connection)?.rows == claim?.rows)
        #expect(connection.lastWindowSizes.count == 1)
    }

    @Test func hiddenOrDetachedMirrorNeverImposesAndFreezesItsContainer() {
        // While hidden or detached, the tree lives in a portal host that no window
        // clamps, so imposing an absolute extent there grows the host
        // instead of shrinking the second child — and the grown bounds come
        // back through noteContainerSize, compounding every pass (observed
        // live: a hidden window's host at 224k points claiming 27,984
        // columns). Hidden mirrors therefore neither impose nor record
        // container sizes; logical visibility alone is not a trustworthy bound.
        let (mirror, connection) = makeMirror(
            layout: reflow123,
            geometry: calibratedGeometry,
            hostingContentSizeSource: { nil }
        )
        mirror.noteContainerSize(pointSize: CGSize(width: 800, height: 620), scale: 2)
        mirror.isVisibleForSizing = false
        mirror.reconcile(layout: reflow123)
        mirror.performSizingPassNow()
        #expect(Self.imposedExtents(of: mirror.bonsplitController.treeSnapshot()).isEmpty)
        // Inflated portal-limbo bounds arrive while hidden: not recorded.
        mirror.noteContainerSize(pointSize: CGSize(width: 224_000, height: 620), scale: 2)
        mirror.isVisibleForSizing = true
        mirror.performSizingPassNow()
        #expect(Self.imposedExtents(of: mirror.bonsplitController.treeSnapshot()).isEmpty)
        #expect(mirror.updateClientSize())
        // The claim reflects the frozen 800pt container, not limbo bounds.
        #expect(pushed(connection)?.cols == 100)
        #expect(connection.lastWindowSizes.count == 1)
    }

    @Test func sizingTransactionSettlesAtFixedPointUnderInputStorms() {
        // Closed-loop convergence property: throw a seeded storm of input
        // events at the mirror in randomized order — container resizes,
        // layout reflows, visibility flips — then drain. The transaction
        // must reach a fixed point (a drain with unchanged inputs does
        // nothing), and the settled tree must hold exactly the plan for
        // the FINAL inputs, never a stale intermediate's. This is the
        // unit-level version of the live fuzz's settle check, and it is
        // what makes feedback loops structurally impossible: every event
        // the storm delivers mid-drain only changes data.
        var state: UInt64 = 0x5EED
        func rand(_ n: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(state >> 33) % n
        }
        let (mirror, _) = readyMirror(layout: reflow123)
        mirror.isVisibleForSizing = true
        mirror.reconcile(layout: reflow123)
        mirror.performSizingPassNow()

        for _ in 0..<200 {
            switch rand(4) {
            case 0:
                mirror.noteContainerSize(
                    pointSize: CGSize(
                        width: CGFloat(500 + rand(900)),
                        height: CGFloat(400 + rand(400))
                    ),
                    scale: 2
                )
            case 1:
                mirror.reconcile(layout: reflow123)
            case 2:
                mirror.isVisibleForSizing = false
                mirror.setNeedsSizingPass()
            default:
                mirror.isVisibleForSizing = true
                mirror.setNeedsSizingPass()
            }
            if rand(3) == 0 { mirror.performSizingPassNow() }
        }

        // Storm over: make the mirror visible and drain to the fixed point.
        mirror.isVisibleForSizing = true
        mirror.performSizingPassNow()
        let settled = Self.imposedExtents(of: mirror.bonsplitController.treeSnapshot())
        mirror.performSizingPassNow()
        let again = Self.imposedExtents(of: mirror.bonsplitController.treeSnapshot())
        #expect(settled == again, "a drain with unchanged inputs must change nothing")
        #expect(!settled.isEmpty, "the settled tree must hold impositions")

        // The settled impositions are the plan for the FINAL inputs.
        if let metrics = mirror.nativeLayoutMetrics() {
            let planner = RemoteTmuxNativeSplitLayoutPlanner(metrics: metrics)
            let plan = planner.plan(
                tree: RemoteTmuxNativeMeasuredSplitTree(
                    tree: RemoteTmuxNativeSplitTree(layout: mirror.renderedLayout),
                    metrics: metrics
                ),
                parentSize: mirror.containerSizePt
            )
            var planned: [CGFloat] = []
            func walk(_ node: RemoteTmuxNativeSplitLayoutPlanner.Plan) {
                if case .split(_, _, let extent, let first, let second) = node {
                    if let extent { planned.append(extent) }
                    walk(first); walk(second)
                }
            }
            walk(plan)
            let settledSorted = settled.values.map { CGFloat($0) }.sorted()
            #expect(
                settledSorted == planned.sorted().map { $0 },
                "settled impositions must equal the final inputs' plan"
            )
        }
    }

    @Test func degeneratePixelsClampToWorkableFloors() {
        let (mirror, connection) = makeMirror(layout: reflow123, geometry: calibratedGeometry)
        mirror.noteContainerSize(pointSize: CGSize(width: 30, height: 20), scale: 2)
        #expect(mirror.updateClientSize())
        #expect(pushed(connection)?.cols == RemoteTmuxMirrorGeometry.minCols)
        #expect(pushed(connection)?.rows == RemoteTmuxMirrorGeometry.minRows)
        #expect(connection.lastWindowSizes[0] != nil)
    }

    // MARK: zoom (dual tree)

    @Test func zoomNeverTouchesPanelLifecycleOrThePushedSize() {
        let (mirror, connection) = readyMirror(layout: reflow123)
        #expect(mirror.updateClientSize())
        let before = pushed(connection)
        let zoomedWindow = RemoteTmuxWindow(
            id: 0, name: "w", width: 123, height: 35,
            layout: reflow123,
            visibleLayout: node(.pane(2), w: 123, h: 35),
            zoomed: true
        )
        mirror.apply(window: zoomedWindow)
        #expect(mirror.layoutStructureVersion == 0) // base structure unchanged
        #expect(mirror.zoomed)
        #expect(mirror.visibleLayout?.paneIDsInOrder == [2])
        #expect(mirror.paneIDsInOrder == [1, 2, 3]) // base tree still owns panes
        #expect(mirror.updateClientSize())
        #expect(pushed(connection)?.cols == before?.cols) // f zoom-invariant
        #expect(pushed(connection)?.rows == before?.rows)
        // Unzoom arrives as a fresh event (never latched).
        mirror.apply(window: RemoteTmuxWindow(
            id: 0, name: "w", width: 123, height: 35,
            layout: reflow123, visibleLayout: reflow123, zoomed: false
        ))
        #expect(mirror.zoomed == false)
        #expect(mirror.visibleLayout == nil)
    }

}

/// Per-window sizing semantics on the CONNECTION: dedup per window, the
/// reconnect re-pin table, and the old-server fallback.

/// The rect-publication invariant on the CONNECTION: `windowsByID` (what
/// observers read) only ever holds trees whose leaf rects came from a
/// `list-panes` fetch. Layout strings are quarantined and published solely by
/// the generation-guarded rects reply — these tests drive the control-mode
/// message flow end to end through the positional command FIFO.
