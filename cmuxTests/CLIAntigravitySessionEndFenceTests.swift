import Foundation
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
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
}
