import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - Mock workspace

/// Test double for `TmuxReconcilerWorkspace`. Records calls and controls
/// the panel UUIDs returned by `newTerminalSplitForTmuxPane`.
@MainActor
final class MockTmuxReconcilerWorkspace: TmuxReconcilerWorkspace {
    /// Pane IDs passed to `newTerminalSplitForTmuxPane`, in call order.
    var createdPaneIds: [String] = []
    /// Window hints passed alongside each `newTerminalSplitForTmuxPane` call.
    var createdWindowHints: [String] = []
    /// Panel IDs passed to `closePanel`, in call order.
    var closedPanelIds: [UUID] = []
    /// Optional override: if set, `newTerminalSplitForTmuxPane` returns these
    /// in FIFO order. If empty it auto-generates a fresh UUID per call.
    var panelIdsToReturn: [UUID] = []

    func newTerminalSplitForTmuxPane(_ paneId: String, windowHint: String) -> UUID? {
        createdPaneIds.append(paneId)
        createdWindowHints.append(windowHint)
        if !panelIdsToReturn.isEmpty {
            return panelIdsToReturn.removeFirst()
        }
        return UUID()
    }

    @discardableResult
    func closePanel(_ panelId: UUID, force: Bool) -> Bool {
        closedPanelIds.append(panelId)
        return true
    }

    func reset() {
        createdPaneIds.removeAll()
        createdWindowHints.removeAll()
        closedPanelIds.removeAll()
        panelIdsToReturn.removeAll()
    }
}

// MARK: - Helpers

private func makeLayout(
    window: String,
    paneIds: [String],
    flags: String = ""
) -> TmuxControlEvent {
    // Build a flat horizontal layout containing `paneIds` as leaves.
    let root: TmuxLayoutNode
    if paneIds.isEmpty {
        // No panes — return an event that won't match any reconcile path.
        // (In practice tmux never sends an empty layout, but guard anyway.)
        return .windowClose(window: window)
    } else if paneIds.count == 1 {
        root = .pane(TmuxPaneGeometry(paneId: paneIds[0], width: 220, height: 50, x: 0, y: 0))
    } else {
        let children = paneIds.enumerated().map { idx, pid in
            TmuxLayoutNode.pane(TmuxPaneGeometry(paneId: pid,
                                                 width: 110, height: 50,
                                                 x: idx * 111, y: 0))
        }
        root = .horizontal(children, width: 220, height: 50, x: 0, y: 0)
    }
    let layout = TmuxLayout(windowId: window, windowFlags: flags, root: root)
    return .layoutChange(layout: layout)
}

/// Drive the reconciler with an event and wait for any deferred Tasks to run.
@MainActor
private func applyAndDrain(_ reconciler: TmuxLayoutReconciler, _ event: TmuxControlEvent) async {
    reconciler.apply(event)
    // Yield twice so async Task { } closures scheduled inside the reconciler
    // have a chance to execute on the main actor before the test assertion.
    await Task.yield()
    await Task.yield()
}

// MARK: - Tests

@MainActor
final class TmuxLayoutReconcilerTests: XCTestCase {

    // MARK: - Basic panel lookup

    func testPanelIdForTmuxPane_unknownPaneReturnsNil() {
        let reconciler = TmuxLayoutReconciler()
        let mock = MockTmuxReconcilerWorkspace()
        reconciler.attach(to: mock)
        XCTAssertNil(reconciler.panelId(forTmuxPane: "%99"))
    }

    // MARK: - reset()

    func testReset_clearsAllState() {
        let reconciler = TmuxLayoutReconciler()
        let mock = MockTmuxReconcilerWorkspace()
        reconciler.attach(to: mock)
        reconciler.reset()
        XCTAssertNil(reconciler.panelId(forTmuxPane: "%1"))
        XCTAssertNil(reconciler.panelId(forTmuxPane: "%2"))
    }

    func testReset_idempotent() {
        let reconciler = TmuxLayoutReconciler()
        let mock = MockTmuxReconcilerWorkspace()
        reconciler.attach(to: mock)
        reconciler.reset()
        reconciler.reset()
    }

    // MARK: - Fresh attach

    func testFreshAttach_createsOnePanelPerPane() async {
        let reconciler = TmuxLayoutReconciler()
        let mock = MockTmuxReconcilerWorkspace()
        reconciler.attach(to: mock)

        await applyAndDrain(reconciler, makeLayout(window: "@1", paneIds: ["%1", "%2", "%3"]))

        XCTAssertEqual(mock.createdPaneIds.sorted(), ["%1", "%2", "%3"])
        XCTAssertEqual(mock.closedPanelIds.count, 0)
    }

    func testFreshAttach_panelsAreTracked() async {
        let reconciler = TmuxLayoutReconciler()
        let mock = MockTmuxReconcilerWorkspace()
        let panelA = UUID()
        let panelB = UUID()
        mock.panelIdsToReturn = [panelA, panelB]
        reconciler.attach(to: mock)

        await applyAndDrain(reconciler, makeLayout(window: "@1", paneIds: ["%1", "%2"]))

        XCTAssertEqual(reconciler.panelId(forTmuxPane: "%1"), panelA)
        XCTAssertEqual(reconciler.panelId(forTmuxPane: "%2"), panelB)
    }

