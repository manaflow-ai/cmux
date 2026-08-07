import Darwin
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    func testAmpLifecycleReconcilesNotificationsAndStatusThroughGenericHookPath() throws {
        let context = try makeClaudeHookContext(name: "amp-lifecycle")
        defer { context.cleanup() }
        startAgentHookMockServerAccepting(context: context)

        let ampProcess = Process()
        ampProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        ampProcess.arguments = ["30"]
        try ampProcess.run()
        defer {
            if ampProcess.isRunning {
                ampProcess.terminate()
                ampProcess.waitUntilExit()
            }
        }
        let sessionID = "T-amp-lifecycle"

        let sessionStart = runAmpHook(
            context: context,
            subcommand: "session-start",
            sessionID: sessionID,
            pid: ampProcess.processIdentifier,
            fields: ["hook_event_name": "SessionStart"]
        )
        XCTAssertFalse(sessionStart.timedOut, sessionStart.stderr)
        XCTAssertEqual(sessionStart.status, 0, sessionStart.stderr)

        let beforeRunning = context.state.snapshot().count
        let running = runAmpHook(
            context: context,
            subcommand: "lifecycle",
            sessionID: sessionID,
            pid: ampProcess.processIdentifier,
            fields: [
                "hook_event_name": "Lifecycle",
                "agent_state": "running",
            ]
        )
        XCTAssertFalse(running.timedOut, running.stderr)
        XCTAssertEqual(running.status, 0, running.stderr)
        let runningCommands = Array(context.state.snapshot().dropFirst(beforeRunning))
        XCTAssertTrue(
            runningCommands.contains {
                $0.hasPrefix("set_agent_lifecycle amp running --tab=\(context.workspaceId)")
                    && $0.contains("--panel=\(context.surfaceId)")
            },
            "Amp running state did not use the generic lifecycle path: \(runningCommands)"
        )
        XCTAssertTrue(
            runningCommands.contains { $0.hasPrefix("set_status amp ") && $0.contains("--icon=bolt.fill") },
            "Amp running state did not publish generic running status: \(runningCommands)"
        )
        XCTAssertFalse(
            runningCommands.contains { $0.hasPrefix("notify_target_async ") },
            "Amp running state unexpectedly notified: \(runningCommands)"
        )

        let beforeApproval = context.state.snapshot().count
        let approval = runAmpHook(
            context: context,
            subcommand: "lifecycle",
            sessionID: sessionID,
            pid: ampProcess.processIdentifier,
            fields: [
                "hook_event_name": "Lifecycle",
                "agent_state": "awaiting-approval",
                "notification_type": "permission_prompt",
                "message": "Amp is waiting for approval",
            ]
        )
        XCTAssertFalse(approval.timedOut, approval.stderr)
        XCTAssertEqual(approval.status, 0, approval.stderr)
        let approvalCommands = Array(context.state.snapshot().dropFirst(beforeApproval))
        XCTAssertTrue(
            approvalCommands.contains {
                $0.hasPrefix("set_agent_lifecycle amp needsInput --tab=\(context.workspaceId)")
            },
            "Amp approval did not become needs-input: \(approvalCommands)"
        )
        XCTAssertTrue(
            approvalCommands.contains { $0.hasPrefix("set_status amp ") && $0.contains("--icon=bell.fill") },
            "Amp approval did not publish the needs-input status: \(approvalCommands)"
        )
        XCTAssertTrue(
            approvalCommands.contains {
                $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Amp|")
            },
            "Amp approval did not use agent notification delivery: \(approvalCommands)"
        )

        let beforeCompletion = context.state.snapshot().count
        let completion = runAmpHook(
            context: context,
            subcommand: "lifecycle",
            sessionID: sessionID,
            pid: ampProcess.processIdentifier,
            fields: [
                "hook_event_name": "Lifecycle",
                "agent_state": "idle",
                "turn_outcome": "done",
                "last_assistant_message": "Completed Amp work",
            ]
        )
        XCTAssertFalse(completion.timedOut, completion.stderr)
        XCTAssertEqual(completion.status, 0, completion.stderr)
        let completionCommands = Array(context.state.snapshot().dropFirst(beforeCompletion))
        XCTAssertTrue(
            completionCommands.contains {
                $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Amp|")
                    && $0.contains("Completed Amp work")
            },
            "Amp completion did not use the generic turn-complete notification path: \(completionCommands)"
        )
        XCTAssertTrue(
            completionCommands.contains {
                $0.hasPrefix("set_agent_lifecycle amp idle --tab=\(context.workspaceId)")
            },
            "Amp completion did not reconcile to idle: \(completionCommands)"
        )

        let errorTurnID = "amp-error-turn"
        let errorPrompt = runAmpHook(
            context: context,
            subcommand: "prompt-submit",
            sessionID: sessionID,
            pid: ampProcess.processIdentifier,
            fields: [
                "hook_event_name": "UserPromptSubmit",
                "turn_id": errorTurnID,
                "prompt": "fail after settling",
                "title": "Amp lifecycle thread",
            ]
        )
        XCTAssertFalse(errorPrompt.timedOut, errorPrompt.stderr)
        XCTAssertEqual(errorPrompt.status, 0, errorPrompt.stderr)

        let beforeIdleError = context.state.snapshot().count
        let idleError = runAmpHook(
            context: context,
            subcommand: "lifecycle",
            sessionID: sessionID,
            pid: ampProcess.processIdentifier,
            fields: [
                "hook_event_name": "Lifecycle",
                "agent_state": "idle",
                "turn_outcome": "error",
                "notification_type": "error",
                "turn_id": errorTurnID,
            ]
        )
        XCTAssertFalse(idleError.timedOut, idleError.stderr)
        XCTAssertEqual(idleError.status, 0, idleError.stderr)
        let idleErrorCommands = Array(context.state.snapshot().dropFirst(beforeIdleError))
        XCTAssertTrue(
            idleErrorCommands.contains {
                $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Amp|")
                    && $0.contains("Amp reported an error")
            },
            "Amp idle-after-error did not use agent error notification delivery: \(idleErrorCommands)"
        )
        XCTAssertTrue(
            idleErrorCommands.contains {
                $0.hasPrefix("set_status amp ")
                    && $0.contains("--icon=exclamationmark.triangle.fill")
            },
            "Amp idle-after-error was misclassified as completion: \(idleErrorCommands)"
        )
        let settledErrorRecord = try readAmpHookSession(sessionID, context: context)
        XCTAssertNil(settledErrorRecord["activePromptDepth"])
        XCTAssertEqual(settledErrorRecord["lastPromptTurnId"] as? String, errorTurnID)
        XCTAssertEqual(settledErrorRecord["title"] as? String, "Amp lifecycle thread")
        XCTAssertTrue(
            (settledErrorRecord["terminalPromptTurnIds"] as? [String])?.contains(errorTurnID) == true
        )

        let beforeError = context.state.snapshot().count
        let error = runAmpHook(
            context: context,
            subcommand: "lifecycle",
            sessionID: sessionID,
            pid: ampProcess.processIdentifier,
            fields: [
                "hook_event_name": "Lifecycle",
                "agent_state": "error",
                "turn_outcome": "error",
                "notification_type": "error",
                "error": "Amp turn failed",
            ]
        )
        XCTAssertFalse(error.timedOut, error.stderr)
        XCTAssertEqual(error.status, 0, error.stderr)
        let errorCommands = Array(context.state.snapshot().dropFirst(beforeError))
        XCTAssertTrue(
            errorCommands.contains {
                $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Amp|")
                    && $0.contains("Amp turn failed")
            },
            "Amp error did not use the generic error notification path: \(errorCommands)"
        )
        XCTAssertTrue(
            errorCommands.contains { $0.hasPrefix("set_status amp ") && $0.contains("--icon=exclamationmark.triangle.fill") },
            "Amp error did not publish generic error status: \(errorCommands)"
        )

        let record = try readAmpHookSession(sessionID, context: context)
        XCTAssertEqual(record["runtimeStatus"] as? String, "error")
        XCTAssertEqual(record["agentLifecycle"] as? String, "needsInput")
    }

    func testAmpCancelledTurnSettlesWithoutCompletionNotification() throws {
        let context = try makeClaudeHookContext(name: "amp-cancelled")
        defer { context.cleanup() }
        startAgentHookMockServerAccepting(context: context)

        let ampProcess = Process()
        ampProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        ampProcess.arguments = ["30"]
        try ampProcess.run()
        defer {
            if ampProcess.isRunning {
                ampProcess.terminate()
                ampProcess.waitUntilExit()
            }
        }
        let sessionID = "T-amp-cancelled"
        let turnID = "amp-cancelled-turn"

        let sessionStart = runAmpHook(
            context: context,
            subcommand: "session-start",
            sessionID: sessionID,
            pid: ampProcess.processIdentifier,
            fields: ["hook_event_name": "SessionStart"]
        )
        XCTAssertFalse(sessionStart.timedOut, sessionStart.stderr)
        XCTAssertEqual(sessionStart.status, 0, sessionStart.stderr)

        let prompt = runAmpHook(
            context: context,
            subcommand: "prompt-submit",
            sessionID: sessionID,
            pid: ampProcess.processIdentifier,
            fields: [
                "hook_event_name": "UserPromptSubmit",
                "turn_id": turnID,
                "prompt": "stop this turn",
            ]
        )
        XCTAssertFalse(prompt.timedOut, prompt.stderr)
        XCTAssertEqual(prompt.status, 0, prompt.stderr)

        let beforeCancellation = context.state.snapshot().count
        let cancellation = runAmpHook(
            context: context,
            subcommand: "lifecycle",
            sessionID: sessionID,
            pid: ampProcess.processIdentifier,
            fields: [
                "hook_event_name": "Lifecycle",
                "agent_state": "idle",
                "turn_outcome": "cancelled",
                "turn_id": turnID,
            ]
        )
        XCTAssertFalse(cancellation.timedOut, cancellation.stderr)
        XCTAssertEqual(cancellation.status, 0, cancellation.stderr)
        let cancellationCommands = Array(context.state.snapshot().dropFirst(beforeCancellation))
        XCTAssertTrue(
            cancellationCommands.contains {
                $0.hasPrefix("set_agent_lifecycle amp idle --tab=\(context.workspaceId)")
            },
            "Amp cancellation did not reconcile to idle: \(cancellationCommands)"
        )
        XCTAssertFalse(
            cancellationCommands.contains { $0.hasPrefix("notify_target_async ") },
            "Amp cancellation was misreported as a completed turn: \(cancellationCommands)"
        )

        let record = try readAmpHookSession(sessionID, context: context)
        XCTAssertNil(record["activePromptDepth"])
        XCTAssertEqual(record["runtimeStatus"] as? String, "idle")
        XCTAssertEqual(record["agentLifecycle"] as? String, "idle")
        XCTAssertTrue(
            (record["terminalPromptTurnIds"] as? [String])?.contains(turnID) == true
        )
    }

    func testAmpRunningAndNeedsInputSignalsFailClosedForDeadProcess() throws {
        let context = try makeClaudeHookContext(name: "amp-dead")
        defer { context.cleanup() }
        startAgentHookMockServerAccepting(context: context)

        for state in ["running", "awaiting-approval"] {
            let before = context.state.snapshot().count
            let result = runAmpHook(
                context: context,
                subcommand: "lifecycle",
                sessionID: "T-dead-\(state)",
                pid: 999_999,
                fields: [
                    "hook_event_name": "Lifecycle",
                    "agent_state": state,
                    "notification_type": "permission_prompt",
                    "message": "stale Amp state",
                ]
            )
            XCTAssertFalse(result.timedOut, result.stderr)
            XCTAssertEqual(result.status, 0, result.stderr)
            let commands = Array(context.state.snapshot().dropFirst(before))
            XCTAssertFalse(
                commands.contains { command in
                    command.hasPrefix("set_agent_lifecycle ")
                        || command.hasPrefix("set_status ")
                        || command.hasPrefix("notify_target_async ")
                },
                "Dead Amp process published \(state) state: \(commands)"
            )
        }
    }

    private func runAmpHook(
        context: ClaudeHookContext,
        subcommand: String,
        sessionID: String,
        pid: Int32,
        fields: [String: Any]
    ) -> ProcessRunResult {
        var payload = fields
        payload["session_id"] = sessionID
        payload["cwd"] = context.root.path
        let input = String(
            data: try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            encoding: .utf8
        )!
        let executable = "/opt/amp/bin/amp"
        let environment = [
            "HOME": context.root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": context.root.path,
            "CMUX_SOCKET_PATH": context.socketPath,
            "CMUX_WORKSPACE_ID": context.workspaceId,
            "CMUX_SURFACE_ID": context.surfaceId,
            "CMUX_AGENT_HOOK_STATE_DIR": context.root.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_AMP_PID": String(pid),
            "CMUX_AGENT_LAUNCH_KIND": "amp",
            "CMUX_AGENT_LAUNCH_EXECUTABLE": executable,
            "CMUX_AGENT_LAUNCH_CWD": context.root.path,
            "CMUX_AGENT_LAUNCH_ARGV_B64": base64NULSeparated([executable, "--mode", "smart"]),
        ]
        return runProcess(
            executablePath: context.cliPath,
            arguments: [
                "hooks", "amp", subcommand,
                "--workspace", context.workspaceId,
                "--surface", context.surfaceId,
            ],
            environment: environment,
            standardInput: input,
            timeout: 5
        )
    }

    private func readAmpHookSession(
        _ sessionID: String,
        context: ClaudeHookContext
    ) throws -> [String: Any] {
        let stateURL = context.root.appendingPathComponent("amp-hook-sessions.json")
        let state = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        let sessions = try XCTUnwrap(state["sessions"] as? [String: Any])
        return try XCTUnwrap(sessions[sessionID] as? [String: Any])
    }
}
