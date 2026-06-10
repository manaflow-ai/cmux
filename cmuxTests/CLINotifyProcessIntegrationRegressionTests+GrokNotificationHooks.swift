import XCTest
import Darwin


// MARK: - Grok notification hook payload routing
extension CLINotifyProcessIntegrationRegressionTests {
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

}
