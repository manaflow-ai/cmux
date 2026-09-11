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

    func testAntigravityDelayedSessionEndCannotCloseNewerPrompt() throws {
        let context = try makeClaudeHookContext(name: "antigravity-session-end-generation")
        defer { context.cleanup() }

        startAgentHookMockServerAccepting(context: context)
        let sessionId = "antigravity-session-end-generation-session"
        func run(_ subcommand: String, payload: String) -> ProcessRunResult {
            runAgentHook(
                context: context,
                agent: "antigravity",
                subcommand: subcommand,
                standardInput: payload
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

        let barrier = context.root.appendingPathComponent("session-end.barrier").path
        FileManager.default.createFile(atPath: barrier, contents: Data())
        let sessionEndFinished = expectation(description: "delayed SessionEnd finishes")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.runAgentHook(
                context: context,
                agent: "antigravity",
                subcommand: "session-end",
                standardInput: #"{"conversationId":"\#(sessionId)","workspacePaths":["\#(context.root.path)"],"hook_event_name":"SessionEnd"}"#,
                extraEnvironment: ["CMUX_TEST_AGENT_HOOK_SESSION_END_BARRIER": barrier]
            )
            sessionEndFinished.fulfill()
        }

        let readyPath = barrier + ".ready"
        let readyDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: readyPath), Date() < readyDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: readyPath), "SessionEnd must reach the post-lookup barrier")

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

        try FileManager.default.removeItem(atPath: barrier)
        wait(for: [sessionEndFinished], timeout: 5)

        let finalRecord = try readAntigravityHookSession(sessionId, context: context)
        assertActivePromptState(finalRecord)
        XCTAssertEqual(finalRecord["activePromptDepth"] as? Int, 1)
        XCTAssertEqual(finalRecord["agentLifecycle"] as? String, "running")
        XCTAssertEqual(finalRecord["runtimeStatus"] as? String, "running")
        XCTAssertEqual(
            (finalRecord["promptLifecycleRevision"] as? NSNumber)?.int64Value,
            newerRevision
        )
        let commands = context.state.snapshot()
        XCTAssertFalse(
            AgentJournalAppendCapture.contains(
                commands,
                kind: "agent.turn.completed",
                agentKey: "antigravity",
                sessionId: sessionId
            ),
            "A fenced SessionEnd must not journal completion for the newer prompt"
        )
        XCTAssertFalse(
            commands.contains {
                $0.contains(#""method":"feed.push""#)
                    && $0.contains(#""hook_event_name":"SessionEnd""#)
            },
            "A fenced SessionEnd must not publish completion to Feed"
        )
    }

    func testAntigravityDelayedSessionEndPreservesSettledIntermediateStop() throws {
        let context = try makeClaudeHookContext(name: "antigravity-session-end-settled-stop")
        defer { context.cleanup() }

        startAgentHookMockServerAccepting(context: context)
        let sessionId = "antigravity-session-end-settled-stop-session"
        func run(_ subcommand: String, payload: String) -> ProcessRunResult {
            runAgentHook(
                context: context,
                agent: "antigravity",
                subcommand: subcommand,
                standardInput: payload
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
        let initialRecord = try readAntigravityHookSession(sessionId, context: context)
        let initialRevision = try XCTUnwrap(
            (initialRecord["promptLifecycleRevision"] as? NSNumber)?.int64Value
        )

        let sessionEndBarrier = context.root.appendingPathComponent("session-end-settled-stop.barrier").path
        FileManager.default.createFile(atPath: sessionEndBarrier, contents: Data())
        let sessionEndFinished = expectation(description: "delayed SessionEnd finishes")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.runAgentHook(
                context: context,
                agent: "antigravity",
                subcommand: "session-end",
                standardInput: #"{"conversationId":"\#(sessionId)","workspacePaths":["\#(context.root.path)"],"hook_event_name":"SessionEnd"}"#,
                extraEnvironment: ["CMUX_TEST_AGENT_HOOK_SESSION_END_BARRIER": sessionEndBarrier]
            )
            sessionEndFinished.fulfill()
        }

        let readyPath = sessionEndBarrier + ".ready"
        let readyDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: readyPath), Date() < readyDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: readyPath),
            "SessionEnd must reach the post-lookup barrier"
        )

        let intermediateStop = run(
            "stop",
            payload: #"{"conversationId":"\#(sessionId)","fullyIdle":false,"workspacePaths":["\#(context.root.path)"],"hook_event_name":"Stop"}"#
        )
        XCTAssertEqual(intermediateStop.status, 0, intermediateStop.stderr)
        let settledRecord = try readAntigravityHookSession(sessionId, context: context)
        XCTAssertNil(settledRecord["activePromptDepth"])
        XCTAssertEqual(settledRecord["agentLifecycle"] as? String, "running")
        XCTAssertEqual(settledRecord["runtimeStatus"] as? String, "running")

        try FileManager.default.removeItem(atPath: sessionEndBarrier)
        wait(for: [sessionEndFinished], timeout: 5)

        let finalRecord = try readAntigravityHookSession(sessionId, context: context)
        XCTAssertNil(finalRecord["activePromptDepth"])
        XCTAssertEqual(
            finalRecord["agentLifecycle"] as? String,
            "running",
            "A delayed SessionEnd must not overwrite an accepted intermediate Stop"
        )
        XCTAssertEqual(finalRecord["runtimeStatus"] as? String, "running")
        XCTAssertEqual(
            (finalRecord["promptLifecycleRevision"] as? NSNumber)?.int64Value,
            initialRevision,
            "Settling a same-generation Stop must not create a new prompt generation"
        )
    }

    func testAntigravityDelayedSessionEndCannotCloseNewerIDLessPrompt() throws {
        let context = try makeClaudeHookContext(name: "antigravity-session-end-invocation-generation")
        defer { context.cleanup() }

        startAgentHookMockServerAccepting(context: context)
        let sessionId = "antigravity-session-end-invocation-generation-session"
        func run(_ subcommand: String, payload: String) -> ProcessRunResult {
            runAgentHook(
                context: context,
                agent: "antigravity",
                subcommand: subcommand,
                standardInput: payload
            )
        }

        XCTAssertEqual(
            run(
                "session-start",
                payload: #"{"conversationId":"\#(sessionId)","workspacePaths":["\#(context.root.path)"],"hook_event_name":"SessionStart"}"#
            ).status,
            0
        )
        XCTAssertEqual(
            run(
                "prompt-submit",
                payload: #"{"conversationId":"\#(sessionId)","invocationNum":2,"workspacePaths":["\#(context.root.path)"],"hook_event_name":"PreInvocation"}"#
            ).status,
            0
        )
        let firstPromptRecord = try readAntigravityHookSession(sessionId, context: context)
        assertActivePromptState(firstPromptRecord)
        let firstRevision = try XCTUnwrap(
            (firstPromptRecord["promptLifecycleRevision"] as? NSNumber)?.int64Value
        )

        let barrier = context.root.appendingPathComponent("session-end-invocation-generation.barrier").path
        FileManager.default.createFile(atPath: barrier, contents: Data())
        let sessionEndFinished = expectation(description: "delayed SessionEnd finishes")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.runAgentHook(
                context: context,
                agent: "antigravity",
                subcommand: "session-end",
                standardInput: #"{"conversationId":"\#(sessionId)","workspacePaths":["\#(context.root.path)"],"hook_event_name":"SessionEnd"}"#,
                extraEnvironment: ["CMUX_TEST_AGENT_HOOK_SESSION_END_BARRIER": barrier]
            )
            sessionEndFinished.fulfill()
        }

        let readyPath = barrier + ".ready"
        let readyDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: readyPath), Date() < readyDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: readyPath))

        let newerPrompt = run(
            "prompt-submit",
            payload: #"{"conversationId":"\#(sessionId)","invocationNum":0,"workspacePaths":["\#(context.root.path)"],"hook_event_name":"PreInvocation"}"#
        )
        XCTAssertEqual(newerPrompt.status, 0, newerPrompt.stderr)
        let newerPromptRecord = try readAntigravityHookSession(sessionId, context: context)
        assertActivePromptState(newerPromptRecord)
        let newerRevision = try XCTUnwrap(
            (newerPromptRecord["promptLifecycleRevision"] as? NSNumber)?.int64Value
        )
        XCTAssertGreaterThan(
            newerRevision,
            firstRevision,
            "A reset Antigravity invocation number must identify a newer prompt"
        )

        try FileManager.default.removeItem(atPath: barrier)
        wait(for: [sessionEndFinished], timeout: 5)

        let finalRecord = try readAntigravityHookSession(sessionId, context: context)
        assertActivePromptState(finalRecord)
        XCTAssertEqual(finalRecord["activePromptDepth"] as? Int, 1)
        XCTAssertEqual(finalRecord["runtimeStatus"] as? String, "running")
        XCTAssertEqual(
            (finalRecord["promptLifecycleRevision"] as? NSNumber)?.int64Value,
            newerRevision
        )
        let commands = context.state.snapshot()
        XCTAssertFalse(
            AgentJournalAppendCapture.contains(
                commands,
                kind: "agent.turn.completed",
                agentKey: "antigravity",
                sessionId: sessionId
            ),
            "A fenced SessionEnd must not journal completion for an ID-less newer prompt"
        )
        XCTAssertFalse(
            commands.contains {
                $0.contains(#""method":"feed.push""#)
                    && $0.contains(#""hook_event_name":"SessionEnd""#)
            },
            "A fenced SessionEnd must not publish ID-less prompt completion to Feed"
        )
    }

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
                        && $0.contains(#"#(expectedHookEventName)"#)
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

    func testAntigravityConcurrentStopsRetainSamePromptRevision() throws {
        let context = try makeClaudeHookContext(name: "antigravity-concurrent-completions")
        defer { context.cleanup() }

        startAgentHookMockServerAccepting(context: context)
        let sessionId = "antigravity-concurrent-completions-session"
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
            payload: #"{"conversationId":"\#(sessionId)","workspacePaths":["\#(context.root.path)"],"hook_event_name":"PreInvocation"}"#
        )
        XCTAssertEqual(prompt.status, 0, prompt.stderr)
        let initialRecord = try readAntigravityHookSession(sessionId, context: context)
        assertActivePromptState(initialRecord)
        let initialRevision = try XCTUnwrap(
            (initialRecord["promptLifecycleRevision"] as? NSNumber)?.int64Value
        )

        let intermediateBarrier = context.root.appendingPathComponent("intermediate-stop.barrier").path
        let completionBarrier = context.root.appendingPathComponent("completion-stop.barrier").path
        FileManager.default.createFile(atPath: intermediateBarrier, contents: Data())
        FileManager.default.createFile(atPath: completionBarrier, contents: Data())
        let intermediateFinished = expectation(description: "intermediate stop finishes")
        let completionFinished = expectation(description: "completion stop finishes")
        let stopPayload = { (fullyIdle: Bool) in
            #"{"conversationId":"\#(sessionId)","fullyIdle":\#(fullyIdle),"terminationReason":"model_stop","workspacePaths":["\#(context.root.path)"],"hook_event_name":"Stop"}"#
        }

        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.runAgentHook(
                context: context,
                agent: "antigravity",
                subcommand: "stop",
                standardInput: stopPayload(false),
                extraEnvironment: ["CMUX_TEST_AGENT_HOOK_STOP_BARRIER": intermediateBarrier]
            )
            intermediateFinished.fulfill()
        }
        let intermediateReadyPath = intermediateBarrier + ".ready"
        let intermediateReadyDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: intermediateReadyPath), Date() < intermediateReadyDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: intermediateReadyPath),
            "Intermediate Stop must reach the post-lookup barrier"
        )

        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.runAgentHook(
                context: context,
                agent: "antigravity",
                subcommand: "stop",
                standardInput: stopPayload(true),
                extraEnvironment: ["CMUX_TEST_AGENT_HOOK_STOP_BARRIER": completionBarrier]
            )
            completionFinished.fulfill()
        }
        let completionReadyPath = completionBarrier + ".ready"
        let completionReadyDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: completionReadyPath), Date() < completionReadyDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: completionReadyPath),
            "Completion Stop must reach the post-lookup barrier"
        )

        try FileManager.default.removeItem(atPath: intermediateBarrier)
        wait(for: [intermediateFinished], timeout: 5)
        let intermediateRecord = try readAntigravityHookSession(sessionId, context: context)
        XCTAssertNil(intermediateRecord["activePromptDepth"])
        XCTAssertEqual(intermediateRecord["runtimeStatus"] as? String, "running")

        try FileManager.default.removeItem(atPath: completionBarrier)
        wait(for: [completionFinished], timeout: 5)

        let finalRecord = try readAntigravityHookSession(sessionId, context: context)
        XCTAssertNil(finalRecord["activePromptDepth"])
        XCTAssertEqual(finalRecord["agentLifecycle"] as? String, "idle")
        XCTAssertEqual(finalRecord["runtimeStatus"] as? String, "idle")
        XCTAssertEqual(finalRecord["lastNotificationStatus"] as? String, "idle")
        XCTAssertEqual(
            (finalRecord["promptLifecycleRevision"] as? NSNumber)?.int64Value,
            initialRevision,
            "Terminal completion must not advance the prompt generation"
        )
    }

    private func readAntigravityHookSession(
        _ sessionId: String,
        context: ClaudeHookContext
    ) throws -> [String: Any] {
        let stateURL = context.root.appendingPathComponent("antigravity-hook-sessions.json")
        let state = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        let sessions = try XCTUnwrap(state["sessions"] as? [String: Any])
        return try XCTUnwrap(sessions[sessionId] as? [String: Any])
    }

    private func assertActivePromptState(
        _ record: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThan(record["activePromptDepth"] as? Int ?? 0, 0, file: file, line: line)
        XCTAssertEqual(record["agentLifecycle"] as? String, "running", file: file, line: line)
    }
}
