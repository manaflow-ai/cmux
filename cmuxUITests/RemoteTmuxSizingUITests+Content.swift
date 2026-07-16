import XCTest
import Foundation

/// Content scenarios: the mirror's on-screen TEXT must equal tmux's own
/// capture of the same pane. The grid oracle compares dimensions; these
/// compare what the user actually reads. That is the class the grid checks
/// cannot see: a pane holding the right-size grid but stale content (output
/// that never rendered), or a stale-size grid on a window the settle oracle
/// does not judge (single-pane windows have no mirror and no pane_grids
/// entry). Both shapes were first caught by the live fuzz's text oracle;
/// these scenarios make them deterministic.
extension RemoteTmuxSizingUITests {

    // MARK: content probe

    /// Starts a full-screen ruler in a pane: every 2 seconds it clears the
    /// screen and prints one `%<id> <cols>x<rows> 0123456789…` line per row (to
    /// the exact width) plus an `END %<id> <cols>x<rows>` last line. Any
    /// divergence between the mirror and tmux — stale content, a clipped row, a
    /// wrong grid — shows up as plain text inequality. Same probe the live fuzz
    /// runs; the printed size is the PTY's own view (`stty size`), so a pane that
    /// was resized reprints at the new size within a cycle.
    ///
    /// Every line carries the pane's OWN id (tmux exports `TMUX_PANE` into the
    /// pane's environment). Without it, two panes of equal dimensions print
    /// byte-identical screens, so a comparison that read the wrong pane's surface
    /// would pass — which is exactly how a broken text oracle stayed green.
    func startRuler(pane: String) {
        let ruler = """
        unset COLUMNS LINES; id=${TMUX_PANE:-%?}; while :; do sz=$(stty size 2>/dev/null); \
        r=${sz%% *}; c=${sz##* }; [ -n "$r" ] || r=24; [ -n "$c" ] || c=80; \
        base=$(printf '%0.s0123456789' $(seq 1 400)); printf '\\033[2J\\033[H'; \
        i=1; while [ "$i" -lt "$r" ]; do printf '%s\\n' \
        "$(printf '%s %03dx%03d %s' "$id" "$c" "$r" "$base" | cut -c1-"$c")"; \
        i=$((i+1)); done; printf 'END %s %03dx%03d' "$id" "$c" "$r"; sleep 2; done
        """
        XCTAssertNotNil(
            tmux(["send-keys", "-t", pane, ruler, "Enter"]),
            "could not start the ruler in \(pane): \(lastTmuxFailure ?? "?")"
        )
    }

    /// Starts the ruler in every pane of a tmux window and waits until each one is
    /// actually PRINTING it.
    ///
    /// A discarded `send-keys` failure would leave the pane showing its idle shell
    /// prompt — which the mirror renders faithfully, so every content assertion
    /// would pass while testing nothing. Requiring the marker in tmux's own capture
    /// makes the probe's presence a precondition rather than an assumption.
    func startRulers(window: Int) throws {
        let out = try XCTUnwrap(
            tmux(["list-panes", "-t", "\(sessionName):@\(window)", "-F", "#{pane_id}"]),
            "cannot list panes of @\(window): \(lastTmuxFailure ?? "?")"
        )
        let panes = out.split(separator: "\n").map(String.init)
        XCTAssertFalse(panes.isEmpty, "@\(window) reported no panes to run the ruler in")
        for pane in panes {
            startRuler(pane: pane)
        }
        for pane in panes {
            let deadline = Date().addingTimeInterval(10)
            var last = "never captured"
            var running = false
            while Date() < deadline {
                if let screen = captureRemoteScreen(pane: pane) {
                    last = screen.split(separator: "\n").first.map(String.init) ?? "<empty>"
                    // The ruler's own output, not a shell echoing the command line:
                    // its lines start with the pane id and carry the size marker.
                    if screen.contains("END \(pane) ") {
                        running = true
                        break
                    }
                }
                Thread.sleep(forTimeInterval: 0.3)
            }
            XCTAssertTrue(
                running,
                "the ruler never printed in \(pane) — every content assertion would "
                    + "pass against an idle shell instead (last capture: \(last))"
            )
        }
    }

