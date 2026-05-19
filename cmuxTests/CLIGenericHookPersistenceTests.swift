import XCTest
import Darwin

extension CLINotifyProcessIntegrationRegressionTests {
    struct GenericHookPersistenceScenario {
        let agent: String
        let subcommand: String
        let sessionId: String
        let executable: String
        let launchArguments: [String]
        let extraEnvironment: [String: String]
        let expectedArguments: [String]
        let expectedEnvironment: [String: String]?
    }

    func testGenericHookAgentsPersistSanitizedLaunchCommandsForSessionRestore() throws {
        let scenarios: [GenericHookPersistenceScenario] = [
            GenericHookPersistenceScenario(
                agent: "cursor",
                subcommand: "prompt-submit",
                sessionId: "cursor-session-123",
                executable: "/Users/example/.local/bin/cursor-agent",
                launchArguments: [
                    "/Users/example/.local/bin/cursor-agent",
                    "agent",
                    "--model",
                    "gpt-5.4",
                    "--resume",
                    "old-chat",
                    "--workspace",
                    "/tmp/old repo",
                    "--sandbox",
                    "enabled",
                    "initial prompt should not persist"
                ],
                extraEnvironment: [:],
                expectedArguments: [
                    "/Users/example/.local/bin/cursor-agent",
                    "--model",
                    "gpt-5.4",
                    "--sandbox",
                    "enabled"
                ],
                expectedEnvironment: nil
            ),
            GenericHookPersistenceScenario(
                agent: "gemini",
                subcommand: "session-start",
                sessionId: "gemini-session-123",
                executable: "/Users/example/.bun/bin/gemini",
                launchArguments: [
                    "/Users/example/.bun/bin/gemini",
                    "--model",
                    "gemini-2.5-pro",
                    "--resume",
                    "old-session",
                    "--sandbox",
                    "danger-full-access",
                    "initial prompt should not persist"
                ],
                extraEnvironment: [
                    "GEMINI_CLI_HOME": "/tmp/gemini home",
                    "GEMINI_API_KEY": "secret"
                ],
                expectedArguments: [
                    "/Users/example/.bun/bin/gemini",
                    "--model",
                    "gemini-2.5-pro",
                    "--sandbox",
                    "danger-full-access"
                ],
                expectedEnvironment: ["GEMINI_CLI_HOME": "/tmp/gemini home"]
            ),
            GenericHookPersistenceScenario(
                agent: "grok",
                subcommand: "session-start",
                sessionId: "grok-session-123",
                executable: "/Users/example/.grok/bin/grok",
                launchArguments: [
                    "/Users/example/.grok/bin/grok",
                    "--model",
                    "grok-4",
                    "--resume",
                    "old-session",
                    "--permission-mode",
                    "auto",
                    "--cwd",
                    "/tmp/grok repo",
                    "initial prompt should not persist"
                ],
                extraEnvironment: [
                    "GROK_HOME": "/tmp/grok home",
                    "XAI_API_KEY": "secret"
                ],
                expectedArguments: [
                    "/Users/example/.grok/bin/grok",
                    "--model",
                    "grok-4",
                    "--permission-mode",
                    "auto",
                    "--cwd",
                    "/tmp/grok repo"
                ],
                expectedEnvironment: ["GROK_HOME": "/tmp/grok home"]
            ),
            GenericHookPersistenceScenario(
                agent: "copilot",
                subcommand: "session-start",
                sessionId: "copilot-session-123",
                executable: "/tmp/cmux-agent-upstreams/copilot-install/bin/copilot",
                launchArguments: [
                    "/tmp/cmux-agent-upstreams/copilot-install/bin/copilot",
                    "--model",
                    "gpt-5.4",
                    "--resume=old-session",
                    "--allow-all-tools",
                    "-i",
                    "old prompt",
                    "initial prompt should not persist"
                ],
                extraEnvironment: [
                    "COPILOT_HOME": "/tmp/copilot home",
                    "COPILOT_GITHUB_TOKEN": "secret"
                ],
                expectedArguments: [
                    "/tmp/cmux-agent-upstreams/copilot-install/bin/copilot",
                    "--model",
                    "gpt-5.4",
                    "--allow-all-tools"
                ],
                expectedEnvironment: ["COPILOT_HOME": "/tmp/copilot home"]
            ),
            GenericHookPersistenceScenario(
                agent: "codebuddy",
                subcommand: "session-start",
                sessionId: "codebuddy-session-123",
                executable: "/Users/example/.npm/bin/codebuddy",
                launchArguments: [
                    "/Users/example/.npm/bin/codebuddy",
                    "--model",
                    "gpt-5.4",
                    "--resume",
                    "old-session",
                    "--permission-mode",
                    "plan",
                    "--worktree",
                    "scratch",
                    "initial prompt should not persist"
                ],
                extraEnvironment: [
                    "CODEBUDDY_CONFIG_DIR": "/tmp/codebuddy config",
                    "CODEBUDDY_API_KEY": "secret"
                ],
                expectedArguments: [
                    "/Users/example/.npm/bin/codebuddy",
                    "--model",
                    "gpt-5.4",
                    "--permission-mode",
                    "plan"
                ],
                expectedEnvironment: ["CODEBUDDY_CONFIG_DIR": "/tmp/codebuddy config"]
            ),
            GenericHookPersistenceScenario(
                agent: "factory",
                subcommand: "session-start",
                sessionId: "factory-session-123",
                executable: "/Users/example/.npm/bin/droid",
                launchArguments: [
                    "/Users/example/.npm/bin/droid",
                    "--resume",
                    "old-session",
                    "--cwd",
                    "/tmp/factory repo",
                    "--append-system-prompt",
                    "be terse",
                    "initial prompt should not persist"
                ],
                extraEnvironment: [
                    "FACTORY_API_KEY": "secret"
                ],
                expectedArguments: [
                    "/Users/example/.npm/bin/droid",
                    "--cwd",
                    "/tmp/factory repo",
                    "--append-system-prompt",
                    "be terse"
                ],
                expectedEnvironment: nil
            ),
            GenericHookPersistenceScenario(
                agent: "qoder",
                subcommand: "session-start",
                sessionId: "qoder-session-123",
                executable: "/Users/example/.npm/bin/qodercli",
                launchArguments: [
                    "/Users/example/.npm/bin/qodercli",
                    "--model",
                    "gemini-2.5-pro",
                    "--resume",
                    "old-session",
                    "--permission-mode",
                    "plan",
                    "--workspace",
                    "/tmp/qoder repo",
                    "initial prompt should not persist"
                ],
                extraEnvironment: [
                    "QODER_CONFIG_DIR": "/tmp/qoder config",
                    "GEMINI_API_KEY": "secret"
                ],
                expectedArguments: [
                    "/Users/example/.npm/bin/qodercli",
                    "--model",
                    "gemini-2.5-pro",
                    "--permission-mode",
                    "plan",
                    "--workspace",
                    "/tmp/qoder repo"
                ],
                expectedEnvironment: ["QODER_CONFIG_DIR": "/tmp/qoder config"]
            ),
        ]

        for scenario in scenarios {
            try XCTContext.runActivity(named: scenario.agent) { _ in
                try runGenericHookPersistenceScenario(scenario)
            }
        }
    }

