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
    private var socketPath = ""
    private var diagnosticsPath = ""
    private var launchTag = ""
    private var tmuxTmpDir = ""
    private var tmuxBin: String?
    private let sessionName = "sizing"
    /// The checked-in ssh shim the app execs (repo path — the unsandboxed app
    /// reaches it; the sandboxed runner cannot write one to a shared dir).
    private var shimPath: String {
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
        // the runner.
        tmuxTmpDir = "/tmp/ct\(UUID().uuidString.prefix(6))"
        tmuxBin = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    override func tearDown() {
        _ = tmux(["kill-server"])
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
        try assertSettles(selectedWindow: 0, within: 15, context: "after attach")
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
        // loaded CI runner can exceed any reasonable settle window).
        for size in [CGSize(width: 1000, height: 700),
                     CGSize(width: 860, height: 700),
                     CGSize(width: 920, height: 700),
                     CGSize(width: 965, height: 700)] {
            setMirrorWindowSize(size)
            for name in Self.shapeNames {
                guard let id = windowId(named: name) else {
                    XCTFail("no tmux window named \(name)")
                    continue
                }
                XCTAssertTrue(selectTab(named: name), "could not select tab \(name)")
                try assertSettles(
                    selectedWindow: id, within: 25,
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
        try assertSettles(selectedWindow: 0, within: 15, context: "before sweep")

        // End-to-end proof each resize really happened: a wider window must
        // settle to strictly more pushed columns (860 < 920 < 965 spans
        // several cell widths). Guards against a resize path that silently
        // stops applying, which would run every round at one size.
        var previousCols: Int?
        for width in [860.0, 920.0, 965.0] {
            setMirrorWindowSize(CGSize(width: width, height: 700))
            try assertSettles(selectedWindow: 0, within: 10, context: "at width \(Int(width))")
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

    /// A geometry-only layout change NOT caused by the app — a co-attached
    /// client's `resize-pane` — must heal (bounded correction), not stick
    /// mismatched and not oscillate.
    func testForeignResizePaneHealsAndHolds() throws {
        try requireTmux()
        let app = launchApp()
        defer { app.terminate() }
        try buildLabSession()
        attachSession()
        try assertSettles(selectedWindow: 0, within: 15, context: "before foreign resize")

        let panes = try splitWindowPaneIds()
        _ = tmux(["resize-pane", "-t", "\(sessionName):@0.\(panes[0])", "-x", "13"])
        try assertSettles(selectedWindow: 0, within: 10, context: "after foreign resize-pane")
    }


    /// Pane RATIOS are user state: the lab window starts even-horizontal, and
    /// no amount of window resizing may let the sizing machinery redistribute
    /// columns between panes beyond remainder scatter. Catches any sizing
    /// path that writes per-pane geometry from transient mid-resize state
    /// (panes walked toward slivers) — invisible to stability/coherence
    /// checks, which pass at ANY stable ratio.
    private func assertRatiosPreserved(context: String) throws {
        let out = try XCTUnwrap(tmux(["list-panes", "-t", "\(sessionName):@0", "-F", "#{pane_width}"]))
        let widths = out.split(separator: "\n").compactMap { Int($0) }
        XCTAssertEqual(widths.count, 3, "expected 3 panes \(context)")
        let spread = (widths.max() ?? 0) - (widths.min() ?? 0)
        XCTAssertLessThanOrEqual(
            spread, 4,
            "pane ratios drifted \(context): \(widths) — sizing must not mutate user layout"
        )
    }

    // MARK: settle oracle

    /// Polls until the SELECTED window is settled:
    ///   1. STABILITY — its tmux size holds across 8 consecutive samples.
    ///   2. COHERENCE — its top-row pane widths + one separator per gap equal
    ///      its window width (tmux's own layout arithmetic).
    ///   3. EXACT RENDER — via `remote.tmux.pane_grids`, every pane of the
    ///      selected window renders exactly the cells tmux assigned it (the
    ///      invariant tmux queries cannot see; this is what fails when
    ///      frame/grid calibration drifts), and every OTHER mirrored window
    ///      has claimed its per-window size (base == pushed).
    /// Sizes are PER WINDOW; the session-wide client size is deliberately
    /// never written, so no check compares against it.
    private func assertSettles(
        selectedWindow: Int, within timeout: TimeInterval, context: String
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastFailure = "no samples"
        while Date() < deadline {
            if let failure = settleFailure(selectedWindow: selectedWindow) {
                lastFailure = failure
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            return
        }
        XCTFail("Sizing never settled \(context): \(lastFailure)")
    }

    private func settleFailure(selectedWindow: Int) -> String? {
        var samples: [String] = []
        for _ in 0..<8 {
            guard let size = tmux(["display-message", "-p", "-t", "\(sessionName):@\(selectedWindow)",
                                   "#{window_width}x#{window_height}"]) else {
                return "window @\(selectedWindow) unqueryable: \(lastTmuxFailure ?? "?")"
            }
            samples.append(size)
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard Set(samples).count == 1 else {
            return "window @\(selectedWindow) size oscillating: \(samples.joined(separator: " "))"
        }
        guard let winWidth = samples[0].split(separator: "x").first.flatMap({ Int($0) }) else {
            return "unparseable window size \(samples[0])"
        }
        guard let panes = tmux(["list-panes", "-t", "\(sessionName):@\(selectedWindow)",
                                "-F", "#{pane_width} #{pane_top}"]) else {
            return "no panes in @\(selectedWindow): \(lastTmuxFailure ?? "?")"
        }
        var topRowSum = 0
        var topRowCount = 0
        for line in panes.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let w = Int(parts[0]), parts[1] == "0" else { continue }
            topRowSum += w
            topRowCount += 1
        }
        if topRowCount > 1 {
            let expected = topRowSum + (topRowCount - 1)
            if expected != winWidth {
                return "@\(selectedWindow) top-row \(topRowSum)+\(topRowCount - 1)sep=\(expected) != window \(winWidth)"
            }
        }
        if let failure = paneGridsFailure(selectedWindow: selectedWindow) { return failure }
        return nil
    }

    /// The app-side oracle over `remote.tmux.pane_grids`: full
    /// assigned==rendered for the SELECTED window; a claimed, applied size
    /// (base == pushed) for every other mirrored window (hidden tabs don't
    /// re-render to match until selected — that is the visibility contract,
    /// not drift).
    private func paneGridsFailure(selectedWindow: Int) -> String? {
        guard let response = socketJSON(method: "remote.tmux.pane_grids", params: [
            "host": "e2e-shim-host",
            "session": sessionName,
        ]) else {
            return "pane_grids unavailable: no response"
        }
        guard response["mirrored"] as? Bool == true,
              let windows = response["windows"] as? [[String: Any]] else {
            return "pane_grids unavailable: \(response)"
        }
        // The selected window must be REPRESENTED, with panes — otherwise a
        // regression that stops mirrors from being created (empty `windows`)
        // would skip every render assertion and pass on tmux-side checks
        // alone.
        let selectedEntry = windows.first { ($0["window_id"] as? String) == "@\(selectedWindow)" }
        guard let selectedEntry,
              let selectedPanes = selectedEntry["panes"] as? [[String: Any]], !selectedPanes.isEmpty
        else {
            return "selected @\(selectedWindow) not mirrored (windows=\(windows.count))"
        }
        for window in windows {
            guard let idString = window["window_id"] as? String,
                  let id = Int(idString.dropFirst()) else { continue }
            guard let base = window["base"] as? [String: Any] else { continue }
            guard let pushed = window["pushed"] as? [String: Any] else {
                return "\(idString) never claimed a size"
            }
            if base["cols"] as? Int != pushed["cols"] as? Int
                || base["rows"] as? Int != pushed["rows"] as? Int {
                return "\(idString) base != pushed (push in flight)"
            }
            guard id == selectedWindow, let panes = window["panes"] as? [[String: Any]] else { continue }
            for pane in panes {
                guard pane["rendered"] != nil else {
                    return "pane \(pane["pane_id"] ?? "?") has no rendered grid yet: \(pane)"
                }
                if pane["match"] as? Bool != true {
                    return "pane \(pane["pane_id"] ?? "?") assigned≠rendered "
                        + "[win base=\(base) pushed=\(pushed) zoomed=\(window["zoomed"] ?? "?") "
                        + "visible=\(window["visible_for_sizing"] ?? "?") "
                        + "container=\(window["container_pt"] ?? "?") "
                        + "f_now=\(window["current_f"] ?? "?")]: \(pane)"
                }
            }
        }
        return nil
    }

    // MARK: lab plumbing

    private func requireTmux() throws {
        try XCTSkipIf(tmuxBin == nil, "tmux binary not found; e2e workflow installs it via brew")
    }

    private func buildLabSession() throws {
        _ = tmux(["kill-server"])
        XCTAssertNotNil(
            tmux(["new-session", "-d", "-s", sessionName, "-x", "180", "-y", "45"]),
            "lab server never started: \(lastTmuxFailure ?? "no stderr captured")"
        )
        _ = tmux(["split-window", "-h", "-t", "\(sessionName):0"])
        _ = tmux(["split-window", "-h", "-t", "\(sessionName):0"])
        _ = tmux(["select-layout", "-t", "\(sessionName):0", "even-horizontal"])
        _ = tmux(["new-window", "-t", sessionName])
        _ = tmux(["select-window", "-t", "\(sessionName):0"])
        startWidthProbes()
    }

    /// The layout-shape zoo: one window per split SHAPE, because sizing bugs
    /// are shape-dependent (a boundary miss can hit a nested column while
    /// even columns land clean). Names double as the tab titles the
    /// exploratory sweep clicks through.
    static let shapeNames = ["even3", "nested", "rows3", "grid4", "deep", "sixcol", "mainh"]

    /// Builds one window per shape (plus the plain single-pane window), all
    /// panes running the width probe.
    private func buildShapeZoo() throws {
        _ = tmux(["kill-server"])
        XCTAssertNotNil(
            tmux(["new-session", "-d", "-s", sessionName, "-x", "180", "-y", "45",
                  "-n", "even3"]),
            "lab server never started: \(lastTmuxFailure ?? "no stderr captured")"
        )
        _ = tmux(["split-window", "-h", "-t", "\(sessionName):0"])
        _ = tmux(["split-window", "-h", "-t", "\(sessionName):0"])
        _ = tmux(["select-layout", "-t", "\(sessionName):0", "even-horizontal"])
        _ = tmux(["new-window", "-t", sessionName, "-n", "nested"])
        _ = tmux(["split-window", "-h", "-t", "\(sessionName):1"])
        _ = tmux(["split-window", "-v", "-t", "\(sessionName):1.1"])
        _ = tmux(["new-window", "-t", sessionName, "-n", "rows3"])
        _ = tmux(["split-window", "-v", "-t", "\(sessionName):2"])
        _ = tmux(["split-window", "-v", "-t", "\(sessionName):2"])
        _ = tmux(["select-layout", "-t", "\(sessionName):2", "even-vertical"])
        _ = tmux(["new-window", "-t", sessionName, "-n", "grid4"])
        _ = tmux(["split-window", "-h", "-t", "\(sessionName):3"])
        _ = tmux(["split-window", "-v", "-t", "\(sessionName):3.0"])
        _ = tmux(["split-window", "-v", "-t", "\(sessionName):3.2"])
        _ = tmux(["select-layout", "-t", "\(sessionName):3", "tiled"])
        _ = tmux(["new-window", "-t", sessionName, "-n", "deep"])
        _ = tmux(["split-window", "-h", "-t", "\(sessionName):4"])
        _ = tmux(["split-window", "-v", "-t", "\(sessionName):4.1"])
        _ = tmux(["split-window", "-h", "-t", "\(sessionName):4.2"])
        _ = tmux(["new-window", "-t", sessionName, "-n", "sixcol"])
        for _ in 0..<5 {
            _ = tmux(["split-window", "-h", "-t", "\(sessionName):5"])
            _ = tmux(["select-layout", "-t", "\(sessionName):5", "even-horizontal"])
        }
        _ = tmux(["new-window", "-t", sessionName, "-n", "mainh"])
        _ = tmux(["split-window", "-v", "-t", "\(sessionName):6"])
        _ = tmux(["split-window", "-h", "-t", "\(sessionName):6.1"])
        _ = tmux(["split-window", "-h", "-t", "\(sessionName):6.1"])
        _ = tmux(["select-layout", "-t", "\(sessionName):6", "main-horizontal"])
        _ = tmux(["new-window", "-t", sessionName, "-n", "plain"])
        _ = tmux(["select-window", "-t", "\(sessionName):0"])
        startWidthProbes()
    }

    /// Runs `scripts/remote-tmux-width-probe.sh` in the FIRST window's panes:
    /// continuous (synchronized-output) redraw traffic makes the resize
    /// scenarios exercise live content, and the recorded CI video shows each
    /// pane's PTY-wide ruler, bottom sentinel, and two-axis check — a
    /// human-readable narration of the sizing oracle. One window's worth is
    /// the ceiling: probes in every zoo pane push enough %output through the
    /// control stream to stall the app's main thread for tens of seconds
    /// mid-sweep. Scenarios never PARSE the probe's output; the machine
    /// truth is the `remote.tmux.pane_grids` assertion.
    private func startWidthProbes() {
        let probe = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // cmuxUITests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("scripts/remote-tmux-width-probe.sh").path
        guard FileManager.default.isExecutableFile(atPath: probe) else { return }
        // Wait on the real readiness signal — every pane's foreground command
        // is an interactive shell — instead of a fixed grace period.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            guard let commands = tmux(["list-panes", "-t", "\(sessionName):@0", "-F", "#{pane_current_command}"]) else { break }
            let shells: Set<Substring> = ["zsh", "bash", "sh", "fish", "-zsh", "-bash"]
            if commands.split(separator: "\n").allSatisfy({ shells.contains($0) }) { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard let panes = tmux(["list-panes", "-t", "\(sessionName):@0", "-F", "#{pane_id}"]) else { return }
        for pane in panes.split(separator: "\n") {
            // Slow tick: the probes exist for churn and human-readable CI
            // video, not the oracle. The default 4Hz across a dozen zoo
            // panes floods %output through the control stream hard enough
            // to starve the app's main thread mid-sweep.
            _ = tmux(["send-keys", "-t", String(pane), "PROBE_TICK=2 bash \(probe)", "Enter"])
        }
    }

    /// Maps a window NAME to its tmux window id (the `@N` number).
    private func windowId(named name: String) -> Int? {
        guard let out = tmux(["list-windows", "-t", sessionName, "-F", "#{window_id} #{window_name}"]) else {
            return nil
        }
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2, String(parts[1]) == name,
               let id = Int(parts[0].dropFirst()) {
                return id
            }
        }
        return nil
    }

    /// Selects the tab titled `name` via `surface.focus` — the socket twin of
    /// clicking the tab bar. It flips the same tab-visibility state a click
    /// does (the mirror re-owns its size on selection), without routing a
    /// mouse event through whatever else is on the desktop.
    @discardableResult
    private func selectTab(named name: String) -> Bool {
        // Poll: surface titles arrive over the control stream shortly after
        // the mirror window opens, so the first lookups can race them.
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let list = socketJSON(method: "surface.list", params: [:]),
               let surfaces = list["surfaces"] as? [[String: Any]],
               let surfaceId = surfaces.first(where: { $0["title"] as? String == name })?["id"] as? String {
                let response = socketJSON(method: "surface.focus", params: ["surface_id": surfaceId])
                return response?["ok"] as? Bool == true
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return false
    }

    /// Resizes the mirror window to an exact size via the DEBUG
    /// `remote.tmux.test_set_frame` verb (see that handler for why the suite
    /// avoids XCUITest drag gestures), and asserts the window ACTUALLY
    /// reached the requested size — a silently clamped or misrouted resize
    /// would run every sweep round at one size and fake full coverage.
    private func setMirrorWindowSize(_ size: CGSize) {
        guard let windowId = mirrorWindowId else {
            XCTFail("no mirror window id recorded")
            return
        }
        // Up to three attempts: the main-actor hop can time out behind a
        // render/output burst on a loaded runner; later attempts land once
        // the burst drains. The ping between attempts confirms the socket
        // worker itself is alive (distinguishing a busy main thread from a
        // dead app).
        var response: [String: Any]?
        for attempt in 0..<3 {
            if attempt > 0 { _ = socketJSON(method: "system.ping", params: [:]) }
            response = socketJSON(method: "remote.tmux.test_set_frame", params: [
                "window_id": windowId,
                "width": Double(size.width),
                "height": Double(size.height),
            ])
            if response?["ok"] as? Bool == true { break }
        }
        XCTAssertEqual(response?["ok"] as? Bool, true, "test_set_frame failed: \(response ?? [:])")
        let appliedWidth = response?["applied_width"] as? Double ?? -1
        let appliedHeight = response?["applied_height"] as? Double ?? -1
        XCTAssertEqual(appliedWidth, Double(size.width), accuracy: 1.0,
                       "window width did not apply: \(response ?? [:])")
        XCTAssertEqual(appliedHeight, Double(size.height), accuracy: 1.0,
                       "window height did not apply: \(response ?? [:])")
    }

    /// The pushed column count `pane_grids` reports for a tmux window.
    private func pushedCols(window: Int) -> Int? {
        guard let response = socketJSON(method: "remote.tmux.pane_grids", params: [
            "host": "e2e-shim-host",
            "session": sessionName,
        ]), let windows = response["windows"] as? [[String: Any]] else { return nil }
        for entry in windows where (entry["window_id"] as? String) == "@\(window)" {
            return (entry["pushed"] as? [String: Any])?["cols"] as? Int
        }
        return nil
    }

    private func splitWindowPaneIds() throws -> [String] {
        let out = try XCTUnwrap(tmux(["list-panes", "-t", "\(sessionName):@0", "-F", "#{pane_id}"]))
        return out.split(separator: "\n").map(String.init)
    }

    /// Launches the app and waits for its control socket. The app owns the
    /// lab tmux server (built afterward through `remote.tmux.test_exec`), so
    /// launch precedes any tmux call — the sandboxed runner never spawns tmux
    /// itself.
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-socketControlMode", "allowAll",
            // Plist-typed bool: the settings decoder accepts only real
            // booleans, so a bare "YES" string via the argument domain never
            // enables the flag.
            "-remoteTmux.beta.enabled", "<true/>",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        // These three actually START the socket listener (matching the
        // passing browser/automation UITests); without them the app never
        // binds CMUX_SOCKET_PATH and every socket call times out.
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = launchTag
        // The ssh shim (checked into the repo) and the app's own tmux commands
        // both use this TMUX_TMPDIR to reach the one lab server.
        app.launchEnvironment["CMUX_REMOTE_TMUX_SSH_FOR_TESTING"] = shimPath
        app.launchEnvironment["TMUX_TMPDIR"] = tmuxTmpDir
        if let path = ProcessInfo.processInfo.environment["PATH"], !path.isEmpty {
            app.launchEnvironment["PATH"] = path
        }
        // Activation can fail on a headless or lock-screen session
        // ("Running Background"). The suite is socket-driven end to end and
        // the sizing oracle follows view LAYOUT (which advances for
        // background apps), not visible painting — so treat activation as
        // best-effort, exactly like the browser-fixture suites.
        let activationOptions = XCTExpectedFailure.Options()
        activationOptions.isStrict = false
        XCTExpectFailure("App activation may fail on headless/locked sessions", options: activationOptions) {
            app.launch()
        }
        _ = app.wait(for: .runningForeground, timeout: 10)
        XCTAssertTrue(
            waitForSocket(timeout: 12),
            "control socket never answered. candidates=\(socketCandidates()) "
                + "lastSocketFailure=\(lastSocketFailure ?? "nil") diagnostics=\(loadDiagnostics())"
        )
        return app
    }

    /// Mirrors the lab host in a dedicated, activated cmux window — the
    /// `cmux ssh-tmux` entry point. Activation matters: it mounts the mirror
    /// views, and only mounted views have geometry to feed the client-size
    /// push (`remote.tmux.mirror` alone creates unselected workspaces whose
    /// windows never claim a size).
    private func attachSession() {
        let response = socketJSON(method: "remote.tmux.window", params: [
            "host": "e2e-shim-host",
            "activate": true,
        ])
        XCTAssertEqual(response?["ok"] as? Bool, true, "remote.tmux.window failed: \(response ?? [:])")
        XCTAssertEqual(response?["mirrored"] as? Bool, true, "host not mirrored: \(response ?? [:])")
        mirrorWindowId = response?["window_id"] as? String
    }

    /// The cmux window UUID hosting the mirror (from `remote.tmux.window`).
    private var mirrorWindowId: String?


    /// The last tmux invocation failure (spawn error or nonzero exit +
    /// stderr) — surfaced in assertion messages so a lab-setup failure names
    /// its cause instead of a bare XCTAssertNotNil.
    private var lastTmuxFailure: String?

    /// Runs a tmux argv against the lab server — INSIDE THE APP via the
    /// `remote.tmux.test_exec` debug socket verb, never in the sandboxed
    /// runner (which cannot create /tmp dirs or spawn tmux there). Returns
    /// trimmed stdout on exit 0, else records the failure and returns nil.
    @discardableResult
    private func tmux(_ args: [String]) -> String? {
        guard let bin = tmuxBin else { return nil }
        guard let response = socketJSON(method: "remote.tmux.test_exec", params: [
            "tmpdir": tmuxTmpDir,
            "bin": bin,
            "args": args,
        ]) else {
            lastTmuxFailure = "tmux \(args.joined(separator: " ")): socket call returned nil"
            return nil
        }
        // The socket call succeeded (response["ok"]); tmux's own exit is in
        // "exit". Both must be clean.
        guard response["ok"] as? Bool == true, response["exit"] as? Int == 0 else {
            lastTmuxFailure = "tmux \(args.joined(separator: " ")) -> \(response)"
            return nil
        }
        return (response["stdout"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: socket plumbing (per-file copy, matching the target's pattern)

    /// The app binds a TAG-DERIVED socket (`/tmp/cmux-debug-<slug>.sock`) and
    /// ignores CMUX_SOCKET_PATH in tag mode, so probe both and adopt whichever
    /// answers — matching the passing browser/automation UITests. Once found,
    /// `socketPath` is updated so every later call uses the live socket.
    private func waitForSocket(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for candidate in socketCandidates() {
                guard FileManager.default.fileExists(atPath: candidate) else { continue }
                socketPath = candidate
                if socketJSON(method: "system.ping", params: [:])?["ok"] as? Bool == true {
                    return true
                }
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return false
    }

    /// Every path the app might have bound: the one we dictated, the
    /// tag-derived one, and whatever the app itself recorded in its
    /// diagnostics file — the app's own ground truth.
    private func socketCandidates() -> [String] {
        var candidates = [socketPath, taggedSocketPath()]
        if let expected = loadDiagnostics()["socketExpectedPath"], !expected.isEmpty {
            candidates.append(expected)
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    /// The app's UI-test diagnostics (socket path, sanity result, …), or empty.
    private func loadDiagnostics() -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: diagnosticsPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object.reduce(into: [:]) { $0[$1.key] = String(describing: $1.value) }
    }

    /// `/tmp/cmux-debug-<slug>.sock`, the path the app derives from CMUX_TAG.
    private func taggedSocketPath() -> String {
        let slug = launchTag
            .lowercased()
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return "/tmp/cmux-debug-\(slug).sock"
    }

    private func socketJSON(method: String, params: [String: Any]) -> [String: Any]? {
        let request: [String: Any] = ["id": UUID().uuidString, "method": method, "params": params]
        guard JSONSerialization.isValidJSONObject(request),
              let data = try? JSONSerialization.data(withJSONObject: request),
              let line = String(data: data, encoding: .utf8),
              let response = sendLine(line),
              let responseData = response.data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any]
        else { return nil }
        // Success responses nest the payload under "result" ({ok, id, result});
        // errors are flat ({ok, id, error}). Flatten result up so callers read
        // payload keys (exit, windows, …) and the top-level "ok" uniformly.
        if let result = object["result"] as? [String: Any] {
            for (key, value) in result where object[key] == nil { object[key] = value }
        }
        return object
    }

    private var lastSocketFailure: String?

    private func sendLine(_ line: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            lastSocketFailure = "socket() errno=\(errno) (\(String(cString: strerror(errno))))"
            return nil
        }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 65, tv_usec: 0)
        withUnsafePointer(to: &timeout) { ptr in
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }
        var addr = sockaddr_un()
        memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            for index in 0..<pathBytes.count { raw[index] = pathBytes[index] }
        }
        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        let addrLen = socklen_t(pathOffset + pathBytes.count)
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, addrLen) }
        }
        guard connected == 0 else {
            lastSocketFailure = "connect(\(socketPath)) errno=\(errno) (\(String(cString: strerror(errno))))"
            return nil
        }
        let payload = Array((line + "\n").utf8)
        let wrote = payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            return Darwin.write(fd, base, raw.count) == raw.count
        }
        guard wrote else { return nil }
        var buffer = [UInt8](repeating: 0, count: 8192)
        var accumulator = ""
        let deadline = Date().addingTimeInterval(65)
        while Date() < deadline {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            if let chunk = String(bytes: buffer[0..<count], encoding: .utf8) {
                accumulator.append(chunk)
                if let newline = accumulator.firstIndex(of: "\n") {
                    return String(accumulator[..<newline])
                }
            }
        }
        return accumulator.isEmpty ? nil : accumulator.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
