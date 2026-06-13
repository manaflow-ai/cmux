import Foundation
import Testing

@Suite(.serialized)
struct ClaudeNoFlickerHookTransientTests {
    private let support = ClaudeHookRoutingTestSupport()

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
