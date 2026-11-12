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
        // Like the Claude hook: a lifecycle report plus the status entry that
        // draws the row with compact status off. Agent status rows show only
        // for a live agent PID; the app's own ({pid}) stands in for Claude.
        ("needs input", [
            "set_agent_pid claude_code {pid} --tab={tab}",
            "set_agent_lifecycle claude_code needsInput --tab={tab}",
            "set_status claude_code \"Needs input\" --icon=bell.fill --color=#4C8DFF --tab={tab}",
        ]),
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
        // Notified below, once another workspace is selected, so it stays unread.
        ("unseen", ["let unseen"]),
        ("plain terminal", []),
    ]

    /// A collapsed group whose hidden members need input and are running:
    /// its header shows the needs-input glyph, naming both members.
    private let groupCommands: [String] = [
        "new_workspace grouped input", "select_workspace {last}", "wait 400", "let groupedInput",
        "set_agent_lifecycle claude_code needsInput --tab={groupedInput}",
        "new_workspace grouped running", "select_workspace {last}", "wait 400", "let groupedRunning",
        "set_agent_lifecycle claude_code running --tab={groupedRunning}",
        #"{"id":"group","method":"workspace.group.create","params":{"name":"agents","child_workspace_ids":["{groupedInput}","{groupedRunning}"]}}"#,
        #"{"id":"collapse","method":"workspace.group.collapse","params":{"group_id":"{group}"}}"#,
        "wait 400",
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
            ["new_workspace \(scenario.title)", "select_workspace {last}", "wait 400"]
                + scenario.commands.map { $0.replacingOccurrences(of: "{tab}", with: "{last}") }
        } + [
            "list_surfaces {unseen}",
            "notify_target {unseen} {surface} Done|Claude Code|Finished",
            "wait 400",
        ] + groupCommands
        app.launchArguments += ["-newWorkspacePlacement", "end"]
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // Plist syntax: the settings decoder accepts only real booleans, and a
        // bare YES/NO argument arrives as a string and falls back to the default.
        app.launchArguments += ["-sidebarCompactAgentStatus", compact ? "<true/>" : "<false/>"]
        app.launchArguments += ["-socketControlMode", "allowAll"]
        // Keep the reported branches and PRs: shell integration reports the
        // real (non-repo) state of the terminal's directory at each prompt,
        // clearing them, and with git watching off it clears them outright.
        app.launchArguments += ["-sidebarShellIntegration", "<false/>"]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = "ui-compact-status-\(token.prefix(8))"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_COMMANDS"] = commands.joined(separator: "\n")
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_COMMANDS_RESULT_PATH"] = resultPath

        launchAndEnsureRunning(app)
        var result: [String: Any] = [:]
        let finished = pollUntil(timeout: 40.0) {
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
        // The workspace list is the window's first table. Query inside it: an
        // app-wide descendants query also walks the right sidebar's file tree
        // and can time out.
        let sidebar = app.tables.firstMatch
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
            // "Finished" is the unseen workspace's notification, which leads its tooltip.
            // "grouped input: " is the collapsed group header's roll-up.
            for label in ["Needs input", "PR #12: open", "PR #13: merged", "main", "Idle", "Finished", "grouped input: "] {
                let glyph = sidebar.descendants(matching: .any)
                    .matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
                XCTAssertTrue(glyph.waitForExistence(timeout: 5.0), "Expected a compact status glyph labelled \(label)")
            }
            // One line per row: branch and PR details live in the tooltip only.
            for detail in ["feat/sidebar", "feat/done"] {
                let line = sidebar.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", detail)).firstMatch
                XCTAssertFalse(line.exists, "Expected no \(detail) line under the title in compact mode")
            }
        }
        if !compact {
            let agentStatusRow = sidebar.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Needs input", "Needs input"))
                .firstMatch
            XCTAssertTrue(
                agentStatusRow.waitForExistence(timeout: 5.0),
                "Expected an agent-status row when compact mode is disabled"
            )
        }
        // The custom (non-agent) status keeps its row in both modes.
        let customRow = sidebar.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "green", "green")).firstMatch
        XCTAssertTrue(customRow.waitForExistence(timeout: 5.0), "Expected the custom status row to stay visible")
    }

    /// A plain launch: CI's execution guard rejects a run whose launch was
    /// wrapped in an expected activation failure.
    private func launchAndEnsureRunning(_ app: XCUIApplication) {
        app.launch()
        let activated = pollUntil(timeout: 2.0) {
            if app.state == .runningForeground { return true }
            app.activate()
            return app.state == .runningForeground
        }
        XCTAssertTrue(
            activated || pollUntil(timeout: 2.0) { app.state == .runningForeground },
            "App did not reach runningForeground. state=\(app.state.rawValue)"
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
