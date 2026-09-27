import Foundation
import XCTest

/// Launches cmux with `sidebar.compactAgentStatus` on and off, seeds one
/// workspace per glyph state with in-app socket commands
/// (`CMUX_UI_TEST_SOCKET_COMMANDS`), and keeps a sidebar screenshot so
/// reviewers and agents can see the rows (`scripts/ci/e2e-frames.py`).
final class SidebarCompactAgentStatusUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testCompactStatusGlyphsRenderOnTheTitleLine() {
        runScenario(compact: true)
    }

    func testStatusRowsWithCompactStatusOff() {
        runScenario(compact: false)
    }

    /// (workspace title, socket commands for it; `{tab}` is its workspace id)
    private let scenarios: [(title: String, commands: [String])] = [
        ("needs input", ["set_agent_lifecycle claude_code needsInput --tab={tab}"]),
        ("running", ["set_agent_lifecycle claude_code running --tab={tab}"]),
        ("open PR", [
            "set_agent_lifecycle codex idle --tab={tab}",
            "report_git_branch feat/sidebar --tab={tab}",
            "report_pr 12 https://github.com/manaflow-ai/cmux/pull/12 --label=PR --state=open --tab={tab}",
        ]),
        ("merged PR", [
            "report_git_branch feat/done --tab={tab}",
            "report_pr 13 https://github.com/manaflow-ai/cmux/pull/13 --label=PR --state=merged --tab={tab}",
        ]),
        ("branch only", ["report_git_branch main --tab={tab}"]),
        ("idle agent", ["set_agent_lifecycle claude_code idle --tab={tab}"]),
        ("starting agent", ["set_agent_lifecycle claude_code unknown --tab={tab}"]),
        ("custom status", ["set_status deploy green --icon=checkmark --tab={tab}"]),
    ]

    private func runScenario(compact: Bool) {
        let app = XCUIApplication.cmuxTestApplication()
        let token = UUID().uuidString
        let resultPath = "/tmp/cmux-ui-compact-status-\(token).json"
        defer {
            app.terminate()
            try? FileManager.default.removeItem(atPath: resultPath)
        }

        // The app runs these itself (UITestSocketCommandScript); `{last}` is
        // the workspace the preceding new_workspace created.
        let commands = scenarios.flatMap { scenario in
            ["new_workspace \(scenario.title)"]
                + scenario.commands.map { $0.replacingOccurrences(of: "{tab}", with: "{last}") }
        }
        app.launchArguments += ["-newWorkspacePlacement", "end"]
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += ["-sidebarCompactAgentStatus", compact ? "YES" : "NO"]
        app.launchArguments += ["-socketControlMode", "allowAll"]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = "ui-compact-status-\(token.prefix(8))"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_COMMANDS"] = commands.joined(separator: "\n")
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_COMMANDS_RESULT_PATH"] = resultPath

        launchAndEnsureRunning(app)
        var result: [String: Any] = [:]
        let finished = pollUntil(timeout: 20.0) {
            guard let data = FileManager.default.contents(atPath: resultPath),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            result = object
            return object["done"] as? String == "1"
        }
        let replies = (result["replies"] as? [String]) ?? []
        let replyLog = zip(commands, replies).map { "\($0) -> \($1)" }.joined(separator: "\n")
        let log = XCTAttachment(string: finished ? replyLog : "setup script never finished")
        log.name = "setup-replies"
        log.lifetime = .keepAlways
        add(log)

        app.activate()
        let sidebar = app.descendants(matching: .any)["Sidebar"].firstMatch
        _ = sidebar.waitForExistence(timeout: 5.0)
        // Capture before asserting, so a failed assertion still leaves the picture.
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        let window = app.windows.firstMatch
        let shot = XCTAttachment(screenshot: window.exists ? window.screenshot() : XCUIScreen.main.screenshot())
        shot.name = compact ? "compact-status-sidebar" : "status-rows-sidebar"
        shot.lifetime = .keepAlways
        add(shot)

        XCTAssertTrue(finished, "The in-app setup script did not finish")
        XCTAssertEqual(result["failed"] as? String, "0", "Setup commands failed:\n\(replyLog)")
        XCTAssertTrue(sidebar.exists, "Expected the workspace sidebar")

        if compact {
            // Glyph accessibility labels carry the tooltip text.
            for label in ["Needs input", "PR #12: open", "PR #13: merged", "main", "Idle"] {
                let glyph = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
                XCTAssertTrue(glyph.waitForExistence(timeout: 5.0), "Expected a compact status glyph labelled \(label)")
            }
        }
        // The custom (non-agent) status keeps its row in both modes.
        let customRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "green", "green")).firstMatch
        XCTAssertTrue(customRow.waitForExistence(timeout: 5.0), "Expected the custom status row to stay visible")
    }

    private func launchAndEnsureRunning(_ app: XCUIApplication) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("Headless CI may launch the app without foreground activation", options: options) {
            app.launch()
        }
        XCTAssertTrue(
            pollUntil(timeout: 10.0) {
                app.state == .runningForeground || app.state == .runningBackground
            },
            "App failed to launch. state=\(app.state.rawValue)"
        )
    }

    private func pollUntil(
        timeout: TimeInterval,
        interval: TimeInterval = 0.05,
        condition: () -> Bool
    ) -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        while true {
            if condition() {
                return true
            }
            if ProcessInfo.processInfo.systemUptime - start >= timeout {
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(interval))
        }
    }
}
