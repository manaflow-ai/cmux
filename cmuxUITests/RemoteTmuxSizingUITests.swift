import XCTest
import Foundation
import Darwin

/// End-to-end gate for remote-tmux mirror sizing, against a REAL tmux server.
///
/// Sizing spans a full round trip (container pixels → pushed client size →
/// tmux's per-pane assignment → imposed frames → rendered grids), and defects
/// live in the interactions between those stages — invisible to unit tests of
/// any single stage. This suite drives the real loop end to end and asserts
/// the two invariants that define "settled":
///
///   1. STABILITY: after any disturbance, the client size converges to a
///      single value and stays there (no oscillation, no churn).
///   2. COHERENCE: client == every window's size, and a split window's
///      top-row pane widths + one separator per gap == the window width.
///
/// Hermetic by construction: a throwaway tmux server runs on an isolated
/// socket directory, and the app is launched with
/// `CMUX_REMOTE_TMUX_SSH_FOR_TESTING` pointing at a shim that strips the ssh
/// framing and execs the remote command locally — the full mirror stack runs
/// with no sshd and no network. Skips when no tmux binary is present (CI
/// installs one in the e2e workflow's dependency step).
final class RemoteTmuxSizingUITests: XCTestCase {
    var socketPath = ""
    var diagnosticsPath = ""
    var launchTag = ""
    var tmuxTmpDir = ""
    var tmuxBin: String?
    let sessionName = "sizing"
    /// The checked-in ssh shim the app execs (repo path — the unsandboxed app
    /// reaches it; the sandboxed runner cannot write one to a shared dir).
    var shimPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // cmuxUITests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("scripts/remote-tmux-e2e-ssh-shim.sh").path
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        // In the RUNNER's container: the sandboxed test runner can connect()
        // to a socket in its own container but not to one in /tmp, while the
        // unsandboxed app can bind anywhere it can write. Kept short for the
        // ~104-byte unix socket path cap.
        socketPath = "\(NSHomeDirectory())/s\(UUID().uuidString.prefix(4)).sock"
        diagnosticsPath = "/tmp/cmux-ui-test-sizing-\(UUID().uuidString).json"
        launchTag = "ui-tests-sizing-\(UUID().uuidString.prefix(8))"
        // Short: tmux appends "/tmux-<uid>/default" and the unix socket path
        // caps at ~104 bytes. The APP creates this dir (via test_exec), not
        // the runner. FIXED, not per-run: teardown can't run when a test
        // wedges (kill-server rides the app socket, and a wedged app is
        // exactly what doesn't answer), so a unique dir per run leaks one
        // tmux server per wedged run — dozens accumulated once and drove the
        // host's load average into the hundreds. With a fixed
        // dir the NEXT run's session builder reaps whatever the last run
        // left behind.
        tmuxTmpDir = "/tmp/ct-sizing"
        tmuxBin = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    override func tearDown() {
        _ = tmux(["kill-server"])
        // That kill rides the APP's socket, and a wedged app is exactly what
        // can't answer — leaving the lab server running until
        // the NEXT run's setup reaps it (stacked across a few dead runs,
        // that load is what times out this suite's own 10s socket calls).
        // Also kill the lab server directly, scoped to its socket dir so a
        // developer's own tmux servers are untouchable by construction.
        // Best-effort: the sandboxed runner may not reach /tmp sockets; a
        // failure here just falls back to the setup-time reap.
        if let tmuxBin {
            let reap = Process()
            reap.executableURL = URL(fileURLWithPath: tmuxBin)
            reap.arguments = ["kill-server"]
            var env = ProcessInfo.processInfo.environment
            env["TMUX_TMPDIR"] = tmuxTmpDir
            env.removeValue(forKey: "TMUX")
            reap.environment = env
            try? reap.run()
            reap.waitUntilExit()
        }
        try? FileManager.default.removeItem(atPath: socketPath)
        super.tearDown()
    }

    // MARK: scenarios

    /// Attach a session holding a 3-pane split window plus a single-pane
    /// window; the client must settle to one stable, coherent size.
    func testAttachSettlesStableAndCoherent() throws {
        try requireTmux()
        let app = launchApp()
        defer { app.terminate() }
        try buildLabSession()
        attachSession()
        // Pin the mirror window to a known size: the app restores persisted
        // window geometry, so without this the scenario runs at whatever
        // frame an earlier app run left behind — small enough, and the pane
        // surfaces can never produce the measured constants sizing needs.
        setMirrorWindowSize(CGSize(width: 1000, height: 700))
        try assertSettles(selectedWindow: 0, within: 10, context: "after attach")
    }

