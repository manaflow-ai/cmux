import Testing

@Suite(.serialized)
struct ClaudeNoFlickerHookRoutingTests {
    private let support = ClaudeHookRoutingTestSupport()

    @Test
    func claudePromptSubmitUsesAgentPIDWhenNoFlickerHookInheritsStaleSurface() throws {
        let context = try support.makeHookContext(name: "claude-no-flicker-stale-surface")
        defer { context.cleanup() }

        let staleSurfaceId = "33333333-3333-3333-3333-333333333333"
        let staleWorkspaceId = "44444444-4444-4444-4444-444444444444"
        let claudePID = "6048"
        let server = support.startMockServer(listenerFD: context.listenerFD, state: context.state) { line in
            guard let payload = ClaudeHookRoutingTestSupport.jsonObject(line) else {
                return "OK"
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return ClaudeHookRoutingTestSupport.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                return ClaudeHookRoutingTestSupport.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "surfaces": [
                            [
                                "id": context.surfaceId,
                                "ref": "surface:1",
                                "focused": false,
                            ],
                            [
                                "id": staleSurfaceId,
                                "ref": "surface:2",
                                "focused": true,
                            ],
                        ],
                    ]
                )
            case "system.top":
                return ClaudeHookRoutingTestSupport.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "windows": [
                            [
                                "workspaces": [
                                    [
                                        "id": context.workspaceId,
                                        "panes": [
                                            [
                                                "surfaces": [
                                                    [
                                                        "id": context.surfaceId,
                                                        "top_level_pids": [Int(claudePID)!],
                                                    ],
                                                    [
                                                        "id": staleSurfaceId,
                                                        "top_level_pids": [],
                                                    ],
                                                ],
                                            ],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ]
                )
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
        environment["CMUX_CLAUDE_PID"] = claudePID
        environment["CLAUDE_CODE_NO_FLICKER"] = "1"
        environment.merge(
            support.agentLaunchEnvironment(context: context, kind: "claude", executable: "/usr/local/bin/claude")
        ) { _, new in new }

        let result = support.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"no-flicker-session","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"run"}"#,
            timeout: 5
        )

        #expect(server.wait(timeout: .now() + 5) == .success, "mock server did not finish")
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "OK\n")
        let commands = context.state.snapshot()
        #expect(
            commands.contains {
                $0.hasPrefix("set_agent_pid claude_code \(claudePID) --tab=\(context.workspaceId)")
                    && $0.contains("--panel=\(context.surfaceId)")
            },
            "Expected prompt-submit to refresh Claude's PID gate for the PID-bound pane, saw \(commands)"
        )
        #expect(
            commands.contains {
                $0.hasPrefix("set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab=\(context.workspaceId)")
                    && $0.contains("--panel=\(context.surfaceId)")
            },
            "Expected prompt-submit to mark the PID-bound pane Running, saw \(commands)"
        )
        #expect(
            !commands.contains {
                ($0.hasPrefix("set_status claude_code Running ") || $0.hasPrefix("set_agent_pid claude_code "))
                    && $0.contains("--panel=\(staleSurfaceId)")
            },
            "Stale ambient CMUX_SURFACE_ID must not receive Claude's visible status or PID gate, saw \(commands)"
        )
        #expect(
            !commands.contains {
                ($0.hasPrefix("set_status claude_code Running ") || $0.hasPrefix("set_agent_pid claude_code "))
                    && $0.contains("--tab=\(staleWorkspaceId)")
            },
            "Stale ambient CMUX_WORKSPACE_ID must not receive Claude's visible status or PID gate, saw \(commands)"
        )
        let systemTopCalls = commands.filter {
            ClaudeHookRoutingTestSupport.jsonObject($0)?["method"] as? String == "system.top"
        }
        #expect(systemTopCalls.count == 1, "Expected one cached process snapshot, saw \(commands)")
    }

    @Test
    func claudePromptSubmitValidatesStaleAmbientWorkspaceWithoutBinding() throws {
        let context = try support.makeHookContext(name: "claude-stale-workspace-no-binding")
        defer { context.cleanup() }

        let staleWorkspaceId = "44444444-4444-4444-4444-444444444444"
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
                if params["workspace_id"] as? String == staleWorkspaceId {
                    return ClaudeHookRoutingTestSupport.v2Response(
                        id: id,
                        ok: false,
                        error: ["code": "workspace_not_found", "message": "workspace not found"]
                    )
                }
                return ClaudeHookRoutingTestSupport.surfaceListResponse(id: id, surfaceId: context.surfaceId)
            case "workspace.current":
                return ClaudeHookRoutingTestSupport.v2Response(id: id, ok: true, result: ["workspace_id": context.workspaceId])
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

        let result = support.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"stale-workspace-session","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"run"}"#,
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
            "Expected stale ambient workspace to fall back to the app-selected workspace, saw \(commands)"
        )
        #expect(
            !commands.contains {
                ($0.hasPrefix("set_status claude_code Running ") || $0.hasPrefix("set_agent_pid claude_code "))
                    && $0.contains("--tab=\(staleWorkspaceId)")
            },
            "Stale ambient CMUX_WORKSPACE_ID must not receive Claude visible state without a terminal/PID binding, saw \(commands)"
        )
    }

    @Test
    func claudeForkSessionStartDoesNotRegisterProcessSnapshotOnlyPID() throws {
        let context = try support.makeHookContext(name: "claude-fork-process-only")
        defer { context.cleanup() }

        let parentSessionId = "parent-session"
        let parentSurfaceId = "99999999-9999-9999-9999-999999999999"
        let claudePID = "6048"
        try support.seedClaudeForkHookStore(
            context: context,
            parentSessionId: parentSessionId,
            parentSurfaceId: parentSurfaceId,
            activeSessionId: parentSessionId
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
            case "system.top":
                return ClaudeHookRoutingTestSupport.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "windows": [
                            [
                                "workspaces": [
                                    [
                                        "id": context.workspaceId,
                                        "panes": [
                                            [
                                                "surfaces": [
                                                    [
                                                        "id": context.surfaceId,
                                                        "top_level_pids": [Int(claudePID)!],
                                                    ],
                                                ],
                                            ],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ]
                )
            case "feed.push":
                return ClaudeHookRoutingTestSupport.v2Response(id: id, ok: true, result: [:])
            default:
                return ClaudeHookRoutingTestSupport.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        var environment = support.baseHookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = ""
        environment["CMUX_SURFACE_ID"] = ""
        environment["CMUX_CLAUDE_PID"] = claudePID
        environment.merge(support.claudeForkLaunchEnvironment(context: context, parentSessionId: parentSessionId)) { _, new in new }

        let result = support.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "session-start"],
            environment: environment,
            standardInput: #"{"session_id":"\#(parentSessionId)","source":"resume","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            timeout: 5
        )

        #expect(server.wait(timeout: .now() + 5) == .success, "mock server did not finish")
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let commands = context.state.snapshot()
        #expect(
            !commands.contains { $0.hasPrefix("set_agent_pid claude_code ") },
            "A pre-prompt fork SessionStart must not register a PID found only through process snapshot binding, saw \(commands)"
        )
    }

}
