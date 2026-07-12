import Darwin
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    func testCodexHookPrefersProcessWorkspaceOverStaleAmbientWorkspace() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex-stale-ambient-workspace")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-stale-ambient-workspace-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent("cmuxterm-hq", isDirectory: true)
        let ambientWorkspaceId = "11111111-1111-1111-1111-111111111111"
        let ambientSurfaceId = "22222222-2222-2222-2222-222222222222"
        let processWorkspaceId = "33333333-3333-3333-3333-333333333333"
        let processSurfaceId = "44444444-4444-4444-4444-444444444444"
        let sessionId = "codex-stale-ambient-workspace-session"
        let ttyName = "ttys308"

        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else { return "OK" }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                let workspaceId = (payload["params"] as? [String: Any])?["workspace_id"] as? String
                if workspaceId == ambientWorkspaceId {
                    return self.surfaceListResponse(id: id, surfaceId: ambientSurfaceId)
                }
                if workspaceId == processWorkspaceId {
                    return self.surfaceListResponse(id: id, surfaceId: processSurfaceId)
                }
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "not_found", "message": "workspace not found"]
                )
            case "system.resolve_terminal":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "tty_bindings": [[
                            "workspace_id": processWorkspaceId,
                            "surface_id": processSurfaceId,
                        ]],
                        "pid_binding": NSNull(),
                    ]
                )
            case "debug.terminals":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["terminals": [[
                        "tty": ttyName,
                        "workspace_id": processWorkspaceId,
                        "surface_id": processSurfaceId,
                    ]]]
                )
            case "surface.resume.set", "surface.resume.clear":
                return self.v2Response(id: id, ok: true, result: ["ok": true])
            case "feed.push":
                return self.v2Response(id: id, ok: true, result: [:])
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = root.path
        environment["PWD"] = repo.path
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = ambientWorkspaceId
        environment["CMUX_SURFACE_ID"] = ambientSurfaceId
        environment["CMUX_CLI_TTY_NAME"] = ttyName
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        for key in [
            "ANTHROPIC_BASE_URL",
            "CLAUDE_CONFIG_DIR",
            "CODEX_HOME",
            "CMUX_AGENT_LAUNCH_KIND",
            "CMUX_AGENT_LAUNCH_EXECUTABLE",
            "CMUX_AGENT_LAUNCH_ARGV_B64",
            "CMUX_AGENT_LAUNCH_CWD",
        ] {
            environment.removeValue(forKey: key)
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(repo.path)","hook_event_name":"UserPromptSubmit","prompt":"review this"}"#,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let resumeRequests = state.snapshot().compactMap { command -> [String: Any]? in
            guard let payload = self.jsonObject(command),
                  payload["method"] as? String == "surface.resume.set" else { return nil }
            return payload["params"] as? [String: Any]
        }
        let resume = try XCTUnwrap(resumeRequests.last)
        XCTAssertEqual(resume["workspace_id"] as? String, processWorkspaceId)
        XCTAssertEqual(resume["surface_id"] as? String, processSurfaceId)
    }
}
