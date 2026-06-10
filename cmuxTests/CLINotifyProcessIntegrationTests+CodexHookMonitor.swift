import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Codex monitor hook transcript polling and notifications
extension CLINotifyProcessIntegrationTests {
    private func waitForProcess(_ process: Process, toHoldOpenFile path: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var consecutiveHits = 0
        while Date() < deadline {
            guard process.isRunning else { return false }
            let result = runProcess(
                executablePath: "/usr/sbin/lsof",
                arguments: ["-n", "-p", "\(process.processIdentifier)", "-Fn"],
                environment: ProcessInfo.processInfo.environment,
                timeout: 1
            )
            if result.status == 0, result.stdout.contains(path) {
                consecutiveHits += 1
                if consecutiveHits >= 2 {
                    return true
                }
            } else {
                consecutiveHits = 0
            }
            _ = DispatchSemaphore(value: 0).wait(timeout: .now() + 0.05)
        }
        return false
    }

    private func waitForSocketCommand(
        state: MockSocketServerState,
        timeout: TimeInterval,
        matching predicate: (String) -> Bool
    ) -> Bool {
        state.waitForCommand(timeout: timeout, matching: predicate)
    }

    func testCodexHookMonitorSetsErrorStatusFromCompletedTranscriptWithoutAssistant() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-monitor-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-monitor-no-final"

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
        {"timestamp":"2026-04-25T07:55:29.804Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-monitor","last_agent_message":null}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: ["surfaces": [["id": surfaceId, "ref": surfaceId]]])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "hooks", "codex", "monitor",
                "--workspace",
                workspaceId,
                "--surface",
                surfaceId,
                "--session",
                sessionId,
                "--turn",
                "turn-monitor",
                "--transcript",
                transcriptURL.path,
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("notify_target \(workspaceId) \(surfaceId) Codex|Error|Codex ended before sending a final response")
            },
            "Expected monitor to send no-final-response notification, saw \(state.commands)"
        )
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected monitor to publish high-priority Codex error status, saw \(state.commands)"
        )
    }

    func testCodexHookMonitorReportsExplicitErrorBeforeTerminalCompletion() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-monitor-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-monitor-stream-error"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let transcriptURL = root.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.500Z","type":"event_msg","payload":{"type":"task_started","turnId":"turn-monitor-stream-error","started_at":1777107522}}
        {"timestamp":"2026-04-25T07:55:29.803Z","type":"event_msg","payload":{"type":"error","message":"Stream disconnected before completion.","codex_error_info":"response_stream_disconnected"}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: ["surfaces": [["id": surfaceId, "ref": surfaceId]]])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "hooks", "codex", "monitor",
                "--workspace",
                workspaceId,
                "--surface",
                surfaceId,
                "--session",
                sessionId,
                "--turn",
                "turn-monitor-stream-error",
                "--transcript",
                transcriptURL.path,
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("notify_target \(workspaceId) \(surfaceId) Codex|Network error|Stream disconnected before completion.")
            },
            "Expected monitor to send stream error notification before terminal completion, saw \(state.commands)"
        )
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex network error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected monitor to publish high-priority Codex network error status, saw \(state.commands)"
        )
    }

    func testCodexHookMonitorNotifiesOnRequestUserInput() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-monitor-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-monitor-user-input"
        let turnId = "turn-monitor-user-input"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let transcriptURL = root.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.500Z","type":"event_msg","payload":{"type":"task_started","turn_id":"\(turnId)","started_at":1777107522}}
        {"timestamp":"2026-04-25T07:55:29.700Z","type":"event_msg","payload":{"type":"request_user_input","call_id":"call-plan-question","turn_id":"\(turnId)","questions":[{"id":"demo_path","header":"Demo","question":"Which demo path should I use?","options":[{"label":"Plan","description":"Show plan mode"}]}]}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        _ = startMockServerSignal(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: ["surfaces": [["id": surfaceId, "ref": surfaceId]]])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = [
            "hooks", "codex", "monitor",
            "--workspace",
            workspaceId,
            "--surface",
            surfaceId,
            "--session",
            sessionId,
            "--turn",
            turnId,
            "--transcript",
            transcriptURL.path,
        ]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }
        defer {
            if process.isRunning {
                process.terminate()
                _ = exitSignal.wait(timeout: .now() + 1)
            }
            _ = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        XCTAssertTrue(
            waitForProcess(process, toHoldOpenFile: transcriptURL.path, timeout: 2),
            "Monitor did not start watching the request_user_input transcript"
        )
        XCTAssertTrue(
            waitForSocketCommand(state: state, timeout: 5) { command in
                command.contains("notify_target \(workspaceId) \(surfaceId) Codex|Waiting|Which demo path should I use?")
            },
            "Expected monitor to send Codex input notification, saw \(state.snapshot())"
        )
        XCTAssertTrue(
            waitForSocketCommand(state: state, timeout: 5) { command in
                command.contains("set_status codex Codex needs input") &&
                    command.contains("--icon=bell.fill") &&
                    command.contains("--color=#4C8DFF") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected monitor to publish high-priority Codex input status, saw \(state.snapshot())"
        )
        XCTAssertTrue(process.isRunning, "Monitor should keep watching the turn after publishing input notification")
    }

    func testCodexHookMonitorNotifiesOnResponseItemRequestUserInput() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex-response-item")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-monitor-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-monitor-response-item"
        let turnId = "turn-monitor-response-item"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let transcriptURL = root.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.500Z","type":"turn_context","payload":{"turn_id":"\(turnId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.700Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"{\\"questions\\":[{\\"id\\":\\"demo_type\\",\\"header\\":\\"Demo Type\\",\\"question\\":\\"What kind of demo plan should I create?\\",\\"options\\":[{\\"label\\":\\"Product walkthrough (Recommended)\\",\\"description\\":\\"A timed agenda.\\"}]}]}","call_id":"call-plan-function"}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        _ = startMockServerSignal(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: ["surfaces": [["id": surfaceId, "ref": surfaceId]]])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = [
            "hooks", "codex", "monitor",
            "--workspace",
            workspaceId,
            "--surface",
            surfaceId,
            "--session",
            sessionId,
            "--turn",
            turnId,
            "--transcript",
            transcriptURL.path,
        ]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }
        defer {
            if process.isRunning {
                process.terminate()
                _ = exitSignal.wait(timeout: .now() + 1)
            }
            _ = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        XCTAssertTrue(
            waitForProcess(process, toHoldOpenFile: transcriptURL.path, timeout: 2),
            "Monitor did not start watching the response_item request_user_input transcript"
        )
        XCTAssertTrue(
            waitForSocketCommand(state: state, timeout: 5) { command in
                command.contains("notify_target \(workspaceId) \(surfaceId) Codex|Waiting|What kind of demo plan should I create?")
            },
            "Expected monitor to send Codex input notification from response_item, saw \(state.snapshot())"
        )
        XCTAssertTrue(
            waitForSocketCommand(state: state, timeout: 5) { command in
                command.contains("set_status codex Codex needs input") &&
                    command.contains("--icon=bell.fill") &&
                    command.contains("--color=#4C8DFF") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected monitor to publish high-priority Codex input status, saw \(state.snapshot())"
        )
        XCTAssertTrue(process.isRunning, "Monitor should keep watching the turn after publishing input notification")
    }

    func testCodexHookMonitorReResolvesUnavailableTranscriptPath() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-monitor-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-monitor-reresolve"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let transcriptDirectory = try codexSessionDirectory(in: codexHome)
        let staleTranscriptURL = root.appendingPathComponent("missing-rollout-\(sessionId).jsonl")
        let transcriptURL = transcriptDirectory.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.500Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-monitor-reresolve","started_at":1777107522}}
        {"timestamp":"2026-04-25T07:55:29.804Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-monitor-reresolve","last_agent_message":null}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: ["surfaces": [["id": surfaceId, "ref": surfaceId]]])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CODEX_HOME"] = codexHome.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "hooks", "codex", "monitor",
                "--workspace",
                workspaceId,
                "--surface",
                surfaceId,
                "--session",
                sessionId,
                "--turn",
                "turn-monitor-reresolve",
                "--transcript",
                staleTranscriptURL.path,
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("notify_target \(workspaceId) \(surfaceId) Codex|Error|Codex ended before sending a final response")
            },
            "Expected monitor to recover from stale transcript path, saw \(state.commands)"
        )
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected monitor to publish high-priority Codex error status after re-resolving transcript path, saw \(state.commands)"
        )
    }

    func testCodexHookMonitorIgnoresUnscopedTerminalForTurnScopedMonitor() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-monitor-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-session-monitor-turn-scoped"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let transcriptURL = root.appendingPathComponent("rollout-\(sessionId).jsonl")
        try """
        {"timestamp":"2026-04-25T07:55:29.462Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"\(root.path)"}}
        {"timestamp":"2026-04-25T07:55:29.804Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"Old unscoped turn completed."}}
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let serverHandled = startMockServerSignal(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String {
                return self.v2Response(id: id, ok: true, result: ["surfaces": [["id": surfaceId, "ref": surfaceId]]])
            }
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = [
            "hooks", "codex", "monitor",
            "--workspace",
            workspaceId,
            "--surface",
            surfaceId,
            "--session",
            sessionId,
            "--turn",
            "turn-monitor-scoped",
            "--transcript",
            transcriptURL.path,
        ]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        XCTAssertTrue(
            waitForProcess(process, toHoldOpenFile: transcriptURL.path, timeout: 2),
            "Monitor did not start watching the initial transcript before scoped append"
        )
        XCTAssertTrue(process.isRunning, "Monitor exited on an unscoped terminal event before the scoped turn wrote an error")

        let appendHandle = try FileHandle(forWritingTo: transcriptURL)
        try appendHandle.seekToEnd()
        appendHandle.write(Data("\n".utf8))
        appendHandle.write(Data("""
        {"timestamp":"2026-04-25T07:55:30.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-monitor-scoped","started_at":1777107530}}
        {"timestamp":"2026-04-25T07:55:30.100Z","type":"event_msg","payload":{"type":"error","message":"Stream disconnected before completion.","codex_error_info":"response_stream_disconnected"}}
        """.utf8))
        try appendHandle.close()

        let serverTimedOut = serverHandled.wait(timeout: .now() + 5) == .timedOut
        let timedOut = exitSignal.wait(timeout: .now() + 5) == .timedOut
        if timedOut {
            process.terminate()
            _ = exitSignal.wait(timeout: .now() + 1)
        }
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertFalse(serverTimedOut, "Timed out waiting for mock socket command. stderr: \(stderr)")
        XCTAssertFalse(timedOut, stderr)
        XCTAssertEqual(process.terminationStatus, 0, stderr)
        XCTAssertEqual(stdout, "")
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("notify_target \(workspaceId) \(surfaceId) Codex|Network error|Stream disconnected before completion.")
            },
            "Expected monitor to ignore old unscoped terminal event and report scoped stream error, saw \(state.commands)"
        )
        XCTAssertTrue(
            state.commands.contains { command in
                command.contains("set_status codex Codex network error") &&
                    command.contains("--icon=exclamationmark.triangle.fill") &&
                    command.contains("--color=#FF453A") &&
                    command.contains("--priority=100") &&
                    command.contains("--tab=\(workspaceId)")
            },
            "Expected monitor to publish scoped Codex network error status, saw \(state.commands)"
        )
    }

}