    /// The deterministic exploratory sweep: EVERY layout shape, at EVERY
    /// width in the sweep, must render every pane per the sizing contract.
    /// Shape coverage is the point — sizing defects are shape-dependent (a
    /// quantization-boundary miss lands on a nested column while even
    /// columns sit clean), so a one-shape suite gives false green.
    ///
    /// Window sizes and tab selection are driven over the control socket
    /// (`remote.tmux.test_set_frame`, `surface.focus`), not with XCUITest
    /// mouse gestures: an AX click/drag routes through whatever else is on
    /// the desktop, and any overlapping third-party window triggers
    /// XCUITest's permission-dialog scan (which crashes outright on elements
    /// with numeric accessibility values). `NSWindow.setFrame` exercises the
    /// same AppKit resize path a drag drives, and `surface.focus` flips the
    /// same tab-visibility state a click does.
    func testEveryShapeRendersExactlyAtEveryWidth() throws {
        try requireTmux()
        let app = launchApp()
        defer { app.terminate() }
        try buildShapeZoo()
        attachSession()

        // The sweep sizes. 1000×700 first is also the surface warm-up round:
        // every shape settles once before the resizes, so later rounds
        // measure resizing rather than cold surface creation (which on a
        // loaded CI runner can exceed any reasonable settle window). All
        // widths sit ABOVE the workspace's minimum content width (~990 with
        // the zoo's eight tabs): AppKit enforces the content minimum as a
        // required constraint, so a request below it applies clamped — a
        // size no user window can occupy, and one the `setMirrorWindowSize`
        // exact-apply assertion would rightly reject.
        for size in [CGSize(width: 1000, height: 700),
                     CGSize(width: 1032, height: 700),
                     CGSize(width: 1048, height: 700),
                     CGSize(width: 1080, height: 700)] {
            setMirrorWindowSize(size)
            for name in Self.shapeNames {
                guard let id = windowId(named: name) else {
                    XCTFail("no tmux window named \(name)")
                    continue
                }
                XCTAssertTrue(selectTab(named: name), "could not select tab \(name)")
                try assertSettles(
                    selectedWindow: id, within: 10,
                    context: "shape \(name) at width \(Int(size.width))"
                )
            }
            XCTAssertTrue(selectTab(named: "even3"), "could not return to even3")
        }
    }

    /// Resizing the app window (the local trigger) must re-converge at each
    /// width — the sweep that exposes resize feedback loops.
    func testWindowResizeSweepConvergesAtEachWidth() throws {
        try requireTmux()
        let app = launchApp()
        defer { app.terminate() }
        try buildLabSession()
        attachSession()
        setMirrorWindowSize(CGSize(width: 1000, height: 700))
        try assertSettles(selectedWindow: 0, within: 10, context: "before sweep")

        // End-to-end proof each resize really happened: a wider window must
        // settle to strictly more pushed columns (1032 < 1048 < 1080 spans
        // several cell widths). Guards against a resize path that silently
        // stops applying, which would run every round at one size. Widths sit
        // above the workspace minimum content width — see
        // testEveryShapeRendersExactlyAtEveryWidth for why.
        var previousCols: Int?
        for width in [1032.0, 1048.0, 1080.0] {
            setMirrorWindowSize(CGSize(width: width, height: 700))
            try assertSettles(selectedWindow: 0, within: 5, context: "at width \(Int(width))")
            try assertRatiosPreserved(context: "at width \(Int(width))")
            let cols = try XCTUnwrap(pushedCols(window: 0), "no pushed size at width \(Int(width))")
            if let previous = previousCols {
                XCTAssertGreaterThan(
                    cols, previous,
                    "pushed cols did not grow with the window (\(previous) -> \(cols) at \(Int(width))pt)"
                )
            }
            previousCols = cols
        }
    }

