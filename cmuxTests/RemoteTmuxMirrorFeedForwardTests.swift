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

    // MARK: fresh-connect wedge (container reading resolution)

    /// With a real window bounding the reading: a sane (within-bound) reading
    /// banks as-is; an OVERSIZED one is an ancestor's content ideal, says
    /// nothing about the true slot, and must be DROPPED — banking the bound
    /// itself overstated the region by the window-to-mirror chrome and the
    /// live fuzz measured plans running ~40pt wide at rest. Only a first-ever
    /// reading clamps, so the initial claim still exists.
    @Test func visibleWindowBanksSaneReadingsAndDropsOversizedOnes() {
        let bound = CGSize(width: 1200, height: 800)
        let (mirror, _) = makeMirror(
            layout: reflow123,
            geometry: calibratedGeometry,
            hostingContentSizeSource: { bound }
        )
        mirror.isVisibleForSizing = true
        // Sane reading within the bound: banked verbatim.
        mirror.noteContainerSize(pointSize: CGSize(width: 1100, height: 700), scale: 2)
        #expect(mirror.containerSizePt == CGSize(width: 1100, height: 700))
        // Oversized with a good reading on record: dropped, not clamped, not
        // stashed — the last good reading stays authoritative.
        mirror.noteContainerSize(pointSize: CGSize(width: 3000, height: 2000), scale: 2)
        #expect(mirror.containerSizePt == CGSize(width: 1100, height: 700))
        #expect(mirror.pendingContainerSizePt == nil)
        // One oversized axis is as pathological as two.
        mirror.noteContainerSize(pointSize: CGSize(width: 1100, height: 2000), scale: 2)
        #expect(mirror.containerSizePt == CGSize(width: 1100, height: 700))
    }

    /// During an AppKit window resize, SwiftUI can deliver the CORRECT
    /// post-resize slot reading while the window's transient frame still
    /// holds the old bound — the reading is truth, the bound is noise.
    /// Dropping it permanently freezes the mirror at the pre-resize size:
    /// geometry callbacks only re-fire when the region changes again, and
    /// the pass-top clamp cannot recover the width because the window bound
    /// overstates the mirror slot by the sidebar. A reading dropped against
    /// a torn bound must be re-judged once against the next settled bound
    /// and banked when it fits.
    @Test func readingDroppedAgainstATornBoundIsReJudgedAtTheSettledBound() {
        var hostingBound: CGSize? = CGSize(width: 1789, height: 875)
        let (mirror, connection) = makeMirror(
            layout: reflow123,
            geometry: calibratedGeometry,
            hostingContentSizeSource: { hostingBound }
        )
        mirror.isVisibleForSizing = true
        // A good reading on record, banked against a settled window.
        mirror.noteContainerSize(pointSize: CGSize(width: 1549, height: 819), scale: 2)
        #expect(mirror.containerSizePt == CGSize(width: 1549, height: 819))
        // Mid-resize tear: the slot already reads its post-resize size while
        // the window still reports a transient smaller frame. Oversized on
        // both axes against that torn bound, so today this reading is lost.
        hostingBound = CGSize(width: 1250, height: 583)
        mirror.noteContainerSize(pointSize: CGSize(width: 1334, height: 593), scale: 2)
        // The window settles larger than the reading; the next pass is the
        // only re-judgment edge — no further geometry callback is coming.
        hostingBound = CGSize(width: 1574, height: 617)
        mirror.performSizingPassNow()
        #expect(mirror.containerSizePt == CGSize(width: 1334, height: 593))
        // (1334 − 3 × (pad 4 + slack 1) − 2 × (divider 1 − cell 8)) / 8 → 166.
        #expect(pushed(connection)?.cols == 166)
    }

    /// The asymmetry the drop guard exists for, pinned so the re-judgment
    /// cannot decay into a clamp: a content-ideal reading that still exceeds
    /// the settled bound carries no truth about the slot and stays dropped —
    /// banking it (or the bound) would resurrect the ~40pt-wide-at-rest
    /// plans the drop path was built to prevent.
    @Test func parkedReadingStillOversizedAtTheSettledBoundStaysDropped() {
        let bound = CGSize(width: 1728, height: 663)
        let (mirror, _) = makeMirror(
            layout: reflow123,
            geometry: calibratedGeometry,
            hostingContentSizeSource: { bound }
        )
        mirror.isVisibleForSizing = true
        mirror.noteContainerSize(pointSize: CGSize(width: 1549, height: 639), scale: 2)
        #expect(mirror.containerSizePt == CGSize(width: 1549, height: 639))
        // An ancestor's content ideal, far beyond any real window.
        mirror.noteContainerSize(pointSize: CGSize(width: 6133, height: 639), scale: 2)
        mirror.performSizingPassNow()
        #expect(mirror.containerSizePt == CGSize(width: 1549, height: 639))
    }

    /// A HIDDEN-tab reading is parked into `pendingContainerSizePt` and
    /// consumed on the next visible pass — but it must be REJECTED, not
    /// clamped, when it exceeds the settled bound. An inflated portal-limbo
    /// reading taken while the tab was unselected carries no truth about the
    /// slot; clamping it to the bound (which overstates the slot by the
    /// window-to-mirror chrome) would overwrite a correct container with a
    /// too-wide one, exactly the reject rule the sibling oversized consumer
    /// already applies.
    @Test func parkedHiddenReadingOverTheBoundIsRejectedNotClamped() {
        let bound = CGSize(width: 1200, height: 800)
        let (mirror, _) = makeMirror(
            layout: reflow123,
            geometry: calibratedGeometry,
            hostingContentSizeSource: { bound }
        )
        // A correct container banked while visible.
        mirror.isVisibleForSizing = true
        mirror.noteContainerSize(pointSize: CGSize(width: 800, height: 620), scale: 2)
        #expect(mirror.containerSizePt == CGSize(width: 800, height: 620))
        // Tab hidden: an inflated portal-limbo reading is PARKED, never banked.
        mirror.isVisibleForSizing = false
        mirror.noteContainerSize(pointSize: CGSize(width: 3000, height: 620), scale: 2)
        #expect(mirror.pendingContainerSizePt == CGSize(width: 3000, height: 620))
        // Revealed: the parked reading exceeds the settled bound, so it is
        // dropped and the last good container survives — NOT clamped to the
        // bound (which would bank 1200 and overstate the slot).
        mirror.isVisibleForSizing = true
        mirror.performSizingPassNow()
        #expect(mirror.containerSizePt == CGSize(width: 800, height: 620))
        #expect(mirror.pendingContainerSizePt == nil)
    }

    /// An oversized FIRST reading clamps to the bound so the initial claim
    /// can still be made — only later readings have a good value to keep.
    @Test func oversizedFirstReadingClampsToTheWindowBound() {
        let bound = CGSize(width: 1200, height: 800)
        let (mirror, _) = makeMirror(
            layout: reflow123,
            geometry: calibratedGeometry,
            hostingContentSizeSource: { bound }
        )
        mirror.isVisibleForSizing = true
        mirror.noteContainerSize(pointSize: CGSize(width: 3000, height: 2000), scale: 2)
        #expect(mirror.containerSizePt == bound)
    }

    /// A degenerate reading (portal mount/teardown 0x0 or 1x1) is never
    /// sizing truth and must not consume the first-measurement slot.
    @Test func degenerateFirstReadingIsSkipped() {
        let (mirror, _) = makeMirror(
            layout: reflow123,
            geometry: calibratedGeometry,
            hostingContentSizeSource: { nil }
        )
        mirror.noteContainerSize(pointSize: CGSize(width: 1, height: 1), scale: 2)
        #expect(mirror.containerSizePt == nil)
    }

    // MARK: grid parity

    /// A pane rendering MORE cells than tmux assigned it is a mismatch just
    /// as a short pane is: the surplus rows/columns hold content tmux never
    /// repaints. The parity check must flag either direction (`!=`, not a
    /// one-sided `<`) so the recovery pass re-applies the pin and clamps the
    /// over-render back down.
    @Test func gridParityFlagsAnOverRenderedPane() {
        let (mirror, _) = makeMirror(layout: reflow123, geometry: calibratedGeometry)
        // Pane 1's tmux assignment is 41×35; the surface rendered 43 columns.
        mirror.lastRenderedGrids[1] = (cols: 43, rows: 35)
        #expect(mirror.gridParityMismatch() != nil)
        // At exactly the assignment there is no mismatch.
        mirror.lastRenderedGrids[1] = (cols: 41, rows: 35)
        #expect(mirror.gridParityMismatch() == nil)
        // A short pane is still a mismatch.
        mirror.lastRenderedGrids[1] = (cols: 39, rows: 35)
        #expect(mirror.gridParityMismatch() != nil)
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
        // Claims charge real chrome AND one rail-slack point per pane —
        // whole-point rails cannot always place a slack-free claim's cells
        // (the tight-container fuzz measures the dropped cell):
        // (800 − 3 × (pad 4 + slack 1) − 2 × (divider 1 − cell 8)) / 8 → 99.
        #expect(pushed(connection)?.cols == 99)
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
        #expect(claim?.cols == 99)
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
        #expect(pushed(connection)?.cols == 99)
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

    // MARK: render ownership: divider drag sessions

    /// Mid-drag the user owns divider geometry: a sizing pass firing while a
    /// drag session is live must hold — not claim, not impose — and the
    /// session end (the deterministic mouseUp signal, delivered through the
    /// controller delegate) must re-arm the pass.
    @Test func sizingPassDefersMidDragAndSessionEndReschedules() {
        let (mirror, connection) = readyMirror(layout: reflow123)
        mirror.isVisibleForSizing = true
        mirror.performSizingPassNow()
        #expect(pushed(connection) != nil)

        mirror.bonsplitController.noteDividerDragSession(true)
        #expect(mirror.bonsplitController.isDividerDragActive)
        mirror.setNeedsSizingPassIgnoringInputs() // views no longer hold the plan
        mirror.performSizingPassNow()
        #expect(!mirror.sizingPassScheduled, "a held pass must not re-arm itself mid-drag")
        #expect(
            mirror.lastCompletedSizingInputs == nil,
            "a pass firing mid-drag must hold, not complete"
        )

        mirror.bonsplitController.noteDividerDragSession(false)
        #expect(!mirror.bonsplitController.isDividerDragActive)
        #expect(mirror.sizingPassScheduled, "session end must reschedule the held pass")
    }

    /// A drag ending while a remote layout apply is in flight cannot run the
    /// divider sync mid-apply, but it must still schedule a sizing pass so a
    /// pass held mid-drag reruns once the apply completes.
    @Test func dragEndDuringRemoteApplySchedulesAPass() {
        let (mirror, _) = readyMirror(layout: reflow123)
        mirror.isVisibleForSizing = true
        mirror.performSizingPassNow()
        mirror.bonsplitController.noteDividerDragSession(true)
        mirror.setNeedsSizingPassIgnoringInputs()
        mirror.performSizingPassNow()
        #expect(!mirror.sizingPassScheduled, "a held pass must not re-arm itself mid-drag")

        mirror.isApplyingRemoteLayout = true
        mirror.splitTabBarDividerDragDidEnd(mirror.bonsplitController)
        mirror.isApplyingRemoteLayout = false
        #expect(
            mirror.sizingPassScheduled,
            "drag end during a remote apply must schedule the pass held for the drag"
        )
        mirror.bonsplitController.noteDividerDragSession(false)
    }

    /// A drag ending during a remote apply must still land the user's final
    /// divider position at tmux. Skipping the send outright (only scheduling a
    /// pass) loses the move: it never reaches tmux and the next sizing pass
    /// re-imposes the pre-drag layout. The send is deferred one runloop turn,
    /// after the apply's synchronous scope clears the flag, and then fires.
    @Test func dragEndDuringRemoteApplyStillSendsTheFinalPosition() throws {
        let two = node(.horizontal([
            node(.pane(1), w: 61, h: 34, x: 0, y: 0),
            node(.pane(2), w: 61, h: 34, x: 62, y: 0),
        ]), w: 123, h: 34, x: 0, y: 0)
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "drag-defer-\(UUID().uuidString)@host"),
            sessionName: "work"
        )
        let pipe = Pipe()
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-drag-defer-test",
            maxPendingBytes: 1 << 16,
            onFailure: {}
        )
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        connection.installStdinWriterForTesting(writer)
        connection.handleMessageForTesting(.enter)
        let geometry = calibratedGeometry
        let mirror = RemoteTmuxWindowMirror(
            windowId: 0,
            panelId: UUID(),
            connection: connection,
            layout: two,
            geometrySource: { geometry },
            hostingContentSizeSource: { CGSize(width: 800, height: 620) },
            makePanel: { _ in nil }
        )
        mirror.isVisibleForSizing = true
        mirror.containerSizePt = CGSize(width: 800, height: 620)
        mirror.containerScale = 2
        mirror.reconcile(layout: two)
        mirror.performSizingPassNow()
        guard case .split(let split) = mirror.bonsplitController.treeSnapshot(),
              let splitId = UUID(uuidString: split.id) else {
            Issue.record("the reconciled tree holds no split")
            return
        }
        // Rebaseline the drag detector off the imposed state (no live views
        // ever mirror the fraction back headlessly).
        _ = mirror.syncChangedDividerPositions()

        // The user drags to a feasible position, then releases WHILE a remote
        // apply is in flight.
        mirror.bonsplitController.noteDividerDragSession(true)
        mirror.bonsplitController.setDividerPosition(0.3, forSplit: splitId)
        let pendingBefore = connection.pendingCommandKindsForTesting.count
        mirror.isApplyingRemoteLayout = true
        mirror.splitTabBarDividerDragDidEnd(mirror.bonsplitController)
        #expect(
            connection.pendingCommandKindsForTesting.count == pendingBefore,
            "the send must not run mid-apply"
        )
        mirror.isApplyingRemoteLayout = false
        mirror.bonsplitController.noteDividerDragSession(false)

        // The deferred flush runs on the next runloop turn and sends the move.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        #expect(
            connection.pendingCommandKindsForTesting.count == pendingBefore + 1,
            "the deferred drag-end must send the user's final divider position"
        )
    }

    // MARK: assigned-grid pin lag (marathon residual)

    /// The input-only settle proof cannot see a pin that fell behind: when
    /// tmux grows a pane's assignment between our claim and settle and the pin
    /// applied against stale cell metrics, the surface renders one row short
    /// and wraps while the sizing inputs read unchanged. The output-parity
    /// re-arm treats a rendered grid behind its assignment as a miss — but
    /// ONLY for a mirror whose panes are actually on screen. A grid lag on an
    /// offscreen mirror (a hidden tab whose views were dismantled, leaving
    /// isVisibleForSizing stale-true) must NOT spin recovery passes against
    /// grids nothing renders: the re-arm is gated on effective visibility.
    @Test func gridLagFlagsAShortRenderButAnOffscreenMirrorDoesNotRearm() {
        let (mirror, _) = readyMirror(layout: reflow123)
        mirror.isVisibleForSizing = true
        mirror.performSizingPassNow()
        #expect(!mirror.sizingPassScheduled)
        #expect(mirror.gridParityMismatch() == nil, "no samples yet is not a lag")

        // tmux assigned pane 1 41×35; the surface still renders one row short.
        mirror.lastRenderedGrids = [1: (41, 34), 2: (40, 35), 3: (40, 35)]
        #expect(mirror.gridParityMismatch() != nil, "a short render is a grid lag")

        // This headless mirror has no on-screen panes, so it is not
        // effectively visible; the lag must not re-arm the pass.
        #expect(!mirror.isEffectivelyVisibleForSizing)
        mirror.rearmIfOutputMissedPlan()
        #expect(
            !mirror.sizingPassScheduled,
            "a lag on a mirror with no on-screen views must not re-arm"
        )
    }

    /// The mirror is settled once every renderable pane renders exactly its
    /// assigned grid — a grid at or beyond the assignment is not a lag (the
    /// pin clips a surplus; only a short render wraps).
    @Test func gridParityIgnoresPanesThatRenderTheirAssignment() {
        let (mirror, _) = readyMirror(layout: reflow123)
        mirror.isVisibleForSizing = true
        mirror.lastRenderedGrids = [1: (41, 35), 2: (40, 35), 3: (40, 35)]
        #expect(mirror.gridParityMismatch() == nil)
    }

    // MARK: drag → tmux cell conversion: grid feasibility

    /// A divider drag converts to a resize-pane span in cells, and tmux can
    /// only move the boundary within what the split's two subtrees hold: the
    /// gap between them (separator column, or the title rows that replace
    /// it) is fixed, so the first subtree caps at the combined span minus
    /// the least the second can shrink to, and floors at its own minimum.
    @Test func feasibleFirstSpanClampsToWhatTmuxCanAssign() throws {
        let metrics = RemoteTmuxNativeLayoutMetrics(
            cellSize: CGSize(width: 8, height: 17),
            surfacePadding: CGSize(width: 4, height: 0),
            tabBarHeight: 30,
            dividerThickness: 1
        )
        func splitHalves(
            _ layout: RemoteTmuxLayoutNode
        ) throws -> (first: RemoteTmuxNativeMeasuredSplitTree, second: RemoteTmuxNativeMeasuredSplitTree, orientation: RemoteTmuxSplitOrientation) {
            let measured = RemoteTmuxNativeMeasuredSplitTree(
                tree: RemoteTmuxNativeSplitTree(layout: layout),
                metrics: metrics
            )
            guard case .split(_, _, _, let orientation, let first, let second) = measured else {
                throw TestSetupError.notASplit
            }
            return (first, second, orientation)
        }

        // Sibling pane already at the one-cell minimum: the cap is the
        // assigned span itself, so an over-drag clamps back to "no change".
        let starved = try splitHalves(node(.horizontal([
            node(.pane(1), w: 97, h: 34, x: 0, y: 0),
            node(.pane(2), w: 1, h: 34, x: 98, y: 0),
        ]), w: 99, h: 34, x: 0, y: 0))
        #expect(RemoteTmuxNativeMeasuredSplitTree.clampToFeasibleFirstSpan(
            98, first: starved.first, second: starved.second, orientation: starved.orientation
        ) == 97)
        #expect(RemoteTmuxNativeMeasuredSplitTree.clampToFeasibleFirstSpan(
            45, first: starved.first, second: starved.second, orientation: starved.orientation
        ) == 45)
        #expect(RemoteTmuxNativeMeasuredSplitTree.clampToFeasibleFirstSpan(
            0, first: starved.first, second: starved.second, orientation: starved.orientation
        ) == 1)

        // Nested same-axis sibling: its minimum is one cell per pane plus
        // the separator column the current assignment holds between them.
        let fanned = try splitHalves(node(.horizontal([
            node(.pane(1), w: 40, h: 34, x: 0, y: 0),
            node(.pane(2), w: 30, h: 34, x: 41, y: 0),
            node(.pane(3), w: 28, h: 34, x: 72, y: 0),
        ]), w: 100, h: 34, x: 0, y: 0))
        // Combined 40 + 59, second's minimum 1 + 1 + 1 separator = 3.
        #expect(RemoteTmuxNativeMeasuredSplitTree.clampToFeasibleFirstSpan(
            1_000, first: fanned.first, second: fanned.second, orientation: fanned.orientation
        ) == 96)

        // Cross-axis sibling: along this axis its panes overlay, so its
        // minimum is the max of theirs — one cell.
        let crossed = try splitHalves(node(.horizontal([
            node(.pane(1), w: 50, h: 34, x: 0, y: 0),
            node(.vertical([
                node(.pane(2), w: 49, h: 20, x: 51, y: 0),
                node(.pane(3), w: 49, h: 13, x: 51, y: 21),
            ]), w: 49, h: 34, x: 51, y: 0),
        ]), w: 100, h: 34, x: 0, y: 0))
        #expect(RemoteTmuxNativeMeasuredSplitTree.clampToFeasibleFirstSpan(
            200, first: crossed.first, second: crossed.second, orientation: crossed.orientation
        ) == 98)

        // Titled stack: adjacent spans, no separator rows — the gap read off
        // the assignment is zero and the cap is combined minus one.
        let titled = try splitHalves(node(.vertical([
            node(.pane(1), w: 80, h: 9, x: 0, y: 0),
            node(.pane(2), w: 80, h: 9, x: 0, y: 9),
        ]), w: 80, h: 18, x: 0, y: 0))
        #expect(RemoteTmuxNativeMeasuredSplitTree.clampToFeasibleFirstSpan(
            25, first: titled.first, second: titled.second, orientation: titled.orientation
        ) == 17)
    }

    private enum TestSetupError: Error { case notASplit }

    /// Desk repro of the parked-divider stall: the sibling pane already sits
    /// at tmux's one-cell minimum, and the user drags further out anyway.
    /// Un-clamped, the walk converts the drag to more cells than tmux can
    /// assign and sends a resize-pane that changes no layout — no layout
    /// reply ever comes, drag-end trusts the reply to settle the divider,
    /// and the split parks off-grid while later passes early-return on
    /// unchanged inputs. Clamped, the request rounds back to the assigned
    /// span: nothing is sent and drag-end re-imposes the plan locally.
    @Test func dragBeyondTheFeasibleGridSendsNothingAndReimposesAtDragEnd() throws {
        let starved = node(.horizontal([
            node(.pane(1), w: 97, h: 34, x: 0, y: 0),
            node(.pane(2), w: 1, h: 34, x: 98, y: 0),
        ]), w: 99, h: 34, x: 0, y: 0)
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "drag-clamp-\(UUID().uuidString)@host"),
            sessionName: "work"
        )
        let pipe = Pipe()
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-drag-clamp-test",
            maxPendingBytes: 1 << 16,
            onFailure: {}
        )
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        connection.installStdinWriterForTesting(writer)
        connection.handleMessageForTesting(.enter)
        let geometry = calibratedGeometry
        let mirror = RemoteTmuxWindowMirror(
            windowId: 0,
            panelId: UUID(),
            connection: connection,
            layout: starved,
            geometrySource: { geometry },
            hostingContentSizeSource: { CGSize(width: 800, height: 620) },
            makePanel: { _ in nil }
        )
        mirror.isVisibleForSizing = true
        mirror.containerSizePt = CGSize(width: 800, height: 620)
        mirror.containerScale = 2
        mirror.reconcile(layout: starved)
        mirror.performSizingPassNow()
        let snapshot = mirror.bonsplitController.treeSnapshot()
        guard case .split(let split) = snapshot, let splitId = UUID(uuidString: split.id) else {
            Issue.record("the reconciled tree holds no split")
            return
        }
        #expect(split.imposedFirstExtent != nil, "the sizing pass must impose the plan")
        // Rebaseline the drag detector from the imposed state: with no live
        // views, no geometry callback ever mirrors the applied fraction back,
        // and an unseeded baseline would route the first drag event to the
        // seed path instead of the conversion under test.
        _ = mirror.syncChangedDividerPositions()

        // Drag past the grid's edge: the session clears the imposition and
        // parks the fraction where tmux has nothing left to assign.
        mirror.bonsplitController.noteDividerDragSession(true)
        mirror.bonsplitController.setDividerPosition(0.995, forSplit: splitId)
        let pendingBefore = connection.pendingCommandKindsForTesting.count
        #expect(
            mirror.syncChangedDividerPositions() == false,
            "an infeasible drag must not count as sent"
        )
        #expect(
            connection.pendingCommandKindsForTesting.count == pendingBefore,
            "no resize-pane may go to tmux for a span it cannot assign"
        )
        mirror.bonsplitController.noteDividerDragSession(false)
        mirror.performSizingPassNow()
        let reimposed = Self.imposedExtents(of: mirror.bonsplitController.treeSnapshot())
        #expect(
            reimposed[split.id] != nil,
            "drag end must re-impose locally when no tmux reply is coming"
        )
        // Rebaseline again: the re-imposition renewed divider ownership and
        // cleared the baseline pending a post-layout callback that headless
        // tests never get.
        _ = mirror.syncChangedDividerPositions()

        // Control: a feasible drag on the same split really sends — the
        // clamp trims only what tmux cannot assign.
        mirror.bonsplitController.noteDividerDragSession(true)
        mirror.bonsplitController.setDividerPosition(0.3, forSplit: splitId)
        #expect(mirror.syncChangedDividerPositions(), "a feasible drag must send")
        #expect(connection.pendingCommandKindsForTesting.count == pendingBefore + 1)
        mirror.bonsplitController.noteDividerDragSession(false)
    }

    /// The first drag after a non-continuing imposition must still reach
    /// tmux. Imposing a changed extent parks the split's baseline at nil,
    /// waiting for a post-layout geometry callback to record the clamped
    /// outcome — but that callback can never arrive: the deferred apply runs
    /// under the programmatic-sync guard (didResize returns before
    /// onGeometryChange fires), and once the user grabs the divider the drag
    /// guard eats every mid-drag callback. Drag end then found no baseline,
    /// seeded it from the post-drag fraction, sent nothing (sent=0 in five
    /// of six live drags), and re-imposed the pre-drag extent — the divider
    /// snapped back in the user's hand. Drag begin is the correct seeding
    /// edge: by then the deferred apply HAS landed, so the model fraction is
    /// exactly the outcome the nil was waiting for.
    @Test func firstDragAfterANonContinuingImpositionStillSendsResizePane() throws {
        let starved = node(.horizontal([
            node(.pane(1), w: 97, h: 34, x: 0, y: 0),
            node(.pane(2), w: 1, h: 34, x: 98, y: 0),
        ]), w: 99, h: 34, x: 0, y: 0)
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "drag-baseline-\(UUID().uuidString)@host"),
            sessionName: "work"
        )
        let pipe = Pipe()
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-drag-baseline-test",
            maxPendingBytes: 1 << 16,
            onFailure: {}
        )
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        connection.installStdinWriterForTesting(writer)
        connection.handleMessageForTesting(.enter)
        let geometry = calibratedGeometry
        let mirror = RemoteTmuxWindowMirror(
            windowId: 0,
            panelId: UUID(),
            connection: connection,
            layout: starved,
            geometrySource: { geometry },
            hostingContentSizeSource: { CGSize(width: 800, height: 620) },
            makePanel: { _ in nil }
        )
        mirror.isVisibleForSizing = true
        mirror.containerSizePt = CGSize(width: 800, height: 620)
        mirror.containerScale = 2
        mirror.reconcile(layout: starved)
        mirror.performSizingPassNow()
        guard case .split(let split) = mirror.bonsplitController.treeSnapshot(),
              let splitId = UUID(uuidString: split.id) else {
            Issue.record("the reconciled tree holds no split")
            return
        }
        let imposedBeforeDrag = try #require(
            split.imposedFirstExtent, "the sizing pass must impose the plan"
        )
        // The live pre-drag state this pins: the imposition parked the
        // baseline at nil and no geometry callback ever reseeded it.
        try #require(
            mirror.lastDividerPositions[splitId] == nil,
            "precondition: the non-continuing imposition must park the baseline at nil"
        )

        // The user's drag, delivered through the same hooks bonsplit drives
        // live: session begin, one committed feasible fraction several cells
        // away (setDividerPosition clears the imposition exactly like a live
        // grab), session end.
        let pendingBefore = connection.pendingCommandKindsForTesting.count
        mirror.bonsplitController.noteDividerDragSession(true)
        _ = mirror.bonsplitController.setDividerPosition(0.3, forSplit: splitId)
        mirror.bonsplitController.noteDividerDragSession(false)

        #expect(
            connection.pendingCommandKindsForTesting.count == pendingBefore + 1,
            "a multi-cell drag must produce exactly one resize-pane request, not be swallowed by a missing baseline"
        )
        // The sent branch defers to tmux's layout reply: no local re-impose
        // of the pre-drag extent may fire from unchanged inputs.
        mirror.performSizingPassNow()
        let reimposed = Self.imposedExtents(
            of: mirror.bonsplitController.treeSnapshot()
        )[split.id]
        #expect(
            reimposed != Double(imposedBeforeDrag),
            "drag end re-imposed the pre-drag extent (\(imposedBeforeDrag)pt) — the snap-back"
        )
    }

    /// A parked oversized reading is the ONE chance to bank a mid-resize
    /// truth (no later callback re-delivers it). A pass that runs during
    /// portal darkness — every hosted view briefly detached or hidden, no
    /// bound anywhere — can judge nothing, so it must leave the reading
    /// parked for the next bounded pass. Consuming it there lost the
    /// re-judgment and the frozen-claim class returned.
    @Test func parkedOversizedReadingSurvivesABoundlessPass() throws {
        let layout = node(.horizontal([
            node(.pane(1), w: 48, h: 35, x: 0, y: 0),
            node(.pane(2), w: 49, h: 35, x: 49, y: 0),
        ]), w: 98, h: 35, x: 0, y: 0)
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "parked-\(UUID().uuidString)@host"),
            sessionName: "work"
        )
        final class BoundBox { var size: CGSize? = CGSize(width: 800, height: 620) }
        let box = BoundBox()
        let geometry = calibratedGeometry
        let mirror = RemoteTmuxWindowMirror(
            windowId: 0,
            panelId: UUID(),
            connection: connection,
            layout: layout,
            geometrySource: { geometry },
            hostingContentSizeSource: { box.size },
            makePanel: { _ in nil }
        )
        mirror.isVisibleForSizing = true
        mirror.containerSizePt = CGSize(width: 800, height: 620)
        mirror.containerScale = 2
        mirror.reconcile(layout: layout)
        mirror.performSizingPassNow()

        // Park: an oversized proposal against the live 800pt bound.
        mirror.noteContainerSize(pointSize: CGSize(width: 1200, height: 900), scale: 2)
        try #require(
            mirror.pendingOversizedReading != nil,
            "precondition: the oversized proposal must park, not bank"
        )

        // Darkness: no bound anywhere, a pass runs.
        box.size = nil
        mirror.performSizingPassNow()
        #expect(
            mirror.pendingOversizedReading != nil,
            "a bound-less pass judges nothing — it must keep the reading parked"
        )

        // Reveal with a bound the reading fits: the parked truth banks.
        box.size = CGSize(width: 1300, height: 950)
        mirror.performSizingPassNow()
        #expect(
            mirror.containerSizePt == CGSize(width: 1200, height: 900),
            "the parked reading must bank at the first bounded pass after the reveal, got \(String(describing: mirror.containerSizePt))"
        )
        withExtendedLifetime(connection) {}
    }

    /// The drag path must apply the same resize-pane routing rule the
    /// control path already tests: tmux resizes the TARGET pane's nearest
    /// split along the axis, so the pane addressed for a split's first
    /// subtree must not sit behind an inner same-axis split. In this nested
    /// shape — a root horizontal whose first child holds an inner
    /// horizontal [11,22] above 33, with 44 as the second child — dragging
    /// the ROOT divider must address %33 (the only first-subtree pane whose
    /// nearest horizontal split IS the root). Addressing
    /// first.paneIDsInOrder.first (%11) makes tmux resize the inner split
    /// instead, or no-op entirely.
    @Test func rootDividerDragInNestedSameAxisShapeTargetsTheRoutablePane() throws {
        let layout = node(.vertical([
            node(.horizontal([
                node(.vertical([
                    node(.pane(11), w: 30, h: 17, x: 0, y: 0),
                    node(.pane(22), w: 30, h: 17, x: 0, y: 18),
                ]), w: 30, h: 35, x: 0, y: 0),
                node(.pane(33), w: 30, h: 35, x: 31, y: 0),
            ]), w: 61, h: 35, x: 0, y: 0),
            node(.pane(44), w: 61, h: 35, x: 0, y: 36),
        ]), w: 61, h: 71, x: 0, y: 0)
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "drag-routing-\(UUID().uuidString)@host"),
            sessionName: "work"
        )
        let pipe = Pipe()
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-drag-routing-test",
            maxPendingBytes: 1 << 16,
            onFailure: {}
        )
        defer { try? pipe.fileHandleForReading.close() }
        connection.installStdinWriterForTesting(writer)
        connection.handleMessageForTesting(.enter)
        let geometry = calibratedGeometry
        let mirror = RemoteTmuxWindowMirror(
            windowId: 0,
            panelId: UUID(),
            connection: connection,
            layout: layout,
            geometrySource: { geometry },
            hostingContentSizeSource: { CGSize(width: 800, height: 1400) },
            makePanel: { _ in nil }
        )
        mirror.isVisibleForSizing = true
        mirror.containerSizePt = CGSize(width: 800, height: 1400)
        mirror.containerScale = 2
        mirror.reconcile(layout: layout)
        mirror.performSizingPassNow()
        guard case .split(let root) = mirror.bonsplitController.treeSnapshot(),
              let rootId = UUID(uuidString: root.id) else {
            Issue.record("the reconciled tree holds no root split")
            return
        }
        // Dragging the root (vertical axis) addresses its FIRST subtree.
        // Inside it, %11 and %22 sit behind the inner vertical split — their
        // nearest vertical split is the inner one, so tmux would resize that
        // instead. %33 is the routable pane: its nearest vertical split is
        // the root itself.
        mirror.bonsplitController.noteDividerDragSession(true)
        _ = mirror.bonsplitController.setDividerPosition(0.75, forSplit: rootId)
        mirror.bonsplitController.noteDividerDragSession(false)

        writer.close()
        let sentText = String(
            bytes: (try? pipe.fileHandleForReading.readToEnd()) ?? Data(),
            encoding: .utf8
        ) ?? ""
        let resizeCommands = sentText
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.contains("resize-pane") }
        #expect(
            resizeCommands.count == 1,
            "the drag must produce exactly one resize-pane, got: \(resizeCommands)"
        )
        #expect(
            resizeCommands.first?.contains("%33") == true,
            "the root drag must address the pane whose nearest same-axis split IS the root (%33), not a pane behind the inner same-axis split (%11): \(resizeCommands)"
        )
        withExtendedLifetime(connection) {}
    }

    /// The session counter is authoritative and survives imbalance: an
    /// unmatched end clamps at zero instead of going negative, so the next
    /// begin still reads as an active drag.
    @Test func dividerDragSessionCounterClampsAtZero() {
        let controller = BonsplitController()
        #expect(!controller.isDividerDragActive)
        controller.noteDividerDragSession(true)
        #expect(controller.isDividerDragActive)
        controller.noteDividerDragSession(false)
        controller.noteDividerDragSession(false) // unmatched end
        #expect(!controller.isDividerDragActive)
        controller.noteDividerDragSession(true)
        #expect(controller.isDividerDragActive, "a clamped counter must not absorb the next begin")
        controller.noteDividerDragSession(false)
    }

}

/// Per-window sizing semantics on the CONNECTION: dedup per window, the
/// reconnect re-pin table, and the old-server fallback.

/// The rect-publication invariant on the CONNECTION: `windowsByID` (what
/// observers read) only ever holds trees whose leaf rects came from a
/// `list-panes` fetch. Layout strings are quarantined and published solely by
/// the generation-guarded rects reply — these tests drive the control-mode
/// message flow end to end through the positional command FIFO.
