import Foundation
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    func testAntigravityPreInvocationStopBalancesRepeatedInvocationsAndNestedPairs() throws {
        let context = try makeClaudeHookContext(name: "antigravity-prompt-depth")
        defer { context.cleanup() }

        let sessionId = "antigravity-depth-session"
        func run(
            _ subcommand: String,
            payload: String,
            extraEnvironment: [String: String] = [:]
        ) -> ProcessRunResult {
            let handled = startMockServer(listenerFD: context.listenerFD, state: context.state) { line in
                self.agentHookMockResponse(line: line, context: context)
            }
            let result = runAgentHook(
                context: context,
                agent: "antigravity",
                subcommand: subcommand,
                standardInput: payload,
                extraEnvironment: extraEnvironment
            )
            wait(for: [handled], timeout: 5)
            return result
        }

        let start = run(
            "session-start",
            payload: #"{"conversationId":"\#(sessionId)","workspacePaths":["\#(context.root.path)"],"hook_event_name":"SessionStart"}"#
        )
        XCTAssertEqual(start.status, 0, start.stderr)

        // Antigravity fires PreInvocation for every model invocation in one
        // execution loop. Those callbacks are one active turn, not nested
        // turns, so one Stop must close all of them.
        var firstPromptRevision: Int64?
        for invocation in 0..<4 {
            let prompt = run(
                "prompt-submit",
                payload: #"{"conversationId":"\#(sessionId)","invocationNum":\#(invocation),"workspacePaths":["\#(context.root.path)"],"hook_event_name":"PreInvocation"}"#
            )
            XCTAssertEqual(prompt.status, 0, prompt.stderr)
            if invocation == 0 {
                firstPromptRevision = try XCTUnwrap(
                    (readAntigravityHookSession(sessionId, context: context)["promptLifecycleRevision"] as? NSNumber)?.int64Value
                )
            }
        }

        let repeatedPromptRecord = try readAntigravityHookSession(sessionId, context: context)
        assertActivePromptState(repeatedPromptRecord)
        XCTAssertEqual(
            repeatedPromptRecord["activePromptDepth"] as? Int,
            1,
            "Repeated Antigravity PreInvocation callbacks must remain one active prompt"
        )
        XCTAssertEqual(
            (repeatedPromptRecord["promptLifecycleRevision"] as? NSNumber)?.int64Value,
            firstPromptRevision,
            "Repeated Antigravity PreInvocation callbacks must remain one prompt generation"
        )

        let stop = run(
            "stop",
            payload: #"{"conversationId":"\#(sessionId)","fullyIdle":true,"terminationReason":"model_stop","workspacePaths":["\#(context.root.path)"],"hook_event_name":"Stop"}"#
        )
        XCTAssertEqual(stop.status, 0, stop.stderr)
        var record = try readAntigravityHookSession(sessionId, context: context)
        XCTAssertNil(record["activePromptDepth"], "A single Antigravity Stop must close repeated PreInvocation callbacks")
        XCTAssertEqual(record["agentLifecycle"] as? String, "idle")
        XCTAssertEqual(record["runtimeStatus"] as? String, "idle")

        // Repeated prompt/stop pairs must remain balanced after the first
        // authoritative boundary; this also guards the depth-zero invariant
        // against stale terminal turn metadata.
        for index in 0..<3 {
            let prompt = run(
                "prompt-submit",
                payload: #"{"conversationId":"\#(sessionId)","invocationNum":0,"workspacePaths":["\#(context.root.path)"],"hook_event_name":"PreInvocation","turn_id":"nested-\#(index)"}"#
            )
            XCTAssertEqual(prompt.status, 0, prompt.stderr)
            assertActivePromptState(try readAntigravityHookSession(sessionId, context: context))
            let nestedStop = run(
                "stop",
                payload: #"{"conversationId":"\#(sessionId)","fullyIdle":true,"terminationReason":"model_stop","workspacePaths":["\#(context.root.path)"],"hook_event_name":"Stop","turn_id":"nested-\#(index)"}"#
            )
            XCTAssertEqual(nestedStop.status, 0, nestedStop.stderr)
            record = try readAntigravityHookSession(sessionId, context: context)
            XCTAssertNil(record["activePromptDepth"], "Nested Antigravity pair \(index) must return depth to zero")
            XCTAssertEqual(record["agentLifecycle"] as? String, "idle")
        }

        // The nested-agent suppression path skips the later visible-state
        // upsert, so the prompt-stop transaction itself must retain the
        // authoritative running runtime status while background work remains.
        let suppressedSessionId = "\(sessionId)-background"
        let suppressedStart = run(
            "session-start",
            payload: #"{"conversationId":"\#(suppressedSessionId)","workspacePaths":["\#(context.root.path)"],"hook_event_name":"SessionStart"}"#
        )
        XCTAssertFalse(suppressedStart.timedOut, suppressedStart.stderr)
        XCTAssertEqual(suppressedStart.status, 0, suppressedStart.stderr)
        let suppressedPrompt = run(
            "prompt-submit",
            payload: #"{"conversationId":"\#(suppressedSessionId)","workspacePaths":["\#(context.root.path)"],"hook_event_name":"PreInvocation"}"#
        )
        XCTAssertFalse(suppressedPrompt.timedOut, suppressedPrompt.stderr)
        XCTAssertEqual(suppressedPrompt.status, 0, suppressedPrompt.stderr)
        let suppressedStop = run(
            "stop",
            payload: #"{"conversationId":"\#(suppressedSessionId)","fullyIdle":false,"workspacePaths":["\#(context.root.path)"],"hook_event_name":"Stop"}"#,
            extraEnvironment: ["CMUX_AGENT_HOOK_SUPPRESS_VISIBLE_MUTATIONS": "1"]
        )
        XCTAssertFalse(suppressedStop.timedOut, suppressedStop.stderr)
        XCTAssertEqual(suppressedStop.status, 0, suppressedStop.stderr)
        let suppressedRecord = try readAntigravityHookSession(suppressedSessionId, context: context)
        XCTAssertNil(suppressedRecord["activePromptDepth"])
        XCTAssertEqual(suppressedRecord["agentLifecycle"] as? String, "running")
        XCTAssertEqual(suppressedRecord["runtimeStatus"] as? String, "running")

        // SessionEnd is also an authoritative boundary for Antigravity. When
        // Stop already settled the prompt while background work remains, the
        // later boundary must preserve that durable running state instead of
        // replaying a stale idle decision.
        let settledSessionEnd = run(
            "session-end",
            payload: #"{"conversationId":"\#(suppressedSessionId)","workspacePaths":["\#(context.root.path)"],"hook_event_name":"SessionEnd"}"#
        )
        XCTAssertFalse(settledSessionEnd.timedOut, settledSessionEnd.stderr)
        XCTAssertEqual(settledSessionEnd.status, 0, settledSessionEnd.stderr)
        let settledRecord = try readAntigravityHookSession(suppressedSessionId, context: context)
        XCTAssertNil(settledRecord["activePromptDepth"])
        XCTAssertEqual(settledRecord["agentLifecycle"] as? String, "running")
        XCTAssertEqual(settledRecord["runtimeStatus"] as? String, "running")
    }

    func testAntigravityTerminalEventsProjectWhenPromptIsAlreadyIdle() throws {
        let context = try makeClaudeHookContext(name: "antigravity-idle-terminal-events")
        defer { context.cleanup() }

        startAgentHookMockServerAccepting(context: context)

        func run(_ subcommand: String, payload: String) -> ProcessRunResult {
            runAgentHook(
                context: context,
                agent: "antigravity",
                subcommand: subcommand,
                standardInput: payload
            )
        }

        let stopSessionID = "antigravity-idle-stop-session"
        _ = run(
            "session-start",
            payload: #"{"conversationId":"\#(stopSessionID)","workspacePaths":["\#(context.root.path)"],"hook_event_name":"SessionStart"}"#
        )
        let intermediateStop = run(
            "stop",
            payload: #"{"conversationId":"\#(stopSessionID)","fullyIdle":false,"workspacePaths":["\#(context.root.path)"],"hook_event_name":"Stop"}"#
        )
        XCTAssertEqual(intermediateStop.status, 0, intermediateStop.stderr)
        let intermediateRecord = try readAntigravityHookSession(stopSessionID, context: context)
        XCTAssertNil(intermediateRecord["activePromptDepth"])
        XCTAssertEqual(intermediateRecord["agentLifecycle"] as? String, "running")
        XCTAssertEqual(intermediateRecord["runtimeStatus"] as? String, "running")
        let feedCountBeforeStop = context.state.snapshot().filter { $0.contains(#""method":"feed.push"#) }.count
        let stop = run(
            "stop",
            payload: #"{"conversationId":"\#(stopSessionID)","fullyIdle":true,"terminationReason":"model_stop","workspacePaths":["\#(context.root.path)"],"hook_event_name":"Stop"}"#
        )
        XCTAssertEqual(stop.status, 0, stop.stderr)
        let stoppedRecord = try readAntigravityHookSession(stopSessionID, context: context)
        XCTAssertNil(stoppedRecord["activePromptDepth"])
        XCTAssertEqual(stoppedRecord["agentLifecycle"] as? String, "idle")
        XCTAssertEqual(stoppedRecord["runtimeStatus"] as? String, "idle")
        XCTAssertEqual(stoppedRecord["lastNotificationStatus"] as? String, "idle")
        XCTAssertGreaterThan(
            context.state.snapshot().filter { $0.contains(#""method":"feed.push"#) }.count,
            feedCountBeforeStop,
            "A valid Stop for an already-idle Antigravity session must still publish completion"
        )

        let notificationSessionID = "antigravity-idle-notification-session"
        _ = run(
            "session-start",
            payload: #"{"conversationId":"\#(notificationSessionID)","workspacePaths":["\#(context.root.path)"],"hook_event_name":"SessionStart"}"#
        )
        let feedCountBeforeNotification = context.state.snapshot().filter { $0.contains(#""method":"feed.push"#) }.count
        let notification = run(
            "notification",
            payload: #"{"conversationId":"\#(notificationSessionID)","message":"Completed","workspacePaths":["\#(context.root.path)"],"hook_event_name":"Notification"}"#
        )
        XCTAssertEqual(notification.status, 0, notification.stderr)
        let notificationRecord = try readAntigravityHookSession(notificationSessionID, context: context)
        XCTAssertNil(notificationRecord["activePromptDepth"])
        XCTAssertEqual(notificationRecord["agentLifecycle"] as? String, "idle")
        XCTAssertEqual(notificationRecord["runtimeStatus"] as? String, "idle")
        XCTAssertEqual(notificationRecord["lastNotificationStatus"] as? String, "idle")
        XCTAssertGreaterThan(
            context.state.snapshot().filter { $0.contains(#""method":"feed.push"#) }.count,
            feedCountBeforeNotification,
            "A valid completion Notification for an already-idle Antigravity session must still publish"
        )
    }

    func testAntigravitySessionEndAndSessionStartRecoverUnbalancedPromptState() throws {
        let context = try makeClaudeHookContext(name: "antigravity-boundaries")
        defer { context.cleanup() }

        let sessionId = "antigravity-boundary-session"
        func run(_ subcommand: String, payload: String) -> ProcessRunResult {
            let handled = startMockServer(listenerFD: context.listenerFD, state: context.state) { line in
                self.agentHookMockResponse(line: line, context: context)
            }
            let result = runAgentHook(
                context: context,
                agent: "antigravity",
                subcommand: subcommand,
                standardInput: payload
            )
            wait(for: [handled], timeout: 5)
            return result
        }

        _ = run(
            "session-start",
            payload: #"{"conversationId":"\#(sessionId)","workspacePaths":["\#(context.root.path)"],"hook_event_name":"SessionStart"}"#
        )
        for invocation in 0..<2 {
            _ = run(
                "prompt-submit",
                payload: #"{"conversationId":"\#(sessionId)","invocationNum":\#(invocation),"workspacePaths":["\#(context.root.path)"],"hook_event_name":"PreInvocation"}"#
            )
        }

        assertActivePromptState(try readAntigravityHookSession(sessionId, context: context))

        // There is no Stop callback in this recovery path. SessionEnd is the
        // authoritative turn boundary and must settle every abandoned frame.
        let sessionEnd = run(
            "session-end",
            payload: #"{"conversationId":"\#(sessionId)","workspacePaths":["\#(context.root.path)"],"hook_event_name":"SessionEnd"}"#
        )
        XCTAssertEqual(sessionEnd.status, 0, sessionEnd.stderr)
        var record = try readAntigravityHookSession(sessionId, context: context)
        XCTAssertNil(record["activePromptDepth"])
        XCTAssertEqual(record["agentLifecycle"] as? String, "idle")
        XCTAssertEqual(record["runtimeStatus"] as? String, "idle")
        XCTAssertTrue(
            AgentJournalAppendCapture.contains(
                context.state.snapshot(),
                kind: "agent.turn.completed",
                agentKey: "antigravity",
                sessionId: sessionId
            ),
            "An accepted SessionEnd must still journal turn completion"
        )

        // A subsequent session-start with the same conversation id must also
        // discard a depth left behind when the provider omits SessionEnd.
        let interruptedSessionId = "\(sessionId)-next"
        _ = run(
            "session-start",
            payload: #"{"conversationId":"\#(interruptedSessionId)","workspacePaths":["\#(context.root.path)"],"hook_event_name":"SessionStart"}"#
        )
        for invocation in 0..<3 {
            _ = run(
                "prompt-submit",
                payload: #"{"conversationId":"\#(interruptedSessionId)","invocationNum":\#(invocation),"workspacePaths":["\#(context.root.path)"],"hook_event_name":"PreInvocation"}"#
            )
        }
        assertActivePromptState(try readAntigravityHookSession(interruptedSessionId, context: context))
        let restarted = run(
            "session-start",
            payload: #"{"conversationId":"\#(interruptedSessionId)","workspacePaths":["\#(context.root.path)"],"hook_event_name":"SessionStart"}"#
        )
        XCTAssertEqual(restarted.status, 0, restarted.stderr)
        record = try readAntigravityHookSession(interruptedSessionId, context: context)
        XCTAssertNil(record["activePromptDepth"])
    }
}
