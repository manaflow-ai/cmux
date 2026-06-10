import XCTest
import Darwin


// MARK: - Grok session-end routing and completion status with sibling sessions
extension CLINotifyProcessIntegrationRegressionTests {
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

}
