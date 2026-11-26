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
}