    func testGrokNotificationHookUsesPayloadMessageAndStopDoesNotSendGenericNotification() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("grok-notification")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-notification-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "grok-session-123"
        let grokHome = root.appendingPathComponent("grok-home", isDirectory: true)

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
            "GROK_HOME": grokHome.path,
        ]

        func runGrokHook(_ subcommand: String, input: String) -> ProcessRunResult {
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
                arguments: ["hooks", "grok", subcommand],
                environment: environment,
                standardInput: input,
                timeout: 5
            )
            wait(for: [serverHandled], timeout: 5)
            return result
        }

        let start = runGrokHook(
            "session-start",
            input: #"{"sessionId":"\#(sessionId)","cwd":"\#(root.path)","hookEventName":"SessionStart"}"#
        )
        XCTAssertFalse(start.timedOut, start.stderr)
        XCTAssertEqual(start.status, 0, start.stderr)
        XCTAssertEqual(start.stdout, "{}\n")
        XCTAssertFalse(
            state.commands.contains { $0.contains("set_status grok") || $0.hasPrefix("notify_target_async ") },
            "Grok SessionStart should only establish routing state, saw \(state.commands)"
        )

        let stopCommandStart = state.commands.count
        let stop = runGrokHook(
            "stop",
            input: #"{"sessionId":"\#(sessionId)","cwd":"\#(root.path)","hookEventName":"Stop"}"#
        )
        XCTAssertFalse(stop.timedOut, stop.stderr)
        XCTAssertEqual(stop.status, 0, stop.stderr)
        XCTAssertEqual(stop.stdout, "{}\n")

        let stopCommands = Array(state.commands.dropFirst(stopCommandStart))
        XCTAssertFalse(
            stopCommands.contains { $0.hasPrefix("notify_target_async ") },
            "Grok Stop should not publish a generic completion notification; Notification carries the real message. Saw \(stopCommands)"
        )
        XCTAssertTrue(
            stopCommands.contains { $0.contains("set_status grok Idle") },
            "Expected Grok Stop to keep task-manager status idle, saw \(stopCommands)"
        )

        let notificationCommandStart = state.commands.count
        let notification = runGrokHook(
            "notification",
            input: #"{"sessionId":"\#(sessionId)","cwd":"\#(root.path)","hookEventName":"Notification","message":"Grok finished updating docs"}"#
        )
        XCTAssertFalse(notification.timedOut, notification.stderr)
        XCTAssertEqual(notification.status, 0, notification.stderr)
        XCTAssertEqual(notification.stdout, "{}\n")

        let notificationCommands = Array(state.commands.dropFirst(notificationCommandStart))
        XCTAssertTrue(
            notificationCommands.contains {
                $0.contains("notify_target_async \(workspaceId) \(surfaceId) Grok|Completed|Grok finished updating docs")
            },
            "Expected Grok Notification to forward the payload message, saw \(notificationCommands)"
        )
        XCTAssertTrue(
            notificationCommands.contains { $0.contains("set_status grok Idle") },
            "Expected completion notification to leave Grok idle, saw \(notificationCommands)"
        )

        let storeURL = root.appendingPathComponent("grok-hook-sessions.json", isDirectory: false)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
        var sessions = try XCTUnwrap(json["sessions"] as? [String: Any])
        var session = try XCTUnwrap(sessions[sessionId] as? [String: Any])
        XCTAssertEqual(session["lastSubtitle"] as? String, "Completed")
        XCTAssertEqual(session["lastBody"] as? String, "Grok finished updating docs")
        XCTAssertEqual(session["lastNotificationStatus"] as? String, "idle")

        let preAssistantInternalCommandStart = state.commands.count
        let preAssistantInternal = runGrokHook(
            "notification",
            input: #"{"sessionId":"grok-before-assistant","cwd":"\#(root.path)","hookEventName":"Notification","message":"SessionNotification { update: HookExecution { event_name: session_start } }"}"#
        )
        XCTAssertFalse(preAssistantInternal.timedOut, preAssistantInternal.stderr)
        XCTAssertEqual(preAssistantInternal.status, 0, preAssistantInternal.stderr)
        XCTAssertEqual(preAssistantInternal.stdout, "{}\n")

        let preAssistantInternalCommands = Array(state.commands.dropFirst(preAssistantInternalCommandStart))
        XCTAssertFalse(
            preAssistantInternalCommands.contains { $0.hasPrefix("notify_target_async ") },
            "Grok internal session notifications should not notify before there is an assistant response, saw \(preAssistantInternalCommands)"
        )

        let preAssistantGenericCommandStart = state.commands.count
        let preAssistantGeneric = runGrokHook(
            "notification",
            input: #"{"sessionId":"grok-generic-before-assistant","cwd":"\#(root.path)","hookEventName":"Notification","message":"Turn complete in 3.8s."}"#
        )
        XCTAssertFalse(preAssistantGeneric.timedOut, preAssistantGeneric.stderr)
        XCTAssertEqual(preAssistantGeneric.status, 0, preAssistantGeneric.stderr)
        XCTAssertEqual(preAssistantGeneric.stdout, "{}\n")

        let preAssistantGenericCommands = Array(state.commands.dropFirst(preAssistantGenericCommandStart))
        XCTAssertTrue(
            preAssistantGenericCommands.contains {
                $0.contains("notify_target_async \(workspaceId) \(surfaceId) Grok|Completed|Task completed")
            },
            "Grok generic completion notifications should still fire before there is an assistant response, saw \(preAssistantGenericCommands)"
        )
        XCTAssertTrue(
            preAssistantGenericCommands.contains { $0.contains("set_status grok Idle") },
            "Expected generic completion without an assistant response to leave Grok idle, saw \(preAssistantGenericCommands)"
        )
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
        sessions = try XCTUnwrap(json["sessions"] as? [String: Any])
        let preAssistantGenericSession = try XCTUnwrap(sessions["grok-generic-before-assistant"] as? [String: Any])
        XCTAssertEqual(preAssistantGenericSession["lastSubtitle"] as? String, "Completed")
        XCTAssertEqual(preAssistantGenericSession["lastBody"] as? String, "Task completed")
        XCTAssertEqual(preAssistantGenericSession["lastNotificationStatus"] as? String, "idle")

        let assistantMessage = "**42.** That's the answer, according to Deep Thought."
        try writeGrokAssistantTranscript(
            grokHome: grokHome,
            cwd: root.path,
            sessionId: sessionId,
            text: assistantMessage
        )
        let enrichedStopCommandStart = state.commands.count
        let enrichedStop = runGrokHook(
            "stop",
            input: #"{"sessionId":"\#(sessionId)","cwd":"\#(root.path)","hookEventName":"Stop"}"#
        )
        XCTAssertFalse(enrichedStop.timedOut, enrichedStop.stderr)
        XCTAssertEqual(enrichedStop.status, 0, enrichedStop.stderr)
        XCTAssertEqual(enrichedStop.stdout, "{}\n")

        let enrichedStopCommands = Array(state.commands.dropFirst(enrichedStopCommandStart))
        XCTAssertTrue(
            enrichedStopCommands.contains {
                $0.contains("notify_target_async \(workspaceId) \(surfaceId) Grok|Completed in ")
                    && $0.contains(assistantMessage)
            },
            "Expected Grok Stop to publish the cwd-scoped assistant response when Grok does not emit a Notification event, saw \(enrichedStopCommands)"
        )
        XCTAssertTrue(
            enrichedStopCommands.contains { $0.contains("set_status grok Idle") },
            "Expected enriched Grok Stop to leave Grok idle, saw \(enrichedStopCommands)"
        )

        let genericCompletionCommandStart = state.commands.count
        let genericCompletion = runGrokHook(
            "notification",
            input: #"{"sessionId":"\#(sessionId)","cwd":"\#(root.path)","hookEventName":"Notification","message":"Turn complete in 3.8s."}"#
        )
        XCTAssertFalse(genericCompletion.timedOut, genericCompletion.stderr)
        XCTAssertEqual(genericCompletion.status, 0, genericCompletion.stderr)
        XCTAssertEqual(genericCompletion.stdout, "{}\n")

        let genericCompletionCommands = Array(state.commands.dropFirst(genericCompletionCommandStart))
        XCTAssertTrue(
            genericCompletionCommands.contains {
                $0.contains("notify_target_async \(workspaceId) \(surfaceId) Grok|Completed|\(assistantMessage)")
            },
            "Expected generic Grok completion notification to use the cwd-scoped assistant response, saw \(genericCompletionCommands)"
        )
        XCTAssertTrue(
            genericCompletionCommands.contains { $0.contains("set_status grok Idle") },
            "Expected enriched completion notification to leave Grok idle, saw \(genericCompletionCommands)"
        )

        let sameCwdMissingSessionId = "grok-session-without-own-history"
        let sameCwdMissingCommandStart = state.commands.count
        let sameCwdMissing = runGrokHook(
            "notification",
            input: #"{"sessionId":"\#(sameCwdMissingSessionId)","cwd":"\#(root.path)","hookEventName":"Notification","message":"Turn complete in 4.0s."}"#
        )
        XCTAssertFalse(sameCwdMissing.timedOut, sameCwdMissing.stderr)
        XCTAssertEqual(sameCwdMissing.status, 0, sameCwdMissing.stderr)
        XCTAssertEqual(sameCwdMissing.stdout, "{}\n")

        let sameCwdMissingCommands = Array(state.commands.dropFirst(sameCwdMissingCommandStart))
        XCTAssertTrue(
            sameCwdMissingCommands.contains {
                $0.contains("notify_target_async \(workspaceId) \(surfaceId) Grok|Completed|Task completed")
            },
            "Grok completion without a matching session transcript should still fire a generic completion notification, saw \(sameCwdMissingCommands)"
        )
        XCTAssertFalse(
            sameCwdMissingCommands.contains { $0.contains(assistantMessage) },
            "Grok completion notifications must not read another session from the same cwd, saw \(sameCwdMissingCommands)"
        )

        let envResolvedMessage = "This message belongs to the env-resolved session."
        let unrelatedLatestMessage = "This message belongs to a newer unrelated session."
        try writeGrokAssistantTranscript(
            grokHome: grokHome,
            cwd: root.path,
            sessionId: surfaceId,
            text: envResolvedMessage
        )
        try writeGrokAssistantTranscript(
            grokHome: grokHome,
            cwd: root.path,
            sessionId: "latest-unrelated-grok-session",
            text: unrelatedLatestMessage
        )
        let unrelatedLatestHistoryURL = grokHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(grokEncodedSessionCWD(root.path), isDirectory: true)
            .appendingPathComponent("latest-unrelated-grok-session", isDirectory: true)
            .appendingPathComponent("chat_history.jsonl", isDirectory: false)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)],
            ofItemAtPath: unrelatedLatestHistoryURL.path
        )
        let envResolvedCommandStart = state.commands.count
        let envResolved = runGrokHook(
            "notification",
            input: #"{"cwd":"\#(root.path)","hookEventName":"Notification","message":"Turn complete in 4.2s."}"#
        )
        XCTAssertFalse(envResolved.timedOut, envResolved.stderr)
        XCTAssertEqual(envResolved.status, 0, envResolved.stderr)
        XCTAssertEqual(envResolved.stdout, "{}\n")

        let envResolvedCommands = Array(state.commands.dropFirst(envResolvedCommandStart))
        XCTAssertTrue(
            envResolvedCommands.contains {
                $0.contains("notify_target_async \(workspaceId) \(surfaceId) Grok|Completed|\(envResolvedMessage)")
            },
            "Grok completion without a payload session id should use the resolved hook session id, saw \(envResolvedCommands)"
        )
        XCTAssertFalse(
            envResolvedCommands.contains { $0.contains(unrelatedLatestMessage) },
            "Grok completion without a payload session id must not fall back to the latest unrelated cwd session, saw \(envResolvedCommands)"
        )

        let hookExecutionCommandStart = state.commands.count
        let hookExecution = runGrokHook(
            "notification",
            input: #"{"sessionId":"\#(sessionId)","cwd":"\#(root.path)","hookEventName":"Notification","message":"SessionNotification { update: MemoryFlushCompleted { result: written } }"}"#
        )
        XCTAssertFalse(hookExecution.timedOut, hookExecution.stderr)
        XCTAssertEqual(hookExecution.status, 0, hookExecution.stderr)
        XCTAssertEqual(hookExecution.stdout, "{}\n")

        let hookExecutionCommands = Array(state.commands.dropFirst(hookExecutionCommandStart))
        XCTAssertTrue(
            hookExecutionCommands.contains {
                $0.contains("notify_target_async \(workspaceId) \(surfaceId) Grok|Completed|\(assistantMessage)")
            },
            "Expected Grok HookExecution notification to use the cwd-scoped assistant response, saw \(hookExecutionCommands)"
        )
        XCTAssertFalse(
            hookExecutionCommands.contains { $0.contains("SessionNotification {") },
            "Hook execution status should not become the user-visible Grok notification body, saw \(hookExecutionCommands)"
        )

        let otherCwd = root.appendingPathComponent("other-project", isDirectory: true)
        let missingCwd = root.appendingPathComponent("missing-project", isDirectory: true)
        let otherProjectMessage = "This message belongs to a different project."
        try FileManager.default.createDirectory(at: missingCwd, withIntermediateDirectories: true)
        try writeGrokAssistantTranscript(
            grokHome: grokHome,
            cwd: otherCwd.path,
            sessionId: "other-grok-session",
            text: otherProjectMessage
        )
        let scopedMissSessionId = "grok-session-without-project-history"
        let scopedMissCommandStart = state.commands.count
        let scopedMiss = runGrokHook(
            "notification",
            input: #"{"sessionId":"\#(scopedMissSessionId)","cwd":"\#(missingCwd.path)","hookEventName":"Notification","message":"Turn complete in 4.0s."}"#
        )
        XCTAssertFalse(scopedMiss.timedOut, scopedMiss.stderr)
        XCTAssertEqual(scopedMiss.status, 0, scopedMiss.stderr)
        XCTAssertEqual(scopedMiss.stdout, "{}\n")

        let scopedMissCommands = Array(state.commands.dropFirst(scopedMissCommandStart))
        XCTAssertTrue(
            scopedMissCommands.contains {
                $0.contains("notify_target_async \(workspaceId) \(surfaceId) Grok|Completed|Task completed")
            },
            "Grok completion without a cwd-scoped transcript should still fire a generic completion notification, saw \(scopedMissCommands)"
        )
        XCTAssertFalse(
            scopedMissCommands.contains { $0.contains(otherProjectMessage) },
            "Grok completion notifications must not read another cwd's latest session, saw \(scopedMissCommands)"
        )
        XCTAssertTrue(
            scopedMissCommands.contains { $0.contains("set_status grok Idle") },
            "Expected scoped completion without transcript to leave Grok idle, saw \(scopedMissCommands)"
        )

        let waitingMessage = "Choose docs section"
        let waitingCommandStart = state.commands.count
        let waiting = runGrokHook(
            "notification",
            input: #"{"sessionId":"\#(sessionId)","cwd":"\#(root.path)","hookEventName":"Notification","reason":"idle_prompt","message":"\#(waitingMessage)"}"#
        )
        XCTAssertFalse(waiting.timedOut, waiting.stderr)
        XCTAssertEqual(waiting.status, 0, waiting.stderr)
        XCTAssertEqual(waiting.stdout, "{}\n")

        let waitingCommands = Array(state.commands.dropFirst(waitingCommandStart))
        XCTAssertTrue(
            waitingCommands.contains {
                $0.contains("notify_target_async \(workspaceId) \(surfaceId) Grok|Waiting|\(waitingMessage)")
            },
            "Expected waiting notification to forward the payload message, saw \(waitingCommands)"
        )
        XCTAssertTrue(
            waitingCommands.contains { $0.contains("set_status grok Grok needs input") },
            "Expected waiting notification to mark Grok as needing input, saw \(waitingCommands)"
        )

        let fallbackCommandStart = state.commands.count
        let fallback = runGrokHook(
            "notification",
            input: #"{"sessionId":"\#(sessionId)","cwd":"\#(root.path)","hookEventName":"Notification"}"#
        )
        XCTAssertFalse(fallback.timedOut, fallback.stderr)
        XCTAssertEqual(fallback.status, 0, fallback.stderr)
        XCTAssertEqual(fallback.stdout, "{}\n")

        let fallbackCommands = Array(state.commands.dropFirst(fallbackCommandStart))
        XCTAssertTrue(
            fallbackCommands.contains {
                $0.contains("notify_target_async \(workspaceId) \(surfaceId) Grok|Waiting|\(waitingMessage)")
            },
            "Expected empty Grok Notification payload to reuse the saved message, saw \(fallbackCommands)"
        )
        XCTAssertTrue(
            fallbackCommands.contains { $0.contains("set_status grok Grok needs input") },
            "Expected fallback notification to preserve the saved needs-input status, saw \(fallbackCommands)"
        )

        json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
        sessions = try XCTUnwrap(json["sessions"] as? [String: Any])
        session = try XCTUnwrap(sessions[sessionId] as? [String: Any])
        XCTAssertEqual(session["lastSubtitle"] as? String, "Waiting")
        XCTAssertEqual(session["lastBody"] as? String, waitingMessage)
        XCTAssertEqual(session["lastNotificationStatus"] as? String, "needsInput")

        let progressMessage = "Working through more changes"
        let progressCommandStart = state.commands.count
        let progress = runGrokHook(
            "notification",
            input: #"{"sessionId":"\#(sessionId)","cwd":"\#(root.path)","hookEventName":"Notification","message":"\#(progressMessage)"}"#
        )
        XCTAssertFalse(progress.timedOut, progress.stderr)
        XCTAssertEqual(progress.status, 0, progress.stderr)
        XCTAssertEqual(progress.stdout, "{}\n")

        let progressCommands = Array(state.commands.dropFirst(progressCommandStart))
        XCTAssertTrue(
            progressCommands.contains {
                $0.contains("notify_target_async \(workspaceId) \(surfaceId) Grok|Attention|\(progressMessage)")
            },
            "Expected unclassified notification to notify without changing status, saw \(progressCommands)"
        )
        XCTAssertFalse(
            progressCommands.contains { $0.contains("set_status grok ") },
            "Unclassified Grok notifications should not clear or replace active status, saw \(progressCommands)"
        )

        json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
        sessions = try XCTUnwrap(json["sessions"] as? [String: Any])
        session = try XCTUnwrap(sessions[sessionId] as? [String: Any])
        XCTAssertEqual(session["lastSubtitle"] as? String, "Attention")
        XCTAssertEqual(session["lastBody"] as? String, progressMessage)
        XCTAssertNil(session["lastNotificationStatus"])

        let neutralFallbackCommandStart = state.commands.count
        let neutralFallback = runGrokHook(
            "notification",
            input: #"{"sessionId":"\#(sessionId)","cwd":"\#(root.path)","hookEventName":"Notification"}"#
        )
        XCTAssertFalse(neutralFallback.timedOut, neutralFallback.stderr)
        XCTAssertEqual(neutralFallback.status, 0, neutralFallback.stderr)
        XCTAssertEqual(neutralFallback.stdout, "{}\n")

        let neutralFallbackCommands = Array(state.commands.dropFirst(neutralFallbackCommandStart))
        XCTAssertTrue(
            neutralFallbackCommands.contains {
                $0.contains("notify_target_async \(workspaceId) \(surfaceId) Grok|Attention|\(progressMessage)")
            },
            "Expected empty payload to reuse the neutral saved notification, saw \(neutralFallbackCommands)"
        )
        XCTAssertFalse(
            neutralFallbackCommands.contains { $0.contains("set_status grok ") },
            "Neutral fallback notifications should not publish an Idle status, saw \(neutralFallbackCommands)"
        )
    }

    func testGrokNotificationStillFiresOnRepeatedPromptWhenFeedTelemetryDoesNotReply() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("grok-repeat")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-repeat-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "grok-session-repeat"

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

        func runGrokHook(_ subcommand: String, input: String, stallFeedTelemetry: Bool = false, timeout: TimeInterval = 5) -> ProcessRunResult {
            let serverHandled = startMockServerAllowingNoResponse(listenerFD: listenerFD, state: state) { line in
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
                    return stallFeedTelemetry ? nil : self.v2Response(id: id, ok: true, result: [:])
                default:
                    return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
                }
            }
            let result = runProcess(
                executablePath: cliPath,
                arguments: ["hooks", "grok", subcommand],
                environment: environment,
                standardInput: input,
                timeout: timeout
            )
            wait(for: [serverHandled], timeout: 5)
            return result
        }

        let start = runGrokHook(
            "session-start",
            input: #"{"sessionId":"\#(sessionId)","cwd":"\#(root.path)","hookEventName":"SessionStart"}"#
        )
        XCTAssertFalse(start.timedOut, start.stderr)
        XCTAssertEqual(start.status, 0, start.stderr)

        for index in 1...2 {
            let prompt = runGrokHook(
                "prompt-submit",
                input: #"{"sessionId":"\#(sessionId)","cwd":"\#(root.path)","hookEventName":"UserPromptSubmit","prompt":"prompt \#(index)"}"#
            )
            XCTAssertFalse(prompt.timedOut, prompt.stderr)
            XCTAssertEqual(prompt.status, 0, prompt.stderr)

            let message = "Turn complete in \(index).0s."
            let commandStart = state.commands.count
            let notification = runGrokHook(
                "notification",
                input: #"{"sessionId":"\#(sessionId)","cwd":"\#(root.path)","hookEventName":"Notification","message":"\#(message)"}"#,
                stallFeedTelemetry: index == 2,
                timeout: 2
            )

            XCTAssertFalse(notification.timedOut, notification.stderr)
            XCTAssertEqual(notification.status, 0, notification.stderr)
            XCTAssertEqual(notification.stdout, "{}\n")

            let notificationCommands = Array(state.commands.dropFirst(commandStart))
            XCTAssertTrue(
                notificationCommands.contains {
                    $0.contains("notify_target_async \(workspaceId) \(surfaceId) Grok|Completed|Task completed")
                },
                "Expected Grok completion notification for prompt \(index), saw \(notificationCommands)"
            )
            XCTAssertTrue(
                notificationCommands.contains { $0.contains("set_status grok Idle") },
                "Expected Grok completion for prompt \(index) to leave Grok idle, saw \(notificationCommands)"
            )
        }
    }

    func writeGrokAssistantTranscript(
        grokHome: URL,
        cwd: String,
        sessionId: String,
        text: String
    ) throws {
        let sessionURL = grokHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(grokEncodedSessionCWD(cwd), isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionURL, withIntermediateDirectories: true)
        let payload: [String: Any] = ["type": "assistant", "content": text]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let line = String(decoding: data, as: UTF8.self) + "\n"
        try line.write(
            to: sessionURL.appendingPathComponent("chat_history.jsonl", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    }

    func grokEncodedSessionCWD(_ cwd: String) -> String {
        var encoded = ""
        for byte in cwd.utf8 {
            let isUnreserved = (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x30 && byte <= 0x39)
                || byte == 0x2D
                || byte == 0x2E
                || byte == 0x5F
                || byte == 0x7E
            if isUnreserved {
                encoded.append(Character(UnicodeScalar(byte)))
            } else {
                encoded.append(String(format: "%%%02X", byte))
            }
        }
        return encoded
    }

    func testGrokHookInstallRoutesNotificationEventToNotificationSubcommand() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-hook-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyHookURL = root
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("cmux.json", isDirectory: false)
        try FileManager.default.createDirectory(at: legacyHookURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacyHookJSON: [String: Any] = [
            "hooks": [
                "PostToolUse": [
                    [
                        "hooks": [
                            [
                                "command": "[ -n \"$CMUX_SURFACE_ID\" ] && [ \"$CMUX_GROK_HOOKS_DISABLED\" != \"1\" ] && command -v cmux >/dev/null 2>&1 && cmux hooks feed --source grok --event PostToolUse || echo '{}'",
                                "timeout": 120,
                                "type": "command",
                            ],
                        ],
                    ],
                ],
                "Stop": [
                    [
                        "hooks": [
                            [
                                "command": "[ -n \"$CMUX_SURFACE_ID\" ] && [ \"$CMUX_GROK_HOOKS_DISABLED\" != \"1\" ] && command -v cmux >/dev/null 2>&1 && cmux hooks grok stop || echo '{}'",
                                "timeout": 5,
                                "type": "command",
                            ],
                        ],
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: legacyHookJSON, options: [.prettyPrinted, .sortedKeys])
            .write(to: legacyHookURL, options: .atomic)

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "grok", "install", "--yes"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let hookURL = root
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("cmux-session.json", isDirectory: false)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: hookURL)) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        let notificationGroups = try XCTUnwrap(hooks["Notification"] as? [[String: Any]])
        let notificationCommands = notificationGroups
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["command"] as? String }
        let notificationTimeouts = notificationGroups
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["timeout"] as? Int }
        let preToolUseGroups = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        let preToolUseTimeouts = preToolUseGroups
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["timeout"] as? Int }
        let allCommands = hooks.values
            .compactMap { $0 as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["command"] as? String }

        XCTAssertTrue(
            notificationCommands.contains { $0.contains("cmux hooks grok notification") },
            "Expected Grok Notification to dispatch to the notification handler, saw \(notificationCommands)"
        )
        XCTAssertFalse(
            notificationCommands.contains { $0.contains("cmux hooks grok stop") },
            "Grok Notification should not use the generic stop handler, saw \(notificationCommands)"
        )
        XCTAssertEqual(notificationTimeouts, [10])
        XCTAssertEqual(preToolUseTimeouts, [120])
        XCTAssertFalse(
            allCommands.contains { $0.contains("[ -n \"$CMUX_SURFACE_ID\" ]") },
            "Grok strips CMUX_* from hook subprocesses, so installed commands must not gate on CMUX_SURFACE_ID. Saw \(allCommands)"
        )
        XCTAssertFalse(
            allCommands.contains { $0.contains("$CMUX_") },
            "Grok treats $VAR references as required hook environment, so installed commands must avoid CMUX variable interpolation. Saw \(allCommands)"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacyHookURL.path),
            "Expected setup to remove legacy cmux-owned Grok hook file"
        )
    }

    func testGrokHookInstallPreservesUserWrappedLegacyCommands() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-hook-preserve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyHookURL = root
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("cmux.json", isDirectory: false)
        try FileManager.default.createDirectory(at: legacyHookURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let preservedCommand = "bash -lc 'cmux hooks grok notification && ~/bin/after-grok'"
        let legacyHookJSON: [String: Any] = [
            "hooks": [
                "Notification": [
                    [
                        "hooks": [
                            [
                                "command": preservedCommand,
                                "timeout": 10,
                                "type": "command",
                            ],
                            [
                                "command": "[ \"$CMUX_GROK_HOOKS_DISABLED\" != \"1\" ] && command -v cmux >/dev/null 2>&1 && cmux hooks grok notification || echo '{}'",
                                "timeout": 10,
                                "type": "command",
                            ],
                        ],
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: legacyHookJSON, options: [.prettyPrinted, .sortedKeys])
            .write(to: legacyHookURL, options: .atomic)

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "grok", "install", "--yes"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: legacyHookURL)) as? [String: Any])
        let hooks = try XCTUnwrap(legacyJSON["hooks"] as? [String: Any])
        let notificationGroups = try XCTUnwrap(hooks["Notification"] as? [[String: Any]])
        let commands = notificationGroups
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["command"] as? String }

        XCTAssertEqual(commands, [preservedCommand])
        XCTAssertFalse(
            commands.contains { $0.hasPrefix("[ \"$CMUX_GROK_HOOKS_DISABLED\"") },
            "Expected setup to remove only exact cmux-owned legacy commands, saw \(commands)"
        )
    }

    func testGrokHookInstallPreservesLegacyFileMetadataWhenPruningOwnedHooks() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-hook-metadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyHookURL = root
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("cmux.json", isDirectory: false)
        try FileManager.default.createDirectory(at: legacyHookURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let legacyHookJSON: [String: Any] = [
            "version": 1,
            "hooks": [
                "Notification": [
                    [
                        "hooks": [
                            [
                                "command": "[ \"$CMUX_GROK_HOOKS_DISABLED\" != \"1\" ] && command -v cmux >/dev/null 2>&1 && cmux hooks grok notification || echo '{}'",
                                "timeout": 10,
                                "type": "command",
                            ],
                        ],
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: legacyHookJSON, options: [.prettyPrinted, .sortedKeys])
            .write(to: legacyHookURL, options: .atomic)

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "grok", "install", "--yes"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: legacyHookURL)) as? [String: Any])
        XCTAssertEqual(legacyJSON["version"] as? Int, 1)
        XCTAssertNil(legacyJSON["hooks"])
    }

    func testCodexHookInstallPrefersLaunchingAppBundledCLI() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-install-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let previousBundledHookCommand = "cmux_cli=\"${CMUX_BUNDLED_CLI_PATH:-}\"; if [ -z \"$cmux_cli\" ] || [ ! -x \"$cmux_cli\" ]; then cmux_cli=\"$(command -v cmux 2>/dev/null || true)\"; fi; [ -n \"$CMUX_SURFACE_ID\" ] && [ \"$CMUX_CODEX_HOOKS_DISABLED\" != \"1\" ] && [ -n \"$cmux_cli\" ] && \"$cmux_cli\" hooks codex prompt-submit || echo '{}'"
        let legacyHookJSON: [String: Any] = [
            "hooks": [
                "UserPromptSubmit": [
                    [
                        "hooks": [
                            [
                                "command": previousBundledHookCommand,
                                "timeout": 5000,
                                "type": "command",
                            ],
                        ],
                    ],
                    [
                        "hooks": [
                            [
                                "command": previousBundledHookCommand,
                                "timeout": 5000,
                                "type": "command",
                            ],
                        ],
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: legacyHookJSON, options: [.prettyPrinted, .sortedKeys])
            .write(to: codexHome.appendingPathComponent("hooks.json", isDirectory: false), options: .atomic)

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: [
                "HOME": root.path,
                "CODEX_HOME": codexHome.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let hookURL = codexHome.appendingPathComponent("hooks.json", isDirectory: false)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: hookURL)) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        let allCommands = hooks.values
            .compactMap { $0 as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["command"] as? String }

        XCTAssertTrue(
            allCommands.contains {
                $0.contains("CMUX_BUNDLED_CLI_PATH")
                    && $0.contains("\"$cmux_cli\" --socket \"$CMUX_SOCKET_PATH\" hooks codex prompt-submit")
            },
            "Codex hooks should route through the launching app's bundled CLI, saw \(allCommands)"
        )
        XCTAssertFalse(
            allCommands.contains { $0.contains("command -v cmux >/dev/null 2>&1 && cmux hooks codex") },
            "Codex hooks must not use the reload-global cmux shim directly, saw \(allCommands)"
        )
        XCTAssertFalse(
            allCommands.contains { $0 == previousBundledHookCommand },
            "Codex setup should replace bundled-CLI hooks that did not pin CMUX_SOCKET_PATH, saw \(allCommands)"
        )
        XCTAssertEqual(
            allCommands.filter { $0.contains("hooks codex prompt-submit") }.count,
            1,
            "Codex setup should collapse duplicate cmux-owned prompt hooks to one entry, saw \(allCommands)"
        )
    }

    func testGrokHookInstallRejectsFileAtHooksDirectory() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-hook-file-dir-\(UUID().uuidString)", isDirectory: true)
        let grokRoot = root.appendingPathComponent("custom-grok-home", isDirectory: true)
        let hooksPath = grokRoot.appendingPathComponent("hooks", isDirectory: false)
        try FileManager.default.createDirectory(at: grokRoot, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: hooksPath)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "grok", "install", "--yes"],
            environment: [
                "HOME": root.path,
                "GROK_HOME": grokRoot.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(result.status, 0, result.stdout)
        XCTAssertTrue(
            result.stderr.contains("cmux could not create the hooks directory: a file exists at \(hooksPath.path); remove or rename the conflicting file and re-run `cmux hooks setup`"),
            result.stderr
        )
        XCTAssertFalse(
            result.stdout.contains("Required agent configuration is missing."),
            result.stdout
        )
        var isDirectory: ObjCBool = true
        XCTAssertTrue(FileManager.default.fileExists(atPath: hooksPath.path, isDirectory: &isDirectory))
        XCTAssertFalse(isDirectory.boolValue)
    }

    func runGenericHookPersistenceScenario(_ scenario: GenericHookPersistenceScenario) throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("hook-\(scenario.agent)")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-\(scenario.agent)-hook-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("repo", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"

        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

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

        var environment: [String: String] = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": workspace.path,
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_WORKSPACE_ID": workspaceId,
            "CMUX_SURFACE_ID": surfaceId,
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_LAUNCH_KIND": scenario.agent,
            "CMUX_AGENT_LAUNCH_EXECUTABLE": scenario.executable,
            "CMUX_AGENT_LAUNCH_ARGV_B64": base64NULSeparated(scenario.launchArguments),
            "CMUX_AGENT_LAUNCH_CWD": workspace.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
        ]
        for (key, value) in scenario.extraEnvironment {
            environment[key] = value
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", scenario.agent, scenario.subcommand],
            environment: environment,
            standardInput: #"{"session_id":"\#(scenario.sessionId)","cwd":"\#(workspace.path)","hook_event_name":"SessionStart"}"#,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")

        let storeURL = root.appendingPathComponent("\(scenario.agent)-hook-sessions.json", isDirectory: false)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
        let sessions = try XCTUnwrap(json["sessions"] as? [String: Any])
        let session = try XCTUnwrap(sessions[scenario.sessionId] as? [String: Any])
        XCTAssertEqual(session["workspaceId"] as? String, workspaceId)
        XCTAssertEqual(session["surfaceId"] as? String, surfaceId)
        XCTAssertEqual(session["cwd"] as? String, workspace.path)

        let launchCommand = try XCTUnwrap(session["launchCommand"] as? [String: Any])
        XCTAssertEqual(launchCommand["launcher"] as? String, scenario.agent)
        XCTAssertEqual(launchCommand["executablePath"] as? String, scenario.executable)
        XCTAssertEqual(launchCommand["arguments"] as? [String], scenario.expectedArguments)
        XCTAssertEqual(launchCommand["workingDirectory"] as? String, workspace.path)
        XCTAssertEqual(launchCommand["environment"] as? [String: String], scenario.expectedEnvironment)
    }
}
