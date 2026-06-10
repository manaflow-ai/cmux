import XCTest
import Darwin


// MARK: - Hermes Agent shell-hook notifications and session-end turn boundaries
extension CLINotifyProcessIntegrationRegressionTests {
    func testHermesAgentNotificationsUseShellHookExtraPayload() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("hermes-notification")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hermes-notification-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "hermes-session-123"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let environment: [String: String] = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": root.path,
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_WORKSPACE_ID": workspaceId,
            "CMUX_SURFACE_ID": surfaceId,
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
        ]

        func runHermesHook(_ subcommand: String, input: String) -> ProcessRunResult {
            let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
                guard let payload = self.jsonObject(line) else {
                    return "OK"
                }
                guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                    return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
                }
                switch method {
                case "surface.list":
                    return self.surfaceListResponse(id: id, surfaceId: surfaceId)
                case "feed.push":
                    return self.v2Response(id: id, ok: true, result: [:])
                default:
                    return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
                }
            }
            let result = runProcess(
                executablePath: cliPath,
                arguments: ["hooks", "hermes-agent", subcommand],
                environment: environment,
                standardInput: input,
                timeout: 5
            )
            wait(for: [serverHandled], timeout: 5)
            return result
        }

        func storedHermesSession() throws -> [String: Any] {
            let storeURL = root.appendingPathComponent("hermes-agent-hook-sessions.json", isDirectory: false)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
            let sessions = try XCTUnwrap(json["sessions"] as? [String: Any])
            return try XCTUnwrap(sessions[sessionId] as? [String: Any])
        }

        let start = runHermesHook(
            "session-start",
            input: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"on_session_start"}"#
        )
        XCTAssertFalse(start.timedOut, start.stderr)
        XCTAssertEqual(start.status, 0, start.stderr)
        XCTAssertEqual(start.stdout, "{}\n")

        let assistantResponse = "Updated README.md and added usage notes."
        let stopCommandStart = state.commands.count
        let stop = runHermesHook(
            "agent-response",
            input: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"post_llm_call","extra":{"user_message":"make the docs clearer","assistant_response":"\#(assistantResponse)","model":"gpt-4","platform":"cli"}}"#
        )
        XCTAssertFalse(stop.timedOut, stop.stderr)
        XCTAssertEqual(stop.status, 0, stop.stderr)
        XCTAssertEqual(stop.stdout, "{}\n")

        let stopCommands = Array(state.commands.dropFirst(stopCommandStart))
        XCTAssertTrue(
            stopCommands.contains {
                $0.contains("notify_target_async \(workspaceId) \(surfaceId) Hermes Agent|Completed in ")
                    && $0.contains("|\(assistantResponse)")
            },
            "Expected Hermes completion notification to use extra.assistant_response, saw \(stopCommands)"
        )
        XCTAssertTrue(
            stopCommands.contains { $0.contains("set_status hermes-agent Idle") },
            "Expected Hermes completion to leave status idle, saw \(stopCommands)"
        )

        let approvalCommandStart = state.commands.count
        let approval = runHermesHook(
            "notification",
            input: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"pre_approval_request","extra":{"command":"rm -rf build","description":"recursive delete","pattern_key":"recursive delete","surface":"cli"}}"#
        )
        XCTAssertFalse(approval.timedOut, approval.stderr)
        XCTAssertEqual(approval.status, 0, approval.stderr)
        XCTAssertEqual(approval.stdout, "{}\n")

        let approvalCommands = Array(state.commands.dropFirst(approvalCommandStart))
        XCTAssertTrue(
            approvalCommands.contains {
                $0.contains("notify_target_async \(workspaceId) \(surfaceId) Hermes Agent|Permission|recursive delete: rm -rf build")
            },
            "Expected Hermes approval notification to include description and command, saw \(approvalCommands)"
        )
        XCTAssertTrue(
            approvalCommands.contains { $0.contains("set_status hermes-agent Hermes Agent needs input") },
            "Expected Hermes approval notification to mark needs input, saw \(approvalCommands)"
        )
        XCTAssertFalse(
            approvalCommands.contains { $0.contains(#""method":"feed.push""#) },
            "Hermes approval notifications are also installed as feed hooks, so the generic notification handler must not push duplicate feed events. Saw \(approvalCommands)"
        )

        let session = try storedHermesSession()
        XCTAssertEqual(session["lastSubtitle"] as? String, "Permission")
        XCTAssertEqual(session["lastBody"] as? String, "recursive delete: rm -rf build")
        XCTAssertEqual(session["lastNotificationStatus"] as? String, "needsInput")

        let responseCommandStart = state.commands.count
        let response = runHermesHook(
            "approval-response",
            input: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"post_approval_response","extra":{"approved":true}}"#
        )
        XCTAssertFalse(response.timedOut, response.stderr)
        XCTAssertEqual(response.status, 0, response.stderr)
        XCTAssertEqual(response.stdout, "{}\n")

        let responseCommands = Array(state.commands.dropFirst(responseCommandStart))
        XCTAssertTrue(
            responseCommands.contains { $0.contains("clear_notifications --tab=\(workspaceId) --panel=\(surfaceId)") },
            "Expected Hermes approval response to clear the approval notification, saw \(responseCommands)"
        )
        XCTAssertTrue(
            responseCommands.contains { $0.contains("set_status hermes-agent Running") },
            "Expected Hermes approval response to restore running status, saw \(responseCommands)"
        )
        XCTAssertFalse(
            responseCommands.contains { $0.contains(#""method":"feed.push""#) },
            "Hermes approval responses are also installed as feed hooks, so the generic approval handler must not push duplicate feed events. Saw \(responseCommands)"
        )

        let responseSession = try storedHermesSession()
        XCTAssertNil(responseSession["lastSubtitle"])
        XCTAssertNil(responseSession["lastBody"])
        XCTAssertNil(responseSession["lastNotificationStatus"])
        XCTAssertEqual(responseSession["runtimeStatus"] as? String, "running")
    }

    func testHermesAgentSessionEndIsTurnBoundaryButFinalizeTearsDown() throws {
        // Hermes fires the `on_session_end` plugin hook once per conversation turn
        // (end of every run_conversation()), not at the true session boundary, and a
        // separate `on_session_finalize` hook once at genuine teardown. cmux maps the
        // per-turn event to the `session-end` subcommand and the teardown event to the
        // `session-finalize` subcommand. The per-turn hook must route through the
        // non-destructive turn-boundary path (recordPromptStop) and must NOT consume
        // the session or clear the surface resume binding — otherwise the restore
        // record is destroyed after the first turn and nothing survives a
        // quit/relaunch. The finalize hook must perform the destructive cleanup.
        // See https://github.com/manaflow-ai/cmux/issues/5000.
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("hermes-session-end")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hermes-session-end-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "hermes-session-end-123"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let environment: [String: String] = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": root.path,
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_WORKSPACE_ID": workspaceId,
            "CMUX_SURFACE_ID": surfaceId,
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
        ]

        func runHermesHook(_ subcommand: String, input: String) -> ProcessRunResult {
            let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
                guard let payload = self.jsonObject(line) else {
                    return "OK"
                }
                guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                    return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
                }
                switch method {
                case "surface.list":
                    return self.surfaceListResponse(id: id, surfaceId: surfaceId)
                case "feed.push":
                    return self.v2Response(id: id, ok: true, result: [:])
                default:
                    return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
                }
            }
            let result = runProcess(
                executablePath: cliPath,
                arguments: ["hooks", "hermes-agent", subcommand],
                environment: environment,
                standardInput: input,
                timeout: 5
            )
            wait(for: [serverHandled], timeout: 5)
            return result
        }

        func storedHermesSessionIfPresent() throws -> [String: Any]? {
            let storeURL = root.appendingPathComponent("hermes-agent-hook-sessions.json", isDirectory: false)
            guard let data = try? Data(contentsOf: storeURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessions = json["sessions"] as? [String: Any]
            else {
                return nil
            }
            return sessions[sessionId] as? [String: Any]
        }

        let start = runHermesHook(
            "session-start",
            input: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"on_session_start"}"#
        )
        XCTAssertFalse(start.timedOut, start.stderr)
        XCTAssertEqual(start.status, 0, start.stderr)

        // Finish a turn so a restorable record exists for the session.
        let stop = runHermesHook(
            "agent-response",
            input: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"post_llm_call","extra":{"user_message":"do the thing","assistant_response":"done","model":"gpt-4","platform":"cli"}}"#
        )
        XCTAssertFalse(stop.timedOut, stop.stderr)
        XCTAssertEqual(stop.status, 0, stop.stderr)

        XCTAssertNotNil(
            try storedHermesSessionIfPresent(),
            "Expected a Hermes session record to exist before the per-turn session-end hook fires"
        )

        // The per-turn on_session_end hook. Hermes is a restorable agent, so this is a
        // turn boundary, not a true session teardown.
        let sessionEndCommandStart = state.commands.count
        let sessionEnd = runHermesHook(
            "session-end",
            input: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"on_session_end"}"#
        )
        XCTAssertFalse(sessionEnd.timedOut, sessionEnd.stderr)
        XCTAssertEqual(sessionEnd.status, 0, sessionEnd.stderr)
        XCTAssertEqual(sessionEnd.stdout, "{}\n")

        let sessionEndCommands = Array(state.commands.dropFirst(sessionEndCommandStart))
        XCTAssertTrue(
            sessionEndCommands.contains { $0.contains("feed.push") },
            "Expected Hermes session-end to emit feed telemetry, saw \(sessionEndCommands)"
        )
        XCTAssertFalse(
            sessionEndCommands.contains { $0.hasPrefix("clear_agent_pid hermes-agent.") },
            "Hermes on_session_end fires per turn and must not clear saved routing, saw \(sessionEndCommands)"
        )
        XCTAssertFalse(
            sessionEndCommands.contains { $0.contains("surface.resume.clear") },
            "Hermes on_session_end fires per turn and must not clear the surface resume binding, saw \(sessionEndCommands)"
        )
        XCTAssertNotNil(
            try storedHermesSessionIfPresent(),
            "Hermes on_session_end fires per turn and must not consume the restore record, saw it removed from the store"
        )

        // The genuine teardown hook (on_session_finalize) routes to the dedicated
        // session-finalize subcommand and must perform the destructive cleanup the
        // per-turn path suppresses: consume the record, clear the resume binding, and
        // clear the agent PID routing.
        let finalizeCommandStart = state.commands.count
        let finalize = runHermesHook(
            "session-finalize",
            input: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"on_session_finalize"}"#
        )
        XCTAssertFalse(finalize.timedOut, finalize.stderr)
        XCTAssertEqual(finalize.status, 0, finalize.stderr)
        XCTAssertEqual(finalize.stdout, "{}\n")

        let finalizeCommands = Array(state.commands.dropFirst(finalizeCommandStart))
        XCTAssertTrue(
            finalizeCommands.contains { $0.hasPrefix("clear_agent_pid hermes-agent.") },
            "Hermes on_session_finalize is a true teardown and must clear agent PID routing, saw \(finalizeCommands)"
        )
        XCTAssertTrue(
            finalizeCommands.contains { $0.contains("surface.resume.clear") },
            "Hermes on_session_finalize is a true teardown and must clear the surface resume binding, saw \(finalizeCommands)"
        )
        XCTAssertNil(
            try storedHermesSessionIfPresent(),
            "Hermes on_session_finalize is a true teardown and must consume the restore record"
        )
    }

}