    /// `pane-border-status top`: tmux carves a title row above every pane
    /// but publishes the PRE-title tree in layout strings, so the mirror
    /// must place panes from the real rects (`list-panes`) instead. The
    /// exact-render oracle then asserts against reality: every pane renders
    /// the grid tmux actually displays, title rows and all.
    func testPaneBorderStatusTitleRowsSettle() throws {
        try requireTmux()
        let app = launchApp()
        defer { app.terminate() }
        try buildLabSession()
        _ = tmux(["set", "-w", "-t", "\(sessionName):0", "pane-border-status", "top"])
        attachSession()
        setMirrorWindowSize(CGSize(width: 1000, height: 700))
        try assertSettles(selectedWindow: 0, within: 10, context: "with pane-border-status top")
    }

    /// The growth-spiral trigger, deterministically: shrink the window while
    /// a wide imposed plan is live, so the imposed render frame momentarily
    /// exceeds the region — the state the wedge needed (the fuzz hit it by
    /// resizing under churn). After each shrink the suite requires BOTH
    /// oracles: the grid oracle (sizing settles to exact renders — this leg
    /// also covers re-imposition after a container change) and the frame
    /// oracle (the window's root content and the mirror's whole ancestor
    /// chain hold the window's width). The live wedge kept every claim sane
    /// while the content view marched a step wider per layout pass, so only
    /// the frame oracle can fail on that class.
    func testShrinkUnderImposedPlanSettlesWithRootContentAtWindowWidth() throws {
        try requireTmux()
        let app = launchApp()
        defer { app.terminate() }
        try buildLabSession()
        attachSession()
        setMirrorWindowSize(CGSize(width: 1080, height: 700))
        try assertSettles(selectedWindow: 0, within: 10, context: "at 1080 before shrink")
        try assertRootContentTracksWindow(context: "at 1080 before shrink")

        // Two shrinks: each leaves the banked container and the imposed
        // render frame stale-wide for at least one pass. Widths stay above
        // the workspace minimum content width so the exact-apply assertion
        // in setMirrorWindowSize holds (see the sweep scenarios).
        for width in [1048.0, 1000.0] {
            setMirrorWindowSize(CGSize(width: width, height: 700))
            try assertSettles(selectedWindow: 0, within: 5, context: "after shrink to \(Int(width))")
            try assertRootContentTracksWindow(context: "after shrink to \(Int(width))")
            try assertClaimsWithinWindowCeiling(context: "after shrink to \(Int(width))")
        }
    }

    /// The hidden-mirror lifecycle: attach while another workspace holds the
    /// front, resize the window while the mirror is hidden, then reveal it.
    /// A mirror born hidden takes its first container reading with no
    /// visible window to vouch for it, and the resize while hidden
    /// guarantees whatever it banked at birth is stale by the time it is
    /// shown. The fuzz wedge lived in this lifecycle: a reading deferred for
    /// lack of a window was dropped, no later callback came, and the mirror
    /// rendered a stale-wide tree forever with every claim looking sane.
    /// The wedge's trigger was a race (the reading landing a beat before
    /// the probe joined the window), so this deterministic pass pins the
    /// lifecycle contract rather than that ordering: whatever the first
    /// reading raced against, the reveal must converge to an exact settle —
    /// grids, frames, and claims all judged. The launch workspace plays the
    /// "other tab": `activate: false` mirrors the host behind it, so no
    /// second workspace needs creating.
    func testHiddenAttachThenRevealSettlesAfterResizeWhileHidden() throws {
        try requireTmux()
        let app = launchApp()
        defer { app.terminate() }
        try buildLabSession()
        let workspaceId = try XCTUnwrap(
            attachSession(activate: false), "hidden attach reported no mirror workspace"
        )
        // Churn while hidden: one real window resize, so any size the hidden
        // mirror banked at birth is stale by the time it is shown.
        setMirrorWindowSize(CGSize(width: 1000, height: 700))
        XCTAssertTrue(selectWorkspace(id: workspaceId), "could not select the mirror workspace")
        try assertSettles(selectedWindow: 0, within: 10, context: "after reveal")
        try assertRootContentTracksWindow(context: "after reveal")
        try assertClaimsWithinWindowCeiling(context: "after reveal")
    }

