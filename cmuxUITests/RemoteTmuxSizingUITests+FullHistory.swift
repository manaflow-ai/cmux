import XCTest
import Foundation

/// The find bar's full tmux history load, end to end against the lab tmux
/// server: the attach seed holds only the newest 5,000 rows, and the load
/// repaints the mirrored pane with everything tmux keeps.
extension RemoteTmuxSizingUITests {

    /// Builds a session whose "hist" window printed `rows` numbered rows
    /// (`plain`: `seq`, `dense`: 24-bit color per cell) into a pane with room
    /// for all of them, then waits for tmux to hold them.
    private func buildHistoryLab(rows: Int, style: String) throws -> String {
        _ = tmux(["kill-server"])
        XCTAssertNotNil(
            tmux(["new-session", "-d", "-s", sessionName, "-x", "120", "-y", "30", "-n", "main"]),
            "lab server never started: \(lastTmuxFailure ?? "no stderr captured")"
        )
        XCTAssertNotNil(tmux(["set-history-limit", "\(rows + 10_000)"]), "\(lastTmuxFailure ?? "")")
        XCTAssertNotNil(tmux(["new-window", "-t", sessionName, "-n", "hist"]), "\(lastTmuxFailure ?? "")")
        let pane = try XCTUnwrap(
            tmux(["list-panes", "-t", "\(sessionName):hist", "-F", "#{pane_id}"])?
                .split(separator: "\n").first.map(String.init),
            "no pane in the hist window"
        )
        XCTAssertNotNil(tmux(["print-history", "-t", pane, "\(rows)", style]), "\(lastTmuxFailure ?? "")")
        let deadline = Date().addingTimeInterval(120)
        var historySize = 0
        while Date() < deadline {
            historySize = Int(tmux(["display-message", "-p", "-t", pane, "#{history_size}"]) ?? "") ?? 0
            if historySize >= rows - 100 { return pane }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("tmux never held the printed history: history_size=\(historySize)")
        return pane
    }

    private func scrollbackLines(surfaceId: String) -> [String] {
        guard let response = socketJSON(method: "surface.read_text", params: [
            "surface_id": surfaceId,
            "scrollback": true,
        ]),
        response["ok"] as? Bool == true,
        let text = response["text"] as? String else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func connectionEvents() -> [String] {
        let state = socketJSON(method: "remote.tmux.state", params: [
            "host": "e2e-shim-host",
            "session": sessionName,
        ])
        return (state?["recent_events"] as? [String]) ?? []
    }

    /// Opens the find bar on the hist pane and asks for the full history the
    /// way a user does: Option-Return in the find field.
    private func requestFullHistory(app: XCUIApplication, surfaceId: String) {
        // selectTab already focused the hist tab; this pins the pane. A refusal is
        // logged, not fatal: the find-bar button check below is the real gate.
        let focus = socketJSON(method: "surface.focus", params: ["surface_id": surfaceId])
        if focus?["ok"] as? Bool != true {
            print("surface.focus \(surfaceId) refused: \(focus ?? [:]); surfaces: \(onScreenPaneSurfaces())")
        }
        app.typeKey("f", modifierFlags: [.command])
        let button = app.buttons["TerminalFindFullTmuxHistoryButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the find bar shows no full-history button")
        app.typeKey(.return, modifierFlags: [.option])
    }

    func testFullHistoryLoadPaintsRowsOlderThanTheAttachSeed() throws {
        try requireTmux()
        let app = launchApp()
        defer { app.terminate() }
        let pane = try buildHistoryLab(rows: 30_000, style: "plain")
        attachSession()
        setMirrorWindowSize(CGSize(width: 1000, height: 700))
        XCTAssertTrue(selectTab(named: "hist"), "could not select hist tab")
        let surfaceId = try XCTUnwrap(
            waitForValue(timeout: 15) { self.onScreenPaneSurfaces()[pane] },
            "hist pane has no on-screen surface"
        )
        // The attach seed reads the newest 5,000 rows: 30000 is there, 12345 is not.
        XCTAssertNotNil(
            waitForValue(timeout: 15) { self.scrollbackLines(surfaceId: surfaceId).contains("30000") ? true : nil },
            "attach seed never painted the newest row"
        )
        XCTAssertFalse(
            scrollbackLines(surfaceId: surfaceId).contains("12345"),
            "the attach seed already held row 12345, so this test can't tell the load apart"
        )

        requestFullHistory(app: app, surfaceId: surfaceId)

        let loaded = waitForValue(timeout: 60) { () -> Bool? in
            let lines = self.scrollbackLines(surfaceId: surfaceId)
            return lines.contains("12345") && lines.contains("1") && lines.contains("30000") ? true : nil
        }
        let events = connectionEvents()
        XCTAssertNotNil(
            loaded,
            "full history never painted row 12345. events: \(events.suffix(20))"
        )
        XCTAssertTrue(events.contains { $0.hasPrefix("pane-full-history-seed \(pane) ") }, "no full-history seed: \(events.suffix(20))")
        XCTAssertFalse(events.contains { $0.hasPrefix("reconnecting") }, "the load reconnected: \(events.suffix(20))")
    }

    /// A long history of densely colored output: every cell changes its 24-bit
    /// foreground. The load must finish without the control stream falling
    /// behind far enough to reconnect.
    func testFullHistoryLoadOfDenseColorOutputDoesNotReconnect() throws {
        try requireTmux()
        let app = launchApp()
        defer { app.terminate() }
        let rows = 40_000
        let pane = try buildHistoryLab(rows: rows, style: "dense")
        attachSession()
        setMirrorWindowSize(CGSize(width: 1000, height: 700))
        XCTAssertTrue(selectTab(named: "hist"), "could not select hist tab")
        let surfaceId = try XCTUnwrap(
            waitForValue(timeout: 15) { self.onScreenPaneSurfaces()[pane] },
            "hist pane has no on-screen surface"
        )
        requestFullHistory(app: app, surfaceId: surfaceId)

        let finished = waitForValue(timeout: 90) { () -> [String]? in
            let events = self.connectionEvents()
            let ended = events.contains { $0.hasPrefix("reconnecting") || $0 == "stdout-backpressure" }
            let lines = self.scrollbackLines(surfaceId: surfaceId)
            // Older than the attach seed's 5,000 rows, newer than the ~12 MiB the
            // load keeps at about 1.2 KB a row.
            let painted = lines.contains { $0.hasSuffix(" L\(rows - 7_000)") }
            return ended || painted ? events : nil
        }
        let events = try XCTUnwrap(finished, "the load neither painted nor failed: \(connectionEvents().suffix(20))")
        XCTAssertTrue(events.contains { $0.hasPrefix("pane-full-history-seed \(pane) ") }, "no full-history seed: \(events.suffix(20))")
        XCTAssertFalse(events.contains("stdout-backpressure"), "the load overran the stdout bridge: \(events.suffix(20))")
        XCTAssertFalse(events.contains { $0.hasPrefix("reconnecting") }, "the load reconnected: \(events.suffix(20))")
    }

    private func waitForValue<T>(timeout: TimeInterval, _ probe: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = probe() { return value }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return probe()
    }
}
