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
            scale: 2
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
        #expect(pushed(connection)?.rows == 35) // 1240/34 − 1 title-band row
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
        #expect(claim?.cols == 98)
        mirror.reconcile(layout: reflow123)
        mirror.reconcile(layout: reflow122)
        #expect(pushed(connection)?.cols == claim?.cols)
        #expect(pushed(connection)?.rows == claim?.rows)
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

/// The rect-publication invariant on the CONNECTION: `windowsByID` (what
/// observers read) only ever holds trees whose leaf rects came from a
/// `list-panes` fetch. Layout strings are quarantined and published solely by
/// the generation-guarded rects reply — these tests drive the control-mode
/// message flow end to end through the positional command FIFO.
@MainActor
@Suite struct RemoteTmuxRectPublicationTests {
    /// A connection in attached control mode with a live stdin writer and the
    /// attach block drained, so the FIFO head is the initial `list-windows`.
    private func attachedConnection() -> (
        connection: RemoteTmuxControlConnection,
        writer: RemoteTmuxControlPipeWriter,
        pipe: Pipe
    ) {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"), sessionName: "work"
        )
        let pipe = Pipe()
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-rect-publication-test",
            maxPendingBytes: 1 << 16,
            onFailure: {}
        )
        connection.installStdinWriterForTesting(writer)
        connection.handleMessageForTesting(.enter)
        connection.handleMessageForTesting(
            .commandResult(commandNumber: 0, lines: [], isError: false)
        )
        return (connection, writer, pipe)
    }

    private func reply(
        _ connection: RemoteTmuxControlConnection, lines: [String], isError: Bool = false
    ) {
        connection.handleMessageForTesting(
            .commandResult(commandNumber: 0, lines: lines, isError: isError)
        )
    }

    /// Publishes window @1 as a single 80×24 pane %0 (list-windows reply +
    /// its rects reply), leaving the FIFO empty.
    private func publishSinglePaneWindow(_ connection: RemoteTmuxControlConnection) {
        reply(connection, lines: ["@1 f92f,80x24,0,0,0 f92f,80x24,0,0,0 [] main"])
        reply(connection, lines: ["%0 0 0 80 24 1 off :0 \"ejc3-mac\""])
    }

    private func paneRect(in node: RemoteTmuxLayoutNode, id: Int) -> (x: Int, y: Int, w: Int, h: Int)? {
        switch node.content {
        case let .pane(paneId):
            return paneId == id ? (node.x, node.y, node.width, node.height) : nil
        case let .horizontal(children), let .vertical(children):
            for child in children {
                if let hit = paneRect(in: child, id: id) { return hit }
            }
            return nil
        }
    }

    private func paneRectsFIFOCount(_ connection: RemoteTmuxControlConnection) -> Int {
        connection.pendingCommandKindsForTesting.filter {
            if case .paneRects = $0 { return true }
            return false
        }.count
    }

    @Test func layoutChangeNotifiesOnlyOnItsRectsReply() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        publishSinglePaneWindow(connection)

        var notifies = 0
        let token = connection.addObserver(onTopologyChanged: { notifies += 1 })
        defer { connection.removeObserver(token) }

        connection.handleMessageForTesting(.layoutChange(
            windowId: 1,
            layout: "abcd,120x40,0,0{60x40,0,0,0,59x40,61,0,2}",
            visibleLayout: nil, zoomed: false
        ))
        // The layout string is quarantined: no notify, observers still see the
        // last verified tree, and one rects fetch is on the FIFO.
        #expect(notifies == 0)
        #expect(connection.windowsByID[1]?.layout.width == 80)
        #expect(paneRectsFIFOCount(connection) == 1)

        reply(connection, lines: [
            "%0 0 0 60 40 1 off :0 \"left pane\"",
            "%2 61 0 59 40 0 off :1 \"right\"",
        ])
        #expect(notifies == 1)
        #expect(paneRect(in: connection.windowsByID[1]!.layout, id: 2)! == (61, 0, 59, 40))
        #expect(connection.paneHeaderLabels[0] == "0 \"left pane\"")
        #expect(connection.paneHeaderLabels[2] == "1 \"right\"")
        #expect(connection.windowTitleRowsVisible[1] == false)
    }

    @Test func rectsErrorRetriesOnceThenKeepsLastVerifiedTree() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        publishSinglePaneWindow(connection)

        var notifies = 0
        let token = connection.addObserver(onTopologyChanged: { notifies += 1 })
        defer { connection.removeObserver(token) }

        connection.handleMessageForTesting(.layoutChange(
            windowId: 1,
            layout: "abcd,120x40,0,0{60x40,0,0,0,59x40,61,0,2}",
            visibleLayout: nil, zoomed: false
        ))
        reply(connection, lines: ["can't find window: @1"], isError: true)
        // One retry lands on the FIFO…
        #expect(paneRectsFIFOCount(connection) == 1)
        reply(connection, lines: ["can't find window: @1"], isError: true)
        // …then the pending layout is dropped: observers keep the verified
        // 80×24 tree, never the raw 120×40 string geometry, and no fetch loops.
        #expect(paneRectsFIFOCount(connection) == 0)
        #expect(notifies == 0)
        #expect(connection.windowsByID[1]?.layout.width == 80)
    }

    @Test func initialTopologyPublishesAtomicallyWhenTheLastWindowVerifies() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }

        var notifies = 0
        let token = connection.addObserver(onTopologyChanged: { notifies += 1 })
        defer { connection.removeObserver(token) }

        reply(connection, lines: [
            "@1 f92f,80x24,0,0,0 f92f,80x24,0,0,0 [] one",
            "@2 e5d1,90x30,0,0,5 e5d1,90x30,0,0,5 [] two",
        ])
        notifies = 0 // the list-windows order/name notify is not under test
        let kinds = connection.pendingCommandKindsForTesting
        #expect(kinds.count == 2)
        guard case let .paneRects(firstWindow, _) = kinds[0] else {
            Issue.record("expected a paneRects fetch at the FIFO head, got \(kinds)")
            return
        }
        let firstPane = firstWindow == 1 ? 0 : 5
        let secondPane = firstWindow == 1 ? 5 : 0

        reply(connection, lines: ["%\(firstPane) 0 0 80 24 1 off :zsh"])
        // The FIRST reply publishes nothing: the initial topology flushes
        // atomically, so tab creation order can never follow reply arrival
        // order (which window answers first is a race between round trips).
        #expect(connection.windowsByID.isEmpty)
        #expect(notifies == 0)

        reply(connection, lines: ["%\(secondPane) 0 0 90 30 1 off :vim"])
        // The LAST reply flushes both windows in one publish + one notify.
        #expect(connection.windowsByID[1] != nil)
        #expect(connection.windowsByID[2] != nil)
        #expect(notifies == 1)
    }

    @Test func staleGenerationReplyIsDiscardedAndRefetched() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        publishSinglePaneWindow(connection)

        var notifies = 0
        let token = connection.addObserver(onTopologyChanged: { notifies += 1 })
        defer { connection.removeObserver(token) }

        connection.handleMessageForTesting(.layoutChange(
            windowId: 1,
            layout: "abcd,120x40,0,0{60x40,0,0,0,59x40,61,0,2}",
            visibleLayout: nil, zoomed: false
        ))
        // A newer layout supersedes the in-flight fetch: coalesced (no second
        // send), generation bumped.
        connection.handleMessageForTesting(.layoutChange(
            windowId: 1,
            layout: "abcd,120x40,0,0{80x40,0,0,0,39x40,81,0,2}",
            visibleLayout: nil, zoomed: false
        ))
        #expect(paneRectsFIFOCount(connection) == 1)

        // The reply for the SUPERSEDED fetch is stale: discarded (no publish,
        // no notify) and the owed fetch for the newer generation goes out.
        reply(connection, lines: ["%0 0 0 60 40 1 off :stale", "%2 61 0 59 40 0 off :stale"])
        #expect(notifies == 0)
        #expect(connection.windowsByID[1]?.layout.width == 80)
        #expect(paneRectsFIFOCount(connection) == 1)

        reply(connection, lines: ["%0 0 0 80 40 1 off :wide", "%2 81 0 39 40 0 off :narrow"])
        #expect(notifies == 1)
        #expect(paneRect(in: connection.windowsByID[1]!.layout, id: 2)! == (81, 0, 39, 40))
    }

    @Test func layoutWhileDisconnectedStaysQuarantinedWithoutSending() {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"), sessionName: "work"
        )
        // No writer, not connected: the fetch send fails. The raw tree must
        // stay quarantined (the reconnect's list-windows reseed re-stages it).
        connection.handleMessageForTesting(.layoutChange(
            windowId: 1, layout: "f92f,80x24,0,0,0", visibleLayout: nil, zoomed: false
        ))
        #expect(connection.windowsByID.isEmpty)
        #expect(connection.pendingCommandKindsForTesting.isEmpty)
    }

    @Test func rectsReplySeedsActivePaneAndWindowPaneChangedOverridesIt() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }

        var observed: (windowId: Int, paneId: Int)?
        let token = connection.addObserver(onActivePaneChanged: { observed = ($0, $1) })
        defer { connection.removeObserver(token) }

        reply(connection, lines: ["@1 abcd,120x40,0,0{60x40,0,0,0,59x40,61,0,2} abcd,120x40,0,0{60x40,0,0,0,59x40,61,0,2} [] main"])
        reply(connection, lines: ["%0 0 0 60 40 0 off :left", "%2 61 0 59 40 1 off :right"])
        // The fetch's #{pane_active} seeds the initial active pane…
        #expect(connection.activePaneByWindow[1] == 2)
        #expect(observed! == (1, 2))

        // …and live %window-pane-changed remains the authority afterwards.
        connection.handleMessageForTesting(.windowPaneChanged(windowId: 1, paneId: 0))
        #expect(connection.activePaneByWindow[1] == 0)
        #expect(observed! == (1, 0))
    }

    @Test func mirrorAdoptsRemoteActivePaneAndCopiesLabelsOnReconcile() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        reply(connection, lines: ["@1 abcd,120x40,0,0{60x40,0,0,0,59x40,61,0,2} abcd,120x40,0,0{60x40,0,0,0,59x40,61,0,2} [] main"])
        reply(connection, lines: ["%0 0 1 60 39 1 top :0 \"left\"", "%2 61 1 59 39 0 top :1 \"right\""])

        let published = connection.windowsByID[1]!.layout
        let mirror = RemoteTmuxWindowMirror(
            windowId: 1,
            panelId: UUID(),
            connection: connection,
            layout: published,
            geometrySource: nil,
            makePanel: { _ in nil }
        )
        mirror.reconcile(layout: published)
        // The strip labels ride reconcile from the connection's fetch results,
        // as does whether tmux is drawing header rows (labels render only then).
        #expect(mirror.paneHeaderLabels == [0: "0 \"left\"", 2: "1 \"right\""])
        #expect(mirror.tmuxTitleRowsVisible)
        // On first attach the active-pane event fires BEFORE this mirror
        // exists, so reconcile must adopt the connection's known active pane
        // — otherwise the dot is missing until the next pane switch.
        #expect(mirror.activePaneId == 0)

        // tmux's %window-pane-changed moves the dot (via the session mirror's
        // noteRemoteActivePane call), including before any local focus.
        mirror.noteRemoteActivePane(2)
        #expect(mirror.activePaneId == 2)
    }

    @Test func partialRectsReplyRetriesThenKeepsLastVerifiedTree() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        publishSinglePaneWindow(connection)

        var notifies = 0
        let token = connection.addObserver(onTopologyChanged: { notifies += 1 })
        defer { connection.removeObserver(token) }

        connection.handleMessageForTesting(.layoutChange(
            windowId: 1,
            layout: "abcd,120x40,0,0{60x40,0,0,0,59x40,61,0,2}",
            visibleLayout: nil, zoomed: false
        ))
        // The reply covers only ONE of the tree's two panes: publishing it
        // would smuggle pane %2's raw layout-string geometry into the
        // verified tree (patchingLeafRects leaves unknown leaves untouched).
        reply(connection, lines: ["%0 0 0 60 40 1 off :left"])
        #expect(connection.windowsByID[1]?.layout.width == 80)
        #expect(paneRectsFIFOCount(connection) == 1)
        // A zero-sized rect is a mid-resize artifact, equally unverified.
        reply(connection, lines: ["%0 0 0 60 40 1 off :left", "%2 61 0 0 40 0 off :right"])
        #expect(notifies == 0)
        #expect(connection.windowsByID[1]?.layout.width == 80)
        #expect(paneRectsFIFOCount(connection) == 0)
    }

    @Test func initialBatchDrainsWhenOneWindowErrorsOut() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }

        var notifies = 0
        let token = connection.addObserver(onTopologyChanged: { notifies += 1 })
        defer { connection.removeObserver(token) }

        reply(connection, lines: [
            "@1 f92f,80x24,0,0,0 f92f,80x24,0,0,0 [] one",
            "@2 e5d1,90x30,0,0,5 e5d1,90x30,0,0,5 [] two",
        ])
        notifies = 0
        let kinds = connection.pendingCommandKindsForTesting
        guard case let .paneRects(erroringWindow, _) = kinds.first else {
            Issue.record("expected a paneRects fetch at the FIFO head, got \(kinds)")
            return
        }
        let healthyWindow = erroringWindow == 1 ? 2 : 1
        let healthyPane = healthyWindow == 1 ? 0 : 5
        let healthySize = healthyWindow == 1 ? "80 24" : "90 30"

        // FIFO: [errorer, healthy] -> error consumes head and retries
        // (appends), healthy publishes into staging, the retry errors out and
        // resolves the batch — which must flush the healthy window rather
        // than wait forever on the dead one.
        reply(connection, lines: ["can't find window"], isError: true)
        reply(connection, lines: ["%\(healthyPane) 0 0 \(healthySize) 1 off :sh"])
        #expect(connection.windowsByID.isEmpty)
        reply(connection, lines: ["can't find window"], isError: true)
        #expect(connection.windowsByID[healthyWindow] != nil)
        #expect(connection.windowsByID[erroringWindow] == nil)
        #expect(notifies == 1)
    }

    @Test func styleTokensAreStrippedFromExpandedHeaderFormats() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        // tmux's default pane-border-format marks the active pane with
        // #[reverse]; the dot carries that signal here, so style tokens are
        // dropped and only the text is faithful.
        reply(connection, lines: ["@1 f92f,80x24,0,0,0 f92f,80x24,0,0,0 [] one"])
        reply(connection, lines: ["%0 0 1 80 23 1 top :#[reverse]0#[default] \"ejc3-mac\""])
        #expect(connection.paneHeaderLabels[0] == "0 \"ejc3-mac\"")
        #expect(connection.windowTitleRowsVisible[1] == true)
    }

    @Test func headerSubscriptionKeepsLabelsLiveBetweenLayoutEvents() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        publishSinglePaneWindow(connection)

        var notifies = 0
        let token = connection.addObserver(onTopologyChanged: { notifies += 1 })
        defer { connection.removeObserver(token) }

        // A program retitles its pane with NO layout change: the per-pane
        // subscription pushes the re-expanded format the moment tmux would
        // redraw its own header row.
        connection.handleMessageForTesting(.subscriptionChanged(
            name: "cmux_hdr_0", value: "#[reverse]0#[default] \"vim main.swift\""
        ))
        #expect(connection.paneHeaderLabels[0] == "0 \"vim main.swift\"")
        #expect(notifies == 1)

        // Same value again: no re-notify (equality-guarded).
        connection.handleMessageForTesting(.subscriptionChanged(
            name: "cmux_hdr_0", value: "#[reverse]0#[default] \"vim main.swift\""
        ))
        #expect(notifies == 1)
    }

    @Test func rectsReplyRepairsAStaleActivePane() {
        let (connection, writer, pipe) = attachedConnection()
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        reply(connection, lines: ["@1 abcd,120x40,0,0{60x40,0,0,0,59x40,61,0,2} abcd,120x40,0,0{60x40,0,0,0,59x40,61,0,2} [] main"])
        reply(connection, lines: ["%0 0 0 60 40 1 0 left", "%2 61 0 59 40 0 1 right"])
        #expect(connection.activePaneByWindow[1] == 0)

        var observed: (windowId: Int, paneId: Int)?
        let token = connection.addObserver(onActivePaneChanged: { observed = ($0, $1) })
        defer { connection.removeObserver(token) }

        // An active-pane change with no %window-pane-changed to replay (it
        // happened during an outage): the next fetch's #{pane_active}
        // snapshot must repair the tracked pane, not defer to the stale one.
        connection.handleMessageForTesting(.layoutChange(
            windowId: 1,
            layout: "abcd,120x40,0,0{60x40,0,0,0,59x40,61,0,2}",
            visibleLayout: nil, zoomed: false
        ))
        reply(connection, lines: ["%0 0 0 60 40 0 off :left", "%2 61 0 59 40 1 off :right"])
        #expect(connection.activePaneByWindow[1] == 2)
        #expect(observed! == (1, 2))
    }
}
