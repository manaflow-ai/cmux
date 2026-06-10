import XCTest
import Darwin


// MARK: - Antigravity hook install, stop/notification routing, and feed session fallback
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

        func runAntigravityHook(_ subcommand: String, input: String) -> ProcessRunResult {
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
                arguments: ["hooks", "antigravity", subcommand],
                environment: environment,
                standardInput: input,
                timeout: 5
            )
            wait(for: [serverHandled], timeout: 5)
            return result
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

}
