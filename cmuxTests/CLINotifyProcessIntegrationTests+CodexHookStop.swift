import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Codex stop hook status from transcripts, error payloads, and monitor leases
extension CLINotifyProcessIntegrationTests {
    func testCodexHookStopSetsRateLimitStatusFromTranscript() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-error"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let transcriptDirectory = try codexSessionDirectory(in: codexHome)
        let transcriptURL = transcriptDirectory.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.799Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"credits":{"has_credits":false,"unlimited":false,"balance":"0"}}}}
        {"timestamp":"2026-04-25T07:55:29.803Z","type":"event_msg","payload":{"type":"error","message":"You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at 4:05 AM.","codex_error_info":"usage_limit_exceeded"}}
        {"timestamp":"2026-04-25T07:55:29.804Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1","last_agent_message":null}}
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
        environment["CODEX_HOME"] = codexHome.path

        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-1","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null}
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
                command.contains("notify_target \(workspaceId) \(surfaceId) Codex|Rate limit|")
            },
            "Expected Codex failure notification, saw \(state.commands)"
        )
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex rate limit") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected high-priority Codex rate limit status, saw \(state.commands)"
        )
    }

    func testCodexHookStopTreatsTypedCodexErrorEventAsFailure() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-typed-error"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let transcriptURL = root.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.803Z","type":"event_msg","payload":{"type":"error","message":"Try again later.","codex_error_info":"server_overloaded"}}
        {"timestamp":"2026-04-25T07:55:29.804Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-3","last_agent_message":null}}
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
        {"session_id":"\(sessionId)","turn_id":"turn-3","transcript_path":"\(transcriptURL.path)","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null}
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
            "Expected typed Codex error notification, saw \(state.commands)"
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

    func testCodexHookStopFallsBackToDiscoveredTranscriptWhenProvidedPathUnavailable() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-stale-provided-path"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let transcriptDirectory = try codexSessionDirectory(in: codexHome)
        let discoveredTranscriptURL = transcriptDirectory.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.803Z","type":"event_msg","payload":{"type":"error","turn_id":"turn-stale-path","message":"Stream disconnected before completion.","codex_error_info":"response_stream_disconnected"}}
        {"timestamp":"2026-04-25T07:55:29.804Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-stale-path","last_agent_message":null}}
        """.write(to: discoveredTranscriptURL, atomically: true, encoding: .utf8)

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
        environment["CODEX_HOME"] = codexHome.path

        let unavailableTranscriptURL = root.appendingPathComponent("missing-\(sessionId).jsonl")
        let hookInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-stale-path","transcript_path":"\(unavailableTranscriptURL.path)","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null}
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
                command.contains("notify_target \(workspaceId) \(surfaceId) Codex|Network error|Stream disconnected before completion.")
            },
            "Expected discovered transcript failure notification, saw \(state.commands)"
        )
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex network error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected discovered transcript failure status, saw \(state.commands)"
        )
    }

    func testCodexPromptSubmitRetiresPreviousMonitorLeaseForSameSession() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-monitor-leases-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-lease-dedupe"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        startMockServerAccepting(listenerFD: listenerFD, state: state, connectionLimit: 6) { line in
            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let id = payload["id"] as? String else {
                return "OK"
            }
            return self.v2Response(
                id: id,
                ok: true,
                result: ["surfaces": [["id": surfaceId, "ref": surfaceId, "focused": true]]]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CODEX_HOME"] = root.appendingPathComponent("codex-home", isDirectory: true).path

        let firstInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-one","cwd":"\(root.path)","hook_event_name":"UserPromptSubmit","prompt":"first"}
        """
        let firstResult = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "prompt-submit"],
            environment: environment,
            standardInput: firstInput,
            timeout: 5
        )

        XCTAssertFalse(firstResult.timedOut, firstResult.stderr)
        XCTAssertEqual(firstResult.status, 0, firstResult.stderr)
        XCTAssertEqual(firstResult.stdout, "{}\n")
        XCTAssertTrue(
            waitForCodexMonitorActiveLeaseTurns(in: root, expected: ["turn-one"], timeout: 3),
            "Expected first prompt to leave one active monitor lease, saw \(codexMonitorActiveLeaseTurns(in: root))"
        )

        let secondInput = """
        {"session_id":"\(sessionId)","turn_id":"turn-two","cwd":"\(root.path)","hook_event_name":"UserPromptSubmit","prompt":"second"}
        """
        let secondResult = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "prompt-submit"],
            environment: environment,
            standardInput: secondInput,
            timeout: 5
        )

        XCTAssertFalse(secondResult.timedOut, secondResult.stderr)
        XCTAssertEqual(secondResult.status, 0, secondResult.stderr)
        XCTAssertEqual(secondResult.stdout, "{}\n")
        XCTAssertTrue(
            waitForCodexMonitorActiveLeaseTurns(in: root, expected: ["turn-two"], timeout: 3),
            "Expected a new turn to retire the prior Codex monitor lease, saw \(codexMonitorActiveLeaseTurns(in: root))"
        )
    }

    func testCodexHookStopTreatsCodexErrorInfoPayloadAsFailure() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-payload-error"

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
        {"session_id":"\(sessionId)","turn_id":"turn-4","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null,"message":"Try again later.","codex_error_info":"server_overloaded"}
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
                command.contains("set_status codex Codex error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected high-priority Codex error status from codex_error_info, saw \(state.commands)"
        )
    }

    func testCodexHookStopTreatsStructuredCodexErrorInfoPayloadAsFailure() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-structured-error"

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
        {"session_id":"\(sessionId)","turn_id":"turn-structured","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null,"message":"Try again later.","codex_error_info":{"code":"server_overloaded","retryable":true}}
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
                command.contains("set_status codex Codex error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected structured codex_error_info to publish high-priority Codex error status, saw \(state.commands)"
        )
    }

    func testCodexHookStopTreatsCamelCaseCodexErrorInfoPayloadAsFailure() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-camel-error"

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
        {"session_id":"\(sessionId)","turn_id":"turn-5","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null,"message":"Try again later.","codexErrorInfo":"server_overloaded"}
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
                command.contains("set_status codex Codex error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected high-priority Codex error status from camelCase codexErrorInfo, saw \(state.commands)"
        )
    }

    func testCodexHookStopTreatsTypedHookPayloadAsFailure() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-hook-type-error"

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
        {"session_id":"\(sessionId)","turn_id":"turn-6","cwd":"\(root.path)","hook_event_name":"Stop","model":"gpt-5.5","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null,"type":"error","message":"Try again later."}
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
                command.contains("set_status codex Codex error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected typed hook payload to publish high-priority Codex error status, saw \(state.commands)"
        )
    }

    private func startMockServerAccepting(
        listenerFD: Int32,
        state: MockSocketServerState,
        connectionLimit: Int,
        handler: @escaping @Sendable (String) -> String
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var accepted = 0
            while accepted < connectionLimit {
                var clientAddr = sockaddr_un()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                    }
                }
                if clientFD < 0 {
                    if errno == EINTR { continue }
                    return
                }
                accepted += 1

                DispatchQueue.global(qos: .userInitiated).async {
                    defer { Darwin.close(clientFD) }
                    var pending = Data()
                    var buffer = [UInt8](repeating: 0, count: 4096)

                    while true {
                        let count = Darwin.read(clientFD, &buffer, buffer.count)
                        if count < 0 {
                            if errno == EINTR { continue }
                            return
                        }
                        if count == 0 { return }
                        pending.append(buffer, count: count)

                        while let newlineRange = pending.firstRange(of: Data([0x0A])) {
                            let lineData = pending.subdata(in: 0..<newlineRange.lowerBound)
                            pending.removeSubrange(0...newlineRange.lowerBound)
                            guard let line = String(data: lineData, encoding: .utf8) else { continue }
                            state.append(line)
                            guard self.writeAll(handler(line) + "\n", to: clientFD) else { return }
                        }
                    }
                }
            }
        }
    }

    private func codexMonitorActiveLeaseTurns(in root: URL) -> [String] {
        let directory = root.appendingPathComponent("codex-monitor-leases", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls.compactMap { url -> String? in
            guard let data = try? Data(contentsOf: url),
                  let lease = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                return nil
            }
            if let retiredAt = lease["retiredAt"], !(retiredAt is NSNull) {
                return nil
            }
            return lease["turnId"] as? String
        }.sorted()
    }

    private func waitForCodexMonitorActiveLeaseTurns(
        in root: URL,
        expected: [String],
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if codexMonitorActiveLeaseTurns(in: root) == expected.sorted() {
                return true
            }
            _ = DispatchSemaphore(value: 0).wait(timeout: .now() + 0.05)
        }
        return codexMonitorActiveLeaseTurns(in: root) == expected.sorted()
    }

}
