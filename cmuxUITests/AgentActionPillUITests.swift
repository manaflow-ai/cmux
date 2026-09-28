import Foundation
import XCTest

/// Drives the terminal Stop pill (`agentActions.turnControl`) end to end: a
/// journaled Claude Code turn on a terminal shows the pill, and clicking Stop
/// journals the interrupt so the pill hides again.
final class AgentActionPillUITests: XCTestCase {
    private let stopLabel = "Interrupt Claude Code (Esc)"
    private var root: URL!
    private var socketPath = ""
    private var app: XCUIApplication?

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-pill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // The app runs outside the test runner's sandbox; a socket in the
        // runner's temporary directory is reachable from both processes.
        // Keep the UNIX path below sun_path.
        socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("p\(UUID().uuidString.prefix(6))").path
        XCTAssertLessThan(socketPath.utf8.count, 104)
    }

    override func tearDown() {
        app?.terminate()
        app = nil
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: socketPath + ".lock")
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    func testStopPillShowsWhileClaudeRunsAndHidesAfterStop() throws {
        let app = try launchApp(turnControlEnabled: true)
        let target = try openTerminal()

        try startClaudeTurn(on: target)

        let stop = app.buttons[stopLabel]
        XCTAssertTrue(
            stop.waitForExistence(timeout: 15.0),
            "Expected the Stop pill once Claude Code is running on the terminal"
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
        let app = try launchApp(turnControlEnabled: false)
        let target = try openTerminal()

        try startClaudeTurn(on: target)

        let stop = app.buttons[stopLabel]
        XCTAssertFalse(
            stop.waitForExistence(timeout: 5.0),
            "The Stop pill must stay hidden while agentActions.turnControl is off"
        )
        attachWindowScreenshot(app, name: "agent-stop-pill-setting-off")
    }

    // MARK: - Launch

    private func launchApp(turnControlEnabled: Bool) throws -> XCUIApplication {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchArguments += [
            "-socketControlMode", "allowAll",
            "-NSAppSleepDisabled", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-agentActionsTurnControlEnabled", turnControlEnabled ? "YES" : "NO",
        ]
        app.launchEnvironment["HOME"] = root.path
        app.launchEnvironment["CFFIXED_USER_HOME"] = root.path
        app.launchEnvironment["XDG_CONFIG_HOME"] = root.appendingPathComponent(".config").path
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = "ui-tests-agent-pill-\(UUID().uuidString.prefix(8))"
        self.app = app

        // Headless runners can refuse activation; the flow is socket-driven
        // and the pill is found through accessibility either way.
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }
        XCTAssertTrue(
            app.state == .runningForeground || app.state == .runningBackground,
            "App failed to start. state=\(app.state.rawValue)"
        )

        let ready = waitForControlSocketReady(
            socketPath: socketPath,
            pingTimeout: 20.0
        ) { self.command("ping", timeout: 2.0) == "PONG" }
        XCTAssertTrue(ready, "Control socket never answered ping at \(socketPath)")
        return app
    }

    // MARK: - Socket

    private struct Terminal {
        let workspaceID: String
        let surfaceID: String
    }

    private func command(_ line: String, timeout: TimeInterval = 10.0) -> String? {
        controlSocketCommandViaNetcat(line, socketPath: socketPath, responseTimeout: timeout)
    }

    /// Opens a focused terminal workspace and returns its ids. Retries while
    /// the app's main thread settles after a cold launch.
    private func openTerminal() throws -> Terminal {
        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": "workspace.create",
            "params": ["title": "Agent Stop pill", "focus": true],
        ]
        var last: [String: Any]?
        let deadline = Date().addingTimeInterval(60.0)
        repeat {
            last = controlSocketJSONViaNetcat(request, socketPath: socketPath, responseTimeout: 15.0)
            if last?["ok"] as? Bool == true,
               let result = last?["result"] as? [String: Any],
               let workspaceID = result["workspace_id"] as? String,
               let surfaceID = result["surface_id"] as? String {
                return Terminal(workspaceID: workspaceID, surfaceID: surfaceID)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        } while Date() < deadline
        return try XCTUnwrap(
            nil as Terminal?,
            "workspace.create never returned a terminal: \(String(describing: last)); ping=\(command("ping", timeout: 2.0) ?? "nil")"
        )
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
        let reply = command("agent_journal_append \(json)", timeout: 10.0)
        XCTAssertTrue(reply?.hasPrefix("OK") == true, "agent_journal_append failed: \(reply ?? "nil")")
    }

    // MARK: - UI

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
