import Foundation
import XCTest

/// Drives the terminal Stop pill (`agentActions.turnControl`) end to end: a
/// journaled Claude Code turn on the focused terminal shows the pill, and
/// clicking Stop journals the interrupt so the pill hides again.
final class AgentActionPillUITests: BrowserFixtureSocketTestCase {
    private let stopLabel = "Interrupt Claude Code (Esc)"

    func testStopPillShowsWhileClaudeRunsAndHidesAfterStop() throws {
        let app = try launchApp(additionalLaunchArguments: [
            "-agentActionsTurnControlEnabled", "YES",
        ])
        app.activate()
        let target = try focusedTerminal()

        try startClaudeTurn(on: target)

        let stop = app.buttons[stopLabel]
        XCTAssertTrue(
            stop.waitForExistence(timeout: 15.0),
            "Expected the Stop pill once Claude Code is running on the focused terminal"
        )
        attachWindowScreenshot(app, name: "agent-stop-pill-running")

        stop.click()

        XCTAssertTrue(
            waitForNonExistence(stop, timeout: 15.0),
            "Expected Stop to settle the turn and hide the pill"
        )
        attachWindowScreenshot(app, name: "agent-stop-pill-after-stop")
    }

    func testStopPillStaysHiddenWhenSettingIsOff() throws {
        let app = try launchApp(additionalLaunchArguments: [
            "-agentActionsTurnControlEnabled", "NO",
        ])
        app.activate()
        let target = try focusedTerminal()

        try startClaudeTurn(on: target)

        let stop = app.buttons[stopLabel]
        XCTAssertFalse(
            stop.waitForExistence(timeout: 5.0),
            "The Stop pill must stay hidden while agentActions.turnControl is off"
        )
        attachWindowScreenshot(app, name: "agent-stop-pill-setting-off")
    }

    // MARK: - Helpers

    private struct Terminal {
        let workspaceID: String
        let surfaceID: String
    }

    /// Opens a focused terminal workspace and returns its ids.
    private func focusedTerminal() throws -> Terminal {
        let params: [String: Any] = ["title": "Agent Stop pill", "focus": true]
        let request: [String: Any] = ["id": UUID().uuidString, "method": "workspace.create", "params": params]
        var last: [String: Any]?
        let deadline = Date().addingTimeInterval(20.0)
        repeat {
            // The netcat path is the fallback for hosted runners where the
            // in-process socket client cannot connect.
            last = socketEnvelope(method: "workspace.create", params: params, responseTimeout: 12.0)
                ?? controlSocketJSONViaNetcat(request, socketPath: socketPath, responseTimeout: 12.0)
            if last?["ok"] as? Bool == true,
               let result = last?["result"] as? [String: Any],
               let workspaceID = result["workspace_id"] as? String,
               let surfaceID = result["surface_id"] as? String {
                return Terminal(workspaceID: workspaceID, surfaceID: surfaceID)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < deadline
        return try XCTUnwrap(nil as Terminal?, "workspace.create never returned a terminal: \(String(describing: last)) socket=\(socketPath)")
    }

    /// Journals `agent.turn.started` for a fake Claude Code session on the
    /// terminal, the same event the Claude prompt-submit hook emits.
    private func startClaudeTurn(on terminal: Terminal) throws {
        let draft: [String: Any] = [
            "schema_version": 1,
            "event_id": "ui-test-\(UUID().uuidString)",
            "kind": "agent.turn.started",
            "occurred_at_ms": Int64(Date().timeIntervalSince1970 * 1000),
            "source": "claude",
            "agent_key": "claude_code",
            "session_id": "ui-test-session-\(UUID().uuidString)",
            "workspace_id": terminal.workspaceID,
            "surface_id": terminal.surfaceID,
            "is_subagent": false,
            "pending_work": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: draft)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let reply = controlSocketCommandViaNetcat(
            "agent_journal_append \(json)",
            socketPath: socketPath,
            responseTimeout: 10.0
        )
        XCTAssertTrue(reply?.hasPrefix("OK") == true, "agent_journal_append failed: \(reply ?? "nil")")
    }

    private func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return !element.exists
    }

    private func attachWindowScreenshot(_ app: XCUIApplication, name: String) {
        let window = app.windows.firstMatch
        let screenshot = window.exists ? window.screenshot() : app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
