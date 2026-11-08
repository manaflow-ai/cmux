import XCTest
import Foundation
import Darwin

extension RemoteTmuxSizingUITests {

    /// Pane RATIOS are user state: the lab window starts even-horizontal, and
    /// no amount of window resizing may let the sizing machinery redistribute
    /// columns between panes beyond remainder scatter. Catches any sizing
    /// path that writes per-pane geometry from transient mid-resize state
    /// (panes walked toward slivers) — invisible to stability/coherence
    /// checks, which pass at ANY stable ratio.
    func assertRatiosPreserved(context: String) throws {
        let out = try XCTUnwrap(tmux(["list-panes", "-t", "\(sessionName):@0", "-F", "#{pane_width}"]))
        let widths = out.split(separator: "\n").compactMap { Int($0) }
        XCTAssertEqual(widths.count, 3, "expected 3 panes \(context)")
        let spread = (widths.max() ?? 0) - (widths.min() ?? 0)
        XCTAssertLessThanOrEqual(
            spread, 4,
            "pane ratios drifted \(context): \(widths) — sizing must not mutate user layout"
        )
    }

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
    func assertSettles(
        selectedWindow: Int, within timeout: TimeInterval, context: String
    ) throws {
        let started = Date()
        let deadline = started.addingTimeInterval(timeout)
        var lastFailure = "no samples"
        while Date() < deadline {
            if let failure = settleFailure(selectedWindow: selectedWindow) {
                lastFailure = failure
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            // The measured latency, printed against the budget so a scenario
            // creeping toward its limit is visible before it flakes. The
            // floor is the ~2s stability probe (8 samples x 0.25s), not
            // sizing latency.
            let elapsed = Date().timeIntervalSince(started)
            print("assertSettles: \(String(format: "%.1f", elapsed))s of \(Int(timeout))s \(context)")
            return
        }
        XCTFail("Sizing never settled \(context): \(lastFailure)")
    }

    func settleFailure(selectedWindow: Int) -> String? {
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

    /// One shared fetch of `remote.tmux.pane_grids` for the lab host,
    /// unwrapped to its per-window entries. Returns nil when the verb is
    /// unavailable or the host is not mirrored — every consumer treats
    /// that identically (retry or report), so the unwrap lives here once.
    func paneGridsWindows() -> [[String: Any]]? {
        guard let response = socketJSON(method: "remote.tmux.pane_grids", params: [
            "host": "e2e-shim-host",
            "session": sessionName,
        ]),
        response["mirrored"] as? Bool == true,
        let windows = response["windows"] as? [[String: Any]] else { return nil }
        return windows
    }

    /// The app-side oracle over `remote.tmux.pane_grids`: full
    /// assigned==rendered for the SELECTED window; a claimed, applied size
    /// (base == pushed) for every other mirrored window (hidden tabs don't
    /// re-render to match until selected — that is the visibility contract,
    /// not drift).
    func paneGridsFailure(selectedWindow: Int) -> String? {
        guard let windows = paneGridsWindows() else {
            return "pane_grids unavailable or host not mirrored"
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
                // The full snapshot: which link is missing (no panes? no
                // rendered grids? no calibration?) matters more than the id.
                return "\(idString) never claimed a size: \(window)"
            }
            if base["cols"] as? Int != pushed["cols"] as? Int
                || base["rows"] as? Int != pushed["rows"] as? Int {
                return "\(idString) base != pushed (push in flight)"
            }
            guard id == selectedWindow, let panes = window["panes"] as? [[String: Any]] else { continue }
            for pane in panes {
                // A pane tmux itself squeezed to a 1-cell axis (an attach's
                // 80x24 transit permanently flattens ratios — reproducible in
                // raw tmux) has no renderable grid, and pane ratios are user
                // state cmux must never rewrite. The render contract applies
                // to renderable panes only.
                if let assigned = pane["assigned"] as? [String: Any],
                   let cols = assigned["cols"] as? Int, let rows = assigned["rows"] as? Int,
                   cols <= 1 || rows <= 1 {
                    continue
                }
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

    /// Resizes the mirror window to an exact size via the DEBUG
    /// `remote.tmux.test_set_frame` verb (see that handler for why the suite
    /// avoids XCUITest drag gestures), and asserts the window ACTUALLY
    /// reached the requested size — a silently clamped or misrouted resize
    /// would run every sweep round at one size and fake full coverage.
    func setMirrorWindowSize(_ size: CGSize) {
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

    /// Moves the mirror window to an exact x origin (no size change) via
    /// `remote.tmux.test_set_frame`'s origin parameters, and asserts the
    /// move actually applied — a clamped or ignored move would run the
    /// zero-work guard against a stationary window and fake coverage.
    func setMirrorWindowOrigin(x: Double) {
        guard let windowId = mirrorWindowId else {
            XCTFail("no mirror window id recorded")
            return
        }
        let response = socketJSON(method: "remote.tmux.test_set_frame", params: [
            "window_id": windowId,
            "x": x,
        ])
        XCTAssertEqual(response?["ok"] as? Bool, true, "origin-only test_set_frame failed: \(response ?? [:])")
        let appliedX = response?["applied_x"] as? Double ?? -1
        XCTAssertEqual(appliedX, x, accuracy: 1.0, "window origin did not apply: \(response ?? [:])")
    }

    /// The monotonic sizing work counters `remote.tmux.sizing_settled`
    /// carries (DEBUG builds): sizing passes run, parity re-arms taken,
    /// full portal hierarchy syncs past the signature cut.
    func sizingCounters() -> (pass: Int, rearm: Int, hierarchySync: Int)? {
        guard let settled = socketJSON(method: "remote.tmux.sizing_settled", params: [:]),
              let counters = settled["counters"] as? [String: Any],
              let pass = counters["sizing_pass"] as? Int,
              let rearm = counters["parity_rearm"] as? Int,
              let hierarchySync = counters["full_hierarchy_sync"] as? Int else { return nil }
        return (pass, rearm, hierarchySync)
    }

    /// The frame oracle over `remote.tmux.root_frames`: the mirror's whole
    /// real ancestor chain — probe to the window's content view — must hold
    /// the window's width. The live growth spiral kept every tmux-side claim
    /// sane (the oversized-reading guard dropped the inflated readings) while
    /// the content view marched a step wider per layout pass past the
    /// display-pinned window; the grid oracle above cannot see that class,
    /// only the frames can.
    func assertRootContentTracksWindow(context: String) throws {
        let response = socketJSON(method: "remote.tmux.root_frames", params: [:])
        let windows = try XCTUnwrap(
            response?["windows"] as? [[String: Any]],
            "root_frames returned nothing \(context): \(response ?? [:])"
        )
        XCTAssertFalse(windows.isEmpty, "no visible mirror in root_frames \(context)")
        for entry in windows {
            // Fail CLOSED on a malformed payload: defaulting both widths to
            // -1 let "missing vs missing" pass the comparison and vouch for
            // frames that were never reported.
            guard let windowWidth = entry["window_width"] as? Double,
                  let contentWidth = entry["content_view_width"] as? Double else {
                XCTFail("root_frames entry missing width fields \(context): \(entry)")
                continue
            }
            XCTAssertLessThanOrEqual(
                contentWidth, windowWidth + 1,
                "content view wider than its window \(context): \(entry)"
            )
            for ancestor in entry["ancestors"] as? [[String: Any]] ?? [] {
                guard let width = ancestor["width"] as? Double else {
                    XCTFail("root_frames ancestor missing width \(context): \(ancestor)")
                    continue
                }
                XCTAssertLessThanOrEqual(
                    width, windowWidth + 1,
                    "\(ancestor["class"] ?? "?") is \(Int(width))pt wide in a \(Int(windowWidth))pt window \(context) — an ancestor adopted a content-derived width"
                )
            }
        }
    }

    /// The claim oracle over `remote.tmux.sizing_settled`: every tmux window
    /// claim recorded at settle must fit the hosting window. The claim is a
    /// pure function of window geometry, so a claimed grid above what the
    /// window's content area divides to at the current cell size means
    /// content-derived input reached the claim — the wedge's signature (the
    /// live wedge pushed 318-column claims against a 248-column layout;
    /// older evidence reached 2614 columns) — even while every grid check
    /// still passes, because tmux clamps the layout and the mirror renders
    /// the clamped truth. Two cells of slack absorb rounding and the chrome
    /// model's separator credit; a runaway claim is off by tens of columns,
    /// not two.
    func assertClaimsWithinWindowCeiling(context: String) throws {
        let settled = socketJSON(method: "remote.tmux.sizing_settled", params: [:])
        let claims = try XCTUnwrap(
            settled?["windows"] as? [[String: Any]],
            "sizing_settled returned nothing \(context): \(settled ?? [:])"
        )
        XCTAssertFalse(claims.isEmpty, "no visible mirror in sizing_settled \(context)")
        // The window-derived bound, per mirrored tmux window: root_frames
        // covers exactly the visible set sizing_settled judges, and its
        // content layout rect is the same bound the sizing pass validates
        // container readings against.
        let frames = socketJSON(method: "remote.tmux.root_frames", params: [:])
        var contentByWindow: [Int: (width: Double, height: Double)] = [:]
        for entry in (frames?["windows"] as? [[String: Any]]) ?? [] {
            guard let id = entry["window"] as? Int,
                  let width = entry["content_layout_width"] as? Double,
                  let height = entry["content_layout_height"] as? Double else { continue }
            contentByWindow[id] = (width, height)
        }
        let cell = try XCTUnwrap(
            calibratedCellSizePt(),
            "no calibrated cell size to derive the claim ceiling \(context)"
        )
        for entry in claims {
            guard let windowId = entry["window"] as? Int,
                  let claimed = entry["claimed"] as? String, claimed != "none" else { continue }
            let dims = claimed.split(separator: "x").compactMap { Int($0) }
            guard dims.count == 2 else {
                XCTFail("unparseable claim \(claimed) for @\(windowId) \(context)")
                continue
            }
            let content = try XCTUnwrap(
                contentByWindow[windowId],
                "@\(windowId) claimed \(claimed) with no visible window frame \(context)"
            )
            let ceilingCols = Int(content.width / cell.width) + 2
            let ceilingRows = Int(content.height / cell.height) + 2
            XCTAssertLessThanOrEqual(
                dims[0], ceilingCols,
                "@\(windowId) claimed \(claimed) cols over the window ceiling "
                    + "(content \(Int(content.width))pt / cell \(cell.width)pt + 2 = \(ceilingCols)) "
                    + "\(context) — a content-derived width reached the claim"
            )
            XCTAssertLessThanOrEqual(
                dims[1], ceilingRows,
                "@\(windowId) claimed \(claimed) rows over the window ceiling "
                    + "(content \(Int(content.height))pt / cell \(cell.height)pt + 2 = \(ceilingRows)) "
                    + "\(context) — a content-derived height reached the claim"
            )
        }
    }

    /// The cell size in points from the first live calibration sample in
    /// `pane_grids` (cell px over backing scale) — the divisor the claim's
    /// own `floor(available / cell)` uses.
    func calibratedCellSizePt() -> (width: Double, height: Double)? {
        guard let windows = paneGridsWindows() else { return nil }
        for window in windows {
            for pane in window["panes"] as? [[String: Any]] ?? [] {
                guard let calibration = pane["calibration"] as? [String: Any],
                      let cellPx = calibration["cell_px"] as? [String: Any],
                      let width = cellPx["w"] as? Double, width > 0,
                      let height = cellPx["h"] as? Double, height > 0,
                      let scale = calibration["scale"] as? Double, scale > 0 else { continue }
                return (width / scale, height / scale)
            }
        }
        return nil
    }

    /// The pushed column count `pane_grids` reports for a tmux window.
    func pushedCols(window: Int) -> Int? {
        guard let windows = paneGridsWindows() else { return nil }
        for entry in windows where (entry["window_id"] as? String) == "@\(window)" {
            return (entry["pushed"] as? [String: Any])?["cols"] as? Int
        }
        return nil
    }

    func splitWindowPaneIds() throws -> [String] {
        let out = try XCTUnwrap(tmux(["list-panes", "-t", "\(sessionName):@0", "-F", "#{pane_id}"]))
        return out.split(separator: "\n").map(String.init)
    }
}