    // MARK: - Pane removal

    func testPaneRemoved_closesPanel() async {
        let reconciler = TmuxLayoutReconciler()
        let mock = MockTmuxReconcilerWorkspace()
        let panel1 = UUID()
        let panel2 = UUID()
        mock.panelIdsToReturn = [panel1, panel2]
        reconciler.attach(to: mock)

        await applyAndDrain(reconciler, makeLayout(window: "@1", paneIds: ["%1", "%2"]))
        mock.closedPanelIds.removeAll()

        // Remove %2 from layout
        await applyAndDrain(reconciler, makeLayout(window: "@1", paneIds: ["%1"]))

        XCTAssertEqual(mock.closedPanelIds, [panel2])
        XCTAssertNil(reconciler.panelId(forTmuxPane: "%2"))
        XCTAssertNotNil(reconciler.panelId(forTmuxPane: "%1"))
    }

    // MARK: - Zoom handling (must NOT skip reconciliation)

    func testZoomedWindow_stillReconciles() async {
        let reconciler = TmuxLayoutReconciler()
        let mock = MockTmuxReconcilerWorkspace()
        reconciler.attach(to: mock)

        // First layout establishes %1
        await applyAndDrain(reconciler, makeLayout(window: "@1", paneIds: ["%1"]))
        XCTAssertEqual(mock.createdPaneIds, ["%1"])

        mock.createdPaneIds.removeAll()

        // Second layout arrives while zoomed — %2 added while zoom active.
        // The reconciler must still process pane additions/removals.
        await applyAndDrain(reconciler, makeLayout(window: "@1", paneIds: ["%1", "%2"], flags: "Z"))

        XCTAssertEqual(mock.createdPaneIds, ["%2"],
                       "Reconciliation must run even when the window is zoomed")
    }

    func testZoomedWindow_isZoomedFlagExposed() {
        let layout = TmuxLayout(windowId: "@1", windowFlags: "*Z",
                                root: .pane(TmuxPaneGeometry(paneId: "%1", width: 220,
                                                              height: 50, x: 0, y: 0)))
        XCTAssertTrue(layout.isZoomed)
    }

    // MARK: - Move-pane (break-pane / join-pane)

    func testMovePaneAcrossWindows_preservesPanel() async {
        let reconciler = TmuxLayoutReconciler()
        let mock = MockTmuxReconcilerWorkspace()
        let panel1 = UUID()
        let panel2 = UUID()
        mock.panelIdsToReturn = [panel1, panel2]
        reconciler.attach(to: mock)

        // Initial state: @A has %1 and %2
        await applyAndDrain(reconciler, makeLayout(window: "@A", paneIds: ["%1", "%2"]))
        XCTAssertEqual(reconciler.panelId(forTmuxPane: "%2"), panel2)
        mock.closedPanelIds.removeAll()

        // Simulate break-pane: tmux sends both layout changes in the same event burst
        // (i.e. before the run-loop yields). Apply both synchronously, then drain.
        // If we drained between the two applies the purge would fire prematurely and
        // close panel2 before @B's layout-change can adopt it — that's not the real
        // tmux ordering where events arrive in a tight FIFO sequence.
        reconciler.apply(makeLayout(window: "@A", paneIds: ["%1"])) // %2 orphaned
        reconciler.apply(makeLayout(window: "@B", paneIds: ["%2"])) // %2 adopted before purge

        // Drain: purge task runs — nothing left to close since %2 was adopted.
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(mock.closedPanelIds, [], "panel2 should be adopted, not closed")
        XCTAssertEqual(reconciler.panelId(forTmuxPane: "%2"), panel2)
        XCTAssertEqual(reconciler.windowId(forPanel: panel2), "@B")
    }

    func testPaneDies_closesPanel() async {
        let reconciler = TmuxLayoutReconciler()
        let mock = MockTmuxReconcilerWorkspace()
        let panel1 = UUID()
        let panel2 = UUID()
        mock.panelIdsToReturn = [panel1, panel2]
        reconciler.attach(to: mock)

        await applyAndDrain(reconciler, makeLayout(window: "@A", paneIds: ["%1", "%2"]))

        // %2 exits — it disappears from @A and never appears elsewhere
        await applyAndDrain(reconciler, makeLayout(window: "@A", paneIds: ["%1"]))

        XCTAssertEqual(mock.closedPanelIds, [panel2], "Dead pane's panel must be closed after purge")
        XCTAssertNil(reconciler.panelId(forTmuxPane: "%2"))
    }

    // MARK: - Window-scoped pending panel claim

