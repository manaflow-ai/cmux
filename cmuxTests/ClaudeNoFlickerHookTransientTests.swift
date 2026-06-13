import Foundation
import Testing

@Suite(.serialized)
struct ClaudeNoFlickerHookTransientTests {
    private let support = ClaudeHookRoutingTestSupport()

    @Test
    func claudePromptSubmitNoOpsWhenPIDOnlyRecoverySurfaceIsGone() throws {
        let context = try support.makeHookContext(name: "claude-pid-recovery-miss")
        defer { context.cleanup() }

        let server = support.startMockServer(listenerFD: context.listenerFD, state: context.state) { line in
            guard let payload = ClaudeHookRoutingTestSupport.jsonObject(line) else {
                return "OK"
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return ClaudeHookRoutingTestSupport.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "system.top":
                return ClaudeHookRoutingTestSupport.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "windows": [[
                            "workspaces": [[
                                "id": context.workspaceId,
                                "panes": [["surfaces": [["id": context.surfaceId, "top_level_pids": [6048]]]]],
                            ]],
                        ]],
                    ]
                )
            case "surface.list":
                return ClaudeHookRoutingTestSupport.v2Response(id: id, ok: true, result: ["surfaces": []])
            default:
                return ClaudeHookRoutingTestSupport.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        var environment = support.baseHookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = ""
        environment["CMUX_SURFACE_ID"] = ""
        environment["CMUX_CLAUDE_PID"] = "6048"

        let result = support.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"pid-recovery-miss","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"run"}"#,
            timeout: 5
        )

