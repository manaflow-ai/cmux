import XCTest
import Darwin
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Surface resume bindings
extension CLINotifyProcessIntegrationRegressionTests {
    func testNestedCodexPromptAndStopDoNotReplaceParentResumeBinding() throws {
        let context = try makeClaudeHookContext(name: "codex-nested-resume-guard")
        defer { context.cleanup() }

        let sessionId = "same-process-session"
        let launchEnvironment = codexLaunchEnvironment(context: context, sessionId: sessionId)
        startAgentHookMockServerAccepting(context: context, connectionLimit: 32)

        let parentPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"parent-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"spawn subagent"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(parentPrompt.timedOut, parentPrompt.stderr)
        XCTAssertEqual(parentPrompt.status, 0, parentPrompt.stderr)
        XCTAssertTrue(
            context.state.commands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.set" },
            "Parent Codex prompt should publish a resume binding, saw \(context.state.commands)"
        )

        let childPromptStart = context.state.commands.count
        let childPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"child-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"return 1+1"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(childPrompt.timedOut, childPrompt.stderr)
        XCTAssertEqual(childPrompt.status, 0, childPrompt.stderr)
        let childPromptCommands = Array(context.state.commands.dropFirst(childPromptStart))
        XCTAssertFalse(
            childPromptCommands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.set" },
            "Nested Codex prompt should not replace the parent resume binding, saw \(childPromptCommands)"
        )
        XCTAssertFalse(
            childPromptCommands.contains { $0.hasPrefix("set_status codex Running ") },
            "Nested Codex prompt should not rewrite parent Running status, saw \(childPromptCommands)"
        )

        let childStopStart = context.state.commands.count
        let childStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"child-turn","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"2"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(childStop.timedOut, childStop.stderr)
        XCTAssertEqual(childStop.status, 0, childStop.stderr)
        let childStopCommands = Array(context.state.commands.dropFirst(childStopStart))
        XCTAssertTrue(
            childStopCommands.contains { $0.contains(#""method":"feed.push""#) && $0.contains(#""hook_event_name":"Stop""#) },
            "Nested Codex Stop should remain Feed telemetry, saw \(childStopCommands)"
        )
        XCTAssertFalse(
            childStopCommands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.set" },
            "Nested Codex Stop should not replace the parent resume binding, saw \(childStopCommands)"
        )
        XCTAssertFalse(
            childStopCommands.contains { $0.hasPrefix("notify_target") || $0.hasPrefix("set_status codex ") },
            "Nested Codex Stop should not notify or mark the parent idle, saw \(childStopCommands)"
        )

        let parentStopStart = context.state.commands.count
        let parentStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"parent-turn","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"parent done"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(parentStop.timedOut, parentStop.stderr)
        XCTAssertEqual(parentStop.status, 0, parentStop.stderr)
        let parentStopCommands = Array(context.state.commands.dropFirst(parentStopStart))
        XCTAssertTrue(
            parentStopCommands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.set" },
            "Parent Codex Stop should still refresh the resume binding, saw \(parentStopCommands)"
        )
        XCTAssertTrue(
            parentStopCommands.contains { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Codex|") },
            "Parent Codex Stop should still notify, saw \(parentStopCommands)"
        )
        XCTAssertTrue(
            parentStopCommands.contains { $0.hasPrefix("set_status codex ") && $0.contains(" Idle ") },
            "Parent Codex Stop should mark Codex idle, saw \(parentStopCommands)"
        )
    }

    func testManagedCodexSubagentStopDoesNotReplaceResumeBinding() throws {
        let context = try makeClaudeHookContext(name: "codex-managed-resume-guard")
        defer { context.cleanup() }

        let sessionId = "managed-child-session"
        startAgentHookMockServerAccepting(context: context, connectionLimit: 16)
        let result = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"child done"}"#,
            extraEnvironment: codexLaunchEnvironment(context: context, sessionId: sessionId).merging([
                "CMUX_AGENT_MANAGED_SUBAGENT": "1",
                "CMUX_CODEX_TEAMS_THREAD_ID": "child-thread",
                "CMUX_CODEX_TEAMS_PARENT_THREAD_ID": "root-thread",
                "CMUX_CODEX_TEAMS_DEPTH": "1",
            ], uniquingKeysWith: { _, new in new })
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            context.state.commands.contains { $0.contains(#""method":"feed.push""#) && $0.contains(#""hook_event_name":"Stop""#) },
            "Managed subagent Stop should remain Feed telemetry, saw \(context.state.commands)"
        )
        XCTAssertFalse(
            context.state.commands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.set" },
            "Managed subagent Stop should not publish a child resume binding, saw \(context.state.commands)"
        )
        XCTAssertFalse(
            context.state.commands.contains { $0.hasPrefix("notify_target") || $0.hasPrefix("set_status codex ") },
            "Managed subagent Stop should not notify or clobber visible status, saw \(context.state.commands)"
        )
    }

    func testCodexStopIgnoresStaleSubagentRelayFromCompletedTurnWithoutTurnId() throws {
        let context = try makeClaudeHookContext(name: "codex-stale-relay")
        defer { context.cleanup() }

        let sessionId = "codex-stale-relay-session"
        let transcriptURL = context.root.appendingPathComponent("codex-stale-relay.jsonl")
        try [
            #"{"type":"turn_context","payload":{"turn_id":"old-turn"}}"#,
            #"{"type":"event_msg","payload":{"type":"turn_complete","turn_id":"old-turn"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":"<subagent_notification>old child finished</subagent_notification>"}}"#,
        ].joined(separator: "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        startAgentHookMockServerAccepting(context: context, connectionLimit: 24)
        let launchEnvironment = codexLaunchEnvironment(context: context, sessionId: sessionId)

        let prompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"UserPromptSubmit","prompt":"top-level"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(prompt.timedOut, prompt.stderr)
        XCTAssertEqual(prompt.status, 0, prompt.stderr)

        let stopStart = context.state.commands.count
        let stop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"Stop","last_assistant_message":"parent done"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(stop.timedOut, stop.stderr)
        XCTAssertEqual(stop.status, 0, stop.stderr)

        let stopCommands = Array(context.state.commands.dropFirst(stopStart))
        XCTAssertTrue(
            stopCommands.contains { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Codex|") },
            "Stale completed-turn subagent relay should not suppress the parent completion notification, saw \(stopCommands)"
        )
    }

    func testManagedCodexSubagentSessionEndDoesNotClearParentResumeBinding() throws {
        let context = try makeClaudeHookContext(name: "codex-managed-end-resume-guard")
        defer { context.cleanup() }

        let sessionId = "managed-child-session-end"
        let now = Date().timeIntervalSince1970
        let stateURL = context.root.appendingPathComponent("codex-hook-sessions.json")
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": context.workspaceId,
                    "surfaceId": context.surfaceId,
                    "cwd": context.root.path,
                    "pid": 12345,
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted])
            .write(to: stateURL, options: .atomic)

        startAgentHookMockServerAccepting(context: context, connectionLimit: 16)
        let result = runCodexHook(
            context: context,
            subcommand: "session-end",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionEnd"}"#,
            extraEnvironment: [
                "CMUX_AGENT_MANAGED_SUBAGENT": "1",
                "CMUX_CODEX_TEAMS_THREAD_ID": "child-thread",
                "CMUX_CODEX_TEAMS_PARENT_THREAD_ID": "root-thread",
                "CMUX_CODEX_TEAMS_DEPTH": "1",
            ]
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertFalse(
            context.state.commands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.clear" },
            "Managed subagent SessionEnd should not clear the parent resume binding, saw \(context.state.commands)"
        )
        XCTAssertFalse(
            context.state.commands.contains { $0.hasPrefix("clear_agent_pid codex.") },
            "Managed subagent SessionEnd should not clear the visible parent PID, saw \(context.state.commands)"
        )
        let savedState = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        let savedSessions = try XCTUnwrap(savedState["sessions"] as? [String: Any])
        XCTAssertNotNil(savedSessions[sessionId], "Suppressed SessionEnd should leave the stored parent session intact")
    }

    func testCodexTeamsForkPromptPublishesResumeBinding() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex-team-resume")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-teams-resume-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "33333333-3333-3333-3333-333333333333"
        let surfaceId = "44444444-4444-4444-4444-444444444444"
        let sessionId = "019dad34-d218-7943-b81a-eddac5c87951"
        let parentSessionId = "019dad34-d218-7943-b81a-parent-session"
        let ttyName = "ttys-test-codex-teams-resume"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let storeURL = root.appendingPathComponent("codex-hook-sessions.json", isDirectory: false)
        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": root.path,
                    "startedAt": now,
                    "updatedAt": now,
                    "launchCommand": [
                        "launcher": "codexTeams",
                        "executablePath": "/usr/local/bin/cmux",
                        "arguments": [
                            "/usr/local/bin/cmux",
                            "codex-teams",
                            "fork",
                            parentSessionId,
                            "--model",
                            "gpt-5.4",
                            "stale fork prompt",
                            "--sandbox",
                            "danger-full-access",
                            "initial prompt should not replay"
                        ],
                        "workingDirectory": root.path,
                        "environment": ["CODEX_HOME": root.appendingPathComponent("codex-home", isDirectory: true).path],
                        "capturedAt": now,
                        "source": "test",
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted]).write(to: storeURL, options: .atomic)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else {
                return line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
                    ? self.malformedRequestResponse(raw: line)
                    : "OK"
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                let params = payload["params"] as? [String: Any] ?? [:]
                if params["workspace_id"] as? String == workspaceId {
                    return self.surfaceListResponse(id: id, surfaceId: surfaceId)
                }
                return self.v2Response(id: id, ok: false, error: ["code": "not_found", "message": "workspace not found"])
            case "debug.terminals":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["terminals": [["tty": ttyName, "workspace_id": workspaceId, "surface_id": surfaceId]]]
                )
            case "workspace.current":
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceId])
            case "surface.resume.set":
                return self.v2Response(id: id, ok: true, result: ["ok": true])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_CLI_TTY_NAME"] = ttyName
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_LAUNCH_KIND"] = "codexTeams"
        environment["CMUX_AGENT_LAUNCH_EXECUTABLE"] = "/usr/local/bin/cmux"
        environment["CMUX_AGENT_LAUNCH_CWD"] = root.path
        environment["CMUX_AGENT_LAUNCH_ARGV_B64"] = base64NULSeparated([
            "/usr/local/bin/cmux",
            "codex-teams",
            "fork",
            parentSessionId,
            "--model",
            "gpt-5.4",
            "stale fork prompt",
            "--sandbox",
            "danger-full-access",
            "initial prompt should not replay"
        ])
        environment["CODEX_HOME"] = root.appendingPathComponent("codex-home", isDirectory: true).path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"UserPromptSubmit","prompt":"continue"}"#,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let resumeBindingRequests = state.commands.compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.set" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        XCTAssertEqual(resumeBindingRequests.count, 1, state.commands.joined(separator: "\n"))
        let request = try XCTUnwrap(resumeBindingRequests.first)
        XCTAssertEqual(request["checkpoint_id"] as? String, sessionId)
        XCTAssertEqual(request["auto_resume"] as? Bool, true)
        XCTAssertEqual(
            request["command"] as? String,
            "{ cd -- '\(root.path)' 2>/dev/null || [ ! -d '\(root.path)' ]; } && '/usr/local/bin/cmux' 'codex-teams' 'resume' '\(sessionId)' '--model' 'gpt-5.4' '--sandbox' 'danger-full-access'"
        )
    }

    func testAgentPromptClearsSurfaceResumeBindingWhenResumeCommandUnavailable() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("agent-resume-unavailable")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-resume-unavailable-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "nonresumable-agent-session"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": root.path,
                    "startedAt": now,
                    "updatedAt": now,
                    "launchCommand": [
                        "launcher": "omx",
                        "executablePath": "/usr/local/bin/cmux",
                        "arguments": ["/usr/local/bin/cmux", "omx", "hud"],
                        "workingDirectory": root.path,
                        "capturedAt": now,
                        "source": "test",
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted])
            .write(to: root.appendingPathComponent("claude-hook-sessions.json"), options: .atomic)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else {
                return "OK"
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                let params = payload["params"] as? [String: Any] ?? [:]
                if params["workspace_id"] as? String == workspaceId {
                    return self.surfaceListResponse(id: id, surfaceId: surfaceId)
                }
                return self.v2Response(id: id, ok: false, error: ["code": "not_found", "message": "workspace not found"])
            case "surface.resume.clear":
                return self.v2Response(id: id, ok: true, result: ["cleared": true])
            case "surface.resume.set":
                XCTFail("Non-resumable launcher should not publish a resume binding")
                return self.v2Response(id: id, ok: true, result: ["ok": true])
            case "feed.push":
                return self.v2Response(id: id, ok: true, result: [:])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        let environment = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_WORKSPACE_ID": workspaceId,
            "CMUX_SURFACE_ID": surfaceId,
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
        ]

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "claude", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"UserPromptSubmit"}"#,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let clearRequests = state.commands.compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.clear" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        let request = try XCTUnwrap(clearRequests.first)
        XCTAssertNil(request["workspace_id"])
        XCTAssertEqual(request["surface_id"] as? String, surfaceId)
        XCTAssertEqual(request["source"] as? String, "agent-hook")
        XCTAssertEqual(request["checkpoint_id"] as? String, sessionId)
    }

    func testGenericAgentSessionEndClearsMatchingSurfaceResumeBinding() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("agent-resume-clear")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-resume-clear-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-ending-session"
        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": root.path,
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted])
            .write(to: root.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else {
                return "OK"
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.resume.clear":
                return self.v2Response(id: id, ok: true, result: ["cleared": true])
            case "feed.push":
                return self.v2Response(id: id, ok: true, result: [:])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "session-end"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"SessionEnd"}"#,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let clearRequests = state.commands.compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.clear" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        let request = try XCTUnwrap(clearRequests.first)
        XCTAssertNil(request["workspace_id"])
        XCTAssertEqual(request["surface_id"] as? String, surfaceId)
        XCTAssertEqual(request["checkpoint_id"] as? String, sessionId)
        XCTAssertEqual(request["source"] as? String, "agent-hook")
    }

}