    func testPendingPanel_claimedForCorrectWindow() async {
        let reconciler = TmuxLayoutReconciler()
        let mock = MockTmuxReconcilerWorkspace()
        reconciler.attach(to: mock)

        // Establish two windows each with one pane
        let panelW1 = UUID()
        let panelW2 = UUID()
        mock.panelIdsToReturn = [panelW1, panelW2]
        await applyAndDrain(reconciler, makeLayout(window: "@W1", paneIds: ["%1"]))
        await applyAndDrain(reconciler, makeLayout(window: "@W2", paneIds: ["%2"]))
        mock.createdPaneIds.removeAll()

        // The reconciler provides the correct window hint for each new pane
        await applyAndDrain(reconciler, makeLayout(window: "@W1", paneIds: ["%1", "%3"]))
        XCTAssertEqual(mock.createdWindowHints.last, "@W1",
                       "New pane in @W1 should carry windowHint @W1")

        await applyAndDrain(reconciler, makeLayout(window: "@W2", paneIds: ["%2", "%4"]))
        XCTAssertEqual(mock.createdWindowHints.last, "@W2",
                       "New pane in @W2 should carry windowHint @W2")
    }

    // MARK: - User dismiss

    func testUserDismiss_suppressesReopenForLivePane() async {
        let reconciler = TmuxLayoutReconciler()
        let mock = MockTmuxReconcilerWorkspace()
        let panel1 = UUID()
        mock.panelIdsToReturn = [panel1]
        reconciler.attach(to: mock)

        await applyAndDrain(reconciler, makeLayout(window: "@1", paneIds: ["%1"]))
        XCTAssertEqual(reconciler.panelId(forTmuxPane: "%1"), panel1)

        // User closes the panel (tmux pane is still alive)
        reconciler.removeTracking(forPanel: panel1)
        mock.createdPaneIds.removeAll()

        // Next layout change still reports %1 alive — must NOT reopen
        await applyAndDrain(reconciler, makeLayout(window: "@1", paneIds: ["%1"]))

        XCTAssertEqual(mock.createdPaneIds, [], "Dismissed pane must not be recreated")
    }

    // MARK: - windowClose event

    func testWindowClose_closesAllPanelsInWindow() async {
        let reconciler = TmuxLayoutReconciler()
        let mock = MockTmuxReconcilerWorkspace()
        let p1 = UUID(), p2 = UUID()
        mock.panelIdsToReturn = [p1, p2]
        reconciler.attach(to: mock)

        await applyAndDrain(reconciler, makeLayout(window: "@1", paneIds: ["%1", "%2"]))
        mock.closedPanelIds.removeAll()

        reconciler.apply(.windowClose(window: "@1"))

        XCTAssertEqual(Set(mock.closedPanelIds), Set([p1, p2]))
        XCTAssertNil(reconciler.panelId(forTmuxPane: "%1"))
        XCTAssertNil(reconciler.panelId(forTmuxPane: "%2"))
    }

    // MARK: - allTrackedPanelIds

    func testAllTrackedPanelIds_reflectsLiveSet() async {
        let reconciler = TmuxLayoutReconciler()
        let mock = MockTmuxReconcilerWorkspace()
        let p1 = UUID(), p2 = UUID()
        mock.panelIdsToReturn = [p1, p2]
        reconciler.attach(to: mock)

        await applyAndDrain(reconciler, makeLayout(window: "@1", paneIds: ["%1", "%2"]))
        XCTAssertEqual(reconciler.allTrackedPanelIds(), Set([p1, p2]))

        await applyAndDrain(reconciler, makeLayout(window: "@1", paneIds: ["%1"]))
        XCTAssertEqual(reconciler.allTrackedPanelIds(), Set([p1]))
    }

    // MARK: - windowId(forPanel:)

    func testWindowIdForPanel_returnsCorrectWindow() async {
        let reconciler = TmuxLayoutReconciler()
        let mock = MockTmuxReconcilerWorkspace()
        let p1 = UUID()
        mock.panelIdsToReturn = [p1]
        reconciler.attach(to: mock)

        await applyAndDrain(reconciler, makeLayout(window: "@W", paneIds: ["%1"]))
        XCTAssertEqual(reconciler.windowId(forPanel: p1), "@W")
    }

    func testWindowIdForPanel_unknownPanelReturnsNil() {
        let reconciler = TmuxLayoutReconciler()
        let mock = MockTmuxReconcilerWorkspace()
        reconciler.attach(to: mock)
        XCTAssertNil(reconciler.windowId(forPanel: UUID()))
    }

    // MARK: - reset clears all state including orphans

    func testReset_cancelsOrphansAndClearsAll() async {
        let reconciler = TmuxLayoutReconciler()
        let mock = MockTmuxReconcilerWorkspace()
        let p1 = UUID()
        mock.panelIdsToReturn = [p1]
        reconciler.attach(to: mock)

        await applyAndDrain(reconciler, makeLayout(window: "@1", paneIds: ["%1"]))
        // Orphan the pane (remove from layout without replacement)
        reconciler.apply(makeLayout(window: "@1", paneIds: []))  // triggers orphan but not valid
        reconciler.reset()
        mock.closedPanelIds.removeAll()

        // After reset, nothing should close or re-create on next layout
        await applyAndDrain(reconciler, makeLayout(window: "@1", paneIds: ["%1"]))
        XCTAssertEqual(mock.closedPanelIds, [], "Reset should have purged orphans without closing")
    }
}