    /// The render-ownership liveness rule, end to end: geometry knocked off
    /// the imposed plan with NO sizing input change must re-converge. The
    /// perturb verb clears the visible mirror's root imposition and moves
    /// the divider (the deterministic stand-in for an apply that terminated
    /// off-target — a parked divider, an expired retry budget), and drops
    /// the divider baseline so no `resize-pane` reaches tmux: no layout
    /// echo, no input change, so only the transaction's outcome-parity
    /// re-arm can put the views back on the plan. Before that edge existed,
    /// this state held for 50+ seconds on the live fuzz with every trigger
    /// reporting settled.
    func testDividerPerturbedOffPlanReconvergesWithoutInputChange() throws {
        try requireTmux()
        let app = launchApp()
        defer { app.terminate() }
        try buildLabSession()
        attachSession()
        setMirrorWindowSize(CGSize(width: 1000, height: 700))
        try assertSettles(selectedWindow: 0, within: 10, context: "before divider perturbation")

        let response = socketJSON(method: "remote.tmux.test_perturb_divider", params: [
            "window": 0,
            "position": 0.8,
        ])
        XCTAssertEqual(response?["ok"] as? Bool, true, "test_perturb_divider failed: \(response ?? [:])")
        XCTAssertEqual(response?["moved"] as? Bool, true, "divider did not move: \(response ?? [:])")
        try assertSettles(selectedWindow: 0, within: 5, context: "after divider perturbation")
    }

    /// A window MOVE is geometry-only: no sizing input changes, so it must
    /// do ZERO sizing work. Guards the window-move echo storm, where the
    /// portal's full-pass signature fingerprinted the window frame WITH
    /// origin — the sole terminator of the sync echo chain — so during a
    /// titlebar drag every echoed sync escalated to a full layout pass whose
    /// notifications scheduled the next. Note the approximation: an
    /// origin-only `setFrame` moves the window through the same frame-change
    /// path a drag lands on, but does not run AppKit's interactive drag
    /// tracking loop, so this guard is necessary rather than sufficient.
    func testOriginOnlyMovesDoZeroSizingWork() throws {
        try requireTmux()
        let app = launchApp()
        defer { app.terminate() }
        try buildLabSession()
        attachSession()
        setMirrorWindowSize(CGSize(width: 1000, height: 700))
        try assertSettles(selectedWindow: 0, within: 10, context: "before origin-only moves")

        let before = try XCTUnwrap(sizingCounters(), "sizing counters unavailable before moves")
        for move in 0..<50 {
            setMirrorWindowOrigin(x: Double(20 + (move % 2) * 24))
        }
        let after = try XCTUnwrap(sizingCounters(), "sizing counters unavailable after moves")

        XCTAssertEqual(
            after.pass - before.pass, 0,
            "origin-only moves ran \(after.pass - before.pass) sizing passes — a move is not a sizing input"
        )
        XCTAssertEqual(
            after.rearm - before.rearm, 0,
            "origin-only moves spent \(after.rearm - before.rearm) parity re-arms — geometry never left the plan"
        )
        XCTAssertEqual(
            after.hierarchySync - before.hierarchySync, 0,
            "origin-only moves escalated to \(after.hierarchySync - before.hierarchySync) full hierarchy syncs — "
                + "the geometry signature is origin-sensitive again"
        )
    }

    /// A geometry-only layout change NOT caused by the app — a co-attached
    /// client's `resize-pane` — must heal (bounded correction), not stick
    /// mismatched and not oscillate.
    func testForeignResizePaneHealsAndHolds() throws {
        try requireTmux()
        let app = launchApp()
        defer { app.terminate() }
        try buildLabSession()
        attachSession()
        setMirrorWindowSize(CGSize(width: 1000, height: 700))
        try assertSettles(selectedWindow: 0, within: 10, context: "before foreign resize")

        let panes = try splitWindowPaneIds()
        _ = tmux(["resize-pane", "-t", "\(sessionName):@0.\(panes[0])", "-x", "13"])
        try assertSettles(selectedWindow: 0, within: 5, context: "after foreign resize-pane")
    }

    // MARK: lab state

    /// The cmux window UUID hosting the mirror (from `remote.tmux.mirror`).
    var mirrorWindowId: String?

    /// The last tmux invocation failure (spawn error or nonzero exit +
    /// stderr) — surfaced in assertion messages so a lab-setup failure names
    /// its cause instead of a bare XCTAssertNotNil.
    var lastTmuxFailure: String?

    // MARK: socket plumbing (per-file copy, matching the target's pattern)

    var lastSocketFailure: String?

}
