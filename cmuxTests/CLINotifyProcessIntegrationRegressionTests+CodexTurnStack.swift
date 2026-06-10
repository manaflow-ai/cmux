import XCTest
import Darwin
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Codex turn stack
extension CLINotifyProcessIntegrationRegressionTests {
    func testCodexStopReadsOversizedFinalTranscriptLine() throws {
        let context = try makeClaudeHookContext(name: "codex-oversized-final-transcript")
        defer { context.cleanup() }
        startAgentHookMockServerAccepting(context: context, connectionLimit: 32)

        let turnId = "oversized-final-turn"
        let transcriptURL = context.root.appendingPathComponent("oversized-final-codex-session.jsonl")
        _ = FileManager.default.createFile(atPath: transcriptURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: transcriptURL)
        defer { try? handle.close() }

        try handle.write(contentsOf: Data(#"{"type":"session_meta","payload":{"id":"codex-oversized-final-session"}}"#.utf8))
        try handle.write(contentsOf: Data("\n".utf8))
        let padding = String(repeating: "p", count: 600_000)
        let finalLine = #"{"type":"event_msg","payload":{"type":"turn_complete","turn_id":"\#(turnId)","padding":"\#(padding)"}}"#
        try handle.write(contentsOf: Data(finalLine.utf8))
        try handle.close()

        let stop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"codex-oversized-final-session","turn_id":"\#(turnId)","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"Stop","last_assistant_message":null}"#
        )

        XCTAssertFalse(stop.timedOut, stop.stderr)
        XCTAssertEqual(stop.status, 0, stop.stderr)
        XCTAssertTrue(
            context.state.commands.contains { command in
                command.contains("notify_target_async \(context.workspaceId) \(context.surfaceId) Codex|Error|Codex ended before sending a final response")
            },
            "Expected Codex to parse the oversized final transcript line, saw \(context.state.commands)"
        )
    }

    func testCodexLegacyStopWithoutTurnIdPopsStoredTurnStack() throws {
        let context = try makeClaudeHookContext(name: "codex-legacy-stop-turn-stack")
        defer { context.cleanup() }

        let sessionId = "legacy-stop-turn-stack-session"
        let launchEnvironment = codexLaunchEnvironment(context: context, sessionId: sessionId)
        startAgentHookMockServerAccepting(context: context, connectionLimit: 48)

        let parentPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"parent-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"parent"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(parentPrompt.timedOut, parentPrompt.stderr)
        XCTAssertEqual(parentPrompt.status, 0, parentPrompt.stderr)

        let childPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"child-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"child"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(childPrompt.timedOut, childPrompt.stderr)
        XCTAssertEqual(childPrompt.status, 0, childPrompt.stderr)

        let legacyChildStopStart = context.state.commands.count
        let legacyChildStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"child done"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(legacyChildStop.timedOut, legacyChildStop.stderr)
        XCTAssertEqual(legacyChildStop.status, 0, legacyChildStop.stderr)
        let legacyChildStopCommands = Array(context.state.commands.dropFirst(legacyChildStopStart))
        XCTAssertFalse(
            legacyChildStopCommands.contains { $0.hasPrefix("notify_target") || $0.hasPrefix("set_status codex ") },
            "A legacy child Stop without a turn_id must stay nested, saw \(legacyChildStopCommands)"
        )

        let parentStopStart = context.state.commands.count
        let parentStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"parent-turn","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"parent done"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(parentStop.timedOut, parentStop.stderr)
        XCTAssertEqual(parentStop.status, 0, parentStop.stderr)
        let parentStopCommands = Array(context.state.commands.dropFirst(parentStopStart))
        XCTAssertTrue(
            parentStopCommands.contains { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Codex|") },
            "The parent Stop must still notify after a legacy child Stop without a turn_id, saw \(parentStopCommands)"
        )
        XCTAssertTrue(
            parentStopCommands.contains { $0.hasPrefix("set_status codex ") && $0.contains(" Idle ") },
            "The parent Stop must still mark Codex idle after a legacy child Stop without a turn_id, saw \(parentStopCommands)"
        )
    }

    func testCodexTurnStackPreservesAnonymousDepthBetweenKnownTurns() throws {
        let context = try makeClaudeHookContext(name: "codex-mixed-anonymous-depth")
        defer { context.cleanup() }

        let sessionId = "mixed-anonymous-depth-session"
        let launchEnvironment = codexLaunchEnvironment(context: context, sessionId: sessionId)
        startAgentHookMockServerAccepting(context: context, connectionLimit: 64)

        let parentPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"parent-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"parent"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(parentPrompt.timedOut, parentPrompt.stderr)
        XCTAssertEqual(parentPrompt.status, 0, parentPrompt.stderr)

        let anonymousChildPromptStart = context.state.commands.count
        let anonymousChildPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"anonymous child"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(anonymousChildPrompt.timedOut, anonymousChildPrompt.stderr)
        XCTAssertEqual(anonymousChildPrompt.status, 0, anonymousChildPrompt.stderr)
        let anonymousChildPromptCommands = Array(context.state.commands.dropFirst(anonymousChildPromptStart))
        XCTAssertFalse(
            anonymousChildPromptCommands.contains { (self.jsonObject($0)?["method"] as? String)?.hasPrefix("surface.resume.") == true },
            "An anonymous child under a known parent must not replace the parent resume binding, saw \(anonymousChildPromptCommands)"
        )
        XCTAssertFalse(
            anonymousChildPromptCommands.contains { $0.hasPrefix("set_status codex Running ") },
            "An anonymous child under a known parent must not rewrite parent Running status, saw \(anonymousChildPromptCommands)"
        )

        let grandchildPromptStart = context.state.commands.count
        let grandchildPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"grandchild-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"grandchild"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(grandchildPrompt.timedOut, grandchildPrompt.stderr)
        XCTAssertEqual(grandchildPrompt.status, 0, grandchildPrompt.stderr)
        let grandchildPromptCommands = Array(context.state.commands.dropFirst(grandchildPromptStart))
        XCTAssertFalse(
            grandchildPromptCommands.contains { (self.jsonObject($0)?["method"] as? String)?.hasPrefix("surface.resume.") == true },
            "A known grandchild after anonymous depth must stay nested, saw \(grandchildPromptCommands)"
        )
        XCTAssertFalse(
            grandchildPromptCommands.contains { $0.hasPrefix("set_status codex Running ") },
            "A known grandchild after anonymous depth must not rewrite parent Running status, saw \(grandchildPromptCommands)"
        )

        let grandchildStopStart = context.state.commands.count
        let grandchildStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"grandchild-turn","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"grandchild done"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(grandchildStop.timedOut, grandchildStop.stderr)
        XCTAssertEqual(grandchildStop.status, 0, grandchildStop.stderr)
        let grandchildStopCommands = Array(context.state.commands.dropFirst(grandchildStopStart))
        XCTAssertFalse(
            grandchildStopCommands.contains { $0.hasPrefix("notify_target") || $0.hasPrefix("set_status codex ") },
            "Grandchild Stop must not collapse anonymous child depth and notify, saw \(grandchildStopCommands)"
        )

        let anonymousChildStopStart = context.state.commands.count
        let anonymousChildStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"anonymous child done"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(anonymousChildStop.timedOut, anonymousChildStop.stderr)
        XCTAssertEqual(anonymousChildStop.status, 0, anonymousChildStop.stderr)
        let anonymousChildStopCommands = Array(context.state.commands.dropFirst(anonymousChildStopStart))
        XCTAssertFalse(
            anonymousChildStopCommands.contains { $0.hasPrefix("notify_target") || $0.hasPrefix("set_status codex ") },
            "Anonymous child Stop must stay nested after a known grandchild Stop, saw \(anonymousChildStopCommands)"
        )

        let parentStopStart = context.state.commands.count
        let parentStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"parent-turn","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"parent done"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(parentStop.timedOut, parentStop.stderr)
        XCTAssertEqual(parentStop.status, 0, parentStop.stderr)
        let parentStopCommands = Array(context.state.commands.dropFirst(parentStopStart))
        XCTAssertTrue(
            parentStopCommands.contains { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Codex|") },
            "The parent Stop must still notify after mixed anonymous depth, saw \(parentStopCommands)"
        )
        XCTAssertTrue(
            parentStopCommands.contains { $0.hasPrefix("set_status codex ") && $0.contains(" Idle ") },
            "The parent Stop must still mark Codex idle after mixed anonymous depth, saw \(parentStopCommands)"
        )
    }

    func testCodexStopWithNewTurnIdPopsAnonymousDepthUnderKnownParent() throws {
        let context = try makeClaudeHookContext(name: "codex-anonymous-depth-turn-stop")
        defer { context.cleanup() }

        let sessionId = "anonymous-depth-turn-stop-session"
        let launchEnvironment = codexLaunchEnvironment(context: context, sessionId: sessionId)
        startAgentHookMockServerAccepting(context: context, connectionLimit: 48)

        let parentPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"parent-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"parent"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(parentPrompt.timedOut, parentPrompt.stderr)
        XCTAssertEqual(parentPrompt.status, 0, parentPrompt.stderr)

        let anonymousChildPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"anonymous child"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(anonymousChildPrompt.timedOut, anonymousChildPrompt.stderr)
        XCTAssertEqual(anonymousChildPrompt.status, 0, anonymousChildPrompt.stderr)

        let childStopStart = context.state.commands.count
        let childStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"child-turn","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"child done"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(childStop.timedOut, childStop.stderr)
        XCTAssertEqual(childStop.status, 0, childStop.stderr)
        let childStopCommands = Array(context.state.commands.dropFirst(childStopStart))
        XCTAssertFalse(
            childStopCommands.contains { $0.hasPrefix("notify_target") || $0.hasPrefix("set_status codex ") },
            "The child Stop should pop anonymous depth without notifying, saw \(childStopCommands)"
        )

        let parentStopStart = context.state.commands.count
        let parentStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"parent-turn","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"parent done"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(parentStop.timedOut, parentStop.stderr)
        XCTAssertEqual(parentStop.status, 0, parentStop.stderr)
        let parentStopCommands = Array(context.state.commands.dropFirst(parentStopStart))
        XCTAssertTrue(
            parentStopCommands.contains { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Codex|") },
            "The parent Stop must still notify after a child Stop supplies a new turn_id, saw \(parentStopCommands)"
        )
        XCTAssertTrue(
            parentStopCommands.contains { $0.hasPrefix("set_status codex ") && $0.contains(" Idle ") },
            "The parent Stop must still mark Codex idle after a child Stop supplies a new turn_id, saw \(parentStopCommands)"
        )
    }

    func testCodexStopAfterInterruptedPriorTurnStillNotifies() throws {
        let context = try makeClaudeHookContext(name: "codex-interrupted-turn-depth")
        defer { context.cleanup() }

        let sessionId = "interrupted-depth-session"
        let transcriptURL = try writeCodexTerminalTranscript(
            context: context,
            name: "codex-interrupted-turn-depth.jsonl",
            turnId: "old-turn",
            eventType: "turn_aborted"
        )
        let launchEnvironment = codexLaunchEnvironment(context: context, sessionId: sessionId)
        startAgentHookMockServerAccepting(context: context, connectionLimit: 32)

        let interruptedPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"old-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"UserPromptSubmit","prompt":"interrupted"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(interruptedPrompt.timedOut, interruptedPrompt.stderr)
        XCTAssertEqual(interruptedPrompt.status, 0, interruptedPrompt.stderr)

        let currentPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"current-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"UserPromptSubmit","prompt":"finish now"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(currentPrompt.timedOut, currentPrompt.stderr)
        XCTAssertEqual(currentPrompt.status, 0, currentPrompt.stderr)

        let stopStart = context.state.commands.count
        let currentStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"current-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"Stop","last_assistant_message":"current done"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(currentStop.timedOut, currentStop.stderr)
        XCTAssertEqual(currentStop.status, 0, currentStop.stderr)
        let stopCommands = Array(context.state.commands.dropFirst(stopStart))

        XCTAssertTrue(
            stopCommands.contains { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Codex|") },
            "A stale prompt depth from an interrupted prior turn must not suppress the current top-level completion notification, saw \(stopCommands)"
        )
        XCTAssertTrue(
            stopCommands.contains { $0.hasPrefix("set_status codex ") && $0.contains(" Idle ") },
            "A stale prompt depth from an interrupted prior turn must not leave Codex marked running, saw \(stopCommands)"
        )
    }

    func testCodexStopPrunesLateTerminalPriorTurnBeforeCurrentStop() throws {
        let context = try makeClaudeHookContext(name: "codex-late-terminal-prior-turn")
        defer { context.cleanup() }

        let sessionId = "late-terminal-prior-turn-session"
        let transcriptURL = context.root.appendingPathComponent("codex-late-terminal-prior-turn.jsonl")
        try [
            #"{"type":"turn_context","payload":{"turn_id":"old-turn"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"old-turn"}}"#,
        ].joined(separator: "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let launchEnvironment = codexLaunchEnvironment(context: context, sessionId: sessionId)
        startAgentHookMockServerAccepting(context: context, connectionLimit: 64)

        let oldPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"old-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"UserPromptSubmit","prompt":"old"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(oldPrompt.timedOut, oldPrompt.stderr)
        XCTAssertEqual(oldPrompt.status, 0, oldPrompt.stderr)

        let currentPromptStart = context.state.commands.count
        let currentPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"current-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"UserPromptSubmit","prompt":"current"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(currentPrompt.timedOut, currentPrompt.stderr)
        XCTAssertEqual(currentPrompt.status, 0, currentPrompt.stderr)
        let currentPromptCommands = Array(context.state.commands.dropFirst(currentPromptStart))
        XCTAssertFalse(
            currentPromptCommands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.set" },
            "Before the late terminal transcript update, the current prompt should still look nested, saw \(currentPromptCommands)"
        )

        try [
            #"{"type":"turn_context","payload":{"turn_id":"old-turn"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"old-turn"}}"#,
            #"{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"old-turn"}}"#,
            #"{"type":"turn_context","payload":{"turn_id":"current-turn"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"current-turn"}}"#,
        ].joined(separator: "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

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
            "A late terminal prior turn must not suppress the current top-level completion notification, saw \(currentStopCommands)"
        )
        XCTAssertTrue(
            currentStopCommands.contains { $0.hasPrefix("set_status codex ") && $0.contains(" Idle ") },
            "A late terminal prior turn must not leave Codex marked running after the current Stop, saw \(currentStopCommands)"
        )
    }

    func testCodexTerminalNestedChildDoesNotClearParentTurnStack() throws {
        let context = try makeClaudeHookContext(name: "codex-terminal-child-stack")
        defer { context.cleanup() }

        let sessionId = "terminal-child-stack-session"
        let terminalChildTranscript = try writeCodexTerminalTranscript(
            context: context,
            name: "codex-terminal-child-stack.jsonl",
            turnId: "child-turn",
            eventType: "turn_complete"
        )
        let launchEnvironment = codexLaunchEnvironment(context: context, sessionId: sessionId)
        startAgentHookMockServerAccepting(context: context, connectionLimit: 64)

        let parentPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"parent-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"spawn child"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(parentPrompt.timedOut, parentPrompt.stderr)
        XCTAssertEqual(parentPrompt.status, 0, parentPrompt.stderr)

        let childPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"child-turn","cwd":"\#(context.root.path)","transcript_path":"\#(terminalChildTranscript.path)","hook_event_name":"UserPromptSubmit","prompt":"first child"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(childPrompt.timedOut, childPrompt.stderr)
        XCTAssertEqual(childPrompt.status, 0, childPrompt.stderr)

        let siblingPromptStart = context.state.commands.count
        let siblingPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"sibling-turn","cwd":"\#(context.root.path)","transcript_path":"\#(terminalChildTranscript.path)","hook_event_name":"UserPromptSubmit","prompt":"second child"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(siblingPrompt.timedOut, siblingPrompt.stderr)
        XCTAssertEqual(siblingPrompt.status, 0, siblingPrompt.stderr)
        let siblingPromptCommands = Array(context.state.commands.dropFirst(siblingPromptStart))
        XCTAssertFalse(
            siblingPromptCommands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.set" },
            "A sibling child prompt after a terminal child transcript must stay nested, saw \(siblingPromptCommands)"
        )
        XCTAssertFalse(
            siblingPromptCommands.contains { $0.hasPrefix("set_status codex Running ") },
            "A sibling child prompt after a terminal child transcript must not rewrite parent Running status, saw \(siblingPromptCommands)"
        )

        let childStopStart = context.state.commands.count
        let childStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"child-turn","cwd":"\#(context.root.path)","transcript_path":"\#(terminalChildTranscript.path)","hook_event_name":"Stop","last_assistant_message":"first child done"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(childStop.timedOut, childStop.stderr)
        XCTAssertEqual(childStop.status, 0, childStop.stderr)
        let childStopCommands = Array(context.state.commands.dropFirst(childStopStart))
        XCTAssertFalse(
            childStopCommands.contains { $0.hasPrefix("notify_target") || $0.hasPrefix("set_status codex ") },
            "A late terminal child Stop must remain nested after a sibling child prompt, saw \(childStopCommands)"
        )

        let siblingStopStart = context.state.commands.count
        let siblingStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"sibling-turn","cwd":"\#(context.root.path)","transcript_path":"\#(terminalChildTranscript.path)","hook_event_name":"Stop","last_assistant_message":"second child done"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(siblingStop.timedOut, siblingStop.stderr)
        XCTAssertEqual(siblingStop.status, 0, siblingStop.stderr)
        let siblingStopCommands = Array(context.state.commands.dropFirst(siblingStopStart))
        XCTAssertFalse(
            siblingStopCommands.contains { $0.hasPrefix("notify_target") || $0.hasPrefix("set_status codex ") },
            "The sibling child Stop must not notify while the parent is active, saw \(siblingStopCommands)"
        )

        let parentStopStart = context.state.commands.count
        let parentStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"parent-turn","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"parent done"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(parentStop.timedOut, parentStop.stderr)
        XCTAssertEqual(parentStop.status, 0, parentStop.stderr)
        let parentStopCommands = Array(context.state.commands.dropFirst(parentStopStart))
        XCTAssertTrue(
            parentStopCommands.contains { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Codex|") },
            "The parent Stop should still notify after terminal nested children, saw \(parentStopCommands)"
        )
    }

    func testCodexTerminalInterruptedStackClearsBeforeCurrentPrompt() throws {
        let context = try makeClaudeHookContext(name: "codex-terminal-stack-reset")
        defer { context.cleanup() }

        let sessionId = "terminal-stack-reset-session"
        let transcriptURL = context.root.appendingPathComponent("codex-terminal-stack-reset.jsonl")
        try [
            #"{"type":"turn_context","payload":{"turn_id":"parent-turn"}}"#,
            #"{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"parent-turn"}}"#,
            #"{"type":"turn_context","payload":{"turn_id":"child-turn"}}"#,
            #"{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"child-turn"}}"#,
        ].joined(separator: "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        let launchEnvironment = codexLaunchEnvironment(context: context, sessionId: sessionId)
        startAgentHookMockServerAccepting(context: context, connectionLimit: 64)

        let parentPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"parent-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"parent"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(parentPrompt.timedOut, parentPrompt.stderr)
        XCTAssertEqual(parentPrompt.status, 0, parentPrompt.stderr)

        let childPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"child-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"child"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(childPrompt.timedOut, childPrompt.stderr)
        XCTAssertEqual(childPrompt.status, 0, childPrompt.stderr)

        let currentPromptStart = context.state.commands.count
        let currentPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"current-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"UserPromptSubmit","prompt":"current"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(currentPrompt.timedOut, currentPrompt.stderr)
        XCTAssertEqual(currentPrompt.status, 0, currentPrompt.stderr)
        let currentPromptCommands = Array(context.state.commands.dropFirst(currentPromptStart))
        XCTAssertTrue(
            currentPromptCommands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.set" },
            "A current prompt after a fully terminal interrupted stack must become top-level, saw \(currentPromptCommands)"
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
            "A current Stop after a fully terminal interrupted stack must notify, saw \(currentStopCommands)"
        )
    }

}
