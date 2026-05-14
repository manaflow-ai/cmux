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

    /// Regression test for older `~/.cursor/hooks.json` installs that still
    /// contain `cmux cursor-hook <sub>` entries. The new shape is
    /// `cmux hooks cursor <sub>` (`cmux hooks setup` rewrites the file on
    /// install), but until the user reinstalls hooks the legacy alias must
    /// keep returning valid JSON (`{}`) so Cursor does not block every
    /// `beforeShellExecution` event with an "invalid JSON" error.
    func testLegacyCursorHookAliasReturnsJSONWithoutHelpForShellExec() throws {
        try assertLegacyAgentHookAliasReturnsEmptyJSON(
            agent: "cursor",
            subcommand: "shell-exec",
            launchKind: "cursor",
            launchExecutable: "/Users/example/.local/bin/cursor-agent",
            launchArguments: ["/Users/example/.local/bin/cursor-agent", "agent"],
            launchCwd: "/tmp/cursor-repo",
            socketLabel: "legacy-cursor-shell"
        )
    }

    /// Same regression for `cmux gemini-hook session-start` so we don't
    /// re-break the next agent that gets renamed under `cmux hooks <agent>`.
    func testLegacyGeminiHookAliasReturnsJSONWithoutHelpForSessionStart() throws {
        try assertLegacyAgentHookAliasReturnsEmptyJSON(
            agent: "gemini",
            subcommand: "session-start",
            launchKind: "gemini",
            launchExecutable: "/Users/example/.bun/bin/gemini",
            launchArguments: ["/Users/example/.bun/bin/gemini", "--model", "gemini-2.5-pro"],
            launchCwd: "/tmp/gemini-repo",
            socketLabel: "legacy-gemini"
        )
    }

    /// Older installs also have a Feed-specific legacy entry of the form
    /// `cmux feed-hook --source cursor` (no `--event`). When invoked inside
    /// a cmux terminal it must still print `{}` so the Cursor hook chain
    /// does not break.
    func testLegacyFeedHookAliasReturnsJSONForCursorSourceInsideCmuxTerminal() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("legacy-feed-cursor")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
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
            if method == "feed.push" { return self.v2Response(id: id, ok: true, result: [:]) }
            return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["feed-hook", "--source", "cursor"],
            environment: environment,
            standardInput: #"{"hook_event_name":"PreToolUse","session_id":"legacy-feed-cursor"}"#,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertFalse(result.stdout.contains("Usage:"), result.stdout)
        XCTAssertFalse(result.stderr.contains("Usage:"), result.stderr)
    }

    private func assertLegacyAgentHookAliasReturnsEmptyJSON(
        agent: String,
        subcommand: String,
        launchKind: String,
        launchExecutable: String,
        launchArguments: [String],
        launchCwd: String,
        socketLabel: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath(socketLabel)
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-legacy-\(agent)-hook-\(UUID().uuidString)", isDirectory: true)
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
            if method == "feed.push" { return self.v2Response(id: id, ok: true, result: [:]) }
            return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_AGENT_LAUNCH_KIND"] = launchKind
        environment["CMUX_AGENT_LAUNCH_EXECUTABLE"] = launchExecutable
        environment["CMUX_AGENT_LAUNCH_ARGV_B64"] = base64NULSeparated(launchArguments)
        environment["CMUX_AGENT_LAUNCH_CWD"] = launchCwd
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["\(agent)-hook", subcommand],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr, file: file, line: line)
        XCTAssertEqual(result.status, 0, result.stderr, file: file, line: line)
        XCTAssertEqual(result.stdout, "{}\n", file: file, line: line)
        XCTAssertFalse(result.stdout.contains("Usage:"), result.stdout, file: file, line: line)
        XCTAssertFalse(result.stderr.contains("Usage:"), result.stderr, file: file, line: line)
        XCTAssertFalse(
            result.stdout.contains("Unknown command"),
            "stdout should not contain 'Unknown command' but got: \(result.stdout)",
            file: file,
            line: line
        )
    }
}
