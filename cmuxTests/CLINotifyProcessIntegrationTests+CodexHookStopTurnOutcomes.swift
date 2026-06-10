import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Codex stop hook turn-level success and failure outcomes
extension CLINotifyProcessIntegrationTests {
    func testCodexHookStopTreatsExplicitErrorFieldAsFailureSignal() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-explicit-error-field"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-explicit-error","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null,"error":"quota exceeded"}
        """
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: hookInput,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("notify_target \(workspaceId) \(surfaceId) Codex|Error|quota exceeded")
            },
            "Expected explicit error field notification, saw \(state.commands)"
        )
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected explicit error field status, saw \(state.commands)"
        )
    }

    func testCodexHookStopDoesNotKeepOldTranscriptErrorAfterSuccessfulTurn() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-success"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let transcriptURL = root.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.803Z","type":"event_msg","payload":{"type":"error","message":"You've hit your usage limit.","codex_error_info":"usage_limit_exceeded"}}
        {"timestamp":"2026-04-25T07:56:00.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done"}],"phase":"final_answer"}}
        {"timestamp":"2026-04-25T07:56:00.100Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-2","last_agent_message":"Done"}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-2","transcript_path":"\(transcriptURL.path)","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":"Done"}
        """
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: hookInput,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Idle") &&
                    command.contains("--icon=pause.circle.fill") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected successful Codex turn to report Idle, saw \(state.commands)"
        )
        XCTAssertFalse(
            state.commands.contains { $0.contains("set_status codex Codex rate limit") || $0.contains("#FF453A") },
            "Did not expect stale transcript error status, saw \(state.commands)"
        )
        XCTAssertFalse(
            state.commands.contains { command in
                command.contains("notify_target") &&
                    (command.contains("Rate limit") || command.contains("Error") || command.contains("#FF453A"))
            },
            "Did not expect stale failure notification, saw \(state.commands)"
        )
    }

    func testCodexHookStopPrefersExplicitErrorPayloadOverHealthyTranscript() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-payload-beats-transcript"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let transcriptURL = root.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:56:00.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done"}],"phase":"final_answer"}}
        {"timestamp":"2026-04-25T07:56:00.100Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-payload-error","last_agent_message":"Done"}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-payload-error","transcript_path":"\(transcriptURL.path)","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":"Partial answer","type":"error","message":"Try again later."}
        """
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: hookInput,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("notify_target \(workspaceId) \(surfaceId) Codex|Error|Try again later.")
            },
            "Expected payload error notification to beat healthy transcript, saw \(state.commands)"
        )
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected payload error status to beat healthy transcript, saw \(state.commands)"
        )
    }

    func testCodexHookStopTreatsCompletedTurnWithoutAssistantAsFailure() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-no-final"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let transcriptURL = root.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.600Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Previous turn completed."}]}}
        {"timestamp":"2026-04-25T07:55:29.804Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-no-final","last_agent_message":null}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-no-final","transcript_path":"\(transcriptURL.path)","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null}
        """
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: hookInput,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("notify_target \(workspaceId) \(surfaceId) Codex|Error|Codex ended before sending a final response")
            },
            "Expected no-final-response notification, saw \(state.commands)"
        )
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected high-priority Codex error status, saw \(state.commands)"
        )
    }

    func testCodexHookStopDoesNotSynthesizeNoFinalResponseAfterScopedAssistantMessage() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-scoped-assistant"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let transcriptURL = root.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.500Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-scoped-assistant","started_at":1777107522}}
        {"timestamp":"2026-04-25T07:55:29.600Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done"}]}}
        {"timestamp":"2026-04-25T07:55:29.804Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-scoped-assistant","last_agent_message":null}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-scoped-assistant","transcript_path":"\(transcriptURL.path)","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null}
        """
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: hookInput,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Idle") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected scoped assistant reply to suppress no-final-response error, saw \(state.commands)"
        )
        XCTAssertFalse(
            state.commands.contains { command in
                command.contains("Codex ended before sending a final response") || command.contains("--color=#FF453A")
            },
            "Did not expect no-final-response error after scoped assistant reply, saw \(state.commands)"
        )
    }

    func testCodexHookStopIgnoresUnscopedTranscriptErrorWithoutTurnEvidence() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-stale-unscoped-error"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let transcriptURL = root.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.803Z","type":"event_msg","payload":{"type":"error","message":"Stream disconnected before completion.","codex_error_info":"response_stream_disconnected"}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: [:])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-current","transcript_path":"\(transcriptURL.path)","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null}
        """
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "stop"],
            environment: environment,
            standardInput: hookInput,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Idle") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected stale unscoped error to leave Codex idle, saw \(state.commands)"
        )
        XCTAssertFalse(
            state.commands.contains { command in
                command.contains("set_status codex Codex network error") || command.contains("--color=#FF453A")
            },
            "Did not expect stale unscoped error status, saw \(state.commands)"
        )
    }

}
