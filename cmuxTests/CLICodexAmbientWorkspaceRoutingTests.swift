import Darwin
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    func testCodexHookRejectsStaleMappedWorkspaceWithoutLiveTerminalIdentity() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex-stale-mapped-workspace")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-stale-mapped-workspace-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent("cmuxterm-hq", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-stale-mapped-workspace-session"
        let savedPID = 42_424

        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try writeCodexHookStore(
            root: root,
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: repo.path,
            pid: savedPID,
            launchCommand: nil
        )
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(
            listenerFD: listenerFD,
            state: state,
            fulfillWhen: { $0.contains(#""method":"system.resolve_terminal""#) }
        ) { line in
            guard let payload = self.jsonObject(line) else { return "OK" }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                return self.surfaceListResponse(id: id, surfaceId: surfaceId)
            case "system.resolve_terminal":
                return self.v2Response(id: id, ok: true, result: ["tty_bindings": [], "pid_binding": NSNull()])
            case "system.top":
                let systemTopRequestCount = state.snapshot().compactMap { command in
                    self.jsonObject(command)?["method"] as? String
                }.filter { $0 == "system.top" }.count
                if systemTopRequestCount == 1 {
                    return self.v2Response(id: id, ok: true, result: ["windows": []])
                }
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["windows": [["workspaces": [[
                        "id": workspaceId,
                        "panes": [["surfaces": [[
                            "id": surfaceId,
                            "top_level_pids": [savedPID],
                            "processes": [],
                        ]]]],
                    ]]]]]
                )
            case "debug.terminals":
                return self.v2Response(id: id, ok: true, result: ["terminals": []])
            case "surface.resume.set", "surface.resume.clear", "feed.push":
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
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        for key in [
            "CMUX_WORKSPACE_ID",
            "CMUX_SURFACE_ID",
            "CMUX_CLI_TTY_NAME",
            "CMUX_CODEX_PID",
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
        environment["CMUX_CODEX_PID"] = "42424"

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
        let methods = state.snapshot().compactMap { self.jsonObject($0)?["method"] as? String }
        XCTAssertFalse(methods.contains("system.top"), "saved agent PIDs must not be retried as live identity: \(methods)")
        XCTAssertFalse(methods.contains("surface.resume.set"), "stale saved state must not create a live binding: \(methods)")
        XCTAssertFalse(methods.contains("feed.push"), "stale saved state must not route a hook event: \(methods)")
    }

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

    func testCodexHookUsesLiveHookProcessPIDToOverrideRecycledTTY() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex-recycled-tty-pid")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-recycled-tty-pid-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent("cmuxterm-hq", isDirectory: true)
        let staleWorkspaceId = "11111111-1111-1111-1111-111111111111"
        let staleSurfaceId = "22222222-2222-2222-2222-222222222222"
        let processWorkspaceId = "33333333-3333-3333-3333-333333333333"
        let processSurfaceId = "44444444-4444-4444-4444-444444444444"
        let sessionId = "codex-recycled-tty-pid-session"
        let ttyName = "ttys309"
        let agentPID = 42_424

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
                if workspaceId == staleWorkspaceId {
                    return self.surfaceListResponse(id: id, surfaceId: staleSurfaceId)
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
                let params = payload["params"] as? [String: Any]
                let requestedPID = (params?["pid"] as? NSNumber)?.intValue
                let hasLiveHookProcessPID = requestedPID.map { $0 > 0 && $0 != agentPID } == true
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "tty_bindings": [[
                            "workspace_id": staleWorkspaceId,
                            "surface_id": staleSurfaceId,
                        ]],
                        "pid_binding": hasLiveHookProcessPID
                            ? ["workspace_id": processWorkspaceId, "surface_id": processSurfaceId]
                            : NSNull(),
                    ]
                )
            case "system.top":
                return self.v2Response(id: id, ok: true, result: ["windows": []])
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
        environment["CMUX_WORKSPACE_ID"] = staleWorkspaceId
        environment["CMUX_SURFACE_ID"] = staleSurfaceId
        environment["CMUX_CLI_TTY_NAME"] = ttyName
        environment["CMUX_CODEX_PID"] = String(agentPID)
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
        let resolverParams = try XCTUnwrap(state.snapshot().compactMap { command -> [String: Any]? in
            guard let payload = self.jsonObject(command),
                  payload["method"] as? String == "system.resolve_terminal" else { return nil }
            return payload["params"] as? [String: Any]
        }.first)
        let resolverPID = try XCTUnwrap((resolverParams["pid"] as? NSNumber)?.intValue)
        XCTAssertGreaterThan(resolverPID, 0)
        XCTAssertNotEqual(resolverPID, agentPID, "routing identity must be the live hook CLI, not CMUX_CODEX_PID")
        let methods = state.snapshot().compactMap { self.jsonObject($0)?["method"] as? String }
        XCTAssertFalse(methods.contains("system.top"), "the targeted live hook PID should resolve without a bare-PID retry: \(methods)")
    }
}
