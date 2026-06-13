import Foundation
import Testing

@Suite(.serialized)
struct ClaudeNoFlickerHookBindingTests {
    private let support = ClaudeHookRoutingTestSupport()

    @Test
    func claudePromptSubmitIgnoresPIDBindingWhenBoundSurfaceIsGone() throws {
        let context = try support.makeHookContext(name: "claude-stale-pid-bound-surface")
        defer { context.cleanup() }

        let staleWorkspaceId = "55555555-5555-5555-5555-555555555555"
        let staleSurfaceId = "66666666-6666-6666-6666-666666666666"
        let staleFallbackSurfaceId = "77777777-7777-7777-7777-777777777777"
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
                let params = payload["params"] as? [String: Any] ?? [:]
                if params["workspace_id"] as? String == staleWorkspaceId {
                    return ClaudeHookRoutingTestSupport.v2Response(
                        id: id,
                        ok: true,
                        result: ["surfaces": [["id": staleFallbackSurfaceId, "ref": "surface:1", "focused": true]]]
                    )
                }
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
                                        "id": staleWorkspaceId,
                                        "panes": [
                                            [
                                                "surfaces": [
                                                    [
                                                        "id": staleSurfaceId,
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
            case "surface.resume.set":
                return ClaudeHookRoutingTestSupport.v2Response(id: id, ok: true, result: ["resume_binding": [:]])
            default:
                return ClaudeHookRoutingTestSupport.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        var environment = support.baseHookEnvironment(context: context)
        environment["CMUX_CLAUDE_PID"] = claudePID

        let result = support.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"gone-pid-surface-session","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"run"}"#,
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
            "Expected a PID binding with a gone surface to fall back to the ambient workspace, saw \(commands)"
        )
        #expect(
            !commands.contains {
                ($0.hasPrefix("set_status claude_code Running ") || $0.hasPrefix("set_agent_pid claude_code "))
                    && $0.contains("--tab=\(staleWorkspaceId)")
            },
            "A stale PID-bound surface must not borrow another surface in its workspace, saw \(commands)"
        )
        #expect(
            !commands.contains {
                ($0.hasPrefix("set_status claude_code Running ") || $0.hasPrefix("set_agent_pid claude_code "))
                    && $0.contains("--panel=\(staleFallbackSurfaceId)")
            },
            "A stale PID-bound surface must not fall back to another panel, saw \(commands)"
        )
    }

    @Test
    func claudePromptSubmitPrefersPIDSnapshotOverInheritedTTY() throws {
        let context = try support.makeHookContext(name: "claude-stale-inherited-tty")
        defer { context.cleanup() }

        let staleWorkspaceId = "55555555-5555-5555-5555-555555555555"
        let staleSurfaceId = "66666666-6666-6666-6666-666666666666"
        let staleTTY = "ttys6048"
        let claudePID = "6048"
        let server = support.startMockServer(listenerFD: context.listenerFD, state: context.state) { line in
            guard let payload = ClaudeHookRoutingTestSupport.jsonObject(line) else {
                return "OK"
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return ClaudeHookRoutingTestSupport.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "debug.terminals":
                return ClaudeHookRoutingTestSupport.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "terminals": [
                            [
                                "tty": "/dev/\(staleTTY)",
                                "workspace_id": staleWorkspaceId,
                                "surface_id": staleSurfaceId,
                            ],
                        ],
                    ]
                )
            case "surface.list":
                let params = payload["params"] as? [String: Any] ?? [:]
                if params["workspace_id"] as? String == staleWorkspaceId {
                    return ClaudeHookRoutingTestSupport.surfaceListResponse(id: id, surfaceId: staleSurfaceId)
                }
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
            case "surface.resume.set":
                return ClaudeHookRoutingTestSupport.v2Response(id: id, ok: true, result: ["resume_binding": [:]])
            default:
                return ClaudeHookRoutingTestSupport.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        var environment = support.baseHookEnvironment(context: context)
        environment["CMUX_CLAUDE_PID"] = claudePID
        environment["CMUX_TTY_NAME"] = staleTTY

        let result = support.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"stale-inherited-tty-session","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"run"}"#,
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
            "Expected the live Claude PID snapshot to override stale inherited TTY metadata, saw \(commands)"
        )
        #expect(
            !commands.contains {
                ($0.hasPrefix("set_status claude_code Running ") || $0.hasPrefix("set_agent_pid claude_code "))
                    && $0.contains("--tab=\(staleWorkspaceId)")
            },
            "Stale inherited TTY metadata must not receive Claude visible state, saw \(commands)"
        )
        #expect(
            !commands.contains {
                ($0.hasPrefix("set_status claude_code Running ") || $0.hasPrefix("set_agent_pid claude_code "))
                    && $0.contains("--panel=\(staleSurfaceId)")
            },
            "Stale inherited TTY metadata must not receive Claude visible state, saw \(commands)"
        )
    }

    @Test
    func claudePromptSubmitFallsBackWhenStoredWorkspaceIsGone() throws {
        let context = try support.makeHookContext(name: "claude-gone-stored-workspace")
        defer { context.cleanup() }

        let sessionId = "stored-stale-workspace-session"
        let staleWorkspaceId = "55555555-5555-5555-5555-555555555555"
        let staleSurfaceId = "66666666-6666-6666-6666-666666666666"
        try seedStoredClaudeSession(
            context: context,
            sessionId: sessionId,
            workspaceId: staleWorkspaceId,
            surfaceId: staleSurfaceId
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
                if params["workspace_id"] as? String == staleWorkspaceId {
                    return ClaudeHookRoutingTestSupport.v2Response(
                        id: id,
                        ok: false,
                        error: ["code": "workspace_not_found", "message": "workspace not found"]
                    )
                }
                return ClaudeHookRoutingTestSupport.surfaceListResponse(id: id, surfaceId: context.surfaceId)
            case "feed.push":
                return ClaudeHookRoutingTestSupport.v2Response(id: id, ok: true, result: [:])
            case "surface.resume.set":
                return ClaudeHookRoutingTestSupport.v2Response(id: id, ok: true, result: ["resume_binding": [:]])
            default:
                return ClaudeHookRoutingTestSupport.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        let result = support.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "prompt-submit"],
            environment: support.baseHookEnvironment(context: context),
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
            "Expected stale stored workspace to fall back to the live ambient workspace, saw \(commands)"
        )
        #expect(
            !commands.contains {
                ($0.hasPrefix("set_status claude_code Running ") || $0.hasPrefix("set_agent_pid claude_code "))
                    && $0.contains("--tab=\(staleWorkspaceId)")
            },
            "Stale stored workspace must not receive Claude visible state, saw \(commands)"
        )
    }

    @Test
    func claudePromptSubmitUsesPIDWhenStoredSurfaceIsGone() throws {
        let context = try support.makeHookContext(name: "claude-gone-stored-surface")
        defer { context.cleanup() }

        let sessionId = "stored-stale-surface-session"
        let staleSurfaceId = "66666666-6666-6666-6666-666666666666"
        let borrowedSurfaceId = "77777777-7777-7777-7777-777777777777"
        let claudePID = "6048"
        try seedStoredClaudeSession(
            context: context,
            sessionId: sessionId,
            workspaceId: context.workspaceId,
            surfaceId: staleSurfaceId
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
                return ClaudeHookRoutingTestSupport.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "surfaces": [
                            ["id": borrowedSurfaceId, "ref": "surface:1", "focused": true],
                            ["id": context.surfaceId, "ref": "surface:2", "focused": false],
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
                                                        "id": borrowedSurfaceId,
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
        environment["CMUX_CLAUDE_PID"] = claudePID

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
            "Expected stale stored surface to route to the live Claude PID surface, saw \(commands)"
        )
        #expect(
            !commands.contains {
                ($0.hasPrefix("set_status claude_code Running ") || $0.hasPrefix("set_agent_pid claude_code "))
                    && $0.contains("--panel=\(borrowedSurfaceId)")
            },
            "Stale stored surface must not borrow the focused/default surface, saw \(commands)"
        )
    }

    @Test
    func claudePromptSubmitIgnoresRawShellTTYWithoutCmuxTarget() throws {
        let context = try support.makeHookContext(name: "claude-raw-tty-no-target")
        defer { context.cleanup() }

        var environment = support.baseHookEnvironment(context: context)
        environment["CMUX_WORKSPACE_ID"] = ""
        environment["CMUX_SURFACE_ID"] = ""
        environment["TTY"] = "/dev/ttys6048"
        environment["SSH_TTY"] = "/dev/ttys6049"

        let result = support.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"raw-tty-session","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"run"}"#,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        #expect(context.state.snapshot().isEmpty)
    }

    @Test
    func claudePromptSubmitKeepsValidAmbientTargetOverRawShellTTY() throws {
        let context = try support.makeHookContext(name: "claude-raw-tty-valid-env")
        defer { context.cleanup() }
        let staleWorkspaceId = "55555555-5555-5555-5555-555555555555"
        let staleSurfaceId = "66666666-6666-6666-6666-666666666666"
        let staleTTY = "ttys6048"
        let server = support.startMockServer(listenerFD: context.listenerFD, state: context.state) { line in
            guard let payload = ClaudeHookRoutingTestSupport.jsonObject(line) else { return "OK" }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return ClaudeHookRoutingTestSupport.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "debug.terminals":
                return ClaudeHookRoutingTestSupport.v2Response(id: id, ok: true, result: ["terminals": [["tty": "/dev/\(staleTTY)", "workspace_id": staleWorkspaceId, "surface_id": staleSurfaceId]]])
            case "surface.list":
                let workspaceId = (payload["params"] as? [String: Any])?["workspace_id"] as? String
                return ClaudeHookRoutingTestSupport.surfaceListResponse(
                    id: id,
                    surfaceId: workspaceId == staleWorkspaceId ? staleSurfaceId : context.surfaceId
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
        environment["TTY"] = "/dev/\(staleTTY)"
        let result = support.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"raw-tty-valid-env","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"run"}"#,
            timeout: 5
        )
        #expect(server.wait(timeout: .now() + 5) == .success, "mock server did not finish")
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let commands = context.state.snapshot()
        #expect(commands.contains { $0.hasPrefix("set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab=\(context.workspaceId)") && $0.contains("--panel=\(context.surfaceId)") }, "Expected valid ambient cmux target to win over raw shell TTY, saw \(commands)")
        #expect(!commands.contains { ($0.hasPrefix("set_status claude_code Running ") || $0.hasPrefix("set_agent_pid claude_code ")) && ($0.contains("--tab=\(staleWorkspaceId)") || $0.contains("--panel=\(staleSurfaceId)")) }, "Raw shell TTY target must not receive Claude visible state, saw \(commands)")
    }

    private func seedStoredClaudeSession(
        context: ClaudeHookRoutingTestSupport.HookContext,
        sessionId: String,
        workspaceId: String,
        surfaceId: String
    ) throws {
        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": context.root.path,
                    "agentLifecycle": "idle",
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
            "activeSessionsByWorkspace": [
                workspaceId: [
                    "sessionId": sessionId,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted])
            .write(
                to: context.root.appendingPathComponent("claude-hook-sessions.json"),
                options: .atomic
            )
    }
}
