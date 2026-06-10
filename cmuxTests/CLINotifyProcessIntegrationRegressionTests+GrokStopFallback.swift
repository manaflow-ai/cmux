import XCTest
import Darwin


// MARK: - Grok stop fallback completions and notification resilience
extension CLINotifyProcessIntegrationRegressionTests {
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

}
