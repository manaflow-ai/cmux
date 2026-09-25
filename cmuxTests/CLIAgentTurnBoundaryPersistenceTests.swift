import XCTest
import Darwin
import CmuxFoundation

extension CLINotifyProcessIntegrationRegressionTests {
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

        startDetachedMockServer(listenerFD: listenerFD, state: state) { line in
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

        func storedAntigravitySession() throws -> [String: Any] {
            let storeURL = root.appendingPathComponent("antigravity-hook-sessions.json", isDirectory: false)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
            let sessions = try XCTUnwrap(json["sessions"] as? [String: Any])
            return try XCTUnwrap(sessions[sessionId] as? [String: Any])
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

        var backgroundSession = try storedAntigravitySession()
        XCTAssertEqual(backgroundSession["agentLifecycle"] as? String, "running")
        XCTAssertEqual(backgroundSession["runtimeStatus"] as? String, "running")

        let backgroundSessionEnd = runAntigravityHook(
            "session-end",
            input: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"SessionEnd"}"#
        )
        XCTAssertFalse(backgroundSessionEnd.timedOut, backgroundSessionEnd.stderr)
        XCTAssertEqual(backgroundSessionEnd.status, 0, backgroundSessionEnd.stderr)
        backgroundSession = try storedAntigravitySession()
        XCTAssertEqual(
            backgroundSession["agentLifecycle"] as? String,
            "running",
            "A per-turn Antigravity SessionEnd must preserve a background-running lifecycle"
        )
        XCTAssertEqual(
            backgroundSession["runtimeStatus"] as? String,
            "running",
            "A per-turn Antigravity SessionEnd must preserve a background-running runtime"
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

        let needsInputSessionEnd = runAntigravityHook(
            "session-end",
            input: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"SessionEnd"}"#
        )
        XCTAssertFalse(needsInputSessionEnd.timedOut, needsInputSessionEnd.stderr)
        XCTAssertEqual(needsInputSessionEnd.status, 0, needsInputSessionEnd.stderr)
        let needsInputSession = try storedAntigravitySession()
        XCTAssertEqual(
            needsInputSession["agentLifecycle"] as? String,
            "needsInput",
            "A per-turn Antigravity SessionEnd must preserve a needs-input lifecycle"
        )
        XCTAssertEqual(
            needsInputSession["runtimeStatus"] as? String,
            "needsInput",
            "A per-turn Antigravity SessionEnd must preserve a needs-input runtime"
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

        // This is a new failure boundary, not a second description of the
        // Stop error already delivered for the previous turn.
        let nextPrompt = runAntigravityHook(
            "prompt-submit",
            input: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"UserPromptSubmit","prompt":"try again"}"#
        )
        XCTAssertFalse(nextPrompt.timedOut, nextPrompt.stderr)
        XCTAssertEqual(nextPrompt.status, 0, nextPrompt.stderr)

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

    func testGrokPromptStartsRemainBalancedAcrossOverlappingCallbacks() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("grok-depth")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("cmux-grok-depth-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "grok-depth-session"
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

        startDetachedAgentHookMockServer(listenerFD: listenerFD, state: state, surfaceId: surfaceId)

        func runGrokHook(_ subcommand: String, input: String) -> ProcessRunResult {
            runProcess(
                executablePath: cliPath,
                arguments: ["hooks", "grok", subcommand],
                environment: environment,
                standardInput: input,
                timeout: 5
            )
        }

        let start = runGrokHook(
            "session-start",
            input: #"{"sessionId":"\#(sessionId)","cwd":"\#(root.path)","hookEventName":"SessionStart"}"#
        )
        XCTAssertEqual(start.status, 0, start.stderr)

        for promptIndex in 0..<2 {
            let prompt = runGrokHook(
                "prompt-submit",
                input: #"{"sessionId":"\#(sessionId)","cwd":"\#(root.path)","hookEventName":"UserPromptSubmit","prompt":"overlap \#(promptIndex)"}"#
            )
            XCTAssertEqual(prompt.status, 0, prompt.stderr)
        }

        let storeURL = root.appendingPathComponent("grok-hook-sessions.json", isDirectory: false)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
        var sessions = try XCTUnwrap(json["sessions"] as? [String: Any])
        var session = try XCTUnwrap(sessions[sessionId] as? [String: Any])
        XCTAssertEqual(
            session["activePromptDepth"] as? Int,
            2,
            "Grok prompt starts are independently balanced frames"
        )

        let stop = runGrokHook(
            "stop",
            input: #"{"sessionId":"\#(sessionId)","cwd":"\#(root.path)","hookEventName":"Stop"}"#
        )
        XCTAssertEqual(stop.status, 0, stop.stderr)

        json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
        sessions = try XCTUnwrap(json["sessions"] as? [String: Any])
        session = try XCTUnwrap(sessions[sessionId] as? [String: Any])
        XCTAssertEqual(
            session["activePromptDepth"] as? Int,
            1,
            "One Grok completion must close only its matching prompt frame"
        )
        XCTAssertEqual(session["agentLifecycle"] as? String, "running")
    }
}
