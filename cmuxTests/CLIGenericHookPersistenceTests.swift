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
                agent: "kiro",
                subcommand: "session-start",
                sessionId: "kiro-session-123",
                executable: "/Users/example/.cargo/bin/kiro-cli",
                launchArguments: [
                    "/Users/example/.cargo/bin/kiro-cli",
                    "chat",
                    "--agent",
                    "cmux",
                    "--resume-id",
                    "old-session",
                    "--trust-tools",
                    "fs_read,fs_write",
                    "initial prompt should not persist"
                ],
                extraEnvironment: [
                    "KIRO_HOME": "/tmp/kiro home",
                    "AWS_ACCESS_KEY_ID": "secret"
                ],
                expectedArguments: [
                    "/Users/example/.cargo/bin/kiro-cli",
                    "--agent",
                    "cmux",
                    "--trust-tools",
                    "fs_read,fs_write"
                ],
                expectedEnvironment: ["KIRO_HOME": "/tmp/kiro home"]
            ),
            GenericHookPersistenceScenario(
                agent: "antigravity",
                subcommand: "session-start",
                sessionId: "antigravity-conversation-123",
                executable: "/Users/example/.local/bin/agy",
                launchArguments: [
                    "/Users/example/.local/bin/agy",
                    "--conversation",
                    "old-conversation",
                    "--sandbox",
                    "danger-full-access",
                    "--add-dir",
                    "/tmp/extra repo",
                    "initial prompt should not persist"
                ],
                extraEnvironment: [
                    "GEMINI_CLI_HOME": "/tmp/gemini home",
                    "GEMINI_API_KEY": "secret"
                ],
                expectedArguments: [
                    "/Users/example/.local/bin/agy",
                    "--sandbox",
                    "danger-full-access",
                    "--add-dir",
                    "/tmp/extra repo"
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

    func testAntigravityStopAndNotificationsUseGenericNotificationPath() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("antigravity-notification")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-antigravity-notification-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "antigravity-conversation-123"

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

        startDetachedMockServer(listenerFD: listenerFD, state: state, connectionCount: 128) { line in
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

        func runAntigravityHook(_ subcommand: String, input: String) -> ProcessRunResult {
            runProcess(
                executablePath: cliPath,
                arguments: ["hooks", "antigravity", subcommand],
                environment: environment,
                standardInput: input,
                timeout: 5
            )
        }

        let start = runAntigravityHook(
            "session-start",
            input: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"SessionStart"}"#
        )
        XCTAssertFalse(start.timedOut, start.stderr)
        XCTAssertEqual(start.status, 0, start.stderr)
        XCTAssertEqual(start.stdout, "{}\n")

        let backgroundMessage = "Antigravity is waiting on background work"
        let backgroundStopCommandStart = state.commands.count
        let backgroundStop = runAntigravityHook(
            "stop",
            input: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"Stop","last_assistant_message":"\#(backgroundMessage)","fullyIdle":false}"#
        )
        XCTAssertFalse(backgroundStop.timedOut, backgroundStop.stderr)
        XCTAssertEqual(backgroundStop.status, 0, backgroundStop.stderr)
        XCTAssertEqual(backgroundStop.stdout, "{}\n")

        let backgroundStopCommands = Array(state.commands.dropFirst(backgroundStopCommandStart))
        XCTAssertFalse(
            backgroundStopCommands.contains { $0.hasPrefix("notify_target_async ") },
            "Antigravity Stop with active background work must not publish idle notifications, saw \(backgroundStopCommands)"
        )
        XCTAssertTrue(
            backgroundStopCommands.contains { $0.contains("set_status antigravity Running") },
            "Antigravity Stop with active background work should keep the session running, saw \(backgroundStopCommands)"
        )
        XCTAssertFalse(
            backgroundStopCommands.contains { $0.contains("set_status antigravity Idle") },
            "Antigravity Stop with active background work must not mark idle, saw \(backgroundStopCommands)"
        )

        let backgroundDuplicateCommandStart = state.commands.count
        let backgroundDuplicate = runAntigravityHook(
            "notification",
            input: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"Notification","message":"Turn complete in 1.0s.","fullyIdle":false}"#
        )
        XCTAssertFalse(backgroundDuplicate.timedOut, backgroundDuplicate.stderr)
        XCTAssertEqual(backgroundDuplicate.status, 0, backgroundDuplicate.stderr)
        XCTAssertEqual(backgroundDuplicate.stdout, "{}\n")

        let backgroundDuplicateCommands = Array(state.commands.dropFirst(backgroundDuplicateCommandStart))
        XCTAssertFalse(
            backgroundDuplicateCommands.contains { $0.hasPrefix("notify_target_async ") },
            "Idle-classified Antigravity notifications must not double-notify while background work is active, saw \(backgroundDuplicateCommands)"
        )
        XCTAssertFalse(
            backgroundDuplicateCommands.contains { $0.contains("set_status antigravity Idle") },
            "Idle-classified Antigravity notifications must not override the running status while background work is active, saw \(backgroundDuplicateCommands)"
        )

        let missingFullyIdleSessionId = "\(sessionId)-missing-fully-idle"
        let missingFullyIdleStart = runAntigravityHook(
            "session-start",
            input: #"{"session_id":"\#(missingFullyIdleSessionId)","cwd":"\#(root.path)","hook_event_name":"SessionStart"}"#
        )
        XCTAssertFalse(missingFullyIdleStart.timedOut, missingFullyIdleStart.stderr)
        XCTAssertEqual(missingFullyIdleStart.status, 0, missingFullyIdleStart.stderr)
        XCTAssertEqual(missingFullyIdleStart.stdout, "{}\n")

        let missingFullyIdleBackgroundStop = runAntigravityHook(
            "stop",
            input: #"{"session_id":"\#(missingFullyIdleSessionId)","cwd":"\#(root.path)","hook_event_name":"Stop","last_assistant_message":"Background work still running","fullyIdle":false}"#
        )
        XCTAssertFalse(missingFullyIdleBackgroundStop.timedOut, missingFullyIdleBackgroundStop.stderr)
        XCTAssertEqual(missingFullyIdleBackgroundStop.status, 0, missingFullyIdleBackgroundStop.stderr)
        XCTAssertEqual(missingFullyIdleBackgroundStop.stdout, "{}\n")

        let missingFullyIdleNotificationCommandStart = state.commands.count
        let missingFullyIdleNotification = runAntigravityHook(
            "notification",
            input: #"{"session_id":"\#(missingFullyIdleSessionId)","cwd":"\#(root.path)","hook_event_name":"Notification","message":"Turn complete in 2.0s."}"#
        )
        XCTAssertFalse(missingFullyIdleNotification.timedOut, missingFullyIdleNotification.stderr)
        XCTAssertEqual(missingFullyIdleNotification.status, 0, missingFullyIdleNotification.stderr)
        XCTAssertEqual(missingFullyIdleNotification.stdout, "{}\n")

        let missingFullyIdleNotificationCommands = Array(state.commands.dropFirst(missingFullyIdleNotificationCommandStart))
        XCTAssertTrue(
            missingFullyIdleNotificationCommands.contains { $0.hasPrefix("notify_target_async ") },
            "Antigravity idle notifications without fullyIdle must publish instead of staying suppressed, saw \(missingFullyIdleNotificationCommands)"
        )
        XCTAssertFalse(
            missingFullyIdleNotificationCommands.contains { $0.contains("set_status antigravity Idle") },
            "Antigravity idle notifications must not reset the shared status while another background session is running, saw \(missingFullyIdleNotificationCommands)"
        )

        let stopMessage = "Antigravity finished updating docs"
        let stopCommandStart = state.commands.count
        let stop = runAntigravityHook(
            "stop",
            input: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"AfterAgent","last_assistant_message":"\#(stopMessage)"}"#
        )
        XCTAssertFalse(stop.timedOut, stop.stderr)
        XCTAssertEqual(stop.status, 0, stop.stderr)
        XCTAssertEqual(stop.stdout, "{}\n")

        let stopCommands = Array(state.commands.dropFirst(stopCommandStart))
        XCTAssertTrue(
            stopCommands.contains {
                $0.contains("notify_target_async \(workspaceId) \(surfaceId) Antigravity|Completed in ")
                    && $0.contains(stopMessage)
            },
            "Expected Antigravity stop to publish a turn-completion notification, saw \(stopCommands)"
        )
        XCTAssertTrue(
            stopCommands.contains { $0.contains("set_status antigravity Idle") },
            "Expected Antigravity stop to leave the session idle, saw \(stopCommands)"
        )

        let sessionEndCommandStart = state.commands.count
        let sessionEnd = runAntigravityHook(
            "session-end",
            input: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"SessionEnd"}"#
        )
        XCTAssertFalse(sessionEnd.timedOut, sessionEnd.stderr)
        XCTAssertEqual(sessionEnd.status, 0, sessionEnd.stderr)
        XCTAssertEqual(sessionEnd.stdout, "{}\n")

        let sessionEndCommands = Array(state.commands.dropFirst(sessionEndCommandStart))
        XCTAssertTrue(
            sessionEndCommands.contains { $0.contains("feed.push") },
            "Expected Antigravity SessionEnd to emit feed telemetry, saw \(sessionEndCommands)"
        )
        XCTAssertFalse(
            sessionEndCommands.contains { $0.hasPrefix("clear_agent_pid antigravity.") },
            "Antigravity SessionEnd is a turn boundary and must not clear saved routing, saw \(sessionEndCommands)"
        )

        let duplicateCompletionCommandStart = state.commands.count
        let duplicateCompletion = runAntigravityHook(
            "notification",
            input: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"Notification","message":"Turn complete in 2.0s."}"#
        )
        XCTAssertFalse(duplicateCompletion.timedOut, duplicateCompletion.stderr)
        XCTAssertEqual(duplicateCompletion.status, 0, duplicateCompletion.stderr)
        XCTAssertEqual(duplicateCompletion.stdout, "{}\n")

        let duplicateCompletionCommands = Array(state.commands.dropFirst(duplicateCompletionCommandStart))
        XCTAssertFalse(
            duplicateCompletionCommands.contains { $0.hasPrefix("notify_target_async ") },
            "Antigravity turn-completion notification must not double-notify after stop already did, saw \(duplicateCompletionCommands)"
        )

        let permissionMessage = "Allow shell command?"
        let permissionCommandStart = state.commands.count
        let permission = runAntigravityHook(
            "notification",
            input: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"Notification","reason":"permission_prompt","message":"\#(permissionMessage)"}"#
        )
        XCTAssertFalse(permission.timedOut, permission.stderr)
        XCTAssertEqual(permission.status, 0, permission.stderr)
        XCTAssertEqual(permission.stdout, "{}\n")

        let permissionCommands = Array(state.commands.dropFirst(permissionCommandStart))
        XCTAssertTrue(
            permissionCommands.contains {
                $0.contains("notify_target_async \(workspaceId) \(surfaceId) Antigravity|Permission|\(permissionMessage)")
            },
            "Expected Antigravity permission notifications to publish through cmux, saw \(permissionCommands)"
        )
        XCTAssertTrue(
            permissionCommands.contains { $0.contains("set_status antigravity Antigravity needs input") },
            "Expected Antigravity permission notifications to mark needs-input, saw \(permissionCommands)"
        )

        let stopErrorMessage = "Tool crashed"
        let stopErrorCommandStart = state.commands.count
        let stopError = runAntigravityHook(
            "stop",
            input: #"{"conversationId":"\#(sessionId)","workspacePaths":["\#(root.path)"],"hook_event_name":"Stop","terminationReason":"error","error":"\#(stopErrorMessage)","fullyIdle":true}"#
        )
        XCTAssertFalse(stopError.timedOut, stopError.stderr)
        XCTAssertEqual(stopError.status, 0, stopError.stderr)
        XCTAssertEqual(stopError.stdout, "{}\n")

        let stopErrorCommands = Array(state.commands.dropFirst(stopErrorCommandStart))
        XCTAssertTrue(
            stopErrorCommands.contains {
                $0.contains("notify_target_async \(workspaceId) \(surfaceId) Antigravity|Error|\(stopErrorMessage)")
            },
            "Expected Antigravity Stop errors to publish through cmux, saw \(stopErrorCommands)"
        )
        XCTAssertTrue(
            stopErrorCommands.contains { $0.contains("set_status antigravity Antigravity error") },
            "Expected Antigravity Stop errors to mark error status, saw \(stopErrorCommands)"
        )

        let errorMessage = "Execution failed"
        let errorCommandStart = state.commands.count
        let error = runAntigravityHook(
            "notification",
            input: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"Notification","message":"\#(errorMessage)"}"#
        )
        XCTAssertFalse(error.timedOut, error.stderr)
        XCTAssertEqual(error.status, 0, error.stderr)
        XCTAssertEqual(error.stdout, "{}\n")

        let errorCommands = Array(state.commands.dropFirst(errorCommandStart))
        XCTAssertTrue(
            errorCommands.contains {
                $0.contains("notify_target_async \(workspaceId) \(surfaceId) Antigravity|Error|\(errorMessage)")
            },
            "Expected Antigravity error notifications to publish through cmux, saw \(errorCommands)"
        )
        XCTAssertTrue(
            errorCommands.contains { $0.contains("set_status antigravity Antigravity error") },
            "Expected Antigravity error notifications to mark error status, saw \(errorCommands)"
        )
    }

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
            let serverHandled = startAgentHookMockServer(listenerFD: listenerFD, state: state, surfaceId: surfaceId, connectionCount: 4)
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

    func testAntigravityHookInstallUsesNativeHooksJSONShape() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-antigravity-hook-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "agy", "install", "--yes"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_BUNDLED_CLI_PATH": root.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let hookURL = root
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("hooks.json", isDirectory: false)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: hookURL)) as? [String: Any])
        XCTAssertNil(json["hooks"])

        let cmuxGroup = try XCTUnwrap(json["cmux"] as? [String: Any])
        let allCommands = cmuxGroup.values
            .compactMap { $0 as? [[String: Any]] }
            .flatMap { entries in
                entries.flatMap { entry -> [String] in
                    var commands: [String] = []
                    if let command = entry["command"] as? String {
                        commands.append(command)
                    }
                    if let hooks = entry["hooks"] as? [[String: Any]] {
                        commands += hooks.compactMap { $0["command"] as? String }
                    }
                    return commands
                }
            }
        XCTAssertFalse(allCommands.isEmpty)
        XCTAssertTrue(
            allCommands.allSatisfy { $0.contains("cmux-antigravity-hook-v2") },
            "Expected Antigravity hooks to use the pinned dispatch path, saw \(allCommands)"
        )
        XCTAssertFalse(
            allCommands.contains { $0.contains("'\(root.path)'") || $0.contains("\"\(root.path)\"") },
            "Directory-valued CMUX_BUNDLED_CLI_PATH must not be embedded as a hook executable, saw \(allCommands)"
        )
        XCTAssertFalse(
            allCommands.contains { $0.contains(#"[ -n "$CMUX_SURFACE_ID" ]"#) },
            "Antigravity hooks must still dispatch when agy does not preserve CMUX_SURFACE_ID, saw \(allCommands)"
        )

        let preToolUse = try XCTUnwrap(cmuxGroup["PreToolUse"] as? [[String: Any]])
        let preToolCommands = preToolUse
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
        XCTAssertTrue(
            preToolCommands.contains {
                ($0["command"] as? String)?.contains("hooks feed --source antigravity --event PreToolUse") == true
                    && ($0["timeout"] as? Int) == 120
            },
            "Expected Antigravity PreToolUse feed hook with second-based timeout, saw \(preToolCommands)"
        )

        let stop = try XCTUnwrap(cmuxGroup["Stop"] as? [[String: Any]])
        XCTAssertTrue(
            stop.contains {
                ($0["command"] as? String)?.contains("hooks antigravity stop") == true
                    && ($0["timeout"] as? Int) == 10
            },
            "Expected Antigravity Stop hook to be a direct command handler, saw \(stop)"
        )
        XCTAssertNotNil(cmuxGroup["SessionStart"])
        XCTAssertNotNil(cmuxGroup["SessionEnd"])
        XCTAssertNotNil(cmuxGroup["turn-completion"])
        XCTAssertNotNil(cmuxGroup["Notification"])
        XCTAssertNotNil(cmuxGroup["PostToolUse"])
    }

    func testKiroHookInstallUsesAgentConfigShapeAndPreservesDenyExit() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-kiro-hook-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "kiro", "install", "--yes"],
            environment: [
                "HOME": root.path,
                "KIRO_HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(
            result.stdout.contains("kiro-cli chat --agent cmux"),
            "Expected Kiro install to print the --agent cmux activation hint, saw: \(result.stdout)"
        )

        let hookURL = root
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent("cmux.json", isDirectory: false)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: hookURL)) as? [String: Any])
        XCTAssertEqual(json["name"] as? String, "cmux")
        XCTAssertNil(json["version"], "Kiro agent configs should not receive Cursor's hooks version field")
        XCTAssertEqual(
            json["tools"] as? [String], ["*"],
            "Kiro cmux agent must grant the full tool set so `--agent cmux` can run tools and fire preToolUse hooks"
        )

        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        let preToolUse = try XCTUnwrap(hooks["preToolUse"] as? [[String: Any]])
        XCTAssertTrue(
            preToolUse.contains {
                ($0["command"] as? String)?.contains("hooks feed --source kiro --event preToolUse") == true
                    && ($0["timeout_ms"] as? Int) == 120_000
                    && (($0["command"] as? String)?.contains("|| echo '{}'") == false)
                    && (($0["command"] as? String)?.contains("status=$?") == true)
                    && (($0["command"] as? String)?.contains("exit 2") == true)
            },
            "Expected Kiro preToolUse feed hook to preserve cmux's exit status for deny decisions, saw \(preToolUse)"
        )
        XCTAssertNotNil(hooks["agentSpawn"])
        XCTAssertNotNil(hooks["userPromptSubmit"])
        XCTAssertNotNil(hooks["postToolUse"])
        XCTAssertNotNil(hooks["stop"])
    }

    func testKiroFeedDenyUsesPreToolUseExitCodeTwo() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("kiro-feed-deny")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-kiro-feed-deny-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "33333333-3333-3333-3333-333333333333"
        let surfaceId = "44444444-4444-4444-4444-444444444444"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else {
                return self.malformedRequestResponse(raw: line)
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            XCTAssertEqual(method, "feed.push")
            return self.v2Response(
                id: id,
                ok: true,
                result: [
                    "status": "resolved",
                    "decision": [
                        "kind": "permission",
                        "mode": "deny",
                    ],
                ]
            )
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "feed", "--source", "kiro", "--event", "preToolUse"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId,
                "CMUX_KIRO_PID": "525252",
                "CMUX_KIRO_NOTIFICATION_LEVEL": "standard",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            standardInput: #"{"hook_event_name":"preToolUse","session_id":"kiro-session-123","cwd":"\#(root.path)","tool_name":"fs_write","tool_input":{"operations":[{"mode":"Line","path":"\#(root.appendingPathComponent("README.md").path)"}]}}"#,
            timeout: 5
        )
        wait(for: [serverHandled], timeout: 5)

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 2, result.stderr)
        XCTAssertTrue(result.stderr.contains("User denied permission via cmux Feed."), result.stderr)

        let feedEvents = state.commands.compactMap { command -> [String: Any]? in
            guard let payload = self.jsonObject(command),
                  payload["method"] as? String == "feed.push",
                  let params = payload["params"] as? [String: Any],
                  let event = params["event"] as? [String: Any] else {
                return nil
            }
            return event
        }
        XCTAssertEqual(feedEvents.count, 1, "Expected one Kiro Feed event, saw \(state.commands)")
        XCTAssertEqual(feedEvents.first?["hook_event_name"] as? String, "PermissionRequest")
        XCTAssertEqual(feedEvents.first?["_source"] as? String, "kiro")
        XCTAssertEqual(feedEvents.first?["_ppid"] as? Int, 525252)
    }

    /// The Feed permission modes that allow a tool (`once` / `always` / `all`
    /// / `bypass`, the WorkstreamPermissionMode raw values) must exit 0 so
    /// Kiro proceeds; an unrecognized/malformed mode must fail closed with
    /// exit 2 rather than silently allowing the tool.
    func testKiroFeedAllowModesProceedAndUnknownModeDenies() throws {
        func runKiroDecision(mode: String) throws -> ProcessRunResult {
            let cliPath = try bundledCLIPath()
            let socketPath = makeSocketPath("kiro-feed-mode")
            let listenerFD = try bindUnixSocket(at: socketPath)
            let state = MockSocketServerState()
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-kiro-feed-mode-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer {
                Darwin.close(listenerFD)
                unlink(socketPath)
                try? FileManager.default.removeItem(at: root)
            }
            let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
                guard let payload = self.jsonObject(line), let id = payload["id"] as? String else {
                    return self.malformedRequestResponse(raw: line)
                }
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "status": "resolved",
                        "decision": ["kind": "permission", "mode": mode],
                    ]
                )
            }
            let result = runProcess(
                executablePath: cliPath,
                arguments: ["hooks", "feed", "--source", "kiro", "--event", "preToolUse"],
                environment: [
                    "HOME": root.path,
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "PWD": root.path,
                    "CMUX_SOCKET_PATH": socketPath,
                    "CMUX_WORKSPACE_ID": "33333333-3333-3333-3333-333333333333",
                    "CMUX_SURFACE_ID": "44444444-4444-4444-4444-444444444444",
                    "CMUX_KIRO_PID": "525252",
                    "CMUX_KIRO_NOTIFICATION_LEVEL": "standard",
                    "CMUX_CLI_SENTRY_DISABLED": "1",
                ],
                standardInput: #"{"hook_event_name":"preToolUse","session_id":"kiro-session-mode","cwd":"\#(root.path)","tool_name":"fs_write","tool_input":{"operations":[{"mode":"Line","path":"\#(root.appendingPathComponent("README.md").path)"}]}}"#,
                timeout: 5
            )
            wait(for: [serverHandled], timeout: 5)
            return result
        }

        for mode in ["once", "always", "all", "bypass"] {
            let result = try runKiroDecision(mode: mode)
            XCTAssertFalse(result.timedOut, "\(mode): \(result.stderr)")
            XCTAssertEqual(result.status, 0, "mode \(mode) should allow (exit 0): \(result.stderr)")
            XCTAssertEqual(result.stdout, "{}\n", "mode \(mode) should print {}")
        }

        let unknown = try runKiroDecision(mode: "totally-bogus-mode")
        XCTAssertFalse(unknown.timedOut, unknown.stderr)
        XCTAssertEqual(unknown.status, 2, "unrecognized mode must fail closed (exit 2): \(unknown.stderr)")
        XCTAssertTrue(unknown.stderr.contains("unrecognized"), unknown.stderr)
    }

    /// At the default `standard` notification level, Kiro read-only tool
    /// events (`fs_read`) are suppressed (no Feed telemetry) while mutating
    /// tools (`fs_write`) still emit. Guards that suppression keys off the
    /// classified wire name (`PostToolUse`) rather than the raw camelCase hook
    /// event — i.e. the suppression actually triggers for real Kiro events.
    func testKiroStandardLevelSuppressesReadOnlyToolFeedEvents() throws {
        func feedPushCount(forTool tool: String) throws -> Int {
            let cliPath = try bundledCLIPath()
            let socketPath = makeSocketPath("kiro-suppress")
            let listenerFD = try bindUnixSocket(at: socketPath)
            let state = MockSocketServerState()
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-kiro-suppress-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer {
                Darwin.close(listenerFD)
                unlink(socketPath)
                try? FileManager.default.removeItem(at: root)
            }
            let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
                guard let payload = self.jsonObject(line), let id = payload["id"] as? String else {
                    return self.malformedRequestResponse(raw: line)
                }
                return self.v2Response(id: id, ok: true, result: ["status": "acknowledged"])
            }
            let result = runProcess(
                executablePath: cliPath,
                arguments: ["hooks", "feed", "--source", "kiro", "--event", "postToolUse"],
                environment: [
                    "HOME": root.path,
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "PWD": root.path,
                    "CMUX_SOCKET_PATH": socketPath,
                    "CMUX_WORKSPACE_ID": "33333333-3333-3333-3333-333333333333",
                    "CMUX_SURFACE_ID": "44444444-4444-4444-4444-444444444444",
                    "CMUX_KIRO_PID": "525252",
                    "CMUX_KIRO_NOTIFICATION_LEVEL": "standard",
                    "CMUX_CLI_SENTRY_DISABLED": "1",
                ],
                standardInput: #"{"hook_event_name":"postToolUse","session_id":"kiro-suppress","cwd":"\#(root.path)","tool_name":"\#(tool)"}"#,
                timeout: 5
            )
            XCTAssertFalse(result.timedOut, "\(tool): \(result.stderr)")
            XCTAssertEqual(result.status, 0, "\(tool): \(result.stderr)")
            XCTAssertEqual(result.stdout, "{}\n", "\(tool) stdout")
            // A non-suppressed event sends one feed.push, so wait for the
            // server to record it (generous timeout to avoid flaking on the
            // socket/process round-trip under CI load). A suppressed event
            // sends nothing, so this wait simply times out silently.
            _ = XCTWaiter().wait(for: [serverHandled], timeout: 5)
            return state.commands.filter { $0.contains("feed.push") }.count
        }

        XCTAssertEqual(try feedPushCount(forTool: "fs_read"), 0,
                       "read-only kiro tool at standard level must be suppressed")
        XCTAssertGreaterThan(try feedPushCount(forTool: "fs_write"), 0,
                             "mutating kiro tool at standard level must still emit telemetry")
    }

    func testLowercaseGenericFeedToolsStayTelemetryOutsideKiro() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("generic-lowercase-feed-tool")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-generic-lowercase-feed-tool-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "33333333-3333-3333-3333-333333333333"
        let surfaceId = "44444444-4444-4444-4444-444444444444"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else {
                return self.malformedRequestResponse(raw: line)
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            XCTAssertEqual(method, "feed.push")
            return self.v2Response(id: id, ok: true, result: ["status": "acknowledged"])
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "feed", "--source", "gemini", "--event", "PreToolUse"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId,
                "CMUX_GEMINI_PID": "626262",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            standardInput: #"{"hook_event_name":"PreToolUse","session_id":"gemini-session-123","cwd":"\#(root.path)","tool_name":"write","tool_input":{"path":"\#(root.appendingPathComponent("README.md").path)"}}"#,
            timeout: 5
        )
        wait(for: [serverHandled], timeout: 5)

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")

        let feedPushes = state.commands.compactMap { command -> [String: Any]? in
            guard let payload = self.jsonObject(command),
                  payload["method"] as? String == "feed.push",
                  let params = payload["params"] as? [String: Any] else {
                return nil
            }
            return params
        }
        XCTAssertEqual(feedPushes.count, 1, "Expected one generic Feed event, saw \(state.commands)")
        let event = try XCTUnwrap(feedPushes.first?["event"] as? [String: Any])
        let waitTimeout = try XCTUnwrap(feedPushes.first?["wait_timeout_seconds"] as? NSNumber)
        XCTAssertEqual(event["hook_event_name"] as? String, "PreToolUse")
        XCTAssertEqual(event["_source"] as? String, "gemini")
        XCTAssertEqual(event["tool_name"] as? String, "write")
        XCTAssertEqual(event["_ppid"] as? Int, 626262)
        XCTAssertEqual(waitTimeout.doubleValue, 0)
    }

    func testAntigravityFeedHookMissingSessionIdUsesStableFallback() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("antigravity-feed-stable-session")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-antigravity-feed-stable-session-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "33333333-3333-3333-3333-333333333333"
        let surfaceId = "44444444-4444-4444-4444-444444444444"

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
            "CMUX_ANTIGRAVITY_PID": "424242",
            "CMUX_CLI_SENTRY_DISABLED": "1",
        ]

        func runFeedHook(input: String) -> ProcessRunResult {
            let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
                guard let payload = self.jsonObject(line) else {
                    return self.malformedRequestResponse(raw: line)
                }
                guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                    return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
                }
                XCTAssertEqual(method, "feed.push")
                return self.v2Response(id: id, ok: true, result: ["status": "acknowledged"])
            }
            let result = runProcess(
                executablePath: cliPath,
                arguments: ["hooks", "feed", "--source", "antigravity", "--event", "PreToolUse"],
                environment: environment,
                standardInput: input,
                timeout: 5
            )
            wait(for: [serverHandled], timeout: 5)
            return result
        }

        let input = #"{"hook_event_name":"PreToolUse","workspacePaths":["\#(root.path)"],"notification":{"transcript_path":"\#(root.appendingPathComponent("transcript-a.jsonl").path)"},"toolCall":{"name":"read_file","args":{"path":"README.md"}}}"#
        let first = runFeedHook(input: input)
        XCTAssertFalse(first.timedOut, first.stderr)
        XCTAssertEqual(first.status, 0, first.stderr)
        XCTAssertEqual(first.stdout, "{}\n")

        let second = runFeedHook(input: input)
        XCTAssertFalse(second.timedOut, second.stderr)
        XCTAssertEqual(second.status, 0, second.stderr)
        XCTAssertEqual(second.stdout, "{}\n")

        let differentTranscriptInput = #"{"hook_event_name":"PreToolUse","workspacePaths":["\#(root.path)"],"notification":{"transcript_path":"\#(root.appendingPathComponent("transcript-b.jsonl").path)"},"toolCall":{"name":"read_file","args":{"path":"README.md"}}}"#
        let third = runFeedHook(input: differentTranscriptInput)
        XCTAssertFalse(third.timedOut, third.stderr)
        XCTAssertEqual(third.status, 0, third.stderr)
        XCTAssertEqual(third.stdout, "{}\n")

        let events = state.commands.compactMap { command -> [String: Any]? in
            guard let payload = self.jsonObject(command),
                  payload["method"] as? String == "feed.push",
                  let params = payload["params"] as? [String: Any],
                  let event = params["event"] as? [String: Any] else {
                return nil
            }
            return event
        }
        let sessionIds = events.compactMap { $0["session_id"] as? String }
        XCTAssertEqual(sessionIds.count, 3, "Expected three feed events, saw \(state.commands)")
        XCTAssertEqual(sessionIds[0], sessionIds[1])
        XCTAssertNotEqual(sessionIds[1], sessionIds[2])
        XCTAssertTrue(
            sessionIds[0].hasPrefix("antigravity-fallback-"),
            "Expected deterministic Antigravity fallback session id, saw \(sessionIds[0])"
        )
        XCTAssertEqual(events.compactMap { $0["_ppid"] as? Int }, [424242, 424242, 424242])
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

        startDetachedAgentHookMockServer(listenerFD: listenerFD, state: state, surfaceId: surfaceId, connectionCount: 80)

        func runGrokHook(_ subcommand: String, input: String) -> ProcessRunResult {
            let result = runProcess(
                executablePath: cliPath,
                arguments: ["hooks", "grok", subcommand],
                environment: environment,
                standardInput: input,
                timeout: 5
            )
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
        let nextTurnPrompt = runGrokHook(
            "prompt-submit",
            input: #"{"sessionId":"\#(sessionId)","cwd":"\#(root.path)","hookEventName":"UserPromptSubmit","prompt":"next turn"}"#
        )
        XCTAssertFalse(nextTurnPrompt.timedOut, nextTurnPrompt.stderr)
        XCTAssertEqual(nextTurnPrompt.status, 0, nextTurnPrompt.stderr)
        XCTAssertEqual(nextTurnPrompt.stdout, "{}\n")

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
            "Expected Grok Stop fallback to publish the cwd-scoped assistant response when Grok only emits internal Notification events, saw \(enrichedStopCommands)"
        )
        XCTAssertTrue(
            enrichedStopCommands.contains { $0.contains("set_status grok Idle") },
            "Expected enriched Grok Stop to leave Grok idle, saw \(enrichedStopCommands)"
        )

        let oversizedSessionId = "grok-oversized-final"
        let oversizedAssistantMessage = "Oversized Grok assistant response " + String(repeating: "g", count: 300_000)
        let oversizedStart = runGrokHook(
            "session-start",
            input: #"{"sessionId":"\#(oversizedSessionId)","cwd":"\#(root.path)","hookEventName":"SessionStart"}"#
        )
        XCTAssertFalse(oversizedStart.timedOut, oversizedStart.stderr)
        XCTAssertEqual(oversizedStart.status, 0, oversizedStart.stderr)

        let oversizedPrompt = runGrokHook(
            "prompt-submit",
            input: #"{"sessionId":"\#(oversizedSessionId)","cwd":"\#(root.path)","hookEventName":"UserPromptSubmit","prompt":"oversized turn"}"#
        )
        XCTAssertFalse(oversizedPrompt.timedOut, oversizedPrompt.stderr)
        XCTAssertEqual(oversizedPrompt.status, 0, oversizedPrompt.stderr)

        let oversizedSessionURL = grokHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(grokEncodedSessionCWD(root.path), isDirectory: true)
            .appendingPathComponent(oversizedSessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: oversizedSessionURL, withIntermediateDirectories: true)
        let oversizedPayload: [String: Any] = ["type": "assistant", "content": oversizedAssistantMessage]
        let oversizedData = try JSONSerialization.data(withJSONObject: oversizedPayload, options: [.sortedKeys])
        try oversizedData.write(to: oversizedSessionURL.appendingPathComponent("chat_history.jsonl", isDirectory: false))

        let oversizedStopCommandStart = state.commands.count
        let oversizedStop = runGrokHook(
            "stop",
            input: #"{"sessionId":"\#(oversizedSessionId)","cwd":"\#(root.path)","hookEventName":"Stop"}"#
        )
        XCTAssertFalse(oversizedStop.timedOut, oversizedStop.stderr)
        XCTAssertEqual(oversizedStop.status, 0, oversizedStop.stderr)

        let oversizedStopCommands = Array(state.commands.dropFirst(oversizedStopCommandStart))
        XCTAssertTrue(
            oversizedStopCommands.contains {
                $0.contains("notify_target_async \(workspaceId) \(surfaceId) Grok|Completed in ")
                    && $0.contains("Oversized Grok assistant response")
            },
            "Expected Grok Stop fallback to parse the oversized final chat-history line, saw \(oversizedStopCommands)"
        )

        let multibyteSessionId = "grok-multibyte-boundary"
        let multibyteStart = runGrokHook(
            "session-start",
            input: #"{"sessionId":"\#(multibyteSessionId)","cwd":"\#(root.path)","hookEventName":"SessionStart"}"#
        )
        XCTAssertFalse(multibyteStart.timedOut, multibyteStart.stderr)
        XCTAssertEqual(multibyteStart.status, 0, multibyteStart.stderr)

        let multibytePrompt = runGrokHook(
            "prompt-submit",
            input: #"{"sessionId":"\#(multibyteSessionId)","cwd":"\#(root.path)","hookEventName":"UserPromptSubmit","prompt":"multibyte boundary"}"#
        )
        XCTAssertFalse(multibytePrompt.timedOut, multibytePrompt.stderr)
        XCTAssertEqual(multibytePrompt.status, 0, multibytePrompt.stderr)

        let multibyteSessionURL = grokHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(grokEncodedSessionCWD(root.path), isDirectory: true)
            .appendingPathComponent(multibyteSessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: multibyteSessionURL, withIntermediateDirectories: true)
        let leadingPrefix = #"{"type":"assistant","content":""#
        let leadingContent = String(repeating: "あ", count: 90_000)
        let leadingLine = leadingPrefix + leadingContent + #""}"#
        let leadingPrefixByteCount = Data(leadingPrefix.utf8).count
        let leadingLineByteCount = Data(leadingLine.utf8).count
        var multibyteAssistantMessage = "Grok final after multibyte boundary"
        var multibyteHistoryData: Data?
        for suffixLength in 0..<3 {
            multibyteAssistantMessage = "Grok final after multibyte boundary" + String(repeating: "x", count: suffixLength)
            let finalLine = #"{"type":"assistant","content":"\#(multibyteAssistantMessage)"}"#
            let history = leadingLine + "\n" + finalLine + "\n"
            let data = Data(history.utf8)
            let readStart = data.count - min(data.count, 256 * 1024)
            if readStart > leadingPrefixByteCount,
               readStart < leadingLineByteCount,
               (readStart - leadingPrefixByteCount) % 3 != 0 {
                multibyteHistoryData = data
                break
            }
        }
        let historyData = try XCTUnwrap(multibyteHistoryData)
        try historyData.write(to: multibyteSessionURL.appendingPathComponent("chat_history.jsonl", isDirectory: false))

        let multibyteStopCommandStart = state.commands.count
        let multibyteStop = runGrokHook(
            "stop",
            input: #"{"sessionId":"\#(multibyteSessionId)","cwd":"\#(root.path)","hookEventName":"Stop"}"#
        )
        XCTAssertFalse(multibyteStop.timedOut, multibyteStop.stderr)
        XCTAssertEqual(multibyteStop.status, 0, multibyteStop.stderr)

        let multibyteStopCommands = Array(state.commands.dropFirst(multibyteStopCommandStart))
        XCTAssertTrue(
            multibyteStopCommands.contains {
                $0.contains("notify_target_async \(workspaceId) \(surfaceId) Grok|Completed in ")
                    && $0.contains(multibyteAssistantMessage)
            },
            "Expected Grok Stop fallback to skip the partial multibyte leading line, saw \(multibyteStopCommands)"
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
        XCTAssertFalse(
            genericCompletionCommands.contains { $0.hasPrefix("notify_target_async ") },
            "Grok completion Notification must not double-notify after Stop fallback already published the completion, saw \(genericCompletionCommands)"
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
        XCTAssertFalse(
            hookExecutionCommands.contains { $0.hasPrefix("notify_target_async ") },
            "Grok internal session notifications must not replay the last assistant response as a fresh notification, saw \(hookExecutionCommands)"
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

        for neutralMessage in ["Invalid input format", "Question mark rendered"] {
            let neutralCommandStart = state.commands.count
            let neutral = runGrokHook(
                "notification",
                input: #"{"sessionId":"\#(sessionId)","cwd":"\#(root.path)","hookEventName":"Notification","message":"\#(neutralMessage)"}"#
            )
            XCTAssertFalse(neutral.timedOut, neutral.stderr)
            XCTAssertEqual(neutral.status, 0, neutral.stderr)
            XCTAssertEqual(neutral.stdout, "{}\n")

            let neutralCommands = Array(state.commands.dropFirst(neutralCommandStart))
            XCTAssertFalse(
                neutralCommands.contains { $0.hasPrefix("notify_target_async ") },
                "Neutral classifier text should not alert as needs-input, saw \(neutralCommands)"
            )
            XCTAssertFalse(
                neutralCommands.contains { $0.contains("set_status grok ") },
                "Neutral classifier text should not replace the saved status, saw \(neutralCommands)"
            )
        }

        let incompleteWaitingMessage = "Task incomplete and undone, waiting for input"
        let incompleteWaitingCommandStart = state.commands.count
        let incompleteWaiting = runGrokHook(
            "notification",
            input: #"{"sessionId":"\#(sessionId)","cwd":"\#(root.path)","hookEventName":"Notification","message":"\#(incompleteWaitingMessage)"}"#
        )
        XCTAssertFalse(incompleteWaiting.timedOut, incompleteWaiting.stderr)
        XCTAssertEqual(incompleteWaiting.status, 0, incompleteWaiting.stderr)
        XCTAssertEqual(incompleteWaiting.stdout, "{}\n")

        let incompleteWaitingCommands = Array(state.commands.dropFirst(incompleteWaitingCommandStart))
        XCTAssertTrue(
            incompleteWaitingCommands.contains {
                $0.contains("notify_target_async \(workspaceId) \(surfaceId) Grok|Waiting|\(incompleteWaitingMessage)")
            },
            "Incomplete/undone waiting text should not be classified as a completion, saw \(incompleteWaitingCommands)"
        )
        XCTAssertFalse(
            incompleteWaitingCommands.contains { $0.contains("Grok|Completed|") },
            "Incomplete/undone waiting text must not emit a completed notification, saw \(incompleteWaitingCommands)"
        )

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
        XCTAssertFalse(
            progressCommands.contains { $0.hasPrefix("notify_target_async ") },
            "Unclassified Grok notifications are progress/bookkeeping and should not alert, saw \(progressCommands)"
        )
        XCTAssertFalse(
            progressCommands.contains { $0.contains("set_status grok ") },
            "Unclassified Grok notifications should not clear or replace active status, saw \(progressCommands)"
        )

        json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
        sessions = try XCTUnwrap(json["sessions"] as? [String: Any])
        session = try XCTUnwrap(sessions[sessionId] as? [String: Any])
        XCTAssertEqual(session["lastSubtitle"] as? String, "Waiting")
        XCTAssertEqual(session["lastBody"] as? String, incompleteWaitingMessage)
        XCTAssertEqual(session["lastNotificationStatus"] as? String, "needsInput")

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
                $0.contains("notify_target_async \(workspaceId) \(surfaceId) Grok|Waiting|\(incompleteWaitingMessage)")
            },
            "Expected empty payload to reuse the last terminal saved notification, saw \(neutralFallbackCommands)"
        )
        XCTAssertTrue(
            neutralFallbackCommands.contains { $0.contains("set_status grok Grok needs input") },
            "Fallback notifications should preserve the saved needs-input status, saw \(neutralFallbackCommands)"
        )
    }

    func testGrokStopFallbackCompletionsFireForTwoConcurrentThreads() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("grok-two-threads")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-two-threads-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceIds = [
            "22222222-2222-2222-2222-222222222222",
            "33333333-3333-3333-3333-333333333333",
        ]
        let grokHome = root.appendingPathComponent("grok-home", isDirectory: true)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let baseEnvironment: [String: String] = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": root.path,
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_WORKSPACE_ID": workspaceId,
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "GROK_HOME": grokHome.path,
        ]

        func runGrokHook(_ subcommand: String, input: String, surfaceId: String) -> ProcessRunResult {
            let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
                guard let payload = self.jsonObject(line) else {
                    return "OK"
                }
                guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                    return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
                }
                switch method {
                case "surface.list":
                    return self.v2Response(
                        id: id,
                        ok: true,
                        result: [
                            "surfaces": surfaceIds.enumerated().map { index, listedSurfaceId in
                                [
                                    "id": listedSurfaceId,
                                    "ref": "surface:\(index + 1)",
                                    "focused": listedSurfaceId == surfaceId,
                                ] as [String: Any]
                            },
                        ]
                    )
                case "feed.push":
                    return self.v2Response(id: id, ok: true, result: [:])
                default:
                    return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
                }
            }
            var environment = baseEnvironment
            environment["CMUX_SURFACE_ID"] = surfaceId
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

        let threads = (1...2).map { index in
            (
                index: index,
                sessionId: "grok-thread-\(index)",
                surfaceId: surfaceIds[index - 1],
                assistantMessage: "thread \(index) response complete"
            )
        }

        for thread in threads {
            let start = runGrokHook(
                "session-start",
                input: #"{"sessionId":"\#(thread.sessionId)","cwd":"\#(root.path)","hookEventName":"SessionStart"}"#,
                surfaceId: thread.surfaceId
            )
            XCTAssertFalse(start.timedOut, start.stderr)
            XCTAssertEqual(start.status, 0, start.stderr)
            XCTAssertEqual(start.stdout, "{}\n")

            let prompt = runGrokHook(
                "prompt-submit",
                input: #"{"sessionId":"\#(thread.sessionId)","cwd":"\#(root.path)","hookEventName":"UserPromptSubmit","prompt":"thread \#(thread.index) prompt"}"#,
                surfaceId: thread.surfaceId
            )
            XCTAssertFalse(prompt.timedOut, prompt.stderr)
            XCTAssertEqual(prompt.status, 0, prompt.stderr)
            XCTAssertEqual(prompt.stdout, "{}\n")

            let internalCommandStart = state.commands.count
            let internalNotification = runGrokHook(
                "notification",
                input: #"{"sessionId":"\#(thread.sessionId)","cwd":"\#(root.path)","hookEventName":"Notification","message":"SessionNotification { update: HookExecution { event_name: user_prompt_submit } }"}"#,
                surfaceId: thread.surfaceId
            )
            XCTAssertFalse(internalNotification.timedOut, internalNotification.stderr)
            XCTAssertEqual(internalNotification.status, 0, internalNotification.stderr)
            XCTAssertEqual(internalNotification.stdout, "{}\n")

            let internalCommands = Array(state.commands.dropFirst(internalCommandStart))
            XCTAssertFalse(
                internalCommands.contains { $0.hasPrefix("notify_target_async ") },
                "Prompt-submit bookkeeping for Grok thread \(thread.index) must not notify, saw \(internalCommands)"
            )
        }

        for thread in threads {
            try writeGrokAssistantTranscript(
                grokHome: grokHome,
                cwd: root.path,
                sessionId: thread.sessionId,
                text: thread.assistantMessage
            )
        }

        for thread in threads {
            let stopCommandStart = state.commands.count
            let stop = runGrokHook(
                "stop",
                input: #"{"sessionId":"\#(thread.sessionId)","cwd":"\#(root.path)","hookEventName":"Stop"}"#,
                surfaceId: thread.surfaceId
            )
            XCTAssertFalse(stop.timedOut, stop.stderr)
            XCTAssertEqual(stop.status, 0, stop.stderr)
            XCTAssertEqual(stop.stdout, "{}\n")

            let stopCommands = Array(state.commands.dropFirst(stopCommandStart))
            XCTAssertTrue(
                stopCommands.contains {
                    $0.contains("notify_target_async \(workspaceId) \(thread.surfaceId) Grok|Completed in ")
                        && $0.contains(thread.assistantMessage)
                },
                "Expected Grok Stop fallback to notify for thread \(thread.index), saw \(stopCommands)"
            )
            if thread.index == 1 {
                XCTAssertFalse(
                    stopCommands.contains { $0.contains("set_status grok Idle") },
                    "First Grok thread must not reset shared status while thread 2 is still running, saw \(stopCommands)"
                )
            } else {
                XCTAssertTrue(
                    stopCommands.contains { $0.contains("set_status grok Idle") },
                    "Expected final Grok Stop to leave Grok idle, saw \(stopCommands)"
                )
            }
        }

        for thread in threads {
            let notificationCommandStart = state.commands.count
            let notification = runGrokHook(
                "notification",
                input: #"{"sessionId":"\#(thread.sessionId)","cwd":"\#(root.path)","hookEventName":"Notification","message":"SessionNotification { update: HookExecution { event_name: stop } }"}"#,
                surfaceId: thread.surfaceId
            )
            XCTAssertFalse(notification.timedOut, notification.stderr)
            XCTAssertEqual(notification.status, 0, notification.stderr)
            XCTAssertEqual(notification.stdout, "{}\n")

            let notificationCommands = Array(state.commands.dropFirst(notificationCommandStart))
            XCTAssertFalse(
                notificationCommands.contains { $0.hasPrefix("notify_target_async ") },
                "Internal Grok Notification after Stop fallback must not double-notify thread \(thread.index), saw \(notificationCommands)"
            )
        }
    }

    func testGrokStopNotificationFallsBackWhenTranscriptCwdIsUnavailable() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("grok-stop-without-cwd")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-stop-without-cwd-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "grok-session-without-cwd"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let environment: [String: String] = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_WORKSPACE_ID": workspaceId,
            "CMUX_SURFACE_ID": surfaceId,
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
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
            input: #"{"sessionId":"\#(sessionId)","hookEventName":"SessionStart"}"#
        )
        XCTAssertFalse(start.timedOut, start.stderr)
        XCTAssertEqual(start.status, 0, start.stderr)
        XCTAssertEqual(start.stdout, "{}\n")

        let stopCommandStart = state.commands.count
        let stop = runGrokHook(
            "stop",
            input: #"{"sessionId":"\#(sessionId)","hookEventName":"Stop"}"#
        )
        XCTAssertFalse(stop.timedOut, stop.stderr)
        XCTAssertEqual(stop.status, 0, stop.stderr)
        XCTAssertEqual(stop.stdout, "{}\n")

        let stopCommands = Array(state.commands.dropFirst(stopCommandStart))
        XCTAssertTrue(
            stopCommands.contains {
                $0.contains("notify_target_async \(workspaceId) \(surfaceId) Grok|Completed|Grok session completed")
            },
            "Expected Grok Stop without cwd to notify with a generic completion body, saw \(stopCommands)"
        )
        XCTAssertTrue(
            stopCommands.contains { $0.contains("set_status grok Idle") },
            "Expected Grok Stop without cwd to leave Grok idle, saw \(stopCommands)"
        )

        let duplicateCompletionCommandStart = state.commands.count
        let duplicateCompletion = runGrokHook(
            "notification",
            input: #"{"sessionId":"\#(sessionId)","hookEventName":"Notification","message":"Turn complete in 1.0s."}"#
        )
        XCTAssertFalse(duplicateCompletion.timedOut, duplicateCompletion.stderr)
        XCTAssertEqual(duplicateCompletion.status, 0, duplicateCompletion.stderr)
        XCTAssertEqual(duplicateCompletion.stdout, "{}\n")

        let duplicateCompletionCommands = Array(state.commands.dropFirst(duplicateCompletionCommandStart))
        XCTAssertFalse(
            duplicateCompletionCommands.contains { $0.hasPrefix("notify_target_async ") },
            "Generic Grok completion after Stop fallback must not double-notify, saw \(duplicateCompletionCommands)"
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

        func runGrokHook(_ subcommand: String, input: String, stallFeedTelemetry: Bool = false) -> ProcessRunResult {
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
                stallFeedTelemetry: index == 2
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

    func testGrokSessionEndDoesNotDropRoutingForLaterChatMessages() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("grok-turns")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-turns-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "grok-session-multiple-turns"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let baseEnvironment: [String: String] = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": root.path,
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
        ]
        let initialEnvironment = baseEnvironment.merging([
            "CMUX_WORKSPACE_ID": workspaceId,
            "CMUX_SURFACE_ID": surfaceId,
        ], uniquingKeysWith: { _, new in new })

        func runGrokHook(
            _ subcommand: String,
            input: String,
            environment: [String: String] = baseEnvironment
        ) -> ProcessRunResult {
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
            input: #"{"sessionId":"\#(sessionId)","cwd":"\#(root.path)","hookEventName":"SessionStart"}"#,
            environment: initialEnvironment
        )
        XCTAssertFalse(start.timedOut, start.stderr)
        XCTAssertEqual(start.status, 0, start.stderr)
        XCTAssertEqual(start.stdout, "{}\n")

        for index in 1...2 {
            let promptCommandStart = state.commands.count
            let prompt = runGrokHook(
                "prompt-submit",
                input: #"{"sessionId":"\#(sessionId)","cwd":"\#(root.path)","hookEventName":"UserPromptSubmit","prompt":"message \#(index)"}"#
            )
            XCTAssertFalse(prompt.timedOut, prompt.stderr)
            XCTAssertEqual(prompt.status, 0, prompt.stderr)
            XCTAssertEqual(prompt.stdout, "{}\n")

            let promptCommands = Array(state.commands.dropFirst(promptCommandStart))
            XCTAssertTrue(
                promptCommands.contains { $0.contains("set_status grok Running") },
                "Expected Grok prompt \(index) to reuse the saved target without CMUX env, saw \(promptCommands)"
            )
            XCTAssertTrue(
                promptCommands.contains { $0 == "clear_notifications --tab=\(workspaceId) --panel=\(surfaceId)" },
                "Expected Grok prompt \(index) to clear only its own surface notifications, saw \(promptCommands)"
            )
            XCTAssertFalse(
                promptCommands.contains { $0 == "clear_notifications --tab=\(workspaceId)" },
                "Grok prompt \(index) must not clear sibling surface notifications, saw \(promptCommands)"
            )

            let internalCommandStart = state.commands.count
            let internalNotification = runGrokHook(
                "notification",
                input: #"{"sessionId":"\#(sessionId)","cwd":"\#(root.path)","hookEventName":"Notification","message":"SessionNotification { update: HookExecution { event_name: user_prompt_submit } }"}"#
            )
            XCTAssertFalse(internalNotification.timedOut, internalNotification.stderr)
            XCTAssertEqual(internalNotification.status, 0, internalNotification.stderr)
            XCTAssertEqual(internalNotification.stdout, "{}\n")

            let internalCommands = Array(state.commands.dropFirst(internalCommandStart))
            XCTAssertFalse(
                internalCommands.contains { $0.hasPrefix("notify_target_async ") },
                "Grok internal prompt bookkeeping for chat message \(index) must not notify, saw \(internalCommands)"
            )

            let bareInternalCommandStart = state.commands.count
            let bareInternalNotification = runGrokHook(
                "notification",
                input: #"{"sessionId":"\#(sessionId)","cwd":"\#(root.path)","hookEventName":"Notification","message":"HookExecution { event_name: user_prompt_submit }"}"#
            )
            XCTAssertFalse(bareInternalNotification.timedOut, bareInternalNotification.stderr)
            XCTAssertEqual(bareInternalNotification.status, 0, bareInternalNotification.stderr)
            XCTAssertEqual(bareInternalNotification.stdout, "{}\n")

            let bareInternalCommands = Array(state.commands.dropFirst(bareInternalCommandStart))
            XCTAssertFalse(
                bareInternalCommands.contains { $0.hasPrefix("notify_target_async ") },
                "Grok bare hook execution bookkeeping for chat message \(index) must not notify, saw \(bareInternalCommands)"
            )

            let notificationCommandStart = state.commands.count
            let notification = runGrokHook(
                "notification",
                input: #"{"sessionId":"\#(sessionId)","cwd":"\#(root.path)","hookEventName":"Notification","message":"Turn complete in \#(index).0s."}"#
            )
            XCTAssertFalse(notification.timedOut, notification.stderr)
            XCTAssertEqual(notification.status, 0, notification.stderr)
            XCTAssertEqual(notification.stdout, "{}\n")

            let notificationCommands = Array(state.commands.dropFirst(notificationCommandStart))
            XCTAssertTrue(
                notificationCommands.contains {
                    $0.contains("notify_target_async \(workspaceId) \(surfaceId) Grok|Completed|Task completed")
                },
                "Expected Grok completion notification for chat message \(index), saw \(notificationCommands)"
            )
            XCTAssertTrue(
                notificationCommands.contains { $0.contains("set_status grok Idle") },
                "Expected Grok completion for chat message \(index) to leave Grok idle, saw \(notificationCommands)"
            )

            let sessionEndCommandStart = state.commands.count
            let sessionEnd = runGrokHook(
                "session-end",
                input: #"{"sessionId":"\#(sessionId)","cwd":"\#(root.path)","hookEventName":"SessionEnd"}"#
            )
            XCTAssertFalse(sessionEnd.timedOut, sessionEnd.stderr)
            XCTAssertEqual(sessionEnd.status, 0, sessionEnd.stderr)
            XCTAssertEqual(sessionEnd.stdout, "{}\n")

            let sessionEndCommands = Array(state.commands.dropFirst(sessionEndCommandStart))
            let sessionEndMethods = sessionEndCommands.compactMap { self.jsonObject($0)?["method"] as? String }
            XCTAssertEqual(
                sessionEndMethods,
                ["feed.push"],
                "Grok SessionEnd should only emit feed telemetry from the saved route, saw \(sessionEndCommands)"
            )
            XCTAssertFalse(
                sessionEndCommands.contains { $0.hasPrefix("clear_agent_pid grok.") },
                "Grok SessionEnd is a chat-turn boundary and must not clear the saved route, saw \(sessionEndCommands)"
            )
        }

        let storeURL = root.appendingPathComponent("grok-hook-sessions.json", isDirectory: false)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
        let sessions = try XCTUnwrap(json["sessions"] as? [String: Any])
        XCTAssertNotNil(
            sessions[sessionId],
            "Expected Grok route to remain available after multiple chat-message SessionEnd events"
        )
    }

    func testGrokCompletionDoesNotResetStatusWhileSiblingSessionRuns() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("grok-sibling-status")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-sibling-status-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let runningSurfaceId = "22222222-2222-2222-2222-222222222222"
        let completingSurfaceId = "33333333-3333-3333-3333-333333333333"
        let runningSessionId = "grok-session-running"
        let completingSessionId = "grok-session-completing"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let baseEnvironment: [String: String] = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": root.path,
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
        ]
        func environment(surfaceId: String) -> [String: String] {
            baseEnvironment.merging([
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId,
            ], uniquingKeysWith: { _, new in new })
        }

        func runGrokHook(
            _ subcommand: String,
            input: String,
            environment: [String: String] = baseEnvironment
        ) -> ProcessRunResult {
            let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
                guard let payload = self.jsonObject(line) else {
                    return "OK"
                }
                guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                    return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
                }
                switch method {
                case "surface.list":
                    return self.v2Response(
                        id: id,
                        ok: true,
                        result: [
                            "surfaces": [
                                ["id": runningSurfaceId, "ref": "surface:1", "focused": true],
                                ["id": completingSurfaceId, "ref": "surface:2", "focused": false],
                            ],
                        ]
                    )
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

        let runningStart = runGrokHook(
            "session-start",
            input: #"{"sessionId":"\#(runningSessionId)","cwd":"\#(root.path)","hookEventName":"SessionStart"}"#,
            environment: environment(surfaceId: runningSurfaceId)
        )
        XCTAssertFalse(runningStart.timedOut, runningStart.stderr)
        XCTAssertEqual(runningStart.status, 0, runningStart.stderr)

        let completingStart = runGrokHook(
            "session-start",
            input: #"{"sessionId":"\#(completingSessionId)","cwd":"\#(root.path)","hookEventName":"SessionStart"}"#,
            environment: environment(surfaceId: completingSurfaceId)
        )
        XCTAssertFalse(completingStart.timedOut, completingStart.stderr)
        XCTAssertEqual(completingStart.status, 0, completingStart.stderr)

        let runningStop = runGrokHook(
            "stop",
            input: #"{"sessionId":"\#(runningSessionId)","cwd":"\#(root.path)","hookEventName":"Stop"}"#
        )
        XCTAssertFalse(runningStop.timedOut, runningStop.stderr)
        XCTAssertEqual(runningStop.status, 0, runningStop.stderr)

        let promptCommandStart = state.commands.count
        let runningPrompt = runGrokHook(
            "prompt-submit",
            input: #"{"sessionId":"\#(runningSessionId)","cwd":"\#(root.path)","hookEventName":"UserPromptSubmit","prompt":"keep running"}"#
        )
        XCTAssertFalse(runningPrompt.timedOut, runningPrompt.stderr)
        XCTAssertEqual(runningPrompt.status, 0, runningPrompt.stderr)

        let promptCommands = Array(state.commands.dropFirst(promptCommandStart))
        XCTAssertTrue(
            promptCommands.contains { $0 == "clear_notifications --tab=\(workspaceId) --panel=\(runningSurfaceId)" },
            "Expected running Grok prompt to clear only its own surface notifications, saw \(promptCommands)"
        )
        XCTAssertTrue(
            promptCommands.contains { $0.contains("set_status grok Running") },
            "Expected running Grok prompt to mark Grok running, saw \(promptCommands)"
        )

        let completionCommandStart = state.commands.count
        let completingNotification = runGrokHook(
            "notification",
            input: #"{"sessionId":"\#(completingSessionId)","cwd":"\#(root.path)","hookEventName":"Notification","message":"Turn complete in 1.0s."}"#
        )
        XCTAssertFalse(completingNotification.timedOut, completingNotification.stderr)
        XCTAssertEqual(completingNotification.status, 0, completingNotification.stderr)
        XCTAssertEqual(completingNotification.stdout, "{}\n")

        let completionCommands = Array(state.commands.dropFirst(completionCommandStart))
        XCTAssertTrue(
            completionCommands.contains {
                $0.contains("notify_target_async \(workspaceId) \(completingSurfaceId) Grok|Completed|Task completed")
            },
            "Expected completing Grok session to notify its own surface, saw \(completionCommands)"
        )
        XCTAssertFalse(
            completionCommands.contains { $0.contains("set_status grok Idle") },
            "Completing Grok session must not reset the shared Grok status while a sibling session is running, saw \(completionCommands)"
        )
    }

    func testGrokCompletionResetsStatusWhenSiblingRunningRecordHasDeadPID() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("grok-stale-sibling-status")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-stale-sibling-status-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let staleSurfaceId = "22222222-2222-2222-2222-222222222222"
        let completingSurfaceId = "33333333-3333-3333-3333-333333333333"
        let staleSessionId = "grok-stale-running"
        let completingSessionId = "grok-session-completing"
        let deadPID = 999_999

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let now = Date().timeIntervalSince1970
        let storeURL = root.appendingPathComponent("grok-hook-sessions.json", isDirectory: false)
        let storePayload: [String: Any] = [
            "version": 1,
            "sessions": [
                staleSessionId: [
                    "sessionId": staleSessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": staleSurfaceId,
                    "cwd": root.path,
                    "pid": deadPID,
                    "runtimeStatus": "running",
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        let storeData = try JSONSerialization.data(withJSONObject: storePayload, options: [.prettyPrinted, .sortedKeys])
        try storeData.write(to: storeURL)

        let environment: [String: String] = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": root.path,
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_WORKSPACE_ID": workspaceId,
            "CMUX_SURFACE_ID": completingSurfaceId,
        ]

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else {
                return "OK"
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "surfaces": [
                            ["id": staleSurfaceId, "ref": "surface:1", "focused": false],
                            ["id": completingSurfaceId, "ref": "surface:2", "focused": true],
                        ],
                    ]
                )
            case "feed.push":
                return self.v2Response(id: id, ok: true, result: [:])
            default:
                return self.v2Response(id: id, ok: true, result: [:])
            }
        }
        let completion = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "grok", "notification"],
            environment: environment,
            standardInput: #"{"sessionId":"\#(completingSessionId)","cwd":"\#(root.path)","hookEventName":"Notification","message":"Turn complete in 1.0s."}"#,
            timeout: 5
        )
        wait(for: [serverHandled], timeout: 5)

        XCTAssertFalse(completion.timedOut, completion.stderr)
        XCTAssertEqual(completion.status, 0, completion.stderr)
        XCTAssertEqual(completion.stdout, "{}\n")

        XCTAssertTrue(
            state.commands.contains { $0.contains("set_status grok Idle") },
            "Dead PID running records must not keep the shared Grok status running, saw \(state.commands)"
        )

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
        let sessions = try XCTUnwrap(json["sessions"] as? [String: Any])
        let staleSession = try XCTUnwrap(sessions[staleSessionId] as? [String: Any])
        XCTAssertNil(
            staleSession["runtimeStatus"],
            "Dead PID running records should be cleared when they are ignored"
        )
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
        XCTAssertEqual(notificationTimeouts, [5])
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

    func testGrokHookInstallPinsInstallingCLIAndSocketWithoutCMUXInterpolation() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-hook-pin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pinnedCLI = root.appendingPathComponent("cmux pinned dev cli", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: pinnedCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pinnedCLI.path)

        let socketPath = "/tmp/cmux-debug-grok-pin.sock"
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "grok", "install", "--yes"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_BUNDLED_CLI_PATH": pinnedCLI.path,
                "CMUX_SOCKET_PATH": socketPath,
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
        let allCommands = hooks.values
            .compactMap { $0 as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["command"] as? String }

        XCTAssertFalse(allCommands.isEmpty)
        XCTAssertTrue(
            allCommands.allSatisfy { $0.contains("cmux-grok-hook-v2") },
            "Expected installed Grok hooks to carry the owned-hook marker, saw \(allCommands)"
        )
        XCTAssertTrue(
            allCommands.allSatisfy { $0.contains("'\(pinnedCLI.path)'") },
            "Expected installed Grok hooks to pin the installing CLI path, saw \(allCommands)"
        )
        XCTAssertTrue(
            allCommands.allSatisfy { $0.contains("--socket '\(socketPath)'") },
            "Expected installed Grok hooks to pin the installing socket path, saw \(allCommands)"
        )
        XCTAssertFalse(
            allCommands.contains { $0.contains("$CMUX_") },
            "Grok hook commands must not depend on CMUX environment interpolation, saw \(allCommands)"
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
        let commandBodies = allCommands + allCommands.compactMap { FileManager.default.fileExists(atPath: $0) ? try? String(contentsOf: URL(fileURLWithPath: $0), encoding: .utf8) : nil }
        XCTAssertTrue(
            commandBodies.contains {
                $0.contains("CMUX_BUNDLED_CLI_PATH")
                    && $0.contains("\"$cmux_cli\" --socket \"$CMUX_SOCKET_PATH\" hooks codex prompt-submit")
            },
            "Codex hooks should route through the launching app's bundled CLI, saw \(commandBodies)"
        )
        XCTAssertFalse(
            commandBodies.contains { $0.contains("command -v cmux >/dev/null 2>&1 && cmux hooks codex") },
            "Codex hooks must not use the reload-global cmux shim directly, saw \(commandBodies)"
        )
        XCTAssertFalse(
            commandBodies.contains { $0 == previousBundledHookCommand },
            "Codex setup should replace bundled-CLI hooks that did not pin CMUX_SOCKET_PATH, saw \(commandBodies)"
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
            case "surface.resume.set":
                return self.v2Response(id: id, ok: true, result: ["ok": true])
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

        if scenario.agent == "kiro" {
            let resumeSetRequests = state.commands.compactMap { command -> [String: Any]? in
                guard let payload = self.jsonObject(command),
                      payload["method"] as? String == "surface.resume.set" else {
                    return nil
                }
                return payload["params"] as? [String: Any]
            }
            XCTAssertEqual(resumeSetRequests.count, 1, state.commands.joined(separator: "\n"))
            let params = try XCTUnwrap(resumeSetRequests.first)
            XCTAssertEqual(params["kind"] as? String, "kiro")
            XCTAssertEqual(params["checkpoint_id"] as? String, scenario.sessionId)
            XCTAssertEqual(params["auto_resume"] as? Bool, true)
            XCTAssertEqual(
                params["command"] as? String,
                "cd -- '\(workspace.path)' 2>/dev/null || [ ! -d '\(workspace.path)' ] && '\(scenario.executable)' 'chat' '--resume-id' '\(scenario.sessionId)' '--agent' 'cmux' '--trust-tools' 'fs_read,fs_write'"
            )
            XCTAssertEqual(params["environment"] as? [String: String], scenario.expectedEnvironment)
            XCTAssertFalse(
                state.commands.contains { command in
                    self.jsonObject(command)?["method"] as? String == "surface.resume.clear"
                },
                "Kiro should publish a resume binding instead of clearing it: \(state.commands)"
            )
        }
    }

    /// G2 (https://github.com/manaflow-ai/cmux/issues/5350): plain `codex` under the subrouter account
    /// manager points CODEX_HOME at ~/.codex-accounts/<account>, not ~/.codex. When the launch argv
    /// can't be captured (no CMUX_AGENT_LAUNCH_ARGV_B64 and an exited PID), the session record used to
    /// drop CODEX_HOME, so the resume/fork binding fell back to a bare `codex resume <id>` against the
    /// default home and failed with "No saved session found". The hook must still carry the captured
    /// CODEX_HOME into the resume binding's environment.
    func testCodexHookPreservesCodexHomeWhenLaunchCommandUnavailable() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex-home")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-home-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-home-session"
        let ttyName = "ttys301"
        let codexHome = root.appendingPathComponent("codex-accounts/work", isDirectory: true).path

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        // A reaped, definitely-exited PID forces the no-argv capture path: processArguments() returns
        // nil for a dead process, so the hook can only carry CODEX_HOME via the env-only record.
        let deadHelper = Process()
        deadHelper.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try deadHelper.run()
        deadHelper.waitUntilExit()
        let deadPID = Int(deadHelper.processIdentifier)

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
                    "pid": deadPID,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted])
            .write(to: root.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else { return "OK" }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                return self.surfaceListResponse(id: id, surfaceId: surfaceId)
            case "debug.terminals":
                return self.v2Response(
                    id: id, ok: true,
                    result: ["terminals": [["tty": ttyName, "workspace_id": workspaceId, "surface_id": surfaceId]]]
                )
            case "surface.resume.set":
                return self.v2Response(id: id, ok: true, result: ["ok": true])
            case "feed.push":
                return self.v2Response(id: id, ok: true, result: [:])
            default:
                return self.v2Response(
                    id: id, ok: false,
                    error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = root.path
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_CLI_TTY_NAME"] = ttyName
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CODEX_HOME"] = codexHome
        for key in ["CMUX_AGENT_LAUNCH_KIND", "CMUX_AGENT_LAUNCH_EXECUTABLE", "CMUX_AGENT_LAUNCH_ARGV_B64", "CMUX_AGENT_LAUNCH_CWD"] {
            environment.removeValue(forKey: key)
        }

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

        let resumeRequests = state.snapshot().compactMap { command -> [String: Any]? in
            guard let payload = self.jsonObject(command),
                  payload["method"] as? String == "surface.resume.set" else { return nil }
            return payload["params"] as? [String: Any]
        }
        let params = try XCTUnwrap(resumeRequests.last, "expected a surface.resume.set; saw \(state.snapshot())")
        let boundEnvironment = params["environment"] as? [String: String]
        XCTAssertEqual(
            boundEnvironment?["CODEX_HOME"], codexHome,
            "resume binding must carry the captured CODEX_HOME; params=\(params)"
        )
        let command = try XCTUnwrap(params["command"] as? String)
        XCTAssertTrue(command.contains("'resume' '\(sessionId)'"), command)

        // The env-only record must also be PERSISTED to the hook session store (its arguments are
        // empty, so the store's "only assign launchCommand when arguments is non-empty" gate would
        // otherwise drop it) — a later fork/resume that reads the store rather than re-deriving from a
        // live hook env still needs CODEX_HOME.
        let storeURL = root.appendingPathComponent("codex-hook-sessions.json")
        let storeJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
        let sessions = try XCTUnwrap(storeJSON["sessions"] as? [String: Any])
        let persisted = try XCTUnwrap(sessions[sessionId] as? [String: Any])
        let persistedLaunch = try XCTUnwrap(
            persisted["launchCommand"] as? [String: Any],
            "env-only launchCommand must be persisted for the fork path"
        )
        XCTAssertEqual(
            (persistedLaunch["environment"] as? [String: String])?["CODEX_HOME"], codexHome,
            "persisted launchCommand must carry CODEX_HOME"
        )
    }

    /// G3 (https://github.com/manaflow-ai/cmux/issues/5333): the codex surface jumble. CMUX_SURFACE_ID
    /// can be leaked into the hook env as the operator's FOCUSED pane rather than the agent's own pane.
    /// When the agent process's controlling TTY is bound to a different, accessible surface in the same
    /// workspace, that TTY is ground truth and must override the leaked env surface — otherwise the
    /// session routes to the wrong pane and the no-pid-gate resume binding persists it across reload.
    func testCodexHookOverridesLeakedEnvSurfaceWithProcessTTYBinding() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex-surface")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-surface-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let leakedSurfaceId = "22222222-2222-2222-2222-222222222222"   // env CMUX_SURFACE_ID (wrong)
        let ttySurfaceId = "33333333-3333-3333-3333-333333333333"      // the agent's real pane
        let sessionId = "codex-surface-session"
        let ttyName = "ttys302"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else { return "OK" }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                // Both surfaces are accessible in this workspace, so the env surface is "valid" — the
                // only thing distinguishing the right pane is the TTY binding.
                return self.v2Response(
                    id: id, ok: true,
                    result: ["surfaces": [
                        ["id": leakedSurfaceId, "ref": "surface:1", "focused": true],
                        ["id": ttySurfaceId, "ref": "surface:2", "focused": false],
                    ]]
                )
            case "debug.terminals":
                return self.v2Response(
                    id: id, ok: true,
                    result: ["terminals": [["tty": ttyName, "workspace_id": workspaceId, "surface_id": ttySurfaceId]]]
                )
            case "surface.resume.set":
                return self.v2Response(id: id, ok: true, result: ["ok": true])
            case "feed.push":
                return self.v2Response(id: id, ok: true, result: [:])
            default:
                return self.v2Response(
                    id: id, ok: false,
                    error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = root.path
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = leakedSurfaceId
        environment["CMUX_CLI_TTY_NAME"] = ttyName
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_LAUNCH_KIND"] = "codex"
        environment["CMUX_AGENT_LAUNCH_EXECUTABLE"] = "/usr/local/bin/codex"
        environment["CMUX_AGENT_LAUNCH_CWD"] = root.path
        environment["CMUX_AGENT_LAUNCH_ARGV_B64"] = base64NULSeparated(["/usr/local/bin/codex"])

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

        let resumeRequests = state.snapshot().compactMap { command -> [String: Any]? in
            guard let payload = self.jsonObject(command),
                  payload["method"] as? String == "surface.resume.set" else { return nil }
            return payload["params"] as? [String: Any]
        }
        let params = try XCTUnwrap(resumeRequests.last, "expected a surface.resume.set; saw \(state.snapshot())")
        XCTAssertEqual(
            params["surface_id"] as? String, ttySurfaceId,
            "PID/TTY ground truth must override the leaked env CMUX_SURFACE_ID; params=\(params)"
        )
    }

    /// G3 stale-env variant (https://github.com/manaflow-ai/cmux/issues/5333): when the ambient
    /// CMUX_SURFACE_ID is stale/invalid (the surface was closed, or belongs to another workspace) it no
    /// longer resolves to an accessible surface. That must NOT abort hook routing — the agent's own
    /// TTY-bound pane is valid, so the hook recovers and still publishes the resume binding there
    /// instead of no-op'ing (which would silently lose the session across reload).
    func testCodexHookRecoversFromStaleEnvSurfaceViaProcessTTYBinding() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex-stale")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-stale-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let staleSurfaceId = "22222222-2222-2222-2222-222222222222"   // env CMUX_SURFACE_ID, no longer exists
        let ttySurfaceId = "33333333-3333-3333-3333-333333333333"      // the agent's real, live pane
        let sessionId = "codex-stale-session"
        let ttyName = "ttys303"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else { return "OK" }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                // The stale env surface is NOT listed — only the live TTY pane is accessible.
                return self.surfaceListResponse(id: id, surfaceId: ttySurfaceId)
            case "debug.terminals":
                return self.v2Response(
                    id: id, ok: true,
                    result: ["terminals": [["tty": ttyName, "workspace_id": workspaceId, "surface_id": ttySurfaceId]]]
                )
            case "surface.resume.set":
                return self.v2Response(id: id, ok: true, result: ["ok": true])
            case "feed.push":
                return self.v2Response(id: id, ok: true, result: [:])
            default:
                return self.v2Response(
                    id: id, ok: false,
                    error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = root.path
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = staleSurfaceId
        environment["CMUX_CLI_TTY_NAME"] = ttyName
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_LAUNCH_KIND"] = "codex"
        environment["CMUX_AGENT_LAUNCH_EXECUTABLE"] = "/usr/local/bin/codex"
        environment["CMUX_AGENT_LAUNCH_CWD"] = root.path
        environment["CMUX_AGENT_LAUNCH_ARGV_B64"] = base64NULSeparated(["/usr/local/bin/codex"])

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

        let resumeRequests = state.snapshot().compactMap { command -> [String: Any]? in
            guard let payload = self.jsonObject(command),
                  payload["method"] as? String == "surface.resume.set" else { return nil }
            return payload["params"] as? [String: Any]
        }
        let params = try XCTUnwrap(
            resumeRequests.last,
            "stale ambient surface must not drop the hook; expected a surface.resume.set, saw \(state.snapshot())"
        )
        XCTAssertEqual(
            params["surface_id"] as? String, ttySurfaceId,
            "a stale ambient CMUX_SURFACE_ID must fall through to the TTY pane; params=\(params)"
        )
    }

    /// `codex exec` (and `review`, `login`, …) are non-restorable: AgentLaunchSanitizer rejects their
    /// argv so they never get a resume/fork binding. The CODEX_HOME env-only fallback must NOT bypass
    /// that — a captured-but-rejected argv keeps returning nil even when CODEX_HOME is present, so no
    /// env-only record is persisted for the one-shot command.
    func testCodexHookDoesNotPersistEnvOnlyRecordForNonRestorableExec() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex-exec")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-exec-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-exec-session"
        let ttyName = "ttys304"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else { return "OK" }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                return self.surfaceListResponse(id: id, surfaceId: surfaceId)
            case "debug.terminals":
                return self.v2Response(
                    id: id, ok: true,
                    result: ["terminals": [["tty": ttyName, "workspace_id": workspaceId, "surface_id": surfaceId]]]
                )
            case "surface.resume.set", "surface.resume.clear":
                return self.v2Response(id: id, ok: true, result: ["ok": true])
            case "feed.push":
                return self.v2Response(id: id, ok: true, result: [:])
            default:
                return self.v2Response(
                    id: id, ok: false,
                    error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = root.path
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_CLI_TTY_NAME"] = ttyName
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CODEX_HOME"] = root.appendingPathComponent("codex-accounts/work", isDirectory: true).path
        environment["CMUX_AGENT_LAUNCH_KIND"] = "codex"
        environment["CMUX_AGENT_LAUNCH_EXECUTABLE"] = "/usr/local/bin/codex"
        environment["CMUX_AGENT_LAUNCH_CWD"] = root.path
        // A captured but NON-RESTORABLE codex invocation: the sanitizer rejects `exec`.
        environment["CMUX_AGENT_LAUNCH_ARGV_B64"] = base64NULSeparated(["/usr/local/bin/codex", "exec", "do a one-shot task"])

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

        // No env-only CODEX_HOME record may be persisted for the rejected non-restorable argv.
        let storeURL = root.appendingPathComponent("codex-hook-sessions.json")
        if let data = try? Data(contentsOf: storeURL),
           let storeJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sessions = storeJSON["sessions"] as? [String: Any],
           let persisted = sessions[sessionId] as? [String: Any] {
            let env = (persisted["launchCommand"] as? [String: Any])?["environment"] as? [String: String]
            XCTAssertNil(
                env?["CODEX_HOME"],
                "non-restorable codex exec must not persist an env-only CODEX_HOME record; launchCommand=\(persisted["launchCommand"] ?? "nil")"
            )
        }
    }

    /// Issue #4256 / follow-up of PR #5154: the Claude auto-resume *binding* (source: agent-hook)
    /// must `cd` into the directory the session was *created* in, not a runtime cwd the agent drifted
    /// into mid-session. Claude files transcripts under `<config>/projects/<encoded launch cwd>/`, so a
    /// binding pinned to a drifted subdir resumes from the wrong project dir and fails with
    /// "No conversation found". PR #5154 fixed the snapshot path but explicitly left the binding path
    /// as a follow-up; this covers that path.
    ///
    /// Reproduces the REAL failure: the SessionStart hook fires after the agent already drifted and
    /// `CMUX_AGENT_LAUNCH_CWD` is the drift, so BOTH the captured launch cwd and the runtime cwd are
    /// the drift — the true launch cwd is not available from env at all. The fix recovers it from the
    /// transcript's recorded `cwd` (verified by re-encoding against the transcript's project dir).
    func testClaudeResumeBindingPinsLaunchCwdRecoveredFromTranscript() throws {
        let context = try makeClaudeHookContext(name: "claude-resume-binding-cwd")
        defer { context.cleanup() }

        let sessionId = "drifted-resume-session"
        // The TRUE launch cwd Claude namespaced the transcript under.
        let launchCwd = context.root.appendingPathComponent("repo.main", isDirectory: true).path
        // The drifted cwd the agent moved into; the hook only ever sees this one.
        let driftedCwd = context.root.appendingPathComponent("worktree", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: launchCwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: driftedCwd, withIntermediateDirectories: true)

        // Lay the transcript where Claude actually stores it: under the launch cwd's project dir,
        // with the launch cwd recorded inside (as real Claude transcripts do). Encode independently
        // of the production helper so an encoder regression can't mask the bug.
        let encodedLaunchDir = launchCwd
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let projectDir = context.root
            .appendingPathComponent(".claude/projects/\(encodedLaunchDir)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let transcriptPath = projectDir.appendingPathComponent("\(sessionId).jsonl").path
        try (#"{"type":"user","sessionId":"\#(sessionId)","cwd":"\#(launchCwd)","message":{"role":"user","content":"hi"}}"# + "\n")
            .write(toFile: transcriptPath, atomically: true, encoding: .utf8)

        // The drift trap: the launch capture itself reports the drifted cwd (CMUX_AGENT_LAUNCH_CWD =
        // drift), matching the real case where SessionStart fired after the agent had moved.
        let driftedLaunchEnv: [String: String] = [
            "CMUX_AGENT_LAUNCH_KIND": "claude",
            "CMUX_AGENT_LAUNCH_EXECUTABLE": "/usr/local/bin/claude",
            "CMUX_AGENT_LAUNCH_CWD": driftedCwd,
            "CMUX_AGENT_LAUNCH_ARGV_B64": base64NULSeparated(["/usr/local/bin/claude"]),
        ]

        let start = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "session-start"],
            standardInput: #"{"session_id":"\#(sessionId)","source":"clear","cwd":"\#(driftedCwd)","transcript_path":"\#(transcriptPath)","hook_event_name":"SessionStart"}"#,
            extraEnvironment: driftedLaunchEnv
        )
        XCTAssertFalse(start.timedOut, start.stderr)
        XCTAssertEqual(start.status, 0, start.stderr)
        let prompt = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "prompt-submit"],
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","cwd":"\#(driftedCwd)","transcript_path":"\#(transcriptPath)","hook_event_name":"UserPromptSubmit"}"#,
            extraEnvironment: driftedLaunchEnv
        )
        XCTAssertFalse(prompt.timedOut, prompt.stderr)
        XCTAssertEqual(prompt.status, 0, prompt.stderr)

        let resumeSetParams = context.state.snapshot().compactMap { line -> [String: Any]? in
            guard let payload = self.jsonObject(line),
                  payload["method"] as? String == "surface.resume.set",
                  let params = payload["params"] as? [String: Any],
                  params["kind"] as? String == "claude" else {
                return nil
            }
            return params
        }
        let params = try XCTUnwrap(
            resumeSetParams.last,
            "expected a claude surface.resume.set; saw \(context.state.snapshot())"
        )

        // The binding must target the launch cwd (where the transcript lives), NOT the drifted cwd.
        XCTAssertEqual(
            params["cwd"] as? String, launchCwd,
            "resume binding cwd should pin the launch dir recovered from the transcript, not the drift"
        )
        let command = try XCTUnwrap(params["command"] as? String)
        XCTAssertTrue(
            command.contains(launchCwd) && !command.contains(driftedCwd),
            "resume command should cd into the launch cwd, not the drifted cwd; command=\(command)"
        )
    }
}
