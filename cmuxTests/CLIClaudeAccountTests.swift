import XCTest
import Darwin
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `cmux claude-account`: `switch` sends one `claude_account.switch` for the calling terminal and
/// relays what the app decided; `list` reads cmux.json without a socket.
extension CLINotifyProcessIntegrationRegressionTests {
    func testClaudeAccountSwitchTargetsTheCallingTerminal() throws {
        let surfaceId = UUID().uuidString
        let result = try runClaudeAccountCLI(
            name: "claude-account-switch",
            arguments: ["claude-account", "switch", "work"],
            callerSurfaceId: surfaceId,
            respond: { method, id in
                method == "claude_account.switch"
                    ? self.v2Response(id: id, ok: true, result: [
                        "surface_id": surfaceId, "session_id": "s1", "from": "default", "to": "work",
                        "transcript": "copied", "resumed": true,
                    ])
                    : nil
            }
        )
        XCTAssertEqual(result.process.status, 0, result.process.stderr)
        let request = try XCTUnwrap(result.commands.compactMap(jsonObject).first {
            $0["method"] as? String == "claude_account.switch"
        }, "\(result.commands)")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["account"] as? String, "work")
        XCTAssertEqual(params["surface_id"] as? String, surfaceId)
        XCTAssertEqual(params["force"] as? Bool, false)
        XCTAssertTrue(result.process.stdout.contains("default"), result.process.stdout)
        XCTAssertTrue(result.process.stdout.contains("work"), result.process.stdout)
        XCTAssertFalse(result.process.stdout.contains("--resume"), result.process.stdout)
    }

    func testClaudeAccountSwitchPrintsTheResumeCommandItCouldNotType() throws {
        let surfaceId = UUID().uuidString
        let resumeCommand = "cd /tmp/project && env -u CLAUDE_CONFIG_DIR claude --resume s1"
        let result = try runClaudeAccountCLI(
            name: "claude-account-manual",
            arguments: ["claude-account", "switch", "default", "--surface", surfaceId, "--force"],
            callerSurfaceId: nil,
            respond: { method, id in
                method == "claude_account.switch"
                    ? self.v2Response(id: id, ok: true, result: [
                        "surface_id": surfaceId, "session_id": "s1", "from": "work", "to": "default",
                        "transcript": "refreshed", "resumed": false, "resume_command": resumeCommand,
                        "pane_closed": false,
                    ])
                    : nil
            }
        )
        XCTAssertEqual(result.process.status, 0, result.process.stderr)
        XCTAssertTrue(result.process.stdout.contains(resumeCommand), result.process.stdout)
        let request = try XCTUnwrap(result.commands.compactMap(jsonObject).first {
            $0["method"] as? String == "claude_account.switch"
        })
        XCTAssertEqual((request["params"] as? [String: Any])?["force"] as? Bool, true)
    }

    /// A transcript re-sync that failed gets its own explanation, not the generic "couldn't resume"
    /// one, so the user knows the copy on the new account may be missing the last messages.
    func testClaudeAccountSwitchExplainsAFailedTranscriptResync() throws {
        let resumeCommand = "cd /tmp/project && CLAUDE_CONFIG_DIR=/tmp/.claude-work claude --resume s1"
        func output(notResumedReason: String, name: String) throws -> String {
            let surfaceId = UUID().uuidString
            let result = try runClaudeAccountCLI(
                name: name,
                arguments: ["claude-account", "switch", "work", "--surface", surfaceId],
                callerSurfaceId: nil,
                respond: { method, id in
                    method == "claude_account.switch"
                        ? self.v2Response(id: id, ok: true, result: [
                            "surface_id": surfaceId, "session_id": "s1", "from": "default", "to": "work",
                            "transcript": "copied", "resumed": false, "resume_command": resumeCommand,
                            "pane_closed": false, "not_resumed_reason": notResumedReason,
                        ])
                        : nil
                }
            )
            XCTAssertEqual(result.process.status, 0, result.process.stderr)
            XCTAssertTrue(result.process.stdout.contains(resumeCommand), result.process.stdout)
            return result.process.stdout.replacingOccurrences(of: surfaceId, with: "<surface>")
        }

        let resyncFailed = try output(notResumedReason: "transcript_resync_failed", name: "claude-account-resync")
        let noPrompt = try output(notResumedReason: "no_prompt", name: "claude-account-noprompt")

        // The helper runs the CLI in English; compare with that catalog's text for each reason.
        let resyncText = try claudeAccountCatalogValue("cli.claudeAccount.transcriptResyncFailed", language: "en")
        let noPromptText = try claudeAccountCatalogValue("cli.claudeAccount.resumeManually", language: "en")
        XCTAssertNotEqual(resyncText, noPromptText)
        XCTAssertTrue(resyncFailed.contains(resyncText), resyncFailed)
        XCTAssertFalse(resyncFailed.contains(noPromptText), resyncFailed)
        XCTAssertTrue(noPrompt.contains(noPromptText), noPrompt)
        XCTAssertFalse(noPrompt.contains(resyncText), noPrompt)
    }

    /// The app's refusal already says how to force the switch; the CLI relays it once and adds
    /// no second hint.
    func testClaudeAccountSwitchWhileClaudeRespondsRelaysTheAppsForceHintOnce() throws {
        let appMessage = "Claude is responding in this terminal. Retry with force to stop the response and switch."
        let result = try runClaudeAccountCLI(
            name: "claude-account-running",
            arguments: ["claude-account", "switch", "work"],
            callerSurfaceId: UUID().uuidString,
            respond: { method, id in
                method == "claude_account.switch"
                    ? self.v2Response(id: id, ok: false, error: [
                        "code": "agent_running",
                        "message": appMessage,
                    ])
                    : nil
            }
        )
        XCTAssertNotEqual(result.process.status, 0)
        XCTAssertTrue(result.process.stderr.contains("agent_running"), result.process.stderr)
        XCTAssertTrue(result.process.stderr.contains(appMessage), result.process.stderr)
        XCTAssertEqual(result.process.stderr.components(separatedBy: "force").count - 1, 1, result.process.stderr)
    }

    func testClaudeAccountSwitchOutsideCmuxNeedsATarget() throws {
        let result = try runClaudeAccountCLI(
            name: "claude-account-notarget",
            arguments: ["claude-account", "switch", "work"],
            callerSurfaceId: nil,
            respond: { _, _ in nil }
        )
        XCTAssertNotEqual(result.process.status, 0)
        XCTAssertTrue(result.process.stderr.contains("--surface"), result.process.stderr)
        XCTAssertFalse(result.commands.contains { $0.contains("claude_account.switch") }, "\(result.commands)")
    }

    func testClaudeAccountSwitchWithOnlyAWorkspaceNeedsASurface() throws {
        // The app requires surface_id; a workspace alone never means "its focused pane".
        let result = try runClaudeAccountCLI(
            name: "claude-account-wsonly",
            arguments: ["claude-account", "switch", "work", "--workspace", UUID().uuidString],
            callerSurfaceId: UUID().uuidString,
            respond: { _, _ in nil }
        )
        XCTAssertNotEqual(result.process.status, 0)
        XCTAssertTrue(result.process.stderr.contains("--surface"), result.process.stderr)
        XCTAssertFalse(result.commands.contains { $0.contains("claude_account.switch") }, "\(result.commands)")
    }

    func testClaudeAccountListReadsTheConfigWithoutTheApp() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-account-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: home) }
        let configDirectory = home.appendingPathComponent(".config/cmux")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try Data("""
        { // JSONC
          "agents": { "claudeAccounts": [{ "name": "work", "configDir": "~/.claude-work" }] }
        }
        """.utf8).write(to: configDirectory.appendingPathComponent("cmux.json"))

        var environment = ProcessInfo.processInfo.environment
        environment["AppleLanguages"] = "(en)"
        environment["AppleLocale"] = "en_US"
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        environment["CMUX_SOCKET_PATH"] = makeSocketPath("claude-account-list")
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        let cliPath = try bundledCLIPath()

        let text = runProcess(executablePath: cliPath, arguments: ["claude-account", "list"], environment: environment, timeout: 5)
        XCTAssertEqual(text.status, 0, text.stderr)
        let lines = text.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2, text.stdout)
        XCTAssertTrue(lines.first?.hasPrefix("default") == true && lines.first?.contains("~/.claude") == true, text.stdout)
        XCTAssertTrue(lines.last?.hasPrefix("work") == true && lines.last?.contains("~/.claude-work") == true, text.stdout)

        let json = runProcess(executablePath: cliPath, arguments: ["claude-account", "list", "--json"], environment: environment, timeout: 5)
        XCTAssertEqual(json.status, 0, json.stderr)
        let accounts = try XCTUnwrap(jsonObject(json.stdout)?["accounts"] as? [[String: Any]], json.stdout)
        XCTAssertEqual(accounts.map { $0["name"] as? String }, ["default", "work"])
        XCTAssertEqual(accounts.map { $0["default"] as? Bool }, [true, false])
        // Absolute in JSON, unlike the `~/` text form, and under the fixture home: the CLI reads
        // its home from NSHomeDirectory() (CFFIXED_USER_HOME here) and standardizes the path.
        let workDirectory = try XCTUnwrap(accounts.last?["config_dir"] as? String)
        XCTAssertEqual(workDirectory, (home.path as NSString).standardizingPath + "/.claude-work")
    }

    /// The CLI executable has no string catalog of its own; its text comes from the enclosing
    /// app's, so `claude-account` help follows the user's language like the rest of the CLI.
    func testClaudeAccountHelpUsesTheAppCatalog() throws {
        let cliPath = try bundledCLIPath()
        let german = try claudeAccountCatalogValue("cli.claudeAccount.help", language: "de")
        XCTAssertNotEqual(german, try claudeAccountCatalogValue("cli.claudeAccount.help", language: "en"))

        // Its own home, so no cmux.json or defaults of the user running the tests reach the CLI.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-account-help-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        var environment = ProcessInfo.processInfo.environment
        environment["AppleLanguages"] = "(de)"
        environment["AppleLocale"] = "de_DE"
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        environment["CMUX_SOCKET_PATH"] = makeSocketPath("claude-account-help")
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        let result = runProcess(executablePath: cliPath, arguments: ["claude-account", "--help"], environment: environment, timeout: 5)

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains(german), result.stdout)
    }

    /// `key`'s value in the bundled app's compiled catalog for `language`, so tests compare the
    /// CLI's output with the catalog instead of hard-coding a translation.
    private func claudeAccountCatalogValue(_ key: String, language: String) throws -> String {
        let resources = URL(fileURLWithPath: try bundledCLIPath())
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let strings = resources.appendingPathComponent("\(language).lproj/Localizable.strings")
        let table = try XCTUnwrap(NSDictionary(contentsOf: strings) as? [String: String], strings.path)
        return try XCTUnwrap(table[key], key)
    }

    private func runClaudeAccountCLI(
        name: String,
        arguments: [String],
        callerSurfaceId: String?,
        respond: @escaping (_ method: String, _ id: String) -> String?
    ) throws -> (process: ProcessRunResult, commands: [String]) {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath(name)
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            return respond(method, id) ?? self.v2Response(
                id: id,
                ok: false,
                error: ["code": "unexpected", "message": "Unexpected method \(method)"]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        // The CLI's text follows the user's language; these tests read the English catalog.
        environment["AppleLanguages"] = "(en)"
        environment["AppleLocale"] = "en_US"
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_WORKSPACE_ID"] = nil
        environment["CMUX_SURFACE_ID"] = callerSurfaceId
        let result = runProcess(
            executablePath: cliPath,
            arguments: arguments,
            environment: environment,
            timeout: 5
        )
        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        return (result, state.commands)
    }
}
