import XCTest
import Darwin
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Codex stale stop suppression
extension CLINotifyProcessIntegrationRegressionTests {
    func testCodexStopFromStaleOlderTurnDoesNotNotifyWhileNewerTurnIsActive() throws {
        let context = try makeClaudeHookContext(name: "codex-stale-turn-stop")
        defer { context.cleanup() }

        let sessionId = "stale-turn-stop-session"
        let transcriptURL = try writeCodexTerminalTranscript(
            context: context,
            name: "codex-stale-turn-stop.jsonl",
            turnId: "old-turn",
            eventType: "turn_aborted"
        )
        let launchEnvironment = codexLaunchEnvironment(context: context, sessionId: sessionId)
        startAgentHookMockServerAccepting(context: context, connectionLimit: 48)

        let oldPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"old-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"UserPromptSubmit","prompt":"old"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(oldPrompt.timedOut, oldPrompt.stderr)
        XCTAssertEqual(oldPrompt.status, 0, oldPrompt.stderr)

        let currentPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"current-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"UserPromptSubmit","prompt":"current"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(currentPrompt.timedOut, currentPrompt.stderr)
        XCTAssertEqual(currentPrompt.status, 0, currentPrompt.stderr)

        let staleStopStart = context.state.commands.count
        let staleStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"old-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"Stop","last_assistant_message":"old done"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(staleStop.timedOut, staleStop.stderr)
        XCTAssertEqual(staleStop.status, 0, staleStop.stderr)
        let staleStopCommands = Array(context.state.commands.dropFirst(staleStopStart))

        XCTAssertFalse(
            staleStopCommands.contains { $0.hasPrefix("notify_target") || $0.hasPrefix("set_status codex ") },
            "A stale Stop from an older turn must not notify or mark the newer active turn idle, saw \(staleStopCommands)"
        )

        let currentStopStart = context.state.commands.count
        let currentStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"current-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"Stop","last_assistant_message":"current done"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(currentStop.timedOut, currentStop.stderr)
        XCTAssertEqual(currentStop.status, 0, currentStop.stderr)
        let currentStopCommands = Array(context.state.commands.dropFirst(currentStopStart))

        XCTAssertTrue(
            currentStopCommands.contains { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Codex|") },
            "The current turn should still notify after a stale older Stop, saw \(currentStopCommands)"
        )
    }

    func testCodexLateStopFromOlderTurnDoesNotNotifyAfterNewerTurnCompleted() throws {
        let context = try makeClaudeHookContext(name: "codex-late-stale-turn-stop")
        defer { context.cleanup() }

        let sessionId = "late-stale-turn-stop-session"
        let transcriptURL = try writeCodexTerminalTranscript(
            context: context,
            name: "codex-late-stale-turn-stop.jsonl",
            turnId: "old-turn",
            eventType: "turn_aborted"
        )
        let launchEnvironment = codexLaunchEnvironment(context: context, sessionId: sessionId)
        startAgentHookMockServerAccepting(context: context, connectionLimit: 48)

        let oldPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"old-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"UserPromptSubmit","prompt":"old"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(oldPrompt.timedOut, oldPrompt.stderr)
        XCTAssertEqual(oldPrompt.status, 0, oldPrompt.stderr)

        let currentPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"current-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"UserPromptSubmit","prompt":"current"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(currentPrompt.timedOut, currentPrompt.stderr)
        XCTAssertEqual(currentPrompt.status, 0, currentPrompt.stderr)

        let currentStopStart = context.state.commands.count
        let currentStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"current-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"Stop","last_assistant_message":"current done"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(currentStop.timedOut, currentStop.stderr)
        XCTAssertEqual(currentStop.status, 0, currentStop.stderr)
        let currentStopCommands = Array(context.state.commands.dropFirst(currentStopStart))
        XCTAssertTrue(
            currentStopCommands.contains { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Codex|") },
            "The current turn should notify before a late stale Stop arrives, saw \(currentStopCommands)"
        )

        let lateStopStart = context.state.commands.count
        let lateStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"old-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"Stop","last_assistant_message":"old done"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(lateStop.timedOut, lateStop.stderr)
        XCTAssertEqual(lateStop.status, 0, lateStop.stderr)
        let lateStopCommands = Array(context.state.commands.dropFirst(lateStopStart))

        XCTAssertFalse(
            lateStopCommands.contains { $0.hasPrefix("notify_target") || $0.hasPrefix("set_status codex ") },
            "A late stale Stop from an older turn must not duplicate the newer turn completion, saw \(lateStopCommands)"
        )
    }

    func testCodexStopWithMissedPromptSubmitClearsTerminalStaleTurn() throws {
        let context = try makeClaudeHookContext(name: "codex-missed-prompt-stale-turn")
        defer { context.cleanup() }

        let sessionId = "missed-prompt-stale-turn-session"
        let transcriptURL = try writeCodexTerminalTranscript(
            context: context,
            name: "codex-missed-prompt-stale-turn.jsonl",
            turnId: "old-turn",
            eventType: "turn_aborted"
        )
        let launchEnvironment = codexLaunchEnvironment(context: context, sessionId: sessionId)
        startAgentHookMockServerAccepting(context: context, connectionLimit: 32)

        let oldPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"old-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"UserPromptSubmit","prompt":"old"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(oldPrompt.timedOut, oldPrompt.stderr)
        XCTAssertEqual(oldPrompt.status, 0, oldPrompt.stderr)

        let currentStopStart = context.state.commands.count
        let currentStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"current-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"Stop","last_assistant_message":"current done"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(currentStop.timedOut, currentStop.stderr)
        XCTAssertEqual(currentStop.status, 0, currentStop.stderr)
        let currentStopCommands = Array(context.state.commands.dropFirst(currentStopStart))

        XCTAssertTrue(
            currentStopCommands.contains { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Codex|") },
            "A Stop after a missed prompt-submit must clear terminal stale turns and notify, saw \(currentStopCommands)"
        )
        XCTAssertTrue(
            currentStopCommands.contains { $0.hasPrefix("set_status codex ") && $0.contains(" Idle ") },
            "A Stop after a missed prompt-submit must mark Codex idle, saw \(currentStopCommands)"
        )
    }

    func testCodexStopWithMissedPromptSubmitClearsFullyTerminalStack() throws {
        let context = try makeClaudeHookContext(name: "codex-missed-prompt-terminal-stack")
        defer { context.cleanup() }

        let sessionId = "missed-prompt-terminal-stack-session"
        let transcriptURL = context.root.appendingPathComponent("codex-missed-prompt-terminal-stack.jsonl")
        try [
            #"{"type":"turn_context","payload":{"turn_id":"old-parent-turn"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"old-parent-turn"}}"#,
            #"{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"old-parent-turn"}}"#,
            #"{"type":"turn_context","payload":{"turn_id":"old-child-turn"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"old-child-turn"}}"#,
            #"{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"old-child-turn"}}"#,
            #"{"type":"turn_context","payload":{"turn_id":"current-turn"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"current-turn"}}"#,
        ].joined(separator: "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let stateURL = context.root.appendingPathComponent("codex-hook-sessions.json")
        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": context.workspaceId,
                    "surfaceId": context.surfaceId,
                    "cwd": context.root.path,
                    "transcriptPath": transcriptURL.path,
                    "runtimeStatus": "running",
                    "activePromptDepth": 2,
                    "activePromptTurnId": "old-child-turn",
                    "activePromptTurnIds": ["old-parent-turn", "old-child-turn"],
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted])
            .write(to: stateURL, options: .atomic)

        let launchEnvironment = codexLaunchEnvironment(context: context, sessionId: sessionId)
        startAgentHookMockServerAccepting(context: context, connectionLimit: 32)

        let currentStopStart = context.state.commands.count
        let currentStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"current-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"Stop","last_assistant_message":"current done"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(currentStop.timedOut, currentStop.stderr)
        XCTAssertEqual(currentStop.status, 0, currentStop.stderr)
        let currentStopCommands = Array(context.state.commands.dropFirst(currentStopStart))

        XCTAssertTrue(
            currentStopCommands.contains { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Codex|") },
            "A missed prompt-submit Stop must clear a fully terminal stored stack and notify, saw \(currentStopCommands)"
        )
        XCTAssertTrue(
            currentStopCommands.contains { $0.hasPrefix("set_status codex ") && $0.contains(" Idle ") },
            "A missed prompt-submit Stop must clear a fully terminal stored stack and mark Codex idle, saw \(currentStopCommands)"
        )
    }

    func testCodexStopWithUnseenTurnIdNotSuppressedAtIdleDepth() throws {
        let context = try makeClaudeHookContext(name: "codex-unseen-turn-stop")
        defer { context.cleanup() }

        let sessionId = "unseen-turn-stop-session"
        let launchEnvironment = codexLaunchEnvironment(context: context, sessionId: sessionId)
        startAgentHookMockServerAccepting(context: context, connectionLimit: 48)

        let oldPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"old-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"old"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(oldPrompt.timedOut, oldPrompt.stderr)
        XCTAssertEqual(oldPrompt.status, 0, oldPrompt.stderr)

        let oldStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"old-turn","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"old done"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(oldStop.timedOut, oldStop.stderr)
        XCTAssertEqual(oldStop.status, 0, oldStop.stderr)

        let unseenStopStart = context.state.commands.count
        let unseenStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"new-turn","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"new done"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(unseenStop.timedOut, unseenStop.stderr)
        XCTAssertEqual(unseenStop.status, 0, unseenStop.stderr)
        let unseenStopCommands = Array(context.state.commands.dropFirst(unseenStopStart))

        XCTAssertTrue(
            unseenStopCommands.contains { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Codex|") },
            "A Stop with a missed prompt-submit must still notify at idle depth, saw \(unseenStopCommands)"
        )
        XCTAssertTrue(
            unseenStopCommands.contains { $0.hasPrefix("set_status codex ") },
            "A Stop with a missed prompt-submit must still update Codex status, saw \(unseenStopCommands)"
        )
    }

}