    /// Runs a tmux command that a scenario DEPENDS on and fails the test if it
    /// did not run. A discarded failure here is worse than a red: the churn the
    /// scenario exists to create never happens, the content still matches, and the
    /// test reports green while exercising nothing.
    func mustRunTmux(_ args: [String], _ what: String) {
        XCTAssertNotNil(
            tmux(args),
            "\(what) failed, so the scenario never created the state it asserts on: "
                + "\(lastTmuxFailure ?? "?")"
        )
    }

    /// Trailing-whitespace/blank-line normalization, matching the fuzz's
    /// normalize_screen: per-line trailing spaces stripped, trailing empty
    /// lines dropped. Leading rows are kept — a missing top row is a bug.
    static func normalizeScreen(_ text: String) -> String {
        var lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var s = String(line)
                while s.hasSuffix(" ") || s.hasSuffix("\t") { s.removeLast() }
                return s
            }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// tmux's own view of a pane's screen (joined wrapped lines), normalized.
    func captureRemoteScreen(pane: String) -> String? {
        guard let raw = tmux(["capture-pane", "-p", "-J", "-t", pane]) else { return nil }
        return Self.normalizeScreen(raw)
    }

    /// Waits for the ruler to print at an exact PTY size, proving the remote
    /// resize produced output before the next churn step. This is a real-state
    /// predicate rather than fixed pacing, so loaded runners cannot skip the
    /// intermediate state merely because a sleep expired.
    func waitForRulerScreenSize(
        window: Int,
        columns: Int,
        rows: Int,
        within timeout: TimeInterval,
        context: String
    ) throws {
        let pane = try XCTUnwrap(
            tmux(["list-panes", "-t", "\(sessionName):@\(window)", "-F", "#{pane_id}"])?
                .split(separator: "\n").first.map(String.init),
            "no pane in @\(window) while waiting for ruler size \(context)"
        )
        let marker = String(format: "END %@ %03dx%03d", pane, columns, rows)
        let deadline = Date().addingTimeInterval(timeout)
        var last = "never captured"
        while Date() < deadline {
            if let screen = captureRemoteScreen(pane: pane) {
                last = screen.split(separator: "\n").last.map(String.init) ?? "<empty>"
                if screen.contains(marker) { return }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("ruler never reached \(marker) \(context); last line: \(last)")
    }

    /// The tmux pane id → cmux surface id map (on-screen panes only), from
    /// `remote.tmux.pane_surfaces`.
    ///
    /// A content oracle MUST read the named pane's own surface. Reading "the
    /// focused surface" cannot verify a named pane: cmux does not follow tmux's
    /// active pane or current window, so `select-pane` then read returns
    /// whichever pane the app already showed — which matches the target's
    /// capture whenever the two panes share dimensions (the ruler prints the
    /// same text at the same size), and mismatches when they do not. That is
    /// how the live fuzz reported a mirror defect for a mirror that was right.
    /// Hidden panes are excluded: a hidden tab holds its last render by design.
    func onScreenPaneSurfaces() -> [String: String] {
        guard let response = socketJSON(method: "remote.tmux.pane_surfaces", params: [
            "host": "e2e-shim-host",
            "session": sessionName,
        ]),
        response["mirrored"] as? Bool == true,
        let panes = response["panes"] as? [[String: Any]] else { return [:] }
        var map: [String: String] = [:]
        for pane in panes {
            guard pane["on_screen"] as? Bool == true,
                  let paneId = pane["pane_id"] as? String,
                  let surfaceId = pane["surface_id"] as? String else { continue }
            map[paneId] = surfaceId
        }
        return map
    }

    /// One pane's surface text via `surface.read_text`, normalized.
    func readMirrorScreen(surfaceId: String) -> String? {
        guard let response = socketJSON(method: "surface.read_text", params: [
            "surface_id": surfaceId,
        ]),
        response["ok"] as? Bool == true,
        let text = response["text"] as? String else { return nil }
        return Self.normalizeScreen(text)
    }

    /// One pane's content parity, with the fuzz's tolerance: the ruler
    /// redraws every 2 seconds, so the mirror must equal the remote capture
    /// taken immediately BEFORE or AFTER it — a redraw between the two reads
    /// must not manufacture a mismatch. Polls up to the deadline; on failure
    /// returns a diagnostic with both screens' head lines.
    func paneContentFailure(pane: String, timeout: TimeInterval = 8) -> String? {
        guard let surfaceId = onScreenPaneSurfaces()[pane] else {
            return "pane \(pane) has no on-screen surface (pane_surfaces: \(onScreenPaneSurfaces()))"
        }
        let deadline = Date().addingTimeInterval(timeout)
        var lastRemote: String?
        var lastMirror: String?
        var lastNote = "no reads"
        while Date() < deadline {
            let before = captureRemoteScreen(pane: pane)
            let mirror = readMirrorScreen(surfaceId: surfaceId)
            let after = captureRemoteScreen(pane: pane)
            lastRemote = after ?? before
            lastMirror = mirror
            if let before, let mirror, let after {
                if mirror == before || mirror == after { return nil }
                lastNote = "diff"
            } else {
                lastNote = "capture=\(before != nil ? "ok" : "nil") "
                    + "read=\(mirror != nil ? "ok" : "nil") "
                    + "tmuxErr=\(lastTmuxFailure ?? "-")"
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        let remoteHead = (lastRemote ?? "<nil>").split(separator: "\n").prefix(2).joined(separator: " | ")
        let mirrorHead = (lastMirror ?? "<nil>").split(separator: "\n").prefix(2).joined(separator: " | ")
        return "pane \(pane) mirror != tmux [\(lastNote)] "
            + "remote=[\(remoteHead)] mirror=[\(mirrorHead)]"
    }

    /// Waits until a window's tmux size holds steady across samples, WITHOUT
    /// the pane_grids render check. Single-pane windows have no mirror and no
    /// pane_grids entry, so `assertSettles` (which requires one) cannot judge
    /// them; the content oracle is their render check. Use this to reach a
    /// stable size first, then assert content.
    func waitWindowSizeStable(window: Int, within timeout: TimeInterval, context: String) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var last = "no samples"
        while Date() < deadline {
            var samples: [String] = []
            for _ in 0..<6 {
                guard let size = tmux(["display-message", "-p",
                                       "-t", "\(sessionName):@\(window)",
                                       "#{window_width}x#{window_height}"]) else { break }
                samples.append(size)
                Thread.sleep(forTimeInterval: 0.25)
            }
            if samples.count == 6, Set(samples).count == 1 { return }
            last = samples.joined(separator: " ")
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("window @\(window) size never stabilized \(context): \(last)")
    }

    /// Every pane of a tmux window holds content parity with tmux, each judged
    /// against its OWN surface. Requires the window to be the one on screen:
    /// its panes must all appear in the on-screen surface map, so a scenario
    /// that forgot to select the window's tab fails loudly instead of quietly
    /// checking nothing (or checking another window's surface).
    func assertWindowContentMatchesTmux(window: Int, context: String) throws {
        let out = try XCTUnwrap(
            tmux(["list-panes", "-t", "\(sessionName):@\(window)", "-F", "#{pane_id}"]),
            "cannot list panes of @\(window) \(context): \(lastTmuxFailure ?? "?")"
        )
        let panes = out.split(separator: "\n").map(String.init)
        XCTAssertFalse(panes.isEmpty, "@\(window) reported no panes \(context)")
        let onScreen = onScreenPaneSurfaces()
        for pane in panes {
            XCTAssertNotNil(
                onScreen[pane],
                "@\(window) pane \(pane) is not on screen \(context) — select its tab before "
                    + "asserting content (on-screen panes: \(onScreen.keys.sorted()))"
            )
            if let failure = paneContentFailure(pane: pane) {
                XCTFail("\(failure) \(context)")
            }
        }
    }

    // MARK: scenarios

    /// A minimal, fast-settling lab for content scenarios: one 3-pane split
    /// window ("split", @0) and one single-pane window ("solo", @1). Two
    /// windows claim promptly even on a loaded runner, unlike the eight-tab
    /// shape zoo whose background claims can outrun a settle budget.
    func buildContentLab() throws {
        _ = tmux(["kill-server"])
        XCTAssertNotNil(
            tmux(["new-session", "-d", "-s", sessionName, "-x", "180", "-y", "45", "-n", "split"]),
            "lab server never started: \(lastTmuxFailure ?? "no stderr captured")"
        )
        _ = tmux(["split-window", "-h", "-t", "\(sessionName):0"])
        _ = tmux(["split-window", "-h", "-t", "\(sessionName):0"])
        _ = tmux(["select-layout", "-t", "\(sessionName):0", "even-horizontal"])
        _ = tmux(["new-window", "-t", sessionName, "-n", "solo"])
        _ = tmux(["select-window", "-t", "\(sessionName):0"])
    }

    /// Content parity for a settled window: a multi-pane split and, crucially,
    /// the single-pane window — the class the settle oracle never judges (no
    /// mirror, no pane_grids entry), where a stale surface hides from every
    /// grid check.
    func testPaneContentMatchesTmuxAcrossShapes() throws {
        try requireTmux()
        let app = launchApp()
        defer { app.terminate() }
        try buildContentLab()
        attachSession()
        setMirrorWindowSize(CGSize(width: 1000, height: 700))

        let split = try XCTUnwrap(windowId(named: "split"), "no split window")
        XCTAssertTrue(selectTab(named: "split"), "could not select split tab")
        try assertSettles(selectedWindow: split, within: 10, context: "split")
        try startRulers(window: split)
        try assertWindowContentMatchesTmux(window: split, context: "split")

        let solo = try XCTUnwrap(windowId(named: "solo"), "no solo window")
        XCTAssertTrue(selectTab(named: "solo"), "could not select solo tab")
        try waitWindowSizeStable(window: solo, within: 10, context: "solo")
        try startRulers(window: solo)
        try assertWindowContentMatchesTmux(window: solo, context: "solo")
    }

    /// A single-pane window whose pane tmux resizes out from under the app
    /// (a co-client, a server-side layout command). No mirror pins this
    /// surface, so content parity after the churn is the only guard — the
    /// shape of the live fuzz's seed-2 miss (mirror held a 118x40 frame while
    /// tmux's pane was 99x35).
    func testSinglePaneWindowContentSurvivesExternalResize() throws {
        try requireTmux()
        let app = launchApp()
        defer { app.terminate() }
        try buildContentLab()
        attachSession()
        setMirrorWindowSize(CGSize(width: 1000, height: 700))
        let solo = try XCTUnwrap(windowId(named: "solo"), "no solo window")
        XCTAssertTrue(selectTab(named: "solo"), "could not select solo tab")
        try waitWindowSizeStable(window: solo, within: 10, context: "solo before churn")
        try startRulers(window: solo)
        try assertWindowContentMatchesTmux(window: solo, context: "solo before churn")
        mustRunTmux(["resize-window", "-t", "\(sessionName):@\(solo)", "-x", "99", "-y", "35"], "shrinking solo from the tmux side")
        try waitForRulerScreenSize(
            window: solo,
            columns: 99,
            rows: 35,
            within: 10,
            context: "after visible shrink"
        )
        mustRunTmux(["resize-window", "-t", "\(sessionName):@\(solo)", "-x", "140", "-y", "40"], "growing solo from the tmux side")
        try waitWindowSizeStable(window: solo, within: 10, context: "solo after churn")
        try assertWindowContentMatchesTmux(window: solo, context: "solo after churn")
    }

    /// Zoom collapses the visible tree to one pane and back. The mirror
    /// renders the visible tree while claims derive from the base tree, so a
    /// zoom-state lag renders a pane at the wrong size — content parity
    /// catches it on the zoomed leaf and after unzoom.
    func testZoomToggleKeepsContentParity() throws {
        try requireTmux()
        let app = launchApp()
        defer { app.terminate() }
        try buildContentLab()
        attachSession()
        setMirrorWindowSize(CGSize(width: 1000, height: 700))
        let split = try XCTUnwrap(windowId(named: "split"), "no split window")
        XCTAssertTrue(selectTab(named: "split"), "could not select split tab")
        try assertSettles(selectedWindow: split, within: 10, context: "split before zoom")
        try startRulers(window: split)
        let firstPane = try XCTUnwrap(
            tmux(["list-panes", "-t", "\(sessionName):@\(split)", "-F", "#{pane_id}"])?
                .split(separator: "\n").first.map(String.init),
            "no panes in split window"
        )
        mustRunTmux(["resize-pane", "-Z", "-t", firstPane], "toggling zoom")
        // Zoomed: only the one leaf is visible, so the base-layout coherence
        // check assertSettles runs does not apply (the hidden panes' widths
        // do not sum to the window). Wait for size stability, then let content
        // parity judge the zoomed leaf.
        try waitWindowSizeStable(window: split, within: 10, context: "split zoomed")
        if let failure = paneContentFailure(pane: firstPane) {
            XCTFail("\(failure) while zoomed")
        }
        mustRunTmux(["resize-pane", "-Z", "-t", firstPane], "toggling zoom")
        try assertSettles(selectedWindow: split, within: 10, context: "split unzoomed")
        try assertWindowContentMatchesTmux(window: split, context: "after unzoom")
    }

    /// Killing a split window down to one pane hands the surviving pane's
    /// panel across the mirror/single-pane ownership boundary. The survivor
    /// must render tmux's full-window content, not its old split-sized frame.
    func testCollapseToSinglePaneKeepsContentParity() throws {
        try requireTmux()
        let app = launchApp()
        defer { app.terminate() }
        try buildContentLab()
        attachSession()
        setMirrorWindowSize(CGSize(width: 1000, height: 700))
        let split = try XCTUnwrap(windowId(named: "split"), "no split window")
        XCTAssertTrue(selectTab(named: "split"), "could not select split tab")
        try assertSettles(selectedWindow: split, within: 10, context: "split before collapse")
        try startRulers(window: split)
        var panes = try XCTUnwrap(
            tmux(["list-panes", "-t", "\(sessionName):@\(split)", "-F", "#{pane_id}"])?
                .split(separator: "\n").map(String.init),
            "no panes in split"
        )
        while panes.count > 1 {
            mustRunTmux(["kill-pane", "-t", panes.removeLast()], "killing a pane to collapse the window")
            Thread.sleep(forTimeInterval: 0.5)
        }
        try waitWindowSizeStable(window: split, within: 10, context: "split collapsed")
        try assertWindowContentMatchesTmux(window: split, context: "after collapse to one pane")
    }

    /// Churn a HIDDEN window from the tmux side, then reveal it. Hidden tabs
    /// hold their last geometry and claim by design, so the reveal is where a
    /// deferred resize lands — output that streamed while hidden must be
    /// present after the reveal settles.
    func testHiddenWindowContentCatchesUpOnReveal() throws {
        try requireTmux()
        let app = launchApp()
        defer { app.terminate() }
        try buildContentLab()
        attachSession()
        setMirrorWindowSize(CGSize(width: 1000, height: 700))
        let split = try XCTUnwrap(windowId(named: "split"), "no split window")
        let solo = try XCTUnwrap(windowId(named: "solo"), "no solo window")
        // Settle solo once (so it has claimed + rulers running), then hide it.
        XCTAssertTrue(selectTab(named: "solo"), "could not select solo tab")
        try waitWindowSizeStable(window: solo, within: 10, context: "solo before hide")
        try startRulers(window: solo)
        // Bring split to the front; churn solo while it is hidden.
        XCTAssertTrue(selectTab(named: "split"), "could not select split tab")
        try assertSettles(selectedWindow: split, within: 10, context: "split front")
        mustRunTmux(["resize-window", "-t", "\(sessionName):@\(solo)", "-x", "80", "-y", "24"], "shrinking solo while hidden")
        try waitForRulerScreenSize(
            window: solo,
            columns: 80,
            rows: 24,
            within: 10,
            context: "while solo is hidden"
        )
        mustRunTmux(["resize-window", "-t", "\(sessionName):@\(solo)", "-x", "150", "-y", "42"], "growing solo while hidden")
        // Reveal and require parity.
        XCTAssertTrue(selectTab(named: "solo"), "could not select solo tab")
        try waitWindowSizeStable(window: solo, within: 10, context: "solo revealed")
        try assertWindowContentMatchesTmux(window: solo, context: "after hidden churn reveal")
    }
}
