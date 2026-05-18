import XCTest
import Darwin

extension CLINotifyProcessIntegrationRegressionTests {
    func testLegacyCodexHookAliasReturnsJSONWithoutHelpAndPersistsSession() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("legacy-codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-legacy-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else {
                return line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
                    ? self.malformedRequestResponse(raw: line)
                    : "OK"
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            if method == "surface.list" { return self.surfaceListResponse(id: id, surfaceId: surfaceId) }
            return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_AGENT_LAUNCH_KIND"] = "codex"
        environment["CMUX_AGENT_LAUNCH_EXECUTABLE"] = "/usr/local/bin/codex"
        environment["CMUX_AGENT_LAUNCH_ARGV_B64"] = base64NULSeparated(["/usr/local/bin/codex", "--model", "gpt-5.4"])
        environment["CMUX_AGENT_LAUNCH_CWD"] = "/tmp/repo"
        environment["CODEX_HOME"] = root.appendingPathComponent("codex-home", isDirectory: true).path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["codex-hook", "session-start"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertFalse(result.stdout.contains("Usage:"), result.stdout)
        XCTAssertFalse(result.stderr.contains("Usage:"), result.stderr)

        let storeURL = root.appendingPathComponent("codex-hook-sessions.json", isDirectory: false)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
        let sessions = try XCTUnwrap(json["sessions"] as? [String: Any])
        let session = try XCTUnwrap(sessions[surfaceId] as? [String: Any])
        XCTAssertEqual(session["workspaceId"] as? String, workspaceId)
        XCTAssertEqual(session["surfaceId"] as? String, surfaceId)
        XCTAssertNotNil(session["launchCommand"] as? [String: Any])
    }

    func testLegacyFeedHookAliasReturnsJSONWithoutHelpOutsideCmuxTerminal() throws {
        let cliPath = try bundledCLIPath()
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = makeSocketPath("legacy-feed")
        environment.removeValue(forKey: "CMUX_WORKSPACE_ID")
        environment.removeValue(forKey: "CMUX_SURFACE_ID")
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["feed-hook", "--source", "codex"],
            environment: environment,
            standardInput: #"{"hook_event_name":"UserPromptSubmit","session_id":"legacy-feed"}"#,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertFalse(result.stdout.contains("Usage:"), result.stdout)
        XCTAssertFalse(result.stderr.contains("Usage:"), result.stderr)
    }

    // Regression: legacy `cmux <agent>-hook <subcommand>` aliases were removed
    // in commit 6beb3dbe1 ("Namespace agent hook commands") but `~/.cursor/hooks.json`
    // and other agent hook configs still point at them. The unknown-command path
    // prints the full CLI usage to stdout and exits non-zero, which combines with
    // the `|| echo '{}'` fallback in the installed hook command to produce
    // garbage-followed-by-`{}`. Cursor agent rejects that as invalid JSON and
    // blocks every shell command. The alias must succeed and emit exactly `{}\n`.
    func testLegacyCursorHookAliasShellExecReturnsJSONWithoutHelp() throws {
        try assertLegacyAgentHookAliasReturnsEmptyJSON(
            agentName: "cursor",
            subcommand: "shell-exec",
            slug: "legacy-cursor",
            stdin: #"{"command":"echo hello","cwd":"/tmp","hook_event_name":"beforeShellExecution"}"#
        )
    }

    // Regression: same class of bug for gemini-hook. Confirms the alias dispatch
    // generalizes across agents that lost their legacy `<agent>-hook` command.
    func testLegacyGeminiHookAliasReturnsJSONWithoutHelp() throws {
        try assertLegacyAgentHookAliasReturnsEmptyJSON(
            agentName: "gemini",
            subcommand: "session-start",
            slug: "legacy-gemini",
            stdin: #"{"hook_event_name":"SessionStart","session_id":"legacy-gemini"}"#
        )
    }

    private func assertLegacyAgentHookAliasReturnsEmptyJSON(
        agentName: String,
        subcommand: String,
        slug: String,
        stdin: String
    ) throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath(slug)
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-\(slug)-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else {
                return line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
                    ? self.malformedRequestResponse(raw: line)
                    : "OK"
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            if method == "surface.list" { return self.surfaceListResponse(id: id, surfaceId: surfaceId) }
            return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["\(agentName)-hook", subcommand],
            environment: environment,
            standardInput: stdin,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(result.stdout, "{}\n", "stderr=\(result.stderr)")
        XCTAssertFalse(result.stdout.contains("Usage:"), result.stdout)
        XCTAssertFalse(result.stderr.contains("Usage:"), result.stderr)
        XCTAssertFalse(result.stdout.contains("Unknown command"), result.stdout)
        XCTAssertFalse(result.stderr.contains("Unknown command"), result.stderr)
    }
}
