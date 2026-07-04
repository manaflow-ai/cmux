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

    /// The calibrated 2× constants (cell 16×34 px, pad 8×0 px, header 24 pt).
    private var calibratedGeometry: RemoteTmuxMirrorGeometry {
        RemoteTmuxMirrorGeometry(
            cellWidthPx: 16, cellHeightPx: 34,
            surfacePadWidthPx: 8, surfacePadHeightPx: 0,
            headerHeightPt: 24, scale: 2
        )
    }

    /// Mirror + retained connection (the mirror holds it weakly). `makePanel`
    /// returns nil (no live surfaces exist here), so the measured render
    /// constants are injected through the mirror's `geometrySource` init
    /// parameter — dependency injection, not a debug seam.
    private func makeMirror(
        layout: RemoteTmuxLayoutNode,
        geometry: RemoteTmuxMirrorGeometry? = nil
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
            makePanel: { _ in nil }
        )
        return (mirror, connection)
    }

    /// A mirror fully readied for sizing: calibrated constants injected + an
    /// 800×620pt container at 2× (px 1600×1240 → f = 98×35 for the 3-pane row).
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
        #expect(pushed(connection)?.cols == 98) // (1600-3·8)/16
        #expect(pushed(connection)?.rows == 35) // (1240-48)/34
        #expect(connection.lastWindowSizes[0] != nil)
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

    @Test func reconcileNeverPushesASizeItself() {
        // Pushing from the reconcile path would react to tmux's own layout
        // events — the direction feed-forward forbids. Only the view's local
        // triggers call updateClientSize().
        let (mirror, connection) = readyMirror(layout: reflow123)
        mirror.reconcile(layout: reflow122)
        mirror.reconcile(layout: node(.horizontal([
            node(.pane(1), w: 61, h: 35), node(.pane(2), w: 61, h: 35),
        ]), w: 123, h: 35))
        #expect(pushed(connection) == nil)
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

    // MARK: render-mode selection

    @Test func framesImposeOnlyWhenTheAssignmentMatchesF() {
        let (mirror, _) = readyMirror(layout: reflow123)
        // Assigned size (123×35) ≠ f for these pixels (98×35): transient mode (nil).
        #expect(mirror.framesForRender(containerPt: CGSize(width: 800, height: 620)) == nil)
        // A tmux layout matching f imposes.
        let matching = node(.horizontal([
            node(.pane(1), w: 32, h: 35), node(.pane(2), w: 32, h: 35), node(.pane(3), w: 32, h: 35),
        ]), w: 98, h: 35)
        mirror.reconcile(layout: matching)
        let frames = mirror.framesForRender(containerPt: CGSize(width: 800, height: 620))
        #expect(frames != nil)
        #expect(frames?.paneFramesPt.count == 3)
    }
}

/// Per-window sizing semantics on the CONNECTION: dedup per window, the
/// reconnect re-pin table, and the old-server fallback.
@MainActor
@Suite struct RemoteTmuxConnectionWindowSizingTests {
    private func makeConnection() -> RemoteTmuxControlConnection {
        RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"), sessionName: "work"
        )
    }

    @Test func windowSizesAreTrackedPerWindow() {
        let connection = makeConnection()
        connection.setWindowSize(windowId: 0, columns: 98, rows: 35)
        connection.setWindowSize(windowId: 7, columns: 60, rows: 20)
        #expect(connection.lastWindowSizes[0]?.0 == 98)
        #expect(connection.lastWindowSizes[7]?.0 == 60)
        connection.setWindowSize(windowId: 0, columns: 98, rows: 35) // dedup no-op
        #expect(connection.lastWindowSizes[0]?.0 == 98)
    }

    @Test func perWindowRejectionFallsBackToSessionWide() {
        let connection = makeConnection()
        connection.setWindowSize(windowId: 0, columns: 98, rows: 35)
        connection.notePerWindowSizeRejected()
        #expect(connection.supportsPerWindowSize == false)
        // Requests keep flowing through the session-wide path (recorded for
        // the reconnect reseed even while not connected).
        connection.setWindowSize(windowId: 3, columns: 80, rows: 24)
        #expect(connection.lastRequestedClientSize?.columns == 80)
    }

    @Test func degenerateSizesAreIgnored() {
        let connection = makeConnection()
        connection.setWindowSize(windowId: 0, columns: 0, rows: 35)
        connection.setWindowSize(windowId: 0, columns: 98, rows: -1)
        #expect(connection.lastWindowSizes[0] == nil)
    }
}
