import Foundation
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    func testAntigravityDelayedStopAndNotificationCannotCloseNewerPrompt() throws {
        let context = try makeClaudeHookContext(name: "antigravity-terminal-generation")
        defer { context.cleanup() }

        startAgentHookMockServerAccepting(context: context)

        struct TerminalEvent {
            let name: String
            let subcommand: String
            let payload: (String, URL) -> String
            let barrierEnvironmentKey: String
        }
        let events = [
            TerminalEvent(
                name: "stop",
                subcommand: "stop",
                payload: { sessionId, root in
                    #"{"conversationId":"\#(sessionId)","fullyIdle":true,"terminationReason":"model_stop","workspacePaths":["\#(root.path)"],"hook_event_name":"Stop"}"#
                },
                barrierEnvironmentKey: "CMUX_TEST_AGENT_HOOK_STOP_BARRIER"
            ),
            TerminalEvent(
                name: "notification",
                subcommand: "notification",
                payload: { sessionId, root in
                    #"{"conversationId":"\#(sessionId)","message":"Completed","workspacePaths":["\#(root.path)"],"hook_event_name":"Notification"}"#
                },
                barrierEnvironmentKey: "CMUX_TEST_AGENT_HOOK_NOTIFICATION_BARRIER"
            ),
        ]

        for event in events {
            let sessionId = "antigravity-\(event.name)-generation-session"
            func run(
                _ subcommand: String,
                payload: String,
                extraEnvironment: [String: String] = [:]
            ) -> ProcessRunResult {
                runAgentHook(
                    context: context,
                    agent: "antigravity",
                    subcommand: subcommand,
                    standardInput: payload,
                    extraEnvironment: extraEnvironment
                )
            }

            let sessionStart = run(
                "session-start",
                payload: #"{"conversationId":"\#(sessionId)","workspacePaths":["\#(context.root.path)"],"hook_event_name":"SessionStart"}"#
            )
            XCTAssertEqual(sessionStart.status, 0, sessionStart.stderr)
            let prompt = run(
                "prompt-submit",
                payload: #"{"conversationId":"\#(sessionId)","turn_id":"turn-1","workspacePaths":["\#(context.root.path)"],"hook_event_name":"PreInvocation"}"#
            )
            XCTAssertEqual(prompt.status, 0, prompt.stderr)
            let firstPromptRecord = try readAntigravityHookSession(sessionId, context: context)
            assertActivePromptState(firstPromptRecord)
            let firstRevision = try XCTUnwrap(
                (firstPromptRecord["promptLifecycleRevision"] as? NSNumber)?.int64Value
            )

            let barrier = context.root.appendingPathComponent("\(event.name).barrier").path
            FileManager.default.createFile(atPath: barrier, contents: Data())
            let terminalEventFinished = expectation(description: "delayed \(event.name) finishes")
            let delayedSubcommand = event.subcommand
            let delayedPayload = event.payload(sessionId, context.root)
            let delayedBarrierEnvironmentKey = event.barrierEnvironmentKey
            DispatchQueue.global(qos: .userInitiated).async {
                _ = self.runAgentHook(
                    context: context,
                    agent: "antigravity",
                    subcommand: delayedSubcommand,
                    standardInput: delayedPayload,
                    extraEnvironment: [delayedBarrierEnvironmentKey: barrier]
                )
                terminalEventFinished.fulfill()
            }

            let readyPath = barrier + ".ready"
            let readyDeadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: readyPath), Date() < readyDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: readyPath),
                "Delayed \(event.name) must reach the post-lookup barrier"
            )

            let newerPrompt = run(
                "prompt-submit",
                payload: #"{"conversationId":"\#(sessionId)","turn_id":"turn-2","workspacePaths":["\#(context.root.path)"],"hook_event_name":"PreInvocation"}"#
            )
            XCTAssertEqual(newerPrompt.status, 0, newerPrompt.stderr)
            let newerPromptRecord = try readAntigravityHookSession(sessionId, context: context)
            assertActivePromptState(newerPromptRecord)
            let newerRevision = try XCTUnwrap(
                (newerPromptRecord["promptLifecycleRevision"] as? NSNumber)?.int64Value
            )
            XCTAssertGreaterThan(newerRevision, firstRevision)

            let commandCountBeforeRelease = context.state.snapshot().count
            try FileManager.default.removeItem(atPath: barrier)
            wait(for: [terminalEventFinished], timeout: 5)

            let finalRecord = try readAntigravityHookSession(sessionId, context: context)
            assertActivePromptState(finalRecord)
            XCTAssertEqual(finalRecord["activePromptDepth"] as? Int, 1)
            XCTAssertEqual(finalRecord["agentLifecycle"] as? String, "running")
            XCTAssertEqual(finalRecord["runtimeStatus"] as? String, "running")
            XCTAssertEqual(
                (finalRecord["promptLifecycleRevision"] as? NSNumber)?.int64Value,
                newerRevision
            )
            let delayedCommands = Array(context.state.snapshot().dropFirst(commandCountBeforeRelease))
            let expectedHookEventName = event.subcommand == "stop" ? "Stop" : "Notification"
            XCTAssertFalse(
                AgentJournalAppendCapture.contains(
                    delayedCommands,
                    kind: "agent.turn.completed",
                    agentKey: "antigravity",
                    sessionId: sessionId
                ),
                "A fenced \(event.name) must not journal completion for the newer prompt"
            )
            XCTAssertFalse(
                delayedCommands.contains {
                    $0.contains(#""method":"feed.push""#)
                        && $0.contains(#""hook_event_name":"#)
                        && $0.contains(#""hook_event_name":"\#(expectedHookEventName)"#)
                },
                "A fenced \(event.name) must not publish completion to Feed"
            )
            XCTAssertFalse(
                delayedCommands.contains { $0.hasPrefix("notify") },
                "A fenced \(event.name) must not send a completion notification"
            )
            XCTAssertFalse(
                delayedCommands.contains { $0.hasPrefix("set_status antigravity ") },
                "A fenced \(event.name) must not replace the newer running status"
            )
        }
    }
}
