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

    /// The app-side oracle over `remote.tmux.pane_grids`: full
    /// assigned==rendered for the SELECTED window; a claimed, applied size
    /// (base == pushed) for every other mirrored window (hidden tabs don't
    /// re-render to match until selected — that is the visibility contract,
    /// not drift).
    func paneGridsFailure(selectedWindow: Int) -> String? {
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

    /// The pushed column count `pane_grids` reports for a tmux window.
    func pushedCols(window: Int) -> Int? {
        guard let response = socketJSON(method: "remote.tmux.pane_grids", params: [
            "host": "e2e-shim-host",
            "session": sessionName,
        ]), let windows = response["windows"] as? [[String: Any]] else { return nil }
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
