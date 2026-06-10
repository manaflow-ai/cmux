import XCTest
import Darwin
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Codex depth-only nesting
extension CLINotifyProcessIntegrationRegressionTests {
    func testCodexDepthOnlyLegacyNestingRemainsNestedWhenTurnIdsAppear() throws {
        let context = try makeClaudeHookContext(name: "codex-depth-only-nested")
        defer { context.cleanup() }

        let sessionId = "depth-only-nested-session"
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
                    "runtimeStatus": "running",
                    "activePromptDepth": 1,
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted])
            .write(to: stateURL, options: .atomic)

        let launchEnvironment = codexLaunchEnvironment(context: context, sessionId: sessionId)
        startAgentHookMockServerAccepting(context: context, connectionLimit: 32)

        let childPromptStart = context.state.commands.count
        let childPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"child-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"child"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(childPrompt.timedOut, childPrompt.stderr)
        XCTAssertEqual(childPrompt.status, 0, childPrompt.stderr)
        let childPromptCommands = Array(context.state.commands.dropFirst(childPromptStart))
        XCTAssertFalse(
            childPromptCommands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.set" },
            "A legacy depth-only nested prompt that first gains a turn_id must remain nested, saw \(childPromptCommands)"
        )
        XCTAssertFalse(
            childPromptCommands.contains { $0.hasPrefix("set_status codex Running ") },
            "A legacy depth-only nested prompt that first gains a turn_id must not rewrite parent Running status, saw \(childPromptCommands)"
        )

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
            "A legacy depth-only nested Stop that first gains a turn_id must remain nested, saw \(childStopCommands)"
        )
    }

    func testCodexDepthOnlyHistoricalTerminalDoesNotResetActiveParent() throws {
        let context = try makeClaudeHookContext(name: "codex-depth-only-history")
        defer { context.cleanup() }

        let sessionId = "depth-only-history-session"
        let transcriptURL = context.root.appendingPathComponent("codex-depth-only-history.jsonl")
        try [
            #"{"type":"turn_context","payload":{"turn_id":"old-turn"}}"#,
            #"{"type":"event_msg","payload":{"type":"turn_complete","turn_id":"old-turn"}}"#,
            #"{"type":"turn_context","payload":{"turn_id":"parent-turn"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"parent-turn"}}"#,
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
                    "activePromptDepth": 1,
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted])
            .write(to: stateURL, options: .atomic)

        let launchEnvironment = codexLaunchEnvironment(context: context, sessionId: sessionId)
        startAgentHookMockServerAccepting(context: context, connectionLimit: 32)

        let childPromptStart = context.state.commands.count
        let childPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"child-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"UserPromptSubmit","prompt":"child"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(childPrompt.timedOut, childPrompt.stderr)
        XCTAssertEqual(childPrompt.status, 0, childPrompt.stderr)
        let childPromptCommands = Array(context.state.commands.dropFirst(childPromptStart))
        XCTAssertFalse(
            childPromptCommands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.set" },
            "A historical terminal turn must not make an active depth-only parent look finished, saw \(childPromptCommands)"
        )
        XCTAssertFalse(
            childPromptCommands.contains { $0.hasPrefix("set_status codex Running ") },
            "A historical terminal turn must not let the child rewrite parent Running status, saw \(childPromptCommands)"
        )

        let childStopStart = context.state.commands.count
        let childStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"child-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"Stop","last_assistant_message":"child done"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(childStop.timedOut, childStop.stderr)
        XCTAssertEqual(childStop.status, 0, childStop.stderr)
        let childStopCommands = Array(context.state.commands.dropFirst(childStopStart))
        XCTAssertFalse(
            childStopCommands.contains { $0.hasPrefix("notify_target") || $0.hasPrefix("set_status codex ") },
            "A historical terminal turn must not let a child Stop notify while the parent is active, saw \(childStopCommands)"
        )
    }

    func testCodexDepthOnlyTurnContextOnlyParentDoesNotResetActiveParent() throws {
        let context = try makeClaudeHookContext(name: "codex-depth-only-context-parent")
        defer { context.cleanup() }

        let sessionId = "depth-only-context-parent-session"
        let transcriptURL = context.root.appendingPathComponent("codex-depth-only-context-parent.jsonl")
        try [
            #"{"type":"turn_context","payload":{"turn_id":"old-turn"}}"#,
            #"{"type":"event_msg","payload":{"type":"turn_complete","turn_id":"old-turn"}}"#,
            #"{"type":"turn_context","payload":{"turn_id":"parent-turn"}}"#,
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
                    "activePromptDepth": 1,
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted])
            .write(to: stateURL, options: .atomic)

        let launchEnvironment = codexLaunchEnvironment(context: context, sessionId: sessionId)
        startAgentHookMockServerAccepting(context: context, connectionLimit: 32)

        let childPromptStart = context.state.commands.count
        let childPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"child-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"UserPromptSubmit","prompt":"child"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(childPrompt.timedOut, childPrompt.stderr)
        XCTAssertEqual(childPrompt.status, 0, childPrompt.stderr)
        let childPromptCommands = Array(context.state.commands.dropFirst(childPromptStart))
        XCTAssertFalse(
            childPromptCommands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.set" },
            "A non-terminal parent turn_context must not make a depth-only parent look finished, saw \(childPromptCommands)"
        )
        XCTAssertFalse(
            childPromptCommands.contains { $0.hasPrefix("set_status codex Running ") },
            "A non-terminal parent turn_context must not let the child rewrite parent Running status, saw \(childPromptCommands)"
        )

        let childStopStart = context.state.commands.count
        let childStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"child-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"Stop","last_assistant_message":"child done"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(childStop.timedOut, childStop.stderr)
        XCTAssertEqual(childStop.status, 0, childStop.stderr)
        let childStopCommands = Array(context.state.commands.dropFirst(childStopStart))
        XCTAssertFalse(
            childStopCommands.contains { $0.hasPrefix("notify_target") || $0.hasPrefix("set_status codex ") },
            "A non-terminal parent turn_context must not let a child Stop notify while the parent is active, saw \(childStopCommands)"
        )
    }

    func testCodexDepthOnlyParentStopNotifiesAfterChildTurnStops() throws {
        let context = try makeClaudeHookContext(name: "codex-depth-only-parent-stop")
        defer { context.cleanup() }

        let sessionId = "depth-only-parent-stop-session"
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
                    "runtimeStatus": "running",
                    "activePromptDepth": 1,
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted])
            .write(to: stateURL, options: .atomic)

        let launchEnvironment = codexLaunchEnvironment(context: context, sessionId: sessionId)
        startAgentHookMockServerAccepting(context: context, connectionLimit: 48)

        let childPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"child-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"child"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(childPrompt.timedOut, childPrompt.stderr)
        XCTAssertEqual(childPrompt.status, 0, childPrompt.stderr)

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
            "The child Stop should close only the child depth, saw \(childStopCommands)"
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
            "The depth-only parent Stop must notify after its child turn stops, saw \(parentStopCommands)"
        )
        XCTAssertTrue(
            parentStopCommands.contains { $0.hasPrefix("set_status codex ") && $0.contains(" Idle ") },
            "The depth-only parent Stop must mark Codex idle, saw \(parentStopCommands)"
        )
    }

    func testCodexDepthOnlySiblingStaysNestedAfterChildTerminalTranscript() throws {
        let context = try makeClaudeHookContext(name: "codex-depth-only-child-terminal")
        defer { context.cleanup() }

        let sessionId = "depth-only-child-terminal-session"
        let transcriptURL = context.root.appendingPathComponent("codex-depth-only-child-terminal.jsonl")
        try [
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"parent-turn"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"child-turn"}}"#,
            #"{"type":"event_msg","payload":{"type":"turn_complete","turn_id":"child-turn"}}"#,
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
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted])
            .write(to: stateURL, options: .atomic)

        let launchEnvironment = codexLaunchEnvironment(context: context, sessionId: sessionId)
        startAgentHookMockServerAccepting(context: context, connectionLimit: 64)

        let childStopStart = context.state.commands.count
        let childStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"child-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"Stop","last_assistant_message":"child done"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(childStop.timedOut, childStop.stderr)
        XCTAssertEqual(childStop.status, 0, childStop.stderr)
        XCTAssertEqual(childStop.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "{}")
        XCTAssertEqual(childStop.stderr, "")
        let childStopCommands = Array(context.state.commands.dropFirst(childStopStart))
        XCTAssertFalse(
            childStopCommands.contains { $0.hasPrefix("notify_target") || $0.hasPrefix("set_status codex ") },
            "A late terminal child Stop must stay nested while the depth-only parent remains active, saw \(childStopCommands)"
        )

        let siblingPromptStart = context.state.commands.count
        let siblingPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"sibling-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"UserPromptSubmit","prompt":"sibling"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(siblingPrompt.timedOut, siblingPrompt.stderr)
        XCTAssertEqual(siblingPrompt.status, 0, siblingPrompt.stderr)
        let siblingPromptCommands = Array(context.state.commands.dropFirst(siblingPromptStart))
        XCTAssertFalse(
            siblingPromptCommands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.set" },
            "A sibling prompt must stay nested while the depth-only parent remains active, saw \(siblingPromptCommands)"
        )
        XCTAssertFalse(
            siblingPromptCommands.contains { $0.hasPrefix("set_status codex Running ") },
            "A sibling prompt must not rewrite parent Running status while the depth-only parent remains active, saw \(siblingPromptCommands)"
        )

        let siblingStopStart = context.state.commands.count
        let siblingStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"sibling-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"Stop","last_assistant_message":"sibling done"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(siblingStop.timedOut, siblingStop.stderr)
        XCTAssertEqual(siblingStop.status, 0, siblingStop.stderr)
        let siblingStopCommands = Array(context.state.commands.dropFirst(siblingStopStart))
        XCTAssertFalse(
            siblingStopCommands.contains { $0.hasPrefix("notify_target") || $0.hasPrefix("set_status codex ") },
            "A sibling Stop must stay nested while the depth-only parent remains active, saw \(siblingStopCommands)"
        )
    }

    func testCodexDepthOnlyTerminalHistoryDoesNotResetUnknownActiveDepth() throws {
        let context = try makeClaudeHookContext(name: "codex-depth-only-terminal-history")
        defer { context.cleanup() }

        let sessionId = "depth-only-terminal-history-session"
        let transcriptURL = context.root.appendingPathComponent("codex-depth-only-terminal-history.jsonl")
        try [
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"old-parent-turn"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"old-child-turn"}}"#,
            #"{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"old-child-turn"}}"#,
            #"{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"old-parent-turn"}}"#,
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
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted])
            .write(to: stateURL, options: .atomic)

        let launchEnvironment = codexLaunchEnvironment(context: context, sessionId: sessionId)
        startAgentHookMockServerAccepting(context: context, connectionLimit: 32)

        let childPromptStart = context.state.commands.count
        let childPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"child-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"UserPromptSubmit","prompt":"child"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(childPrompt.timedOut, childPrompt.stderr)
        XCTAssertEqual(childPrompt.status, 0, childPrompt.stderr)
        let childPromptCommands = Array(context.state.commands.dropFirst(childPromptStart))
        XCTAssertFalse(
            childPromptCommands.contains { (self.jsonObject($0)?["method"] as? String)?.hasPrefix("surface.resume.") == true },
            "Terminal history alone must not make unknown depth-only active prompts look finished, saw \(childPromptCommands)"
        )
        XCTAssertFalse(
            childPromptCommands.contains { $0.hasPrefix("set_status codex Running ") },
            "Terminal history alone must not let the child rewrite parent Running status, saw \(childPromptCommands)"
        )

        let childStopStart = context.state.commands.count
        let childStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"child-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"Stop","last_assistant_message":"child done"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(childStop.timedOut, childStop.stderr)
        XCTAssertEqual(childStop.status, 0, childStop.stderr)
        let childStopCommands = Array(context.state.commands.dropFirst(childStopStart))
        XCTAssertFalse(
            childStopCommands.contains { $0.hasPrefix("notify_target") || $0.hasPrefix("set_status codex ") },
            "Terminal history alone must not let a child Stop notify while unknown depth remains, saw \(childStopCommands)"
        )
    }

}