        #expect(server.wait(timeout: .now() + 5) == .success, "mock server did not finish")
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        let commands = context.state.snapshot()
        #expect(commands.contains { ClaudeHookRoutingTestSupport.jsonObject($0)?["method"] as? String == "system.top" })
        #expect(!commands.contains { $0.hasPrefix("set_status claude_code ") || $0.hasPrefix("set_agent_pid claude_code ") || $0.contains("\"method\":\"feed.push\"") }, "PID recovery miss must not fall back to the focused workspace, saw \(commands)")
    }

    @Test
    func claudeSessionEndUsesStoredTargetWhenPIDRecoveryMisses() throws {
        let context = try support.makeHookContext(name: "claude-session-end-stored-target")
        defer { context.cleanup() }

        let sessionId = "stored-session-end-target"
        try support.seedClaudeForkHookStore(
            context: context,
            parentSessionId: sessionId,
            parentSurfaceId: context.surfaceId,
            activeSessionId: sessionId
        )

        let server = support.startMockServer(listenerFD: context.listenerFD, state: context.state) { line in
            guard let payload = ClaudeHookRoutingTestSupport.jsonObject(line) else {
                return "OK"
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return ClaudeHookRoutingTestSupport.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                return ClaudeHookRoutingTestSupport.surfaceListResponse(id: id, surfaceId: context.surfaceId)
            case "surface.resume.clear":
                return ClaudeHookRoutingTestSupport.v2Response(id: id, ok: true, result: [:])
            default:
                return ClaudeHookRoutingTestSupport.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        var environment = support.baseHookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = ""
        environment["CMUX_SURFACE_ID"] = ""
        environment["CMUX_CLAUDE_PID"] = "6048"

        let result = support.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "session-end"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionEnd"}"#,
            timeout: 5
        )

        #expect(server.wait(timeout: .now() + 5) == .success, "mock server did not finish")
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "OK\n")
        let commands = context.state.snapshot()
        #expect(commands.contains { $0.hasPrefix("clear_agent_pid claude_code --tab=\(context.workspaceId)") && $0.contains("--panel=\(context.surfaceId)") }, "SessionEnd must clean the stored target, saw \(commands)")
    }

    @Test
    func claudePromptSubmitSkipsProcessSnapshotWhenStoredPIDMatchesHookPID() throws {
        let context = try support.makeHookContext(name: "claude-stored-pid-hot-path")
        defer { context.cleanup() }

        let sessionId = "stored-pid-hot-path"
        let livePID = 6048
        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": context.workspaceId,
                    "surfaceId": context.surfaceId,
                    "cwd": context.root.path,
                    "pid": livePID,
                    "agentLifecycle": "idle",
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
            "activeSessionsByWorkspace": [context.workspaceId: ["sessionId": sessionId, "updatedAt": now]],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted])
            .write(to: context.root.appendingPathComponent("claude-hook-sessions.json"), options: .atomic)

        let server = support.startMockServer(listenerFD: context.listenerFD, state: context.state) { line in
            guard let payload = ClaudeHookRoutingTestSupport.jsonObject(line) else {
                return "OK"
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return ClaudeHookRoutingTestSupport.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                return ClaudeHookRoutingTestSupport.surfaceListResponse(id: id, surfaceId: context.surfaceId)
            case "system.top":
                return ClaudeHookRoutingTestSupport.v2Response(id: id, ok: true, result: ["windows": []])
            case "feed.push":
                return ClaudeHookRoutingTestSupport.v2Response(id: id, ok: true, result: [:])
            case "surface.resume.set":
                return ClaudeHookRoutingTestSupport.v2Response(id: id, ok: true, result: ["resume_binding": [:]])
            default:
                return ClaudeHookRoutingTestSupport.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        var environment = support.baseHookEnvironment(context: context)
        environment["CMUX_CLAUDE_PID"] = "\(livePID)"

        let result = support.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"run"}"#,
            timeout: 5
        )

        #expect(server.wait(timeout: .now() + 5) == .success, "mock server did not finish")
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let commands = context.state.snapshot()
        #expect(!commands.contains { ClaudeHookRoutingTestSupport.jsonObject($0)?["method"] as? String == "system.top" }, "Current stored PID target must not trigger process snapshot recovery, saw \(commands)")
        #expect(commands.contains { $0.hasPrefix("set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab=\(context.workspaceId)") && $0.contains("--panel=\(context.surfaceId)") }, "Expected stored target to receive Running status, saw \(commands)")
    }

    @Test
    func claudePromptSubmitUsesStoredTargetWhenEnvMissingAndPIDMatches() throws {
        let context = try support.makeHookContext(name: "claude-stored-pid-no-env")
        defer { context.cleanup() }

        let sessionId = "stored-pid-no-env"
        let livePID = 6048
        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": context.workspaceId,
                    "surfaceId": context.surfaceId,
                    "cwd": context.root.path,
                    "pid": livePID,
                    "agentLifecycle": "idle",
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
            "activeSessionsByWorkspace": [context.workspaceId: ["sessionId": sessionId, "updatedAt": now]],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted])
            .write(to: context.root.appendingPathComponent("claude-hook-sessions.json"), options: .atomic)

        let server = support.startMockServer(listenerFD: context.listenerFD, state: context.state) { line in
            guard let payload = ClaudeHookRoutingTestSupport.jsonObject(line) else {
                return "OK"
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return ClaudeHookRoutingTestSupport.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                return ClaudeHookRoutingTestSupport.surfaceListResponse(id: id, surfaceId: context.surfaceId)
            case "feed.push":
                return ClaudeHookRoutingTestSupport.v2Response(id: id, ok: true, result: [:])
            case "surface.resume.set":
                return ClaudeHookRoutingTestSupport.v2Response(id: id, ok: true, result: ["resume_binding": [:]])
            default:
                return ClaudeHookRoutingTestSupport.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        var environment = support.baseHookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = ""
        environment["CMUX_SURFACE_ID"] = ""
        environment["CMUX_CLAUDE_PID"] = "\(livePID)"

        let result = support.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"run"}"#,
            timeout: 5
        )

        #expect(server.wait(timeout: .now() + 5) == .success, "mock server did not finish")
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "OK\n")
        let commands = context.state.snapshot()
        #expect(!commands.contains { ClaudeHookRoutingTestSupport.jsonObject($0)?["method"] as? String == "system.top" }, "Current stored PID target must not trigger process snapshot recovery, saw \(commands)")
        #expect(commands.contains { $0.hasPrefix("set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab=\(context.workspaceId)") && $0.contains("--panel=\(context.surfaceId)") }, "Expected stored target to be used without terminal recovery, saw \(commands)")
    }

    @Test
    func claudePromptSubmitDoesNotPersistPIDOnFallbackSurface() throws {
        let context = try support.makeHookContext(name: "claude-fallback-no-pid-gate")
        defer { context.cleanup() }

        let livePID = 6048
        let sessionId = "fallback-no-pid-gate-session"
        let server = support.startMockServer(listenerFD: context.listenerFD, state: context.state) { line in
            guard let payload = ClaudeHookRoutingTestSupport.jsonObject(line) else {
                return "OK"
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return ClaudeHookRoutingTestSupport.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                return ClaudeHookRoutingTestSupport.surfaceListResponse(id: id, surfaceId: context.surfaceId)
            case "system.top":
                return ClaudeHookRoutingTestSupport.v2Response(id: id, ok: true, result: ["windows": []])
            case "feed.push":
                return ClaudeHookRoutingTestSupport.v2Response(id: id, ok: true, result: [:])
            default:
                return ClaudeHookRoutingTestSupport.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        var environment = support.baseHookEnvironment(context: context)
        environment["CMUX_SURFACE_ID"] = ""
        environment["CMUX_CLAUDE_PID"] = "\(livePID)"

        let result = support.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"run"}"#,
            timeout: 5
        )

        #expect(server.wait(timeout: .now() + 5) == .success, "mock server did not finish")
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let commands = context.state.snapshot()
        #expect(commands.contains { $0.hasPrefix("set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab=\(context.workspaceId)") && $0.contains("--panel=\(context.surfaceId)") }, "Expected fallback surface to receive best-effort status, saw \(commands)")
        #expect(!commands.contains { $0.hasPrefix("set_agent_pid claude_code ") || $0.contains("--pid=\(livePID)") }, "Fallback surface must not receive durable Claude PID metadata, saw \(commands)")
        let persistedData = try Data(contentsOf: context.root.appendingPathComponent("claude-hook-sessions.json"))
        let persisted = try #require(JSONSerialization.jsonObject(with: persistedData) as? [String: Any])
        let sessions = try #require(persisted["sessions"] as? [String: Any])
        let session = try #require(sessions[sessionId] as? [String: Any])
        #expect(session["pid"] == nil, "Fallback surface must not persist Claude PID metadata, saw \(session)")
    }

    @Test
    func claudePromptSubmitKeepsStoredTargetOnTransientWorkspaceProbeFailure() throws {
        let context = try support.makeHookContext(name: "claude-transient-stored-workspace")
        defer { context.cleanup() }

        let sessionId = "stored-transient-workspace-session"
        let staleWorkspaceId = "55555555-5555-5555-5555-555555555555"
        let staleSurfaceId = "66666666-6666-6666-6666-666666666666"
        try support.seedClaudeForkHookStore(
            context: context,
            parentSessionId: sessionId,
            parentSurfaceId: context.surfaceId,
            activeSessionId: sessionId
        )

        let server = support.startMockServer(listenerFD: context.listenerFD, state: context.state) { line in
            guard let payload = ClaudeHookRoutingTestSupport.jsonObject(line) else {
                return "OK"
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return ClaudeHookRoutingTestSupport.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                let params = payload["params"] as? [String: Any] ?? [:]
                if params["workspace_id"] as? String == context.workspaceId {
                    return ClaudeHookRoutingTestSupport.v2Response(
                        id: id,
                        ok: false,
                        error: ["code": "socket_timeout", "message": "temporary surface list timeout"]
                    )
                }
                return ClaudeHookRoutingTestSupport.surfaceListResponse(id: id, surfaceId: staleSurfaceId)
            case "feed.push":
                return ClaudeHookRoutingTestSupport.v2Response(id: id, ok: true, result: [:])
            case "surface.resume.set":
                return ClaudeHookRoutingTestSupport.v2Response(id: id, ok: true, result: ["resume_binding": [:]])
            default:
                return ClaudeHookRoutingTestSupport.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        var environment = support.baseHookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = staleWorkspaceId
        environment["CMUX_SURFACE_ID"] = staleSurfaceId

        let result = support.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"run"}"#,
            timeout: 5
        )

        #expect(server.wait(timeout: .now() + 5) == .success, "mock server did not finish")
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let commands = context.state.snapshot()
        #expect(
            commands.contains {
                $0.hasPrefix("set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab=\(context.workspaceId)")
                    && $0.contains("--panel=\(context.surfaceId)")
            },
            "Expected transient probe failure to keep the stored Claude target, saw \(commands)"
        )
        #expect(
            !commands.contains {
                ($0.hasPrefix("set_status claude_code Running ") || $0.hasPrefix("set_agent_pid claude_code "))
                    && ($0.contains("--tab=\(staleWorkspaceId)") || $0.contains("--panel=\(staleSurfaceId)"))
            },
            "Transient probe failure must not fall through to stale ambient state, saw \(commands)"
        )
    }
}
