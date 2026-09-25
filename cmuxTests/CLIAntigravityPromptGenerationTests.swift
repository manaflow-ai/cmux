import Foundation
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    func testAntigravitySameTurnIDAfterIDLessPromptDoesNotFenceCompletion() throws {
        let context = try makeClaudeHookContext(name: "antigravity-same-turn-id")
        defer { context.cleanup() }

        startAgentHookMockServerAccepting(context: context)
        let sessionId = "antigravity-same-turn-id-session"
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
                payload: #"{"conversationId":"\#(sessionId)","turn_id":"turn-1","invocationNum":0,"workspacePaths":["\#(context.root.path)"],"hook_event_name":"PreInvocation"}"#
            ).status,
            0
        )
        let firstPromptRecord = try readAntigravityHookSession(sessionId, context: context)
        assertActivePromptState(firstPromptRecord)
        let firstRevision = try XCTUnwrap(
            (firstPromptRecord["promptLifecycleRevision"] as? NSNumber)?.int64Value
        )

        // An ID-less callback is another invocation of the same turn. It must
        // preserve the observed turn identity for a later explicit callback.
        XCTAssertEqual(
            run(
                "prompt-submit",
                payload: #"{"conversationId":"\#(sessionId)","invocationNum":1,"workspacePaths":["\#(context.root.path)"],"hook_event_name":"PreInvocation"}"#
            ).status,
            0
        )
        let idLessPromptRecord = try readAntigravityHookSession(sessionId, context: context)
        assertActivePromptState(idLessPromptRecord)
        XCTAssertEqual(
            (idLessPromptRecord["promptLifecycleRevision"] as? NSNumber)?.int64Value,
            firstRevision
        )

        let barrier = context.root.appendingPathComponent("same-turn-id-stop.barrier").path
        FileManager.default.createFile(atPath: barrier, contents: Data())
        let delayedStopFinished = expectation(description: "delayed same-turn Stop finishes")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.runAgentHook(
                context: context,
                agent: "antigravity",
                subcommand: "stop",
                standardInput: #"{"conversationId":"\#(sessionId)","turn_id":"turn-1","fullyIdle":true,"terminationReason":"model_stop","workspacePaths":["\#(context.root.path)"],"hook_event_name":"Stop"}"#,
                extraEnvironment: ["CMUX_TEST_AGENT_HOOK_STOP_BARRIER": barrier]
            )
            delayedStopFinished.fulfill()
        }

        let readyPath = barrier + ".ready"
        let readyDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: readyPath), Date() < readyDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: readyPath))

        let repeatedTurnPrompt = run(
            "prompt-submit",
            payload: #"{"conversationId":"\#(sessionId)","turn_id":"turn-1","invocationNum":2,"workspacePaths":["\#(context.root.path)"],"hook_event_name":"PreInvocation"}"#
        )
        XCTAssertEqual(repeatedTurnPrompt.status, 0, repeatedTurnPrompt.stderr)
        let repeatedTurnRecord = try readAntigravityHookSession(sessionId, context: context)
        assertActivePromptState(repeatedTurnRecord)
        XCTAssertEqual(
            (repeatedTurnRecord["promptLifecycleRevision"] as? NSNumber)?.int64Value,
            firstRevision,
            "An explicit callback for the observed turn must not create a new generation after an ID-less callback"
        )

        try FileManager.default.removeItem(atPath: barrier)
        wait(for: [delayedStopFinished], timeout: 5)

        let finalRecord = try readAntigravityHookSession(sessionId, context: context)
        XCTAssertNil(finalRecord["activePromptDepth"])
        XCTAssertEqual(finalRecord["agentLifecycle"] as? String, "idle")
        XCTAssertEqual(finalRecord["runtimeStatus"] as? String, "idle")
    }

    func testAntigravityNewTurnWithoutInvocationDoesNotDoubleAdvanceGeneration() throws {
        let context = try makeClaudeHookContext(name: "antigravity-invocation-reset")
        defer { context.cleanup() }

        startAgentHookMockServerAccepting(context: context)
        let sessionId = "antigravity-invocation-reset-session"
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
                payload: #"{"conversationId":"\#(sessionId)","turn_id":"turn-1","invocationNum":2,"workspacePaths":["\#(context.root.path)"],"hook_event_name":"PreInvocation"}"#
            ).status,
            0
        )
        let firstRecord = try readAntigravityHookSession(sessionId, context: context)
        assertActivePromptState(firstRecord)
        let firstRevision = try XCTUnwrap(
            (firstRecord["promptLifecycleRevision"] as? NSNumber)?.int64Value
        )

        XCTAssertEqual(
            run(
                "prompt-submit",
                payload: #"{"conversationId":"\#(sessionId)","turn_id":"turn-2","workspacePaths":["\#(context.root.path)"],"hook_event_name":"PreInvocation"}"#
            ).status,
            0
        )
        let secondRecord = try readAntigravityHookSession(sessionId, context: context)
        assertActivePromptState(secondRecord)
        let secondRevision = try XCTUnwrap(
            (secondRecord["promptLifecycleRevision"] as? NSNumber)?.int64Value
        )
        XCTAssertGreaterThan(secondRevision, firstRevision)

        let barrier = context.root.appendingPathComponent("invocation-reset-stop.barrier").path
        FileManager.default.createFile(atPath: barrier, contents: Data())
        let delayedStopFinished = expectation(description: "delayed invocation-reset Stop finishes")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.runAgentHook(
                context: context,
                agent: "antigravity",
                subcommand: "stop",
                standardInput: #"{"conversationId":"\#(sessionId)","turn_id":"turn-2","fullyIdle":true,"terminationReason":"model_stop","workspacePaths":["\#(context.root.path)"],"hook_event_name":"Stop"}"#,
                extraEnvironment: ["CMUX_TEST_AGENT_HOOK_STOP_BARRIER": barrier]
            )
            delayedStopFinished.fulfill()
        }

        let readyPath = barrier + ".ready"
        let readyDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: readyPath), Date() < readyDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: readyPath))

        let firstInvocationOfNewTurn = run(
            "prompt-submit",
            payload: #"{"conversationId":"\#(sessionId)","invocationNum":0,"workspacePaths":["\#(context.root.path)"],"hook_event_name":"PreInvocation"}"#
        )
        XCTAssertEqual(firstInvocationOfNewTurn.status, 0, firstInvocationOfNewTurn.stderr)
        let resetRecord = try readAntigravityHookSession(sessionId, context: context)
        assertActivePromptState(resetRecord)
        XCTAssertEqual(
            (resetRecord["promptLifecycleRevision"] as? NSNumber)?.int64Value,
            secondRevision,
            "Invocation zero on the new turn must not double-advance after the explicit turn reset"
        )

        try FileManager.default.removeItem(atPath: barrier)
        wait(for: [delayedStopFinished], timeout: 5)

        let finalRecord = try readAntigravityHookSession(sessionId, context: context)
        XCTAssertNil(finalRecord["activePromptDepth"])
        XCTAssertEqual(finalRecord["agentLifecycle"] as? String, "idle")
        XCTAssertEqual(finalRecord["runtimeStatus"] as? String, "idle")
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
}
