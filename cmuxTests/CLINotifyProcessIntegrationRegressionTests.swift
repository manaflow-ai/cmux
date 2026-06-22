import Darwin
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
final class CLINotifyProcessIntegrationRegressionTests {
    private var teardownBlocks: [() -> Void] = []

    deinit {
        for block in teardownBlocks.reversed() {
            block()
        }
    }

    private func addTeardownBlock(_ block: @escaping () -> Void) {
        teardownBlocks.append(block)
    }

    @Test
    func testClaudeClearSessionStartMarksWorkspaceRunning() throws {
        let context = try makeClaudeHookContext(name: "claude-clear-running")
        defer { context.cleanup() }

        let result = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "session-start"],
            standardInput: #"{"session_id":"clear-session","source":"clear","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        )

        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertEqual(result.stdout, "OK\n")
        legacyAssertTrue(
            context.state.commands.contains { $0 == "clear_notifications --tab=\(context.workspaceId)" },
            "Expected clear SessionStart to clear stale notifications, saw \(context.state.commands)"
        )
        legacyAssertTrue(
            context.state.commands.contains {
                $0.hasPrefix("set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab=\(context.workspaceId)")
                    && $0.contains("--panel=\(context.surfaceId)")
            },
            "Expected clear SessionStart to mark Claude running, saw \(context.state.commands)"
        )
    }

    @Test
    func testClaudeSessionStartRecordIsNotRestorableUntilPrompt() throws {
        let context = try makeClaudeHookContext(name: "claude-session-restorable")
        defer { context.cleanup() }

        let sessionId = "startup-only-session"
        let start = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "session-start"],
            standardInput: #"{"session_id":"\#(sessionId)","source":"startup","cwd":"\#(context.root.path)","transcript_path":"\#(context.root.path)/projects/startup-only-session.jsonl","hook_event_name":"SessionStart"}"#
        )
        legacyAssertFalse(start.timedOut, start.stderr)
        legacyAssertEqual(start.status, 0, start.stderr)

        var record = try readClaudeHookSession(sessionId, context: context)
        legacyAssertEqual(
            record["isRestorable"] as? Bool,
            false,
            "Startup SessionStart records are only routing state until Claude creates a conversation."
        )
        legacyAssertEqual(
            record["transcriptPath"] as? String,
            "\(context.root.path)/projects/startup-only-session.jsonl"
        )

        let prompt = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "prompt-submit"],
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","cwd":"\#(context.root.path)","transcript_path":"\#(context.root.path)/projects/startup-only-session.jsonl","hook_event_name":"UserPromptSubmit"}"#
        )
        legacyAssertFalse(prompt.timedOut, prompt.stderr)
        legacyAssertEqual(prompt.status, 0, prompt.stderr)

        record = try readClaudeHookSession(sessionId, context: context)
        legacyAssertEqual(
            record["isRestorable"] as? Bool,
            true,
            "UserPromptSubmit marks the session eligible for resume."
        )
    }

    @Test
    func testClaudePreToolUseFeedContextReadsOnlyRecentTranscriptTail() throws {
        let context = try makeClaudeHookContext(name: "claude-pretool-tail")
        defer { context.cleanup() }

        let transcriptURL = context.root.appendingPathComponent("large-claude-session.jsonl")
        _ = FileManager.default.createFile(atPath: transcriptURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: transcriptURL)

        func writeLine(_ line: String) throws {
            try handle.write(contentsOf: Data((line + "\n").utf8))
        }

        try writeLine(#"{"type":"user","message":{"role":"user","content":"ancient user message"}}"#)
        try writeLine(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ancient assistant response"},{"type":"tool_use","name":"Bash","input":{"command":"echo old"}}]}}"#)
        let fillerPayload = String(repeating: "x", count: 1_200)
        for _ in 0..<1_200 {
            try writeLine(#"{"type":"user","message":{"role":"user","content":"\#(fillerPayload)"}}"#)
        }
        try writeLine(#"{"type":"user","message":{"role":"user","content":"recent user message"}}"#)
        try writeLine(#"{"type":"assistant","message":{"role":"assistant","content":"recent assistant response"}}"#)
        try handle.close()

        let result = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "pre-tool-use"],
            standardInput: #"{"session_id":"tail-session","turn_id":"turn-1","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo recent"}}"#
        )

        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        let preToolEvent = try legacyUnwrap(
            feedPushEvents(in: context).last { $0["hook_event_name"] as? String == "PreToolUse" }
        )
        let feedContext = try legacyUnwrap(preToolEvent["context"] as? [String: Any])
        legacyAssertEqual(feedContext["lastUserMessage"] as? String, "recent user message")
        legacyAssertEqual(feedContext["assistantPreamble"] as? String, "recent assistant response")
        legacyAssertFalse(String(describing: feedContext).contains("ancient"), "\(feedContext)")
    }

    @Test
    func testClaudePreToolUseFeedContextKeepsOversizedFinalTranscriptLine() throws {
        let context = try makeClaudeHookContext(name: "claude-pretool-oversized-final")
        defer { context.cleanup() }

        let transcriptURL = context.root.appendingPathComponent("oversized-final-claude-session.jsonl")
        _ = FileManager.default.createFile(atPath: transcriptURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: transcriptURL)
        defer { try? handle.close() }

        try handle.write(contentsOf: Data(#"{"type":"user","message":{"role":"user","content":"ancient user message"}}"#.utf8))
        try handle.write(contentsOf: Data("\n".utf8))
        let longAssistantText = "recent assistant response " + String(repeating: "r", count: 1_100_000)
        let finalLine = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(longAssistantText)"},{"type":"tool_use","name":"Bash","input":{"command":"echo huge"}}]}}"#
        try handle.write(contentsOf: Data(finalLine.utf8))
        try handle.close()

        let result = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "pre-tool-use"],
            standardInput: #"{"session_id":"oversized-final-session","turn_id":"turn-1","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo huge"}}"#
        )

        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        let preToolEvent = try legacyUnwrap(
            feedPushEvents(in: context).last { $0["hook_event_name"] as? String == "PreToolUse" }
        )
        let feedContext = try legacyUnwrap(preToolEvent["context"] as? [String: Any])
        let assistantPreamble = try legacyUnwrap(feedContext["assistantPreamble"] as? String)
        legacyAssertTrue(assistantPreamble.hasPrefix("recent assistant response"), "\(feedContext)")
    }

    @Test
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

        legacyAssertFalse(stop.timedOut, stop.stderr)
        legacyAssertEqual(stop.status, 0, stop.stderr)
        legacyAssertTrue(
            context.state.commands.contains { command in
                command.contains("notify_target_async \(context.workspaceId) \(context.surfaceId) Codex|Error|Codex ended before sending a final response")
            },
            "Expected Codex to parse the oversized final transcript line, saw \(context.state.commands)"
        )
    }

    @Test
    func testCodexPromptSubmitDoesNotRefreshTerminalLastTurnDiffBaseline() throws {
        let context = try makeClaudeHookContext(name: "codex-prompt-baseline")
        defer { context.cleanup() }

        let storyURL = context.root.appendingPathComponent("story.txt")
        func runGit(_ arguments: [String]) throws -> String {
            let result = runProcess(
                executablePath: "/usr/bin/env",
                arguments: ["git", "-C", context.root.path] + arguments,
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
                timeout: 10
            )
            legacyAssertFalse(result.timedOut, result.stderr)
            legacyAssertEqual(result.status, 0, result.stderr)
            guard result.status == 0 else {
                throw NSError(domain: "CLINotifyProcessIntegrationRegressionTests.git", code: Int(result.status))
            }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func baselineRecords() throws -> [[String: Any]] {
            let storeURL = context.root.appendingPathComponent("agent-turn-diff-baselines.json")
            let store = try legacyUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
            return try legacyUnwrap(store["records"] as? [[String: Any]])
        }

        _ = try runGit(["init"])
        _ = try runGit(["checkout", "-b", "main"])
        _ = try runGit(["config", "user.name", "cmux tests"])
        _ = try runGit(["config", "user.email", "cmux@example.invalid"])
        try "one\n".write(to: storyURL, atomically: true, encoding: .utf8)
        _ = try runGit(["add", "story.txt"])
        _ = try runGit(["commit", "-m", "initial"])
        let initialCommit = try runGit(["rev-parse", "HEAD"])

        startAgentHookMockServerAccepting(context: context, connectionLimit: 32)
        let sessionId = "codex-last-turn-session"
        let sessionStart = runCodexHook(
            context: context,
            subcommand: "session-start",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-0","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            extraEnvironment: codexLaunchEnvironment(context: context, sessionId: sessionId)
        )
        legacyAssertFalse(sessionStart.timedOut, sessionStart.stderr)
        legacyAssertEqual(sessionStart.status, 0, sessionStart.stderr)

        try "one\ntwo\n".write(to: storyURL, atomically: true, encoding: .utf8)
        _ = try runGit(["add", "story.txt"])
        _ = try runGit(["commit", "-m", "add two"])
        let promptCommit = try runGit(["rev-parse", "HEAD"])

        let promptSubmit = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit"}"#,
            extraEnvironment: codexLaunchEnvironment(context: context, sessionId: sessionId)
        )
        legacyAssertFalse(promptSubmit.timedOut, promptSubmit.stderr)
        legacyAssertEqual(promptSubmit.status, 0, promptSubmit.stderr)

        let records = try baselineRecords()
        let startRecord = try legacyUnwrap(records.first { $0["turnId"] as? String == "turn-0" })
        let promptRecord = try legacyUnwrap(records.first { $0["turnId"] as? String == "turn-1" })
        legacyAssertEqual(startRecord["baseCommit"] as? String, initialCommit)
        legacyAssertEqual(promptRecord["baseCommit"] as? String, promptCommit)
        legacyAssertEqual(promptRecord["workspaceId"] as? String, context.workspaceId)
        legacyAssertEqual(promptRecord["surfaceId"] as? String, context.surfaceId)

        try "one\ntwo\nnested\n".write(to: storyURL, atomically: true, encoding: .utf8)
        _ = try runGit(["add", "story.txt"])
        _ = try runGit(["commit", "-m", "nested child change"])
        let childPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"child-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit"}"#,
            extraEnvironment: codexLaunchEnvironment(context: context, sessionId: sessionId)
        )
        legacyAssertFalse(childPrompt.timedOut, childPrompt.stderr)
        legacyAssertEqual(childPrompt.status, 0, childPrompt.stderr)

        let childRecords = try baselineRecords()
        legacyAssertNil(
            childRecords.first { $0["turnId"] as? String == "child-turn" },
            "Nested Codex prompts should not create a last-turn diff baseline."
        )
        let parentRecordAfterChild = try legacyUnwrap(childRecords.first { $0["turnId"] as? String == "turn-1" })
        legacyAssertEqual(parentRecordAfterChild["baseCommit"] as? String, promptCommit)

        let childStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"child-turn","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"child done"}"#,
            extraEnvironment: codexLaunchEnvironment(context: context, sessionId: sessionId)
        )
        legacyAssertFalse(childStop.timedOut, childStop.stderr)
        legacyAssertEqual(childStop.status, 0, childStop.stderr)

        let parentStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"parent done"}"#,
            extraEnvironment: codexLaunchEnvironment(context: context, sessionId: sessionId)
        )
        legacyAssertFalse(parentStop.timedOut, parentStop.stderr)
        legacyAssertEqual(parentStop.status, 0, parentStop.stderr)

        try "one\ntwo\nthree\n".write(to: storyURL, atomically: true, encoding: .utf8)
        let dirtyPromptSubmit = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit"}"#,
            extraEnvironment: codexLaunchEnvironment(context: context, sessionId: sessionId)
        )
        legacyAssertFalse(dirtyPromptSubmit.timedOut, dirtyPromptSubmit.stderr)
        legacyAssertEqual(dirtyPromptSubmit.status, 0, dirtyPromptSubmit.stderr)

        let dirtyRecords = try baselineRecords()
        let dirtyRecord = try legacyUnwrap(dirtyRecords.first { $0["turnId"] as? String == "turn-1" })
        let dirtyBaseCommit = try legacyUnwrap(dirtyRecord["baseCommit"] as? String)
        legacyAssertEqual(dirtyBaseCommit, promptCommit)

        let dirtyStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"dirty done"}"#,
            extraEnvironment: codexLaunchEnvironment(context: context, sessionId: sessionId)
        )
        legacyAssertFalse(dirtyStop.timedOut, dirtyStop.stderr)
        legacyAssertEqual(dirtyStop.status, 0, dirtyStop.stderr)

        try "one\ntwo\nthree\nfour\n".write(to: storyURL, atomically: true, encoding: .utf8)
        let refreshedDirtyPromptSubmit = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit"}"#,
            extraEnvironment: codexLaunchEnvironment(context: context, sessionId: sessionId)
        )
        legacyAssertFalse(refreshedDirtyPromptSubmit.timedOut, refreshedDirtyPromptSubmit.stderr)
        legacyAssertEqual(refreshedDirtyPromptSubmit.status, 0, refreshedDirtyPromptSubmit.stderr)

        let refreshedRecords = try baselineRecords()
        let refreshedRecord = try legacyUnwrap(refreshedRecords.first { $0["turnId"] as? String == "turn-1" })
        let refreshedBaseCommit = try legacyUnwrap(refreshedRecord["baseCommit"] as? String)
        legacyAssertEqual(refreshedBaseCommit, dirtyBaseCommit)
        legacyAssertEqual(refreshedBaseCommit, promptCommit)
    }

    @Test
    func testClaudeStopFromPreviousSessionDoesNotClobberClearRunningStatus() throws {
        let context = try makeClaudeHookContext(name: "claude-clear-stale-stop")
        defer { context.cleanup() }

        let oldStart = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "session-start"],
            standardInput: #"{"session_id":"old-session","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        )
        legacyAssertFalse(oldStart.timedOut, oldStart.stderr)
        legacyAssertEqual(oldStart.status, 0, oldStart.stderr)

        let clearStart = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "session-start"],
            standardInput: #"{"session_id":"clear-session","source":"clear","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        )
        legacyAssertFalse(clearStart.timedOut, clearStart.stderr)
        legacyAssertEqual(clearStart.status, 0, clearStart.stderr)

        let lateOldStart = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "session-start"],
            standardInput: #"{"session_id":"old-session","source":"startup","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        )
        legacyAssertFalse(lateOldStart.timedOut, lateOldStart.stderr)
        legacyAssertEqual(lateOldStart.status, 0, lateOldStart.stderr)

        let staleStop = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "stop"],
            standardInput: #"{"session_id":"old-session","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"old turn finished late"}"#
        )
        legacyAssertFalse(staleStop.timedOut, staleStop.stderr)
        legacyAssertEqual(staleStop.status, 0, staleStop.stderr)

        legacyAssertTrue(
            context.state.commands.contains {
                $0.hasPrefix("set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab=\(context.workspaceId)")
                    && $0.contains("--panel=\(context.surfaceId)")
            },
            "Expected clear SessionStart to mark Claude running, saw \(context.state.commands)"
        )
        legacyAssertFalse(
            context.state.commands.contains {
                $0.hasPrefix("set_status claude_code Idle ") && $0.contains("--tab=\(context.workspaceId)")
            },
            "Expected stale Stop from old session not to clobber the clear session, saw \(context.state.commands)"
        )
        let resumeBindingRequests = context.state.commands.compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.set" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        legacyAssertEqual(resumeBindingRequests.count, 1, context.state.commands.joined(separator: "\n"))
        legacyAssertEqual(resumeBindingRequests.first?["checkpoint_id"] as? String, "clear-session")
        legacyAssertEqual(resumeBindingRequests.first?["auto_resume"] as? Bool, true)
    }

    @Test
    func testClaudePromptSubmitFromNewSessionCanReplaceStoppedSession() throws {
        let context = try makeClaudeHookContext(name: "claude-new-session-after-stop")
        defer { context.cleanup() }

        let oldStart = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "session-start"],
            standardInput: #"{"session_id":"old-session","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        )
        legacyAssertFalse(oldStart.timedOut, oldStart.stderr)
        legacyAssertEqual(oldStart.status, 0, oldStart.stderr)

        let oldPrompt = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "prompt-submit"],
            standardInput: #"{"session_id":"old-session","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"PromptSubmit"}"#
        )
        legacyAssertFalse(oldPrompt.timedOut, oldPrompt.stderr)
        legacyAssertEqual(oldPrompt.status, 0, oldPrompt.stderr)

        let oldStop = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "stop"],
            standardInput: #"{"session_id":"old-session","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"old turn finished"}"#
        )
        legacyAssertFalse(oldStop.timedOut, oldStop.stderr)
        legacyAssertEqual(oldStop.status, 0, oldStop.stderr)

        let newStart = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "session-start"],
            standardInput: #"{"session_id":"new-session","source":"startup","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        )
        legacyAssertFalse(newStart.timedOut, newStart.stderr)
        legacyAssertEqual(newStart.status, 0, newStart.stderr)

        let newPromptStart = context.state.commands.count
        let newPrompt = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "prompt-submit"],
            standardInput: #"{"session_id":"new-session","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"PromptSubmit"}"#
        )
        legacyAssertFalse(newPrompt.timedOut, newPrompt.stderr)
        legacyAssertEqual(newPrompt.status, 0, newPrompt.stderr)

        let newPromptCommands = Array(context.state.commands.dropFirst(newPromptStart))
        legacyAssertTrue(
            newPromptCommands.contains {
                $0.hasPrefix("set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab=\(context.workspaceId)")
            },
            "Expected a new Claude session to replace a stopped idle owner on prompt-submit, saw \(newPromptCommands)"
        )
    }

    // MARK: - Forked conversation restore (https://github.com/manaflow-ai/cmux/issues/5908)
    //
    // `claude --resume <parent> --fork-session` fires SessionStart with the PARENT
    // session id; the forked session id is only minted at the first UserPromptSubmit.
    // Without special handling the fork pane's SessionStart steals the parent record's
    // surface binding, and the forked session's own hooks are dropped as stale by the
    // per-workspace active-session gate, so a restart restores the parent conversation
    // in the fork pane and the forked conversation is lost.

    private func claudeForkLaunchEnvironment(
        context: ClaudeHookContext,
        parentSessionId: String
    ) -> [String: String] {
        agentLaunchEnvironment(
            context: context,
            kind: "claude",
            executable: "/usr/local/bin/claude",
            arguments: ["/usr/local/bin/claude", "--resume", parentSessionId, "--fork-session"]
        )
    }

    private func seedClaudeForkHookStore(
        context: ClaudeHookContext,
        parentSessionId: String,
        parentSurfaceId: String,
        forkedSessionId: String? = nil,
        forkedSurfaceId: String? = nil,
        activeSessionId: String,
        activeTurnId: String?
    ) throws {
        let now = Date().timeIntervalSince1970
        var sessions: [String: Any] = [
            parentSessionId: [
                "sessionId": parentSessionId,
                "workspaceId": context.workspaceId,
                "surfaceId": parentSurfaceId,
                "cwd": context.root.path,
                "agentLifecycle": "running",
                "startedAt": now,
                "updatedAt": now,
            ],
        ]
        if let forkedSessionId, let forkedSurfaceId {
            sessions[forkedSessionId] = [
                "sessionId": forkedSessionId,
                "workspaceId": context.workspaceId,
                "surfaceId": forkedSurfaceId,
                "cwd": context.root.path,
                "agentLifecycle": "running",
                "startedAt": now,
                "updatedAt": now,
            ]
        }
        var active: [String: Any] = [
            "sessionId": activeSessionId,
            "updatedAt": now,
        ]
        if let activeTurnId {
            active["turnId"] = activeTurnId
        }
        let store: [String: Any] = [
            "version": 1,
            "sessions": sessions,
            "activeSessionsByWorkspace": [context.workspaceId: active],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted])
            .write(
                to: context.root.appendingPathComponent("claude-hook-sessions.json"),
                options: .atomic
            )
    }

    /// Multi-connection mock server for tests that invoke several hooks in one
    /// scenario; pair with `runClaudeHookWithoutServer`. The per-call
    /// `runClaudeHookListingSurfaces` server accepts a single connection, which
    /// deadlocks sequences once any CLI invocation opens more than one.
    private func startClaudeHookMockServerAccepting(
        context: ClaudeHookContext,
        surfaceIds: [String],
        connectionLimit: Int
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var accepted = 0
            while accepted < connectionLimit {
                var clientAddr = sockaddr_un()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.accept(context.listenerFD, sockaddrPtr, &clientAddrLen)
                    }
                }
                if clientFD < 0 {
                    if errno == EINTR { continue }
                    return
                }
                accepted += 1

                DispatchQueue.global(qos: .userInitiated).async {
                    defer { Darwin.close(clientFD) }
                    var pending = Data()
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let count = Darwin.read(clientFD, &buffer, buffer.count)
                        if count < 0 {
                            if errno == EINTR { continue }
                            return
                        }
                        if count == 0 { return }
                        pending.append(buffer, count: count)
                        while let newlineRange = pending.firstRange(of: Data([0x0A])) {
                            let lineData = pending.subdata(in: 0..<newlineRange.lowerBound)
                            pending.removeSubrange(0...newlineRange.lowerBound)
                            guard let line = String(data: lineData, encoding: .utf8) else { continue }
                            context.state.append(line)
                            let response = self.claudeHookMockResponse(line: line, surfaceIds: surfaceIds) + "\n"
                            _ = response.withCString { ptr in
                                Darwin.write(clientFD, ptr, strlen(ptr))
                            }
                        }
                    }
                }
            }
        }
    }

    private func claudeHookMockResponse(line: String, surfaceIds: [String]) -> String {
        guard let payload = jsonObject(line) else {
            return "OK"
        }
        guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
            return malformedRequestResponse(id: payload["id"] as? String, raw: line)
        }
        switch method {
        case "surface.list":
            return v2Response(
                id: id,
                ok: true,
                result: [
                    "surfaces": surfaceIds.enumerated().map { index, surfaceId in
                        ["id": surfaceId, "ref": "surface:\(index + 1)", "focused": index == 0] as [String: Any]
                    }
                ]
            )
        case "feed.push":
            return v2Response(id: id, ok: true, result: [:])
        case "surface.resume.set":
            return v2Response(id: id, ok: true, result: ["resume_binding": [:]])
        case "surface.resume.clear":
            return v2Response(id: id, ok: true, result: ["cleared": true])
        default:
            return v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
        }
    }

    private func runClaudeHookWithoutServer(
        context: ClaudeHookContext,
        arguments: [String],
        standardInput: String,
        extraEnvironment: [String: String] = [:]
    ) -> ProcessRunResult {
        var environment = [
            "HOME": context.root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_SOCKET_PATH": context.socketPath,
            "CMUX_WORKSPACE_ID": context.workspaceId,
            "CMUX_SURFACE_ID": context.surfaceId,
            "CMUX_CLAUDE_HOOK_STATE_PATH": context.root.appendingPathComponent("claude-hook-sessions.json").path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
        ]
        for (key, value) in extraEnvironment {
            environment[key] = value
        }
        return runProcess(
            executablePath: context.cliPath,
            arguments: arguments,
            environment: environment,
            standardInput: standardInput,
            timeout: 5
        )
    }

    private func runClaudeHookListingSurfaces(
        context: ClaudeHookContext,
        surfaceIds: [String],
        arguments: [String],
        standardInput: String,
        extraEnvironment: [String: String] = [:]
    ) -> ProcessRunResult {
        let serverHandled = startMockServer(listenerFD: context.listenerFD, state: context.state) { line in
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
                        "surfaces": surfaceIds.enumerated().map { index, surfaceId in
                            ["id": surfaceId, "ref": "surface:\(index + 1)", "focused": index == 0] as [String: Any]
                        }
                    ]
                )
            case "feed.push":
                return self.v2Response(id: id, ok: true, result: [:])
            case "surface.resume.set":
                return self.v2Response(id: id, ok: true, result: ["resume_binding": [:]])
            case "surface.resume.clear":
                return self.v2Response(id: id, ok: true, result: ["cleared": true])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        var environment = [
            "HOME": context.root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_SOCKET_PATH": context.socketPath,
            "CMUX_WORKSPACE_ID": context.workspaceId,
            "CMUX_SURFACE_ID": context.surfaceId,
            "CMUX_CLAUDE_HOOK_STATE_PATH": context.root.appendingPathComponent("claude-hook-sessions.json").path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
        ]
        for (key, value) in extraEnvironment {
            environment[key] = value
        }

        let result = runProcess(
            executablePath: context.cliPath,
            arguments: arguments,
            environment: environment,
            standardInput: standardInput,
            timeout: 5
        )
        legacyWait(for: [serverHandled], timeout: 5)
        return result
    }

    @Test
    func testClaudeForkSessionStartKeepsParentSessionBoundToOriginalSurface() throws {
        let context = try makeClaudeHookContext(name: "claude-fork-session-start")
        defer { context.cleanup() }

        let parentSessionId = "parent-session"
        let parentSurfaceId = "99999999-9999-9999-9999-999999999999"
        try seedClaudeForkHookStore(
            context: context,
            parentSessionId: parentSessionId,
            parentSurfaceId: parentSurfaceId,
            activeSessionId: parentSessionId,
            activeTurnId: "parent-turn-1"
        )

        let result = runClaudeHookListingSurfaces(
            context: context,
            surfaceIds: [parentSurfaceId, context.surfaceId],
            arguments: ["hooks", "claude", "session-start"],
            standardInput: #"{"session_id":"\#(parentSessionId)","source":"resume","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            extraEnvironment: claudeForkLaunchEnvironment(context: context, parentSessionId: parentSessionId)
        )
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)

        let parentRecord = try readClaudeHookSession(parentSessionId, context: context)
        legacyAssertEqual(
            parentRecord["surfaceId"] as? String,
            parentSurfaceId,
            "Fork-session SessionStart reports the parent session id and must not steal the parent record's surface binding for the fork pane"
        )
    }

    @Test
    func testClaudeForkSessionStartWithoutSurfaceIdentityDoesNotRegisterPIDOnFallbackPane() throws {
        let context = try makeClaudeHookContext(name: "claude-fork-no-surface")
        defer { context.cleanup() }

        let parentSessionId = "parent-session"
        let parentSurfaceId = "99999999-9999-9999-9999-999999999999"
        try seedClaudeForkHookStore(
            context: context,
            parentSessionId: parentSessionId,
            parentSurfaceId: parentSurfaceId,
            activeSessionId: parentSessionId,
            activeTurnId: nil
        )

        // No surface identity: resolution falls back to the focused surface,
        // which is some other pane. The fork's PID must not be registered
        // there — the matching SessionEnd cleanup only clears authoritative
        // surfaces, so a fallback registration would never be cleared.
        var environment = claudeForkLaunchEnvironment(context: context, parentSessionId: parentSessionId)
        environment["CMUX_SURFACE_ID"] = ""
        environment["CMUX_CLAUDE_PID"] = "12345"
        let result = runClaudeHookListingSurfaces(
            context: context,
            surfaceIds: [parentSurfaceId, context.surfaceId],
            arguments: ["hooks", "claude", "session-start"],
            standardInput: #"{"session_id":"\#(parentSessionId)","source":"resume","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            extraEnvironment: environment
        )
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)

        legacyAssertFalse(
            context.state.commands.contains { $0.hasPrefix("set_agent_pid claude_code ") },
            "A fork SessionStart without an authoritative surface must not register its PID on a borrowed fallback pane, saw \(context.state.commands)"
        )
    }

    @Test
    func testClaudeForkSessionStartRecognizesEqualsFlagForm() throws {
        let context = try makeClaudeHookContext(name: "claude-fork-equals-form")
        defer { context.cleanup() }

        let parentSessionId = "parent-session"
        let parentSurfaceId = "99999999-9999-9999-9999-999999999999"
        try seedClaudeForkHookStore(
            context: context,
            parentSessionId: parentSessionId,
            parentSurfaceId: parentSurfaceId,
            activeSessionId: parentSessionId,
            activeTurnId: "parent-turn-1"
        )

        let result = runClaudeHookListingSurfaces(
            context: context,
            surfaceIds: [parentSurfaceId, context.surfaceId],
            arguments: ["hooks", "claude", "session-start"],
            standardInput: #"{"session_id":"\#(parentSessionId)","source":"resume","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            extraEnvironment: agentLaunchEnvironment(
                context: context,
                kind: "claude",
                executable: "/usr/local/bin/claude",
                arguments: ["/usr/local/bin/claude", "--resume", parentSessionId, "--fork-session=true"]
            )
        )
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)

        let parentRecord = try readClaudeHookSession(parentSessionId, context: context)
        legacyAssertEqual(
            parentRecord["surfaceId"] as? String,
            parentSurfaceId,
            "Fork detection must recognize the --fork-session=true flag form the launch sanitizer already accepts"
        )
    }

    @Test
    func testClaudeLegacyStoreBackfillsPaneBoundaryFromWorkspaceActiveSlot() throws {
        let context = try makeClaudeHookContext(name: "claude-legacy-backfill")
        defer { context.cleanup() }

        let paneA = "99999999-9999-9999-9999-999999999999"
        let paneB = context.surfaceId
        let now = Date().timeIntervalSince1970
        // A store written before per-surface tracking: pane A's current
        // session-2 holds the workspace slot; stale session-1 also lives in
        // pane A; no activeSessionsBySurface key at all.
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                "session-1": [
                    "sessionId": "session-1",
                    "workspaceId": context.workspaceId,
                    "surfaceId": paneA,
                    "cwd": context.root.path,
                    "agentLifecycle": "running",
                    "startedAt": now,
                    "updatedAt": now,
                ],
                "session-2": [
                    "sessionId": "session-2",
                    "workspaceId": context.workspaceId,
                    "surfaceId": paneA,
                    "cwd": context.root.path,
                    "agentLifecycle": "running",
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
            "activeSessionsByWorkspace": [
                context.workspaceId: [
                    "sessionId": "session-2",
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted])
            .write(
                to: context.root.appendingPathComponent("claude-hook-sessions.json"),
                options: .atomic
            )

        startClaudeHookMockServerAccepting(
            context: context,
            surfaceIds: [paneA, paneB],
            connectionLimit: 32
        )

        // Pane B takes the workspace-active slot under the new code…
        let paneBPrompt = runClaudeHookWithoutServer(
            context: context,
            arguments: ["hooks", "claude", "prompt-submit"],
            standardInput: #"{"session_id":"session-3","turn_id":"turn-3","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"three"}"#,
            extraEnvironment: ["CMUX_SURFACE_ID": paneB]
        )
        legacyAssertFalse(paneBPrompt.timedOut, paneBPrompt.stderr)
        legacyAssertEqual(paneBPrompt.status, 0, paneBPrompt.stderr)

        // …then a late Stop from stale session-1 in pane A must stay stale:
        // the pane boundary (session-2 owns pane A) has to survive the upgrade
        // via backfill from the legacy workspace slot.
        let lateStop = runClaudeHookWithoutServer(
            context: context,
            arguments: ["hooks", "claude", "stop"],
            standardInput: #"{"session_id":"session-1","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"late"}"#,
            extraEnvironment: ["CMUX_SURFACE_ID": paneA]
        )
        legacyAssertFalse(lateStop.timedOut, lateStop.stderr)
        legacyAssertEqual(lateStop.status, 0, lateStop.stderr)

        let staleRecord = try readClaudeHookSession("session-1", context: context)
        legacyAssertEqual(
            staleRecord["agentLifecycle"] as? String,
            "running",
            "A legacy store must backfill the pane boundary so pre-upgrade stale sessions stay stale after another pane promotes"
        )
    }

    @Test
    func testClaudeForkedSessionPromptSubmitRecordsWhileParentTurnActive() throws {
        let context = try makeClaudeHookContext(name: "claude-fork-prompt-submit")
        defer { context.cleanup() }

        let parentSessionId = "parent-session"
        let parentSurfaceId = "99999999-9999-9999-9999-999999999999"
        let forkedSessionId = "forked-session"
        try seedClaudeForkHookStore(
            context: context,
            parentSessionId: parentSessionId,
            parentSurfaceId: parentSurfaceId,
            activeSessionId: parentSessionId,
            activeTurnId: "parent-turn-1"
        )

        let commandStart = context.state.commands.count
        let result = runClaudeHookListingSurfaces(
            context: context,
            surfaceIds: [parentSurfaceId, context.surfaceId],
            arguments: ["hooks", "claude", "prompt-submit"],
            standardInput: #"{"session_id":"\#(forkedSessionId)","turn_id":"fork-turn-1","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"diverge here"}"#,
            extraEnvironment: claudeForkLaunchEnvironment(context: context, parentSessionId: parentSessionId)
        )
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)

        let forkedRecord = try readClaudeHookSession(forkedSessionId, context: context)
        legacyAssertEqual(
            forkedRecord["surfaceId"] as? String,
            context.surfaceId,
            "The forked session's first prompt-submit must bind the forked session to the fork pane even while the parent session owns the workspace's active turn"
        )
        legacyAssertEqual(
            forkedRecord["isRestorable"] as? Bool,
            true,
            "The forked session must become restorable so a cmux restart resumes the fork, not the parent"
        )

        let promptCommands = Array(context.state.commands.dropFirst(commandStart))
        let resumeBindingRequests = promptCommands.compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.set" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        legacyAssertEqual(resumeBindingRequests.count, 1, promptCommands.joined(separator: "\n"))
        let request = try legacyUnwrap(resumeBindingRequests.first)
        legacyAssertEqual(request["checkpoint_id"] as? String, forkedSessionId)
        legacyAssertEqual(request["surface_id"] as? String, context.surfaceId)
    }

    @Test
    func testClaudeForkSessionEndBeforeFirstPromptDoesNotConsumeParentSession() throws {
        let context = try makeClaudeHookContext(name: "claude-fork-session-end")
        defer { context.cleanup() }

        let parentSessionId = "parent-session"
        let parentSurfaceId = "99999999-9999-9999-9999-999999999999"
        try seedClaudeForkHookStore(
            context: context,
            parentSessionId: parentSessionId,
            parentSurfaceId: parentSurfaceId,
            activeSessionId: parentSessionId,
            activeTurnId: nil
        )

        // Exiting a fork pane before its first prompt fires SessionEnd with the
        // PARENT session id (the forked id is only minted at the first prompt).
        let result = runClaudeHookListingSurfaces(
            context: context,
            surfaceIds: [parentSurfaceId, context.surfaceId],
            arguments: ["hooks", "claude", "session-end"],
            standardInput: #"{"session_id":"\#(parentSessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionEnd"}"#,
            extraEnvironment: claudeForkLaunchEnvironment(context: context, parentSessionId: parentSessionId)
        )
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)

        let parentRecord = try readClaudeHookSession(parentSessionId, context: context)
        legacyAssertEqual(
            parentRecord["surfaceId"] as? String,
            parentSurfaceId,
            "A pre-prompt fork exit must not consume the parent session record the original pane still owns"
        )
        let resumeClearRequests = context.state.commands.compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.clear" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        legacyAssertTrue(
            resumeClearRequests.isEmpty,
            "A pre-prompt fork exit must not clear the parent pane's resume binding, saw \(resumeClearRequests)"
        )
        legacyAssertTrue(
            context.state.commands.contains {
                $0.hasPrefix("clear_agent_pid claude_code ") && $0.contains("--panel=\(context.surfaceId)")
            },
            "A pre-prompt fork exit must still clear the agent PID/status registered for the fork pane, saw \(context.state.commands)"
        )
    }

    @Test
    func testClaudeForkedSessionPromptSubmitRecordsWithSurfaceRefForm() throws {
        let context = try makeClaudeHookContext(name: "claude-fork-surface-ref")
        defer { context.cleanup() }

        let parentSessionId = "parent-session"
        let parentSurfaceId = "99999999-9999-9999-9999-999999999999"
        let forkedSessionId = "forked-session"
        try seedClaudeForkHookStore(
            context: context,
            parentSessionId: parentSessionId,
            parentSurfaceId: parentSurfaceId,
            activeSessionId: parentSessionId,
            activeTurnId: "parent-turn-1"
        )

        // The hook surface may arrive as the documented surface:N ref form
        // rather than a UUID; the staleness gate must treat the resolved UUID
        // as the hook's own surface in that case too.
        let result = runClaudeHookListingSurfaces(
            context: context,
            surfaceIds: [parentSurfaceId, context.surfaceId],
            arguments: ["hooks", "claude", "prompt-submit"],
            standardInput: #"{"session_id":"\#(forkedSessionId)","turn_id":"fork-turn-1","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"diverge here"}"#,
            extraEnvironment: ["CMUX_SURFACE_ID": "surface:2"]
        )
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)

        let forkedRecord = try readClaudeHookSession(forkedSessionId, context: context)
        legacyAssertEqual(
            forkedRecord["surfaceId"] as? String,
            context.surfaceId,
            "A forked session's first prompt-submit must record via the resolved surface when the hook supplies the surface as a ref"
        )
    }

    @Test
    func testClaudeStaleStopFromClosedPaneStaysStaleWhenSurfaceResolutionFallsBack() throws {
        let context = try makeClaudeHookContext(name: "claude-stale-stop-fallback")
        defer { context.cleanup() }

        let staleSessionId = "stale-session"
        let closedSurfaceId = "99999999-9999-9999-9999-999999999999"
        let activeSessionId = "active-session"
        let activeSurfaceId = "88888888-8888-8888-8888-888888888888"
        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                staleSessionId: [
                    "sessionId": staleSessionId,
                    "workspaceId": context.workspaceId,
                    "surfaceId": closedSurfaceId,
                    "cwd": context.root.path,
                    "agentLifecycle": "running",
                    "startedAt": now,
                    "updatedAt": now,
                ],
                activeSessionId: [
                    "sessionId": activeSessionId,
                    "workspaceId": context.workspaceId,
                    "surfaceId": activeSurfaceId,
                    "cwd": context.root.path,
                    "agentLifecycle": "running",
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
            "activeSessionsByWorkspace": [
                context.workspaceId: [
                    "sessionId": activeSessionId,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted])
            .write(
                to: context.root.appendingPathComponent("claude-hook-sessions.json"),
                options: .atomic
            )

        // The stale session's pane is closed: it is not in surface.list, so
        // surface resolution falls back to the focused surface (a third pane).
        // The cross-surface staleness gate must not treat that borrowed pane as
        // the hook's own surface — the late Stop has to stay stale.
        let result = runClaudeHookListingSurfaces(
            context: context,
            surfaceIds: [context.surfaceId, activeSurfaceId],
            arguments: ["hooks", "claude", "stop"],
            standardInput: #"{"session_id":"\#(staleSessionId)","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"late stop"}"#,
            extraEnvironment: ["CMUX_SURFACE_ID": closedSurfaceId]
        )
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)

        let staleRecord = try readClaudeHookSession(staleSessionId, context: context)
        legacyAssertEqual(
            staleRecord["surfaceId"] as? String,
            closedSurfaceId,
            "A stale hook resolved to a fallback surface must not retarget the session record to a pane it never owned"
        )
        legacyAssertEqual(
            staleRecord["agentLifecycle"] as? String,
            "running",
            "A late Stop from a closed pane must stay stale when surface resolution fell back to another pane"
        )
    }

    @Test
    func testClaudeStaleStopStaysStaleAfterAnotherPaneBecomesWorkspaceActive() throws {
        let context = try makeClaudeHookContext(name: "claude-stale-stop-multi-pane")
        defer { context.cleanup() }

        let paneA = "99999999-9999-9999-9999-999999999999"
        let paneB = context.surfaceId
        startClaudeHookMockServerAccepting(
            context: context,
            surfaceIds: [paneA, paneB],
            connectionLimit: 32
        )

        func runHook(_ subcommand: String, stdin: String, surface: String) -> ProcessRunResult {
            runClaudeHookWithoutServer(
                context: context,
                arguments: ["hooks", "claude", subcommand],
                standardInput: stdin,
                extraEnvironment: ["CMUX_SURFACE_ID": surface]
            )
        }

        // Pane A: session-1 runs a turn, stops, and is replaced by session-2
        // (the /clear-replacement boundary for pane A).
        for (subcommand, stdin) in [
            ("prompt-submit", #"{"session_id":"session-1","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"one"}"#),
            ("stop", #"{"session_id":"session-1","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"done"}"#),
            ("prompt-submit", #"{"session_id":"session-2","turn_id":"turn-2","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"two"}"#),
        ] {
            let result = runHook(subcommand, stdin: stdin, surface: paneA)
            legacyAssertFalse(result.timedOut, result.stderr)
            legacyAssertEqual(result.status, 0, result.stderr)
        }

        // Pane B: a different session (e.g. a forked conversation) takes the
        // workspace-active slot.
        let paneBPrompt = runHook(
            "prompt-submit",
            stdin: #"{"session_id":"session-3","turn_id":"turn-3","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"three"}"#,
            surface: paneB
        )
        legacyAssertFalse(paneBPrompt.timedOut, paneBPrompt.stderr)
        legacyAssertEqual(paneBPrompt.status, 0, paneBPrompt.stderr)

        // A late Stop from the superseded session-1 in pane A must stay stale
        // even though the workspace-active session now lives in pane B.
        let lateStop = runHook(
            "stop",
            stdin: #"{"session_id":"session-1","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"late"}"#,
            surface: paneA
        )
        legacyAssertFalse(lateStop.timedOut, lateStop.stderr)
        legacyAssertEqual(lateStop.status, 0, lateStop.stderr)

        let stateURL = context.root.appendingPathComponent("claude-hook-sessions.json")
        let savedState = try legacyUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        let activeSessions = try legacyUnwrap(savedState["activeSessionsByWorkspace"] as? [String: Any])
        let active = try legacyUnwrap(activeSessions[context.workspaceId] as? [String: Any])
        legacyAssertEqual(
            active["sessionId"] as? String,
            "session-3",
            "A late Stop from a session replaced in its own pane must not re-promote it after another pane became the workspace-active session"
        )
    }

    @Test
    func testClaudeNewSessionReplacesStoppedSessionInPaneAfterAnotherPaneBecameActive() throws {
        let context = try makeClaudeHookContext(name: "claude-replace-multi-pane")
        defer { context.cleanup() }

        let paneA = "99999999-9999-9999-9999-999999999999"
        let paneB = context.surfaceId
        startClaudeHookMockServerAccepting(
            context: context,
            surfaceIds: [paneA, paneB],
            connectionLimit: 32
        )

        func runHook(_ subcommand: String, stdin: String, surface: String) -> ProcessRunResult {
            runClaudeHookWithoutServer(
                context: context,
                arguments: ["hooks", "claude", subcommand],
                standardInput: stdin,
                extraEnvironment: ["CMUX_SURFACE_ID": surface]
            )
        }

        // Pane A: session-1 runs a turn and stops (idle, replacement allowed).
        // Pane B: session-3 (e.g. a forked conversation) takes the
        // workspace-active slot.
        for (subcommand, stdin, surface) in [
            ("prompt-submit", #"{"session_id":"session-1","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"one"}"#, paneA),
            ("stop", #"{"session_id":"session-1","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"done"}"#, paneA),
            ("prompt-submit", #"{"session_id":"session-3","turn_id":"turn-3","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"three"}"#, paneB),
        ] {
            let result = runHook(subcommand, stdin: stdin, surface: surface)
            legacyAssertFalse(result.timedOut, result.stderr)
            legacyAssertEqual(result.status, 0, result.stderr)
        }

        // Pane A: the user starts a fresh Claude session. It must replace the
        // stopped session in its own pane even though the workspace-active
        // session now lives in pane B.
        for (subcommand, stdin) in [
            ("session-start", #"{"session_id":"session-4","source":"startup","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#),
            ("prompt-submit", #"{"session_id":"session-4","turn_id":"turn-4","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"four"}"#),
        ] {
            let result = runHook(subcommand, stdin: stdin, surface: paneA)
            legacyAssertFalse(result.timedOut, result.stderr)
            legacyAssertEqual(result.status, 0, result.stderr)
        }

        let newRecord = try readClaudeHookSession("session-4", context: context)
        legacyAssertEqual(
            newRecord["surfaceId"] as? String,
            paneA,
            "A fresh session in an idle pane must record against its own pane"
        )
        legacyAssertEqual(
            newRecord["isRestorable"] as? Bool,
            true,
            "A fresh session replacing a stopped session in its own pane must not be dropped as stale after another pane became workspace-active"
        )
    }

    @Test
    func testClaudeStaleTurnSessionEndDoesNotConsumeSessionAfterAnotherPaneBecameActive() throws {
        let context = try makeClaudeHookContext(name: "claude-stale-end-multi-pane")
        defer { context.cleanup() }

        let paneA = "99999999-9999-9999-9999-999999999999"
        let paneB = context.surfaceId
        startClaudeHookMockServerAccepting(
            context: context,
            surfaceIds: [paneA, paneB],
            connectionLimit: 32
        )

        func runHook(_ subcommand: String, stdin: String, surface: String) -> ProcessRunResult {
            runClaudeHookWithoutServer(
                context: context,
                arguments: ["hooks", "claude", subcommand],
                standardInput: stdin,
                extraEnvironment: ["CMUX_SURFACE_ID": surface]
            )
        }

        // Pane A: session-1 finishes turn-1 and is mid turn-2. Pane B promotes
        // session-3 into the workspace-active slot.
        for (subcommand, stdin, surface) in [
            ("prompt-submit", #"{"session_id":"session-1","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"one"}"#, paneA),
            ("stop", #"{"session_id":"session-1","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"done"}"#, paneA),
            ("prompt-submit", #"{"session_id":"session-1","turn_id":"turn-2","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"again"}"#, paneA),
            ("prompt-submit", #"{"session_id":"session-3","turn_id":"turn-3","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"three"}"#, paneB),
        ] {
            let result = runHook(subcommand, stdin: stdin, surface: surface)
            legacyAssertFalse(result.timedOut, result.stderr)
            legacyAssertEqual(result.status, 0, result.stderr)
        }

        // A stale SessionEnd for session-1's finished turn-1 must not consume
        // the record while pane A's surface-active turn is turn-2, even though
        // the workspace-active slot now belongs to pane B.
        let staleEnd = runHook(
            "session-end",
            stdin: #"{"session_id":"session-1","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"SessionEnd"}"#,
            surface: paneA
        )
        legacyAssertFalse(staleEnd.timedOut, staleEnd.stderr)
        legacyAssertEqual(staleEnd.status, 0, staleEnd.stderr)

        let record = try readClaudeHookSession("session-1", context: context)
        legacyAssertEqual(
            record["surfaceId"] as? String,
            paneA,
            "A stale turn-mismatched SessionEnd must not consume a session that is still active in its own pane after another pane became workspace-active"
        )
    }

    @Test
    func testClaudeParentPaneStopAppliesAfterForkedSessionPromoted() throws {
        let context = try makeClaudeHookContext(name: "claude-fork-parent-stop")
        defer { context.cleanup() }

        let parentSessionId = "parent-session"
        let parentSurfaceId = "99999999-9999-9999-9999-999999999999"
        let forkedSessionId = "forked-session"
        try seedClaudeForkHookStore(
            context: context,
            parentSessionId: parentSessionId,
            parentSurfaceId: parentSurfaceId,
            forkedSessionId: forkedSessionId,
            forkedSurfaceId: context.surfaceId,
            activeSessionId: forkedSessionId,
            activeTurnId: "fork-turn-1"
        )

        let result = runClaudeHookListingSurfaces(
            context: context,
            surfaceIds: [parentSurfaceId, context.surfaceId],
            arguments: ["hooks", "claude", "stop"],
            standardInput: #"{"session_id":"\#(parentSessionId)","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"parent turn finished"}"#,
            extraEnvironment: ["CMUX_SURFACE_ID": parentSurfaceId]
        )
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)

        let parentRecord = try readClaudeHookSession(parentSessionId, context: context)
        legacyAssertEqual(
            parentRecord["agentLifecycle"] as? String,
            "idle",
            "The parent pane's Stop must keep applying after the forked session became the workspace's active session in another pane"
        )
    }

    @Test
    func testClaudePromptSubmitResumeBindingPersistsSafeAuthSelectionValues() throws {
        let context = try makeClaudeHookContext(name: "claude-resume-env-redaction")
        defer { context.cleanup() }

        let sessionId = "claude-redacted-env-session"
        let launchEnvironment = [
            "CMUX_AGENT_LAUNCH_KIND": "claude",
            "CMUX_AGENT_LAUNCH_EXECUTABLE": "/usr/local/bin/claude",
            "CMUX_AGENT_LAUNCH_CWD": context.root.path,
            "CMUX_AGENT_LAUNCH_ARGV_B64": base64NULSeparated([
                "/usr/local/bin/claude",
                "--model",
                "sonnet",
            ]),
            "ANTHROPIC_API_KEY": "should-not-persist",
            "ANTHROPIC_BASE_URL": "https://api.example.test",
            "ANTHROPIC_MODEL": "claude-sonnet-test",
            "CLAUDE_CONFIG_DIR": context.root.appendingPathComponent("claude-config", isDirectory: true).path,
        ]
        startClaudeHookMockServerAccepting(
            context: context,
            surfaceIds: [context.surfaceId],
            connectionLimit: 5
        )

        let start = runClaudeHookWithoutServer(
            context: context,
            arguments: ["hooks", "claude", "session-start"],
            standardInput: #"{"session_id":"\#(sessionId)","source":"startup","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(start.timedOut, start.stderr)
        legacyAssertEqual(start.status, 0, start.stderr)

        let commandStart = context.state.commands.count
        let prompt = runClaudeHookWithoutServer(
            context: context,
            arguments: ["hooks", "claude", "prompt-submit"],
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(prompt.timedOut, prompt.stderr)
        legacyAssertEqual(prompt.status, 0, prompt.stderr)

        let promptCommands = Array(context.state.commands.dropFirst(commandStart))
        let resumeBindingRequests = promptCommands.compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.set" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        legacyAssertEqual(resumeBindingRequests.count, 1, promptCommands.joined(separator: "\n"))
        let request = try legacyUnwrap(resumeBindingRequests.first)
        legacyAssertEqual(request["auto_resume"] as? Bool, true)
        let environment = try legacyUnwrap(request["environment"] as? [String: Any])
        legacyAssertEqual(environment["CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV"] as? String, "1")
        legacyAssertEqual(
            environment["CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS"] as? String,
            "ANTHROPIC_BASE_URL,ANTHROPIC_MODEL,CLAUDE_CONFIG_DIR"
        )
        legacyAssertNil(environment["ANTHROPIC_API_KEY"])
        legacyAssertEqual(environment["ANTHROPIC_BASE_URL"] as? String, "https://api.example.test")
        legacyAssertEqual(environment["ANTHROPIC_MODEL"] as? String, "claude-sonnet-test")
        legacyAssertEqual(
            environment["CLAUDE_CONFIG_DIR"] as? String,
            context.root.appendingPathComponent("claude-config", isDirectory: true).path
        )
    }

    @Test
    func testClaudeSessionEndChecksConsumedWorkspaceBeforeClearingVisibleState() throws {
        let context = try makeClaudeHookContext(name: "claude-stale-session-end-workspace")
        defer { context.cleanup() }

        let staleWorkspaceId = "33333333-3333-3333-3333-333333333333"
        let activeSurfaceId = "44444444-4444-4444-4444-444444444444"
        let staleSessionId = "stale-session"
        let activeSessionId = "active-session"
        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                staleSessionId: [
                    "sessionId": staleSessionId,
                    "workspaceId": staleWorkspaceId,
                    "surfaceId": context.surfaceId,
                    "cwd": context.root.path,
                    "startedAt": now,
                    "updatedAt": now,
                ],
                activeSessionId: [
                    "sessionId": activeSessionId,
                    "workspaceId": staleWorkspaceId,
                    "surfaceId": activeSurfaceId,
                    "cwd": context.root.path,
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
            "activeSessionsByWorkspace": [
                staleWorkspaceId: [
                    "sessionId": activeSessionId,
                    "updatedAt": now,
                ],
            ],
        ]
        let stateURL = context.root.appendingPathComponent("claude-hook-sessions.json")
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted])
            .write(to: stateURL, options: .atomic)

        let result = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "session-end"],
            standardInput: #"{"cwd":"\#(context.root.path)","hook_event_name":"SessionEnd"}"#
        )

        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertEqual(result.stdout, "OK\n")
        let savedState = try legacyUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        let savedSessions = try legacyUnwrap(savedState["sessions"] as? [String: Any])
        legacyAssertNil(
            savedSessions[staleSessionId],
            "Expected fallback session-end handling to consume the seeded stale session"
        )
        legacyAssertFalse(
            context.state.commands.contains { $0.hasPrefix("clear_status claude_code ") && $0.contains("--tab=\(staleWorkspaceId)") },
            "Expected stale SessionEnd not to clear the consumed workspace, saw \(context.state.commands)"
        )
        legacyAssertFalse(
            context.state.commands.contains { $0.hasPrefix("clear_agent_pid claude_code ") && $0.contains("--tab=\(staleWorkspaceId)") },
            "Expected stale SessionEnd not to clear the consumed workspace PID, saw \(context.state.commands)"
        )
        legacyAssertFalse(
            context.state.commands.contains { $0 == "clear_notifications --tab=\(staleWorkspaceId)" },
            "Expected stale SessionEnd not to clear the consumed workspace notifications, saw \(context.state.commands)"
        )
    }

    @Test
    func testClaudeSessionEndDoesNotConsumeSameSessionStaleTurn() throws {
        let context = try makeClaudeHookContext(name: "claude-stale-session-end-turn")
        defer { context.cleanup() }

        let sessionId = "same-session"
        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": context.workspaceId,
                    "surfaceId": context.surfaceId,
                    "cwd": context.root.path,
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
            "activeSessionsByWorkspace": [
                context.workspaceId: [
                    "sessionId": sessionId,
                    "turnId": "turn-2",
                    "updatedAt": now,
                ],
            ],
        ]
        let stateURL = context.root.appendingPathComponent("claude-hook-sessions.json")
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted])
            .write(to: stateURL, options: .atomic)

        let result = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "session-end"],
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"SessionEnd"}"#
        )

        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertFalse(
            context.state.commands.contains { $0.hasPrefix("clear_agent_pid claude_code ") && $0.contains("--tab=\(context.workspaceId)") },
            "Expected stale same-session turn not to clear current PID, saw \(context.state.commands)"
        )
        legacyAssertFalse(
            context.state.commands.contains { $0 == "clear_notifications --tab=\(context.workspaceId)" },
            "Expected stale same-session turn not to clear current notifications, saw \(context.state.commands)"
        )

        let savedState = try legacyUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        let savedSessions = try legacyUnwrap(savedState["sessions"] as? [String: Any])
        legacyAssertNotNil(
            savedSessions[sessionId],
            "Expected stale same-session SessionEnd not to consume the active session"
        )
        let activeSessions = try legacyUnwrap(savedState["activeSessionsByWorkspace"] as? [String: Any])
        let active = try legacyUnwrap(activeSessions[context.workspaceId] as? [String: Any])
        legacyAssertEqual(active["turnId"] as? String, "turn-2")
    }

    @Test
    func testClaudeSessionEndClearsMatchingSurfaceResumeBinding() throws {
        let context = try makeClaudeHookContext(name: "claude-session-end-resume-clear")
        defer { context.cleanup() }

        let sessionId = "ending-session"
        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": context.workspaceId,
                    "surfaceId": context.surfaceId,
                    "cwd": context.root.path,
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        let stateURL = context.root.appendingPathComponent("claude-hook-sessions.json")
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted])
            .write(to: stateURL, options: .atomic)

        let result = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "session-end"],
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionEnd"}"#
        )

        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        let clearRequests = context.state.commands.compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.clear" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        let request = try legacyUnwrap(clearRequests.first)
        legacyAssertNil(request["workspace_id"])
        legacyAssertEqual(request["surface_id"] as? String, context.surfaceId)
        legacyAssertEqual(request["checkpoint_id"] as? String, sessionId)
        legacyAssertEqual(request["source"] as? String, "agent-hook")
    }

    @Test
    func testNestedCodexPromptAndStopDoNotReplaceParentResumeBinding() throws {
        let context = try makeClaudeHookContext(name: "codex-nested-resume-guard")
        defer { context.cleanup() }

        let sessionId = "same-process-session"
        let launchEnvironment = codexLaunchEnvironment(context: context, sessionId: sessionId)
        startAgentHookMockServerAccepting(context: context, connectionLimit: 32)

        let parentPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"parent-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"spawn subagent"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(parentPrompt.timedOut, parentPrompt.stderr)
        legacyAssertEqual(parentPrompt.status, 0, parentPrompt.stderr)
        legacyAssertTrue(
            context.state.commands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.set" },
            "Parent Codex prompt should publish a resume binding, saw \(context.state.commands)"
        )

        let childPromptStart = context.state.commands.count
        let childPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"child-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"return 1+1"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(childPrompt.timedOut, childPrompt.stderr)
        legacyAssertEqual(childPrompt.status, 0, childPrompt.stderr)
        let childPromptCommands = Array(context.state.commands.dropFirst(childPromptStart))
        legacyAssertFalse(
            childPromptCommands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.set" },
            "Nested Codex prompt should not replace the parent resume binding, saw \(childPromptCommands)"
        )
        legacyAssertFalse(
            childPromptCommands.contains { $0.hasPrefix("set_status codex Running ") },
            "Nested Codex prompt should not rewrite parent Running status, saw \(childPromptCommands)"
        )

        let childStopStart = context.state.commands.count
        let childStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"child-turn","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"2"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(childStop.timedOut, childStop.stderr)
        legacyAssertEqual(childStop.status, 0, childStop.stderr)
        let childStopCommands = Array(context.state.commands.dropFirst(childStopStart))
        legacyAssertTrue(
            childStopCommands.contains { $0.contains(#""method":"feed.push""#) && $0.contains(#""hook_event_name":"Stop""#) },
            "Nested Codex Stop should remain Feed telemetry, saw \(childStopCommands)"
        )
        legacyAssertFalse(
            childStopCommands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.set" },
            "Nested Codex Stop should not replace the parent resume binding, saw \(childStopCommands)"
        )
        legacyAssertFalse(
            childStopCommands.contains { $0.hasPrefix("notify_target") || $0.hasPrefix("set_status codex ") },
            "Nested Codex Stop should not notify or mark the parent idle, saw \(childStopCommands)"
        )

        let parentStopStart = context.state.commands.count
        let parentStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"parent-turn","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"parent done"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(parentStop.timedOut, parentStop.stderr)
        legacyAssertEqual(parentStop.status, 0, parentStop.stderr)
        let parentStopCommands = Array(context.state.commands.dropFirst(parentStopStart))
        legacyAssertTrue(
            parentStopCommands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.set" },
            "Parent Codex Stop should still refresh the resume binding, saw \(parentStopCommands)"
        )
        legacyAssertTrue(
            parentStopCommands.contains { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Codex|") },
            "Parent Codex Stop should still notify, saw \(parentStopCommands)"
        )
        legacyAssertTrue(
            parentStopCommands.contains { $0.hasPrefix("set_status codex ") && $0.contains(" Idle ") },
            "Parent Codex Stop should mark Codex idle, saw \(parentStopCommands)"
        )
    }

    @Test
    func testGenericAgentNotificationUpdatesLifecycleForNeedsInput() throws {
        let context = try makeClaudeHookContext(name: "codex-notification-lifecycle")
        defer { context.cleanup() }

        let sessionId = "notification-lifecycle-session"
        let launchEnvironment = codexLaunchEnvironment(context: context, sessionId: sessionId)
        startAgentHookMockServerAccepting(context: context, connectionLimit: 64)

        let prompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"continue"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(prompt.timedOut, prompt.stderr)
        legacyAssertEqual(prompt.status, 0, prompt.stderr)

        let stop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"done"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(stop.timedOut, stop.stderr)
        legacyAssertEqual(stop.status, 0, stop.stderr)

        let stateURL = context.root.appendingPathComponent("codex-hook-sessions.json")
        var state = try legacyUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        var sessions = try legacyUnwrap(state["sessions"] as? [String: Any])
        var record = try legacyUnwrap(sessions[sessionId] as? [String: Any])
        legacyAssertEqual(record["agentLifecycle"] as? String, "idle")

        let notificationStart = context.state.commands.count
        let notification = runCodexHook(
            context: context,
            subcommand: "notification",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"Notification","message":"permission approval required"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(notification.timedOut, notification.stderr)
        legacyAssertEqual(notification.status, 0, notification.stderr)

        let notificationCommands = Array(context.state.commands.dropFirst(notificationStart))
        legacyAssertTrue(
            notificationCommands.contains {
                $0.hasPrefix("set_agent_lifecycle codex needsInput --tab=\(context.workspaceId)")
                    && $0.contains("--panel=\(context.surfaceId)")
            },
            "Notification requiring user input must correct the visible lifecycle, saw \(notificationCommands)"
        )

        state = try legacyUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        sessions = try legacyUnwrap(state["sessions"] as? [String: Any])
        record = try legacyUnwrap(sessions[sessionId] as? [String: Any])
        legacyAssertEqual(record["agentLifecycle"] as? String, "needsInput")
    }

    @Test
    func testGenericAgentStaleIdleStopDoesNotOverwriteNewerRunningLifecycle() throws {
        let context = try makeClaudeHookContext(name: "codex-stale-idle-stop-lifecycle")
        defer { context.cleanup() }

        let oldSessionId = "stale-idle-stop-old"
        let newSessionId = "stale-idle-stop-new"
        let oldEnvironment = codexLaunchEnvironment(context: context, sessionId: oldSessionId)
        let newEnvironment = codexLaunchEnvironment(context: context, sessionId: newSessionId)
        startAgentHookMockServerAccepting(context: context, connectionLimit: 64)

        let oldPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(oldSessionId)","turn_id":"old-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"old"}"#,
            extraEnvironment: oldEnvironment
        )
        legacyAssertFalse(oldPrompt.timedOut, oldPrompt.stderr)
        legacyAssertEqual(oldPrompt.status, 0, oldPrompt.stderr)

        let newPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(newSessionId)","turn_id":"new-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"new"}"#,
            extraEnvironment: newEnvironment
        )
        legacyAssertFalse(newPrompt.timedOut, newPrompt.stderr)
        legacyAssertEqual(newPrompt.status, 0, newPrompt.stderr)

        let staleStopStart = context.state.commands.count
        let staleStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(oldSessionId)","turn_id":"old-turn","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"old done"}"#,
            extraEnvironment: oldEnvironment
        )
        legacyAssertFalse(staleStop.timedOut, staleStop.stderr)
        legacyAssertEqual(staleStop.status, 0, staleStop.stderr)

        let staleStopCommands = Array(context.state.commands.dropFirst(staleStopStart))
        legacyAssertFalse(
            staleStopCommands.contains { $0.hasPrefix("set_agent_lifecycle codex idle ") },
            "A stale Stop from an older session must not mark the surface idle, saw \(staleStopCommands)"
        )
        legacyAssertFalse(
            staleStopCommands.contains { $0.hasPrefix("set_status codex ") && $0.contains(" Idle ") },
            "A stale Stop from an older session must not replace the newer Running status, saw \(staleStopCommands)"
        )
        legacyAssertFalse(
            staleStopCommands.contains { $0.hasPrefix("notify_target") },
            "A stale Stop from an older session must not publish a completion notification, saw \(staleStopCommands)"
        )

        let stateURL = context.root.appendingPathComponent("codex-hook-sessions.json")
        let state = try legacyUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        let sessions = try legacyUnwrap(state["sessions"] as? [String: Any])
        let newRecord = try legacyUnwrap(sessions[newSessionId] as? [String: Any])
        legacyAssertEqual(newRecord["runtimeStatus"] as? String, "running")
        legacyAssertEqual(newRecord["agentLifecycle"] as? String, "running")
    }

    @Test
    func testGenericAgentStaleIdleNotificationDoesNotOverwriteNewerRunningLifecycle() throws {
        let context = try makeClaudeHookContext(name: "codex-stale-idle-notification-lifecycle")
        defer { context.cleanup() }

        let oldSessionId = "stale-idle-notification-old"
        let newSessionId = "stale-idle-notification-new"
        let oldEnvironment = codexLaunchEnvironment(context: context, sessionId: oldSessionId)
        let newEnvironment = codexLaunchEnvironment(context: context, sessionId: newSessionId)
        startAgentHookMockServerAccepting(context: context, connectionLimit: 64)

        let oldPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(oldSessionId)","turn_id":"old-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"old"}"#,
            extraEnvironment: oldEnvironment
        )
        legacyAssertFalse(oldPrompt.timedOut, oldPrompt.stderr)
        legacyAssertEqual(oldPrompt.status, 0, oldPrompt.stderr)

        let newPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(newSessionId)","turn_id":"new-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"new"}"#,
            extraEnvironment: newEnvironment
        )
        legacyAssertFalse(newPrompt.timedOut, newPrompt.stderr)
        legacyAssertEqual(newPrompt.status, 0, newPrompt.stderr)

        let staleNotificationStart = context.state.commands.count
        let staleNotification = runCodexHook(
            context: context,
            subcommand: "notification",
            standardInput: #"{"session_id":"\#(oldSessionId)","cwd":"\#(context.root.path)","hook_event_name":"Notification","message":"done"}"#,
            extraEnvironment: oldEnvironment
        )
        legacyAssertFalse(staleNotification.timedOut, staleNotification.stderr)
        legacyAssertEqual(staleNotification.status, 0, staleNotification.stderr)

        let staleNotificationCommands = Array(context.state.commands.dropFirst(staleNotificationStart))
        legacyAssertFalse(
            staleNotificationCommands.contains { $0.hasPrefix("set_agent_lifecycle codex idle ") },
            "A stale idle notification must not mark the newer session idle, saw \(staleNotificationCommands)"
        )
        legacyAssertFalse(
            staleNotificationCommands.contains { $0.hasPrefix("set_status codex ") && $0.contains(" Idle ") },
            "A stale idle notification must not replace the newer Running status, saw \(staleNotificationCommands)"
        )
        legacyAssertFalse(
            staleNotificationCommands.contains { $0.hasPrefix("notify_target") },
            "A stale idle notification must not publish a completion notification, saw \(staleNotificationCommands)"
        )

        let stateURL = context.root.appendingPathComponent("codex-hook-sessions.json")
        let state = try legacyUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        let sessions = try legacyUnwrap(state["sessions"] as? [String: Any])
        let newRecord = try legacyUnwrap(sessions[newSessionId] as? [String: Any])
        legacyAssertEqual(newRecord["runtimeStatus"] as? String, "running")
        legacyAssertEqual(newRecord["agentLifecycle"] as? String, "running")
    }

    @Test
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
        legacyAssertFalse(parentPrompt.timedOut, parentPrompt.stderr)
        legacyAssertEqual(parentPrompt.status, 0, parentPrompt.stderr)

        let childPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"child-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"child"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(childPrompt.timedOut, childPrompt.stderr)
        legacyAssertEqual(childPrompt.status, 0, childPrompt.stderr)

        let legacyChildStopStart = context.state.commands.count
        let legacyChildStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"child done"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(legacyChildStop.timedOut, legacyChildStop.stderr)
        legacyAssertEqual(legacyChildStop.status, 0, legacyChildStop.stderr)
        let legacyChildStopCommands = Array(context.state.commands.dropFirst(legacyChildStopStart))
        legacyAssertFalse(
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
        legacyAssertFalse(parentStop.timedOut, parentStop.stderr)
        legacyAssertEqual(parentStop.status, 0, parentStop.stderr)
        let parentStopCommands = Array(context.state.commands.dropFirst(parentStopStart))
        legacyAssertTrue(
            parentStopCommands.contains { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Codex|") },
            "The parent Stop must still notify after a legacy child Stop without a turn_id, saw \(parentStopCommands)"
        )
        legacyAssertTrue(
            parentStopCommands.contains { $0.hasPrefix("set_status codex ") && $0.contains(" Idle ") },
            "The parent Stop must still mark Codex idle after a legacy child Stop without a turn_id, saw \(parentStopCommands)"
        )
    }

    @Test
    func testGenericAgentTurnIdsStayNestedAcrossTurnChanges() throws {
        let context = try makeClaudeHookContext(name: "generic-turn-stack")
        defer { context.cleanup() }

        let sessionId = "generic-turn-stack-session"
        let launchEnvironment = agentLaunchEnvironment(context: context, kind: "gemini", executable: "/usr/local/bin/gemini")
        startAgentHookMockServerAccepting(context: context, connectionLimit: 48)

        let parentPrompt = runAgentHook(
            context: context,
            agent: "gemini",
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"parent-turn","cwd":"\#(context.root.path)","hook_event_name":"BeforeAgent","prompt":"parent"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(parentPrompt.timedOut, parentPrompt.stderr)
        legacyAssertEqual(parentPrompt.status, 0, parentPrompt.stderr)

        let childPromptStart = context.state.commands.count
        let childPrompt = runAgentHook(
            context: context,
            agent: "gemini",
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"child-turn","cwd":"\#(context.root.path)","hook_event_name":"BeforeAgent","prompt":"child"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(childPrompt.timedOut, childPrompt.stderr)
        legacyAssertEqual(childPrompt.status, 0, childPrompt.stderr)
        let childPromptCommands = Array(context.state.commands.dropFirst(childPromptStart))
        legacyAssertFalse(
            childPromptCommands.contains { (self.jsonObject($0)?["method"] as? String)?.hasPrefix("surface.resume.") == true },
            "A generic nested turn_id prompt must not replace the parent resume binding, saw \(childPromptCommands)"
        )
        legacyAssertFalse(
            childPromptCommands.contains { $0.hasPrefix("set_status gemini Running ") },
            "A generic nested turn_id prompt must not rewrite parent Running status, saw \(childPromptCommands)"
        )

        let childStopStart = context.state.commands.count
        let childStop = runAgentHook(
            context: context,
            agent: "gemini",
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"child-turn","cwd":"\#(context.root.path)","hook_event_name":"AfterAgent","last_assistant_message":"child done"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(childStop.timedOut, childStop.stderr)
        legacyAssertEqual(childStop.status, 0, childStop.stderr)
        let childStopCommands = Array(context.state.commands.dropFirst(childStopStart))
        legacyAssertFalse(
            childStopCommands.contains { $0.hasPrefix("notify_target") || $0.hasPrefix("set_status gemini ") },
            "A generic nested turn_id Stop must not notify or mark the parent idle, saw \(childStopCommands)"
        )

        let parentStopStart = context.state.commands.count
        let parentStop = runAgentHook(
            context: context,
            agent: "gemini",
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"parent-turn","cwd":"\#(context.root.path)","hook_event_name":"AfterAgent","last_assistant_message":"parent done"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(parentStop.timedOut, parentStop.stderr)
        legacyAssertEqual(parentStop.status, 0, parentStop.stderr)
        let parentStopCommands = Array(context.state.commands.dropFirst(parentStopStart))
        legacyAssertTrue(
            parentStopCommands.contains { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Gemini|") },
            "The generic parent Stop must still notify after its nested child, saw \(parentStopCommands)"
        )
        legacyAssertTrue(
            parentStopCommands.contains { $0.hasPrefix("set_status gemini ") && $0.contains(" Idle ") },
            "The generic parent Stop must still mark Gemini idle, saw \(parentStopCommands)"
        )
    }

    @Test
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
        legacyAssertFalse(parentPrompt.timedOut, parentPrompt.stderr)
        legacyAssertEqual(parentPrompt.status, 0, parentPrompt.stderr)

        let anonymousChildPromptStart = context.state.commands.count
        let anonymousChildPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"anonymous child"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(anonymousChildPrompt.timedOut, anonymousChildPrompt.stderr)
        legacyAssertEqual(anonymousChildPrompt.status, 0, anonymousChildPrompt.stderr)
        let anonymousChildPromptCommands = Array(context.state.commands.dropFirst(anonymousChildPromptStart))
        legacyAssertFalse(
            anonymousChildPromptCommands.contains { (self.jsonObject($0)?["method"] as? String)?.hasPrefix("surface.resume.") == true },
            "An anonymous child under a known parent must not replace the parent resume binding, saw \(anonymousChildPromptCommands)"
        )
        legacyAssertFalse(
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
        legacyAssertFalse(grandchildPrompt.timedOut, grandchildPrompt.stderr)
        legacyAssertEqual(grandchildPrompt.status, 0, grandchildPrompt.stderr)
        let grandchildPromptCommands = Array(context.state.commands.dropFirst(grandchildPromptStart))
        legacyAssertFalse(
            grandchildPromptCommands.contains { (self.jsonObject($0)?["method"] as? String)?.hasPrefix("surface.resume.") == true },
            "A known grandchild after anonymous depth must stay nested, saw \(grandchildPromptCommands)"
        )
        legacyAssertFalse(
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
        legacyAssertFalse(grandchildStop.timedOut, grandchildStop.stderr)
        legacyAssertEqual(grandchildStop.status, 0, grandchildStop.stderr)
        let grandchildStopCommands = Array(context.state.commands.dropFirst(grandchildStopStart))
        legacyAssertFalse(
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
        legacyAssertFalse(anonymousChildStop.timedOut, anonymousChildStop.stderr)
        legacyAssertEqual(anonymousChildStop.status, 0, anonymousChildStop.stderr)
        let anonymousChildStopCommands = Array(context.state.commands.dropFirst(anonymousChildStopStart))
        legacyAssertFalse(
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
        legacyAssertFalse(parentStop.timedOut, parentStop.stderr)
        legacyAssertEqual(parentStop.status, 0, parentStop.stderr)
        let parentStopCommands = Array(context.state.commands.dropFirst(parentStopStart))
        legacyAssertTrue(
            parentStopCommands.contains { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Codex|") },
            "The parent Stop must still notify after mixed anonymous depth, saw \(parentStopCommands)"
        )
        legacyAssertTrue(
            parentStopCommands.contains { $0.hasPrefix("set_status codex ") && $0.contains(" Idle ") },
            "The parent Stop must still mark Codex idle after mixed anonymous depth, saw \(parentStopCommands)"
        )
    }

    @Test
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
        legacyAssertFalse(parentPrompt.timedOut, parentPrompt.stderr)
        legacyAssertEqual(parentPrompt.status, 0, parentPrompt.stderr)

        let anonymousChildPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"anonymous child"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(anonymousChildPrompt.timedOut, anonymousChildPrompt.stderr)
        legacyAssertEqual(anonymousChildPrompt.status, 0, anonymousChildPrompt.stderr)

        let childStopStart = context.state.commands.count
        let childStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"child-turn","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"child done"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(childStop.timedOut, childStop.stderr)
        legacyAssertEqual(childStop.status, 0, childStop.stderr)
        let childStopCommands = Array(context.state.commands.dropFirst(childStopStart))
        legacyAssertFalse(
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
        legacyAssertFalse(parentStop.timedOut, parentStop.stderr)
        legacyAssertEqual(parentStop.status, 0, parentStop.stderr)
        let parentStopCommands = Array(context.state.commands.dropFirst(parentStopStart))
        legacyAssertTrue(
            parentStopCommands.contains { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Codex|") },
            "The parent Stop must still notify after a child Stop supplies a new turn_id, saw \(parentStopCommands)"
        )
        legacyAssertTrue(
            parentStopCommands.contains { $0.hasPrefix("set_status codex ") && $0.contains(" Idle ") },
            "The parent Stop must still mark Codex idle after a child Stop supplies a new turn_id, saw \(parentStopCommands)"
        )
    }

    @Test
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
        legacyAssertFalse(interruptedPrompt.timedOut, interruptedPrompt.stderr)
        legacyAssertEqual(interruptedPrompt.status, 0, interruptedPrompt.stderr)

        let currentPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"current-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"UserPromptSubmit","prompt":"finish now"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(currentPrompt.timedOut, currentPrompt.stderr)
        legacyAssertEqual(currentPrompt.status, 0, currentPrompt.stderr)

        let stopStart = context.state.commands.count
        let currentStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"current-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"Stop","last_assistant_message":"current done"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(currentStop.timedOut, currentStop.stderr)
        legacyAssertEqual(currentStop.status, 0, currentStop.stderr)
        let stopCommands = Array(context.state.commands.dropFirst(stopStart))

        legacyAssertTrue(
            stopCommands.contains { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Codex|") },
            "A stale prompt depth from an interrupted prior turn must not suppress the current top-level completion notification, saw \(stopCommands)"
        )
        legacyAssertTrue(
            stopCommands.contains { $0.hasPrefix("set_status codex ") && $0.contains(" Idle ") },
            "A stale prompt depth from an interrupted prior turn must not leave Codex marked running, saw \(stopCommands)"
        )
    }

    @Test
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
        legacyAssertFalse(oldPrompt.timedOut, oldPrompt.stderr)
        legacyAssertEqual(oldPrompt.status, 0, oldPrompt.stderr)

        let currentPromptStart = context.state.commands.count
        let currentPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"current-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"UserPromptSubmit","prompt":"current"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(currentPrompt.timedOut, currentPrompt.stderr)
        legacyAssertEqual(currentPrompt.status, 0, currentPrompt.stderr)
        let currentPromptCommands = Array(context.state.commands.dropFirst(currentPromptStart))
        legacyAssertFalse(
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
        legacyAssertFalse(currentStop.timedOut, currentStop.stderr)
        legacyAssertEqual(currentStop.status, 0, currentStop.stderr)
        let currentStopCommands = Array(context.state.commands.dropFirst(currentStopStart))

        legacyAssertTrue(
            currentStopCommands.contains { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Codex|") },
            "A late terminal prior turn must not suppress the current top-level completion notification, saw \(currentStopCommands)"
        )
        legacyAssertTrue(
            currentStopCommands.contains { $0.hasPrefix("set_status codex ") && $0.contains(" Idle ") },
            "A late terminal prior turn must not leave Codex marked running after the current Stop, saw \(currentStopCommands)"
        )
    }

    @Test
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
        legacyAssertFalse(parentPrompt.timedOut, parentPrompt.stderr)
        legacyAssertEqual(parentPrompt.status, 0, parentPrompt.stderr)

        let childPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"child-turn","cwd":"\#(context.root.path)","transcript_path":"\#(terminalChildTranscript.path)","hook_event_name":"UserPromptSubmit","prompt":"first child"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(childPrompt.timedOut, childPrompt.stderr)
        legacyAssertEqual(childPrompt.status, 0, childPrompt.stderr)

        let siblingPromptStart = context.state.commands.count
        let siblingPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"sibling-turn","cwd":"\#(context.root.path)","transcript_path":"\#(terminalChildTranscript.path)","hook_event_name":"UserPromptSubmit","prompt":"second child"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(siblingPrompt.timedOut, siblingPrompt.stderr)
        legacyAssertEqual(siblingPrompt.status, 0, siblingPrompt.stderr)
        let siblingPromptCommands = Array(context.state.commands.dropFirst(siblingPromptStart))
        legacyAssertFalse(
            siblingPromptCommands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.set" },
            "A sibling child prompt after a terminal child transcript must stay nested, saw \(siblingPromptCommands)"
        )
        legacyAssertFalse(
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
        legacyAssertFalse(childStop.timedOut, childStop.stderr)
        legacyAssertEqual(childStop.status, 0, childStop.stderr)
        let childStopCommands = Array(context.state.commands.dropFirst(childStopStart))
        legacyAssertFalse(
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
        legacyAssertFalse(siblingStop.timedOut, siblingStop.stderr)
        legacyAssertEqual(siblingStop.status, 0, siblingStop.stderr)
        let siblingStopCommands = Array(context.state.commands.dropFirst(siblingStopStart))
        legacyAssertFalse(
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
        legacyAssertFalse(parentStop.timedOut, parentStop.stderr)
        legacyAssertEqual(parentStop.status, 0, parentStop.stderr)
        let parentStopCommands = Array(context.state.commands.dropFirst(parentStopStart))
        legacyAssertTrue(
            parentStopCommands.contains { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Codex|") },
            "The parent Stop should still notify after terminal nested children, saw \(parentStopCommands)"
        )
    }

    @Test
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
        legacyAssertFalse(parentPrompt.timedOut, parentPrompt.stderr)
        legacyAssertEqual(parentPrompt.status, 0, parentPrompt.stderr)

        let childPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"child-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"child"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(childPrompt.timedOut, childPrompt.stderr)
        legacyAssertEqual(childPrompt.status, 0, childPrompt.stderr)

        let currentPromptStart = context.state.commands.count
        let currentPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"current-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"UserPromptSubmit","prompt":"current"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(currentPrompt.timedOut, currentPrompt.stderr)
        legacyAssertEqual(currentPrompt.status, 0, currentPrompt.stderr)
        let currentPromptCommands = Array(context.state.commands.dropFirst(currentPromptStart))
        legacyAssertTrue(
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
        legacyAssertFalse(currentStop.timedOut, currentStop.stderr)
        legacyAssertEqual(currentStop.status, 0, currentStop.stderr)
        let currentStopCommands = Array(context.state.commands.dropFirst(currentStopStart))
        legacyAssertTrue(
            currentStopCommands.contains { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Codex|") },
            "A current Stop after a fully terminal interrupted stack must notify, saw \(currentStopCommands)"
        )
    }

    @Test
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
        legacyAssertFalse(childPrompt.timedOut, childPrompt.stderr)
        legacyAssertEqual(childPrompt.status, 0, childPrompt.stderr)
        let childPromptCommands = Array(context.state.commands.dropFirst(childPromptStart))
        legacyAssertFalse(
            childPromptCommands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.set" },
            "A legacy depth-only nested prompt that first gains a turn_id must remain nested, saw \(childPromptCommands)"
        )
        legacyAssertFalse(
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
        legacyAssertFalse(childStop.timedOut, childStop.stderr)
        legacyAssertEqual(childStop.status, 0, childStop.stderr)
        let childStopCommands = Array(context.state.commands.dropFirst(childStopStart))
        legacyAssertFalse(
            childStopCommands.contains { $0.hasPrefix("notify_target") || $0.hasPrefix("set_status codex ") },
            "A legacy depth-only nested Stop that first gains a turn_id must remain nested, saw \(childStopCommands)"
        )
    }

    @Test
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
        legacyAssertFalse(childPrompt.timedOut, childPrompt.stderr)
        legacyAssertEqual(childPrompt.status, 0, childPrompt.stderr)
        let childPromptCommands = Array(context.state.commands.dropFirst(childPromptStart))
        legacyAssertFalse(
            childPromptCommands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.set" },
            "A historical terminal turn must not make an active depth-only parent look finished, saw \(childPromptCommands)"
        )
        legacyAssertFalse(
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
        legacyAssertFalse(childStop.timedOut, childStop.stderr)
        legacyAssertEqual(childStop.status, 0, childStop.stderr)
        let childStopCommands = Array(context.state.commands.dropFirst(childStopStart))
        legacyAssertFalse(
            childStopCommands.contains { $0.hasPrefix("notify_target") || $0.hasPrefix("set_status codex ") },
            "A historical terminal turn must not let a child Stop notify while the parent is active, saw \(childStopCommands)"
        )
    }

    @Test
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
        legacyAssertFalse(childPrompt.timedOut, childPrompt.stderr)
        legacyAssertEqual(childPrompt.status, 0, childPrompt.stderr)
        let childPromptCommands = Array(context.state.commands.dropFirst(childPromptStart))
        legacyAssertFalse(
            childPromptCommands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.set" },
            "A non-terminal parent turn_context must not make a depth-only parent look finished, saw \(childPromptCommands)"
        )
        legacyAssertFalse(
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
        legacyAssertFalse(childStop.timedOut, childStop.stderr)
        legacyAssertEqual(childStop.status, 0, childStop.stderr)
        let childStopCommands = Array(context.state.commands.dropFirst(childStopStart))
        legacyAssertFalse(
            childStopCommands.contains { $0.hasPrefix("notify_target") || $0.hasPrefix("set_status codex ") },
            "A non-terminal parent turn_context must not let a child Stop notify while the parent is active, saw \(childStopCommands)"
        )
    }

    @Test
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
        legacyAssertFalse(childPrompt.timedOut, childPrompt.stderr)
        legacyAssertEqual(childPrompt.status, 0, childPrompt.stderr)

        let childStopStart = context.state.commands.count
        let childStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"child-turn","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"child done"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(childStop.timedOut, childStop.stderr)
        legacyAssertEqual(childStop.status, 0, childStop.stderr)
        let childStopCommands = Array(context.state.commands.dropFirst(childStopStart))
        legacyAssertFalse(
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
        legacyAssertFalse(parentStop.timedOut, parentStop.stderr)
        legacyAssertEqual(parentStop.status, 0, parentStop.stderr)
        let parentStopCommands = Array(context.state.commands.dropFirst(parentStopStart))
        legacyAssertTrue(
            parentStopCommands.contains { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Codex|") },
            "The depth-only parent Stop must notify after its child turn stops, saw \(parentStopCommands)"
        )
        legacyAssertTrue(
            parentStopCommands.contains { $0.hasPrefix("set_status codex ") && $0.contains(" Idle ") },
            "The depth-only parent Stop must mark Codex idle, saw \(parentStopCommands)"
        )
    }

    @Test
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
        legacyAssertFalse(childStop.timedOut, childStop.stderr)
        legacyAssertEqual(childStop.status, 0, childStop.stderr)
        legacyAssertEqual(childStop.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "{}")
        legacyAssertEqual(childStop.stderr, "")
        let childStopCommands = Array(context.state.commands.dropFirst(childStopStart))
        legacyAssertFalse(
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
        legacyAssertFalse(siblingPrompt.timedOut, siblingPrompt.stderr)
        legacyAssertEqual(siblingPrompt.status, 0, siblingPrompt.stderr)
        let siblingPromptCommands = Array(context.state.commands.dropFirst(siblingPromptStart))
        legacyAssertFalse(
            siblingPromptCommands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.set" },
            "A sibling prompt must stay nested while the depth-only parent remains active, saw \(siblingPromptCommands)"
        )
        legacyAssertFalse(
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
        legacyAssertFalse(siblingStop.timedOut, siblingStop.stderr)
        legacyAssertEqual(siblingStop.status, 0, siblingStop.stderr)
        let siblingStopCommands = Array(context.state.commands.dropFirst(siblingStopStart))
        legacyAssertFalse(
            siblingStopCommands.contains { $0.hasPrefix("notify_target") || $0.hasPrefix("set_status codex ") },
            "A sibling Stop must stay nested while the depth-only parent remains active, saw \(siblingStopCommands)"
        )
    }

    @Test
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
        legacyAssertFalse(childPrompt.timedOut, childPrompt.stderr)
        legacyAssertEqual(childPrompt.status, 0, childPrompt.stderr)
        let childPromptCommands = Array(context.state.commands.dropFirst(childPromptStart))
        legacyAssertFalse(
            childPromptCommands.contains { (self.jsonObject($0)?["method"] as? String)?.hasPrefix("surface.resume.") == true },
            "Terminal history alone must not make unknown depth-only active prompts look finished, saw \(childPromptCommands)"
        )
        legacyAssertFalse(
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
        legacyAssertFalse(childStop.timedOut, childStop.stderr)
        legacyAssertEqual(childStop.status, 0, childStop.stderr)
        let childStopCommands = Array(context.state.commands.dropFirst(childStopStart))
        legacyAssertFalse(
            childStopCommands.contains { $0.hasPrefix("notify_target") || $0.hasPrefix("set_status codex ") },
            "Terminal history alone must not let a child Stop notify while unknown depth remains, saw \(childStopCommands)"
        )
    }

    @Test
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
        legacyAssertFalse(oldPrompt.timedOut, oldPrompt.stderr)
        legacyAssertEqual(oldPrompt.status, 0, oldPrompt.stderr)

        let currentPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"current-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"UserPromptSubmit","prompt":"current"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(currentPrompt.timedOut, currentPrompt.stderr)
        legacyAssertEqual(currentPrompt.status, 0, currentPrompt.stderr)

        let staleStopStart = context.state.commands.count
        let staleStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"old-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"Stop","last_assistant_message":"old done"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(staleStop.timedOut, staleStop.stderr)
        legacyAssertEqual(staleStop.status, 0, staleStop.stderr)
        let staleStopCommands = Array(context.state.commands.dropFirst(staleStopStart))

        legacyAssertFalse(
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
        legacyAssertFalse(currentStop.timedOut, currentStop.stderr)
        legacyAssertEqual(currentStop.status, 0, currentStop.stderr)
        let currentStopCommands = Array(context.state.commands.dropFirst(currentStopStart))

        legacyAssertTrue(
            currentStopCommands.contains { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Codex|") },
            "The current turn should still notify after a stale older Stop, saw \(currentStopCommands)"
        )
    }

    @Test
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
        legacyAssertFalse(oldPrompt.timedOut, oldPrompt.stderr)
        legacyAssertEqual(oldPrompt.status, 0, oldPrompt.stderr)

        let currentPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"current-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"UserPromptSubmit","prompt":"current"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(currentPrompt.timedOut, currentPrompt.stderr)
        legacyAssertEqual(currentPrompt.status, 0, currentPrompt.stderr)

        let currentStopStart = context.state.commands.count
        let currentStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"current-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"Stop","last_assistant_message":"current done"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(currentStop.timedOut, currentStop.stderr)
        legacyAssertEqual(currentStop.status, 0, currentStop.stderr)
        let currentStopCommands = Array(context.state.commands.dropFirst(currentStopStart))
        legacyAssertTrue(
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
        legacyAssertFalse(lateStop.timedOut, lateStop.stderr)
        legacyAssertEqual(lateStop.status, 0, lateStop.stderr)
        let lateStopCommands = Array(context.state.commands.dropFirst(lateStopStart))

        legacyAssertFalse(
            lateStopCommands.contains { $0.hasPrefix("notify_target") || $0.hasPrefix("set_status codex ") },
            "A late stale Stop from an older turn must not duplicate the newer turn completion, saw \(lateStopCommands)"
        )
    }

    @Test
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
        legacyAssertFalse(oldPrompt.timedOut, oldPrompt.stderr)
        legacyAssertEqual(oldPrompt.status, 0, oldPrompt.stderr)

        let currentStopStart = context.state.commands.count
        let currentStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"current-turn","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"Stop","last_assistant_message":"current done"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(currentStop.timedOut, currentStop.stderr)
        legacyAssertEqual(currentStop.status, 0, currentStop.stderr)
        let currentStopCommands = Array(context.state.commands.dropFirst(currentStopStart))

        legacyAssertTrue(
            currentStopCommands.contains { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Codex|") },
            "A Stop after a missed prompt-submit must clear terminal stale turns and notify, saw \(currentStopCommands)"
        )
        legacyAssertTrue(
            currentStopCommands.contains { $0.hasPrefix("set_status codex ") && $0.contains(" Idle ") },
            "A Stop after a missed prompt-submit must mark Codex idle, saw \(currentStopCommands)"
        )
    }

    @Test
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
        legacyAssertFalse(currentStop.timedOut, currentStop.stderr)
        legacyAssertEqual(currentStop.status, 0, currentStop.stderr)
        let currentStopCommands = Array(context.state.commands.dropFirst(currentStopStart))

        legacyAssertTrue(
            currentStopCommands.contains { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Codex|") },
            "A missed prompt-submit Stop must clear a fully terminal stored stack and notify, saw \(currentStopCommands)"
        )
        legacyAssertTrue(
            currentStopCommands.contains { $0.hasPrefix("set_status codex ") && $0.contains(" Idle ") },
            "A missed prompt-submit Stop must clear a fully terminal stored stack and mark Codex idle, saw \(currentStopCommands)"
        )
    }

    @Test
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
        legacyAssertFalse(oldPrompt.timedOut, oldPrompt.stderr)
        legacyAssertEqual(oldPrompt.status, 0, oldPrompt.stderr)

        let oldStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"old-turn","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"old done"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(oldStop.timedOut, oldStop.stderr)
        legacyAssertEqual(oldStop.status, 0, oldStop.stderr)

        let unseenStopStart = context.state.commands.count
        let unseenStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"new-turn","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"new done"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(unseenStop.timedOut, unseenStop.stderr)
        legacyAssertEqual(unseenStop.status, 0, unseenStop.stderr)
        let unseenStopCommands = Array(context.state.commands.dropFirst(unseenStopStart))

        legacyAssertTrue(
            unseenStopCommands.contains { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Codex|") },
            "A Stop with a missed prompt-submit must still notify at idle depth, saw \(unseenStopCommands)"
        )
        legacyAssertTrue(
            unseenStopCommands.contains { $0.hasPrefix("set_status codex ") },
            "A Stop with a missed prompt-submit must still update Codex status, saw \(unseenStopCommands)"
        )
    }

    @Test
    func testManagedCodexSubagentStopDoesNotReplaceResumeBinding() throws {
        let context = try makeClaudeHookContext(name: "codex-managed-resume-guard")
        defer { context.cleanup() }

        let sessionId = "managed-child-session"
        startAgentHookMockServerAccepting(context: context, connectionLimit: 16)
        let result = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"child done"}"#,
            extraEnvironment: codexLaunchEnvironment(context: context, sessionId: sessionId).merging([
                "CMUX_AGENT_MANAGED_SUBAGENT": "1",
                "CMUX_CODEX_TEAMS_THREAD_ID": "child-thread",
                "CMUX_CODEX_TEAMS_PARENT_THREAD_ID": "root-thread",
                "CMUX_CODEX_TEAMS_DEPTH": "1",
            ], uniquingKeysWith: { _, new in new })
        )

        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertEqual(result.stdout, "{}\n")
        legacyAssertTrue(
            context.state.commands.contains { $0.contains(#""method":"feed.push""#) && $0.contains(#""hook_event_name":"Stop""#) },
            "Managed subagent Stop should remain Feed telemetry, saw \(context.state.commands)"
        )
        legacyAssertFalse(
            context.state.commands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.set" },
            "Managed subagent Stop should not publish a child resume binding, saw \(context.state.commands)"
        )
        legacyAssertFalse(
            context.state.commands.contains { $0.hasPrefix("notify_target") || $0.hasPrefix("set_status codex ") },
            "Managed subagent Stop should not notify or clobber visible status, saw \(context.state.commands)"
        )
    }

    @Test
    func testCodexStopIgnoresStaleSubagentRelayFromCompletedTurnWithoutTurnId() throws {
        let context = try makeClaudeHookContext(name: "codex-stale-relay")
        defer { context.cleanup() }

        let sessionId = "codex-stale-relay-session"
        let transcriptURL = context.root.appendingPathComponent("codex-stale-relay.jsonl")
        try [
            #"{"type":"turn_context","payload":{"turn_id":"old-turn"}}"#,
            #"{"type":"event_msg","payload":{"type":"turn_complete","turn_id":"old-turn"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":"<subagent_notification>old child finished</subagent_notification>"}}"#,
        ].joined(separator: "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        startAgentHookMockServerAccepting(context: context, connectionLimit: 24)
        let launchEnvironment = codexLaunchEnvironment(context: context, sessionId: sessionId)

        let prompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"UserPromptSubmit","prompt":"top-level"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(prompt.timedOut, prompt.stderr)
        legacyAssertEqual(prompt.status, 0, prompt.stderr)

        let stopStart = context.state.commands.count
        let stop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"Stop","last_assistant_message":"parent done"}"#,
            extraEnvironment: launchEnvironment
        )
        legacyAssertFalse(stop.timedOut, stop.stderr)
        legacyAssertEqual(stop.status, 0, stop.stderr)

        let stopCommands = Array(context.state.commands.dropFirst(stopStart))
        legacyAssertTrue(
            stopCommands.contains { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Codex|") },
            "Stale completed-turn subagent relay should not suppress the parent completion notification, saw \(stopCommands)"
        )
    }

    @Test
    func testManagedCodexSubagentSessionEndDoesNotClearParentResumeBinding() throws {
        let context = try makeClaudeHookContext(name: "codex-managed-end-resume-guard")
        defer { context.cleanup() }

        let sessionId = "managed-child-session-end"
        let now = Date().timeIntervalSince1970
        let stateURL = context.root.appendingPathComponent("codex-hook-sessions.json")
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": context.workspaceId,
                    "surfaceId": context.surfaceId,
                    "cwd": context.root.path,
                    "pid": 12345,
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted])
            .write(to: stateURL, options: .atomic)

        startAgentHookMockServerAccepting(context: context, connectionLimit: 16)
        let result = runCodexHook(
            context: context,
            subcommand: "session-end",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"SessionEnd"}"#,
            extraEnvironment: [
                "CMUX_AGENT_MANAGED_SUBAGENT": "1",
                "CMUX_CODEX_TEAMS_THREAD_ID": "child-thread",
                "CMUX_CODEX_TEAMS_PARENT_THREAD_ID": "root-thread",
                "CMUX_CODEX_TEAMS_DEPTH": "1",
            ]
        )

        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertFalse(
            context.state.commands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.clear" },
            "Managed subagent SessionEnd should not clear the parent resume binding, saw \(context.state.commands)"
        )
        legacyAssertFalse(
            context.state.commands.contains { $0.hasPrefix("clear_agent_pid codex.") },
            "Managed subagent SessionEnd should not clear the visible parent PID, saw \(context.state.commands)"
        )
        let savedState = try legacyUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        let savedSessions = try legacyUnwrap(savedState["sessions"] as? [String: Any])
        legacyAssertNotNil(savedSessions[sessionId], "Suppressed SessionEnd should leave the stored parent session intact")
    }

    @Test
    func testRightSidebarCLIForwardsV1SocketCommandsQuietly() throws {
        let cliPath = try bundledCLIPath()
        let cases: [(name: String, arguments: [String], expectedCommand: String, response: String, stdout: String)] = [
            ("toggle", ["right-sidebar", "toggle"], "right_sidebar toggle", "OK", ""),
            ("show", ["right-sidebar", "show"], "right_sidebar show", "OK", ""),
            ("hide", ["right-sidebar", "hide"], "right_sidebar hide", "OK", ""),
            ("focus", ["right-sidebar", "focus"], "right_sidebar focus", "OK", ""),
            ("set-find", ["right-sidebar", "set", "find"], "right_sidebar set find", "OK", ""),
            ("set-no-focus", ["right-sidebar", "set", "vault", "--no-focus"], "right_sidebar set vault --no-focus", "OK", ""),
            ("set-sessions", ["right-sidebar", "set", "sessions"], "right_sidebar set sessions", "OK", ""),
            ("files-alias", ["right-sidebar", "files"], "right_sidebar set files", "OK", ""),
            ("find-alias", ["right-sidebar", "find"], "right_sidebar set find", "OK", ""),
            ("vault-alias", ["right-sidebar", "vault"], "right_sidebar set vault", "OK", ""),
            ("sessions-alias", ["right-sidebar", "sessions"], "right_sidebar set sessions", "OK", ""),
            ("feed-alias", ["right-sidebar", "feed"], "right_sidebar set feed", "OK", ""),
            ("dock-alias", ["right-sidebar", "dock"], "right_sidebar set dock", "OK", ""),
            ("mode", ["right-sidebar", "mode"], "right_sidebar mode", #"{"visible":true,"mode":"find"}"#, #"{"visible":true,"mode":"find"}"# + "\n"),
        ]

        for item in cases {
            let socketPath = makeSocketPath("rs-\(item.name)")
            let listenerFD = try bindUnixSocket(at: socketPath)
            let state = MockSocketServerState()
            defer {
                Darwin.close(listenerFD)
                unlink(socketPath)
            }

            let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
                legacyAssertEqual(line, item.expectedCommand)
                return item.response
            }

            var environment = ProcessInfo.processInfo.environment
            environment["CMUX_SOCKET_PATH"] = socketPath
            environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

            let result = runProcess(
                executablePath: cliPath,
                arguments: item.arguments,
                environment: environment,
                timeout: 5
            )

            legacyWait(for: [serverHandled], timeout: 5)
            legacyAssertFalse(result.timedOut, "\(item.name): \(result.stderr)")
            legacyAssertEqual(result.status, 0, "\(item.name): \(result.stderr)")
            legacyAssertEqual(result.stdout, item.stdout, item.name)
            legacyAssertTrue(result.stderr.isEmpty, "\(item.name): \(result.stderr)")
            legacyAssertEqual(state.commands, [item.expectedCommand], item.name)
        }
    }

    @Test
    func testRightSidebarInvalidCommandValidatesBeforeTargetResolution() throws {
        let cliPath = try bundledCLIPath()
        let missingSocketPath = "/tmp/cmux-test-missing-\(UUID().uuidString).sock"
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = missingSocketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["right-sidebar", "unknown", "--workspace", "workspace:2"],
            environment: environment,
            timeout: 5
        )

        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 1, result.stderr)
        legacyAssertTrue(result.stdout.isEmpty, result.stdout)
        legacyAssertTrue(result.stderr.contains("Unknown right-sidebar command 'unknown'"), result.stderr)
        legacyAssertFalse(result.stderr.contains("Socket"), result.stderr)
    }

    @Test
    func testRightSidebarInvalidSetModeValidatesBeforeTargetResolution() throws {
        let cliPath = try bundledCLIPath()
        let missingSocketPath = "/tmp/cmux-test-missing-\(UUID().uuidString).sock"
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = missingSocketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["right-sidebar", "set", "unknown", "--workspace", "workspace:2"],
            environment: environment,
            timeout: 5
        )

        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 1, result.stderr)
        legacyAssertTrue(result.stdout.isEmpty, result.stdout)
        legacyAssertTrue(result.stderr.contains("Unknown right-sidebar mode 'unknown'"), result.stderr)
        legacyAssertFalse(result.stderr.contains("Socket"), result.stderr)
    }

    @Test
    func testSSHPersistentPTYUsesReusableForegroundAuthControlConnection() throws {
        let run = try runMockedSSH(arguments: [])
        try assertSSHPersistentPTYUsesReusableForegroundAuthControlConnection(run: run)
    }

    @Test
    func testSSHPersistentPTYTreatsControlPersistZeroAsReusable() throws {
        let run = try runMockedSSH(arguments: ["--ssh-option", "ControlPersist=0"])
        try assertSSHPersistentPTYUsesReusableForegroundAuthControlConnection(run: run)
    }

    @Test
    func testSSHPersistentPTYJSONReportsResolvedSessionID() throws {
        let run = try runMockedSSH(arguments: [], jsonOutput: true)
        let payload = try jsonPayload(from: run.stdout)
        let sessionID = try legacyUnwrap(payload["ssh_pty_session_id"] as? String)
        let persistentDaemonSlot = try legacyUnwrap(payload["persistent_daemon_slot"] as? String)

        legacyAssertEqual(sessionID, "ssh-\(run.workspaceId)-\(run.surfaceId)")
        legacyAssertFalse(sessionID.contains("$"), sessionID)
        legacyAssertFalse(sessionID.contains("{"), sessionID)
        legacyAssertTrue(persistentDaemonSlot.hasPrefix("ssh-"), persistentDaemonSlot)
        legacyAssertNotNil(UUID(uuidString: String(persistentDaemonSlot.dropFirst(4))))
    }

    @Test
    func testSSHPersistentPTYJSONResolvesSessionIDWhenWorkspaceCreateOmitsSurfaceID() throws {
        let run = try runMockedSSH(arguments: [], jsonOutput: true, omitWorkspaceCreateSurfaceID: true)
        let payload = try jsonPayload(from: run.stdout)
        let sessionID = try legacyUnwrap(payload["ssh_pty_session_id"] as? String)
        let persistentDaemonSlot = try legacyUnwrap(payload["persistent_daemon_slot"] as? String)

        legacyAssertEqual(sessionID, "ssh-\(run.workspaceId)-\(run.surfaceId)")
        legacyAssertTrue(persistentDaemonSlot.hasPrefix("ssh-"), persistentDaemonSlot)
        legacyAssertNotNil(UUID(uuidString: String(persistentDaemonSlot.dropFirst(4))))
    }

    @Test
    func testSSHForwardAgentFlagPropagatesCallerAgentSocket() throws {
        let agentSocketPath = try makeExistingAgentSocketPath()
        let run = try runMockedSSH(
            arguments: ["--forward-agent"],
            environmentOverrides: ["SSH_AUTH_SOCK": agentSocketPath]
        )
        let createParams = try legacyUnwrap(params(for: "workspace.create", in: run.requests))
        let configureParams = try legacyUnwrap(params(for: "workspace.remote.configure", in: run.requests))
        let sshOptions = try legacyUnwrap(configureParams["ssh_options"] as? [String])
        let initialEnv = try legacyUnwrap(createParams["initial_env"] as? [String: String])

        legacyAssertTrue(sshOptions.contains("ForwardAgent=yes"), "ssh_options: \(sshOptions)")
        legacyAssertEqual(initialEnv["SSH_AUTH_SOCK"], agentSocketPath)
        legacyAssertEqual(configureParams["ssh_auth_sock"] as? String, agentSocketPath)
    }

    @Test
    func testSSHForwardAgentOptionPropagatesCallerAgentSocket() throws {
        let agentSocketPath = try makeExistingAgentSocketPath()
        let run = try runMockedSSH(
            arguments: ["--ssh-option", "ForwardAgent=yes"],
            environmentOverrides: ["SSH_AUTH_SOCK": agentSocketPath]
        )
        let createParams = try legacyUnwrap(params(for: "workspace.create", in: run.requests))
        let configureParams = try legacyUnwrap(params(for: "workspace.remote.configure", in: run.requests))
        let sshOptions = try legacyUnwrap(configureParams["ssh_options"] as? [String])
        let initialEnv = try legacyUnwrap(createParams["initial_env"] as? [String: String])

        legacyAssertTrue(sshOptions.contains("ForwardAgent=yes"), "ssh_options: \(sshOptions)")
        legacyAssertEqual(initialEnv["SSH_AUTH_SOCK"], agentSocketPath)
        legacyAssertEqual(configureParams["ssh_auth_sock"] as? String, agentSocketPath)
    }

    @Test
    func testSSHForwardAgentRepeatedOptionUsesLastValue() throws {
        let run = try runMockedSSH(
            arguments: [
                "--ssh-option", "ForwardAgent=yes",
                "--ssh-option", "ForwardAgent=no",
            ],
            environmentOverrides: [
                "SSH_AUTH_SOCK": "/tmp/cmux-test-agent-\(UUID().uuidString).sock",
            ]
        )
        let createParams = try legacyUnwrap(params(for: "workspace.create", in: run.requests))
        let configureParams = try legacyUnwrap(params(for: "workspace.remote.configure", in: run.requests))
        let sshOptions = try legacyUnwrap(configureParams["ssh_options"] as? [String])

        legacyAssertEqual(sshOptions.filter { $0.hasPrefix("ForwardAgent=") }, [
            "ForwardAgent=yes",
            "ForwardAgent=no",
        ])
        legacyAssertNil(createParams["initial_env"])
        legacyAssertNil(configureParams["ssh_auth_sock"])
    }

    @Test
    func testSSHPreservesCallerAgentSocketForOpenSSHConfigResolution() throws {
        let agentSocketPath = try makeExistingAgentSocketPath()
        let run = try runMockedSSH(
            arguments: [],
            environmentOverrides: [
                "SSH_AUTH_SOCK": agentSocketPath,
            ]
        )
        let createParams = try legacyUnwrap(params(for: "workspace.create", in: run.requests))
        let configureParams = try legacyUnwrap(params(for: "workspace.remote.configure", in: run.requests))
        let initialEnv = try legacyUnwrap(createParams["initial_env"] as? [String: String])

        legacyAssertNil(configureParams["ssh_options"])
        legacyAssertEqual(initialEnv["SSH_AUTH_SOCK"], agentSocketPath)
        legacyAssertEqual(configureParams["ssh_auth_sock"] as? String, agentSocketPath)
    }

    @Test
    func testSSHForwardAgentLiteralSocketPathPropagatesSocketPath() throws {
        let agentSocketPath = try makeExistingAgentSocketPath()
        let run = try runMockedSSH(
            arguments: ["--ssh-option", "ForwardAgent=\(agentSocketPath)"]
        )
        let createParams = try legacyUnwrap(params(for: "workspace.create", in: run.requests))
        let configureParams = try legacyUnwrap(params(for: "workspace.remote.configure", in: run.requests))
        let sshOptions = try legacyUnwrap(configureParams["ssh_options"] as? [String])
        let initialEnv = try legacyUnwrap(createParams["initial_env"] as? [String: String])

        legacyAssertTrue(sshOptions.contains("ForwardAgent=\(agentSocketPath)"), "ssh_options: \(sshOptions)")
        legacyAssertEqual(initialEnv["SSH_AUTH_SOCK"], agentSocketPath)
        legacyAssertEqual(configureParams["ssh_auth_sock"] as? String, agentSocketPath)
    }

    @Test
    func testSSHForwardAgentTildeSocketPathExpandsSocketPath() throws {
        let homeURL = try makeTemporaryDirectory(prefix: "cmux-ssh-home")
        let tildeSocketPath = "~/.ssh/cmux-test-agent.sock"
        let expandedSocketURL = homeURL.appendingPathComponent(".ssh/cmux-test-agent.sock")
        try createExistingFile(at: expandedSocketURL)
        let run = try runMockedSSH(
            arguments: ["--ssh-option", "ForwardAgent=\(tildeSocketPath)"],
            environmentOverrides: [
                "HOME": homeURL.path,
            ]
        )
        let createParams = try legacyUnwrap(params(for: "workspace.create", in: run.requests))
        let configureParams = try legacyUnwrap(params(for: "workspace.remote.configure", in: run.requests))
        let sshOptions = try legacyUnwrap(configureParams["ssh_options"] as? [String])
        let initialEnv = try legacyUnwrap(createParams["initial_env"] as? [String: String])

        legacyAssertTrue(sshOptions.contains("ForwardAgent=\(tildeSocketPath)"), "ssh_options: \(sshOptions)")
        legacyAssertEqual(initialEnv["SSH_AUTH_SOCK"], expandedSocketURL.path)
        legacyAssertEqual(configureParams["ssh_auth_sock"] as? String, expandedSocketURL.path)
    }

    @Test
    func testSSHForwardAgentAskDoesNotPropagateInvalidSocketPath() throws {
        let run = try runMockedSSH(
            arguments: ["--ssh-option", "ForwardAgent=ask"],
            environmentOverrides: [
                "SSH_AUTH_SOCK": "/tmp/cmux-test-agent-\(UUID().uuidString).sock",
            ]
        )
        let createParams = try legacyUnwrap(params(for: "workspace.create", in: run.requests))
        let configureParams = try legacyUnwrap(params(for: "workspace.remote.configure", in: run.requests))
        let sshOptions = try legacyUnwrap(configureParams["ssh_options"] as? [String])

        legacyAssertTrue(sshOptions.contains("ForwardAgent=ask"), "ssh_options: \(sshOptions)")
        legacyAssertNil(createParams["initial_env"])
        legacyAssertNil(configureParams["ssh_auth_sock"])
    }

    @Test
    func testSSHNoForwardAgentFlagOverridesConfig() throws {
        let agentSocketPath = try makeExistingAgentSocketPath()
        let run = try runMockedSSH(
            arguments: ["--no-forward-agent"],
            environmentOverrides: [
                "SSH_AUTH_SOCK": agentSocketPath,
            ]
        )
        let createParams = try legacyUnwrap(params(for: "workspace.create", in: run.requests))
        let configureParams = try legacyUnwrap(params(for: "workspace.remote.configure", in: run.requests))
        let sshOptions = try legacyUnwrap(configureParams["ssh_options"] as? [String])
        let initialEnv = try legacyUnwrap(createParams["initial_env"] as? [String: String])

        legacyAssertTrue(sshOptions.contains("ForwardAgent=no"), "ssh_options: \(sshOptions)")
        legacyAssertEqual(initialEnv["SSH_AUTH_SOCK"], agentSocketPath)
        legacyAssertEqual(configureParams["ssh_auth_sock"] as? String, agentSocketPath)
    }

    private func assertSSHPersistentPTYUsesReusableForegroundAuthControlConnection(
        run: MockedSSHRun,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let createParams = try legacyUnwrap(params(for: "workspace.create", in: run.requests))
        let configureParams = try legacyUnwrap(params(for: "workspace.remote.configure", in: run.requests))
        let initialCommand = try legacyUnwrap(createParams["initial_command"] as? String)
        let terminalStartupCommand = try legacyUnwrap(configureParams["terminal_startup_command"] as? String)
        let initialScript = try legacyUnwrap(decodedReusableStartupScript(from: initialCommand))
        let terminalStartupScript = try legacyUnwrap(decodedReusableStartupScript(from: terminalStartupCommand))

        legacyAssertTrue(initialScript.contains("ssh-pty-attach"), initialScript)
        legacyAssertTrue(initialScript.contains("--wait"), initialScript)
        legacyAssertTrue(initialScript.contains("ssh-session-end"), initialScript)
        legacyAssertTrue(initialScript.contains("CMUX_WORKSPACE_ID"), initialScript)
        legacyAssertTrue(initialScript.contains("CMUX_SURFACE_ID"), initialScript)
        legacyAssertTrue(
            initialScript.contains("required workspace context missing for SSH PTY attach"),
            initialScript
        )
        legacyAssertTrue(
            initialScript.contains("required terminal context missing for SSH PTY attach"),
            initialScript
        )
        legacyAssertTrue(initialScript.contains("ssh-$cmux_ssh_pty_workspace_id-$cmux_ssh_pty_surface_id"), initialScript)
        let attachIDFlag = "--attachment-id \"$cmux_ssh_pty_surface_id\""
        legacyAssertTrue(initialScript.contains("254|255"), initialScript)
        legacyAssertTrue(initialScript.split(separator: "\n").first { $0.contains("ssh-pty-attach") }.map { $0.contains(attachIDFlag) && !$0.contains("--surface") } == true, initialScript)
        legacyAssertTrue(
            initialScript.contains("--workspace \"$cmux_ssh_pty_workspace_id\""),
            initialScript
        )
        legacyAssertEqual(
            initialScript.components(separatedBy: "workspace.remote.foreground_auth_ready").count - 1,
            1,
            initialScript
        )
        legacyAssertTrue(terminalStartupScript.contains("ssh-pty-attach"), terminalStartupScript)
        legacyAssertTrue(terminalStartupScript.contains("ssh-session-end"), terminalStartupScript)
        legacyAssertTrue(terminalStartupScript.contains("CMUX_WORKSPACE_ID"), terminalStartupScript)
        legacyAssertTrue(terminalStartupScript.contains("CMUX_SURFACE_ID"), terminalStartupScript)
        legacyAssertTrue(
            terminalStartupScript.contains("required workspace context missing for SSH PTY attach"),
            terminalStartupScript
        )
        legacyAssertTrue(
            terminalStartupScript.contains("required terminal context missing for SSH PTY attach"),
            terminalStartupScript
        )
        legacyAssertTrue(
            terminalStartupScript.contains("ssh-$cmux_ssh_pty_workspace_id-$cmux_ssh_pty_surface_id"),
            terminalStartupScript
        )
        legacyAssertTrue(terminalStartupScript.contains("254|255"), terminalStartupScript)
        legacyAssertTrue(terminalStartupScript.split(separator: "\n").first { $0.contains("ssh-pty-attach") }.map { $0.contains(attachIDFlag) && !$0.contains("--surface") } == true, terminalStartupScript)
        legacyAssertTrue(
            terminalStartupScript.contains("--workspace \"$cmux_ssh_pty_workspace_id\""),
            terminalStartupScript
        )
        legacyAssertEqual(
            terminalStartupScript.components(separatedBy: "workspace.remote.foreground_auth_ready").count - 1,
            1,
            terminalStartupScript
        )
        legacyAssertEqual(configureParams["auto_connect"] as? Bool, false)
        legacyAssertNotNil(configureParams["foreground_auth_token"] as? String)
        legacyAssertEqual(configureParams["preserve_after_terminal_exit"] as? Bool, true)
        let persistentDaemonSlot = try legacyUnwrap(configureParams["persistent_daemon_slot"] as? String)
        legacyAssertTrue(persistentDaemonSlot.hasPrefix("ssh-"), persistentDaemonSlot)
        legacyAssertNotNil(UUID(uuidString: String(persistentDaemonSlot.dropFirst(4))))
    }

    @Test
    func testSSHPersistentPTYFallsBackWhenForegroundAuthCannotBeReused() throws {
        let cases: [(name: String, arguments: [String])] = [
            ("control-master-no", ["--ssh-option", "ControlMaster=no"]),
            ("control-persist-no", ["--ssh-option", "ControlPersist=no"]),
            ("local-command", ["--ssh-option", "LocalCommand=echo cmux-test"]),
            ("permit-local-command", ["--ssh-option", "PermitLocalCommand=no"]),
        ]

        for testCase in cases {
            let run = try runMockedSSH(arguments: testCase.arguments)
            let createParams = try legacyUnwrap(
                params(for: "workspace.create", in: run.requests),
                testCase.name
            )
            let configureParams = try legacyUnwrap(
                params(for: "workspace.remote.configure", in: run.requests),
                testCase.name
            )
            let initialCommand = try legacyUnwrap(createParams["initial_command"] as? String, testCase.name)
            let terminalStartupCommand = try legacyUnwrap(
                configureParams["terminal_startup_command"] as? String,
                testCase.name
            )
            let initialScript = decodedReusableStartupScript(from: initialCommand) ?? initialCommand
            let terminalStartupScript = decodedReusableStartupScript(from: terminalStartupCommand) ?? terminalStartupCommand

            legacyAssertFalse(initialScript.contains("ssh-pty-attach"), testCase.name)
            legacyAssertFalse(terminalStartupScript.contains("ssh-pty-attach"), testCase.name)
            legacyAssertEqual(configureParams["auto_connect"] as? Bool, true, testCase.name)
            legacyAssertNil(configureParams["foreground_auth_token"], testCase.name)
            legacyAssertNil(configureParams["preserve_after_terminal_exit"], testCase.name)
            legacyAssertNil(configureParams["persistent_daemon_slot"], testCase.name)
        }
    }

    @Test
    func testSSHPTYAttachBridgeErrorClearsLocalStateBeforeReady() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshpty")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let bridge = try bindLoopbackTCP()
        let state = MockSocketServerState()
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let surfaceId = "33333333-3333-3333-3333-333333333333"
        let sessionId = "ssh-\(workspaceId)-\(surfaceId)"
        let token = "bridge-token"

        defer {
            Darwin.close(listenerFD)
            Darwin.close(bridge.fd)
            unlink(socketPath)
        }

        let socketHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "workspace.remote.pty_bridge":
                legacyAssertEqual(params["workspace_id"] as? String, workspaceId)
                legacyAssertEqual(params["session_id"] as? String, sessionId)
                legacyAssertEqual(params["attachment_id"] as? String, surfaceId)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "host": "127.0.0.1",
                        "port": bridge.port,
                        "token": token,
                        "session_id": sessionId,
                        "attachment_id": surfaceId,
                    ]
                )
            case "workspace.remote.pty_attach_end":
                legacyAssertEqual(params["workspace_id"] as? String, workspaceId)
                legacyAssertEqual(params["surface_id"] as? String, surfaceId)
                legacyAssertEqual(params["session_id"] as? String, sessionId)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceId,
                        "surface_id": surfaceId,
                        "session_id": sessionId,
                        "cleared_remote_pty_session": true,
                    ]
                )
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
        }
        let bridgeHandled = startBridgeErrorServer(
            listenerFD: bridge.fd,
            message: "remote PTY start failed"
        )

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-pty-attach",
                "--workspace", workspaceId,
                "--session-id", sessionId,
                "--attachment-id", surfaceId,
            ],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [socketHandled, bridgeHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 1, result.stderr)
        legacyAssertTrue(result.stdout.isEmpty, result.stdout)
        legacyAssertTrue(result.stderr.contains("ssh-pty-attach: remote PTY start failed"), result.stderr)
        let methods = state.snapshot().compactMap { self.jsonObject($0)?["method"] as? String }
        legacyAssertEqual(methods, ["workspace.remote.pty_bridge", "workspace.remote.pty_attach_end"])
    }

    @Test
    func testSSHPTYAttachBridgeEOFWhileSessionRunsExitsWithoutSSHRetryStatus() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshptyeof")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let bridge = try bindLoopbackTCP()
        let state = MockSocketServerState()
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let surfaceId = "33333333-3333-3333-3333-333333333333"
        let sessionId = "ssh-\(workspaceId)-\(surfaceId)"
        let token = "bridge-token"

        defer {
            Darwin.close(listenerFD)
            Darwin.close(bridge.fd)
            unlink(socketPath)
        }

        let socketHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "workspace.remote.pty_bridge":
                legacyAssertEqual(params["require_existing"] as? Bool, true)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "host": "127.0.0.1",
                        "port": bridge.port,
                        "token": token,
                        "session_id": sessionId,
                        "attachment_id": surfaceId,
                    ]
                )
            case "workspace.remote.pty_resize":
                legacyAssertEqual(params["attachment_token"] as? String, "attach-token")
                legacyAssertEqual(params["surface_id"] as? String, surfaceId)
                return self.v2Response(id: id, ok: true, result: ["resized": true])
            case "workspace.remote.pty_sessions":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "sessions": [
                            [
                                "workspace_id": workspaceId,
                                "session_id": sessionId,
                            ],
                        ],
                    ]
                )
            case "workspace.remote.pty_detach":
                legacyAssertEqual(params["workspace_id"] as? String, workspaceId)
                legacyAssertEqual(params["surface_id"] as? String, surfaceId)
                legacyAssertEqual(params["session_id"] as? String, sessionId)
                legacyAssertEqual(params["attachment_id"] as? String, surfaceId)
                legacyAssertEqual(params["attachment_token"] as? String, "attach-token")
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceId,
                        "session_id": sessionId,
                        "attachment_id": surfaceId,
                        "detached": true,
                    ]
                )
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
        }
        let bridgeHandled = startBridgeReadyThenCloseServer(listenerFD: bridge.fd)

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-pty-attach",
                "--require-existing",
                "--workspace", workspaceId,
                "--session-id", sessionId,
                "--attachment-id", surfaceId,
            ],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [socketHandled, bridgeHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 254, result.stderr)
        legacyAssertTrue(
            result.stderr.contains("ssh-pty-attach: bridge closed while remote PTY session is still running"),
            result.stderr
        )
        let methods = state.snapshot().compactMap { self.jsonObject($0)?["method"] as? String }
        legacyAssertEqual(methods, ["workspace.remote.pty_bridge", "workspace.remote.pty_resize", "workspace.remote.pty_sessions", "workspace.remote.pty_detach"])
    }

    @Test
    func testSSHPTYAttachBridgeEOFWhenSessionGoneClearsLocalState() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshptygone")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let bridge = try bindLoopbackTCP()
        let state = MockSocketServerState()
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let surfaceId = "33333333-3333-3333-3333-333333333333"
        let sessionId = "ssh-\(workspaceId)-\(surfaceId)"
        let token = "bridge-token"

        defer {
            Darwin.close(listenerFD)
            Darwin.close(bridge.fd)
            unlink(socketPath)
        }

        let socketHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            switch method {
            case "workspace.remote.pty_bridge":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "host": "127.0.0.1",
                        "port": bridge.port,
                        "token": token,
                        "session_id": sessionId,
                        "attachment_id": surfaceId,
                    ]
                )
            case "workspace.remote.pty_resize":
                let params = payload["params"] as? [String: Any] ?? [:]
                legacyAssertEqual(params["attachment_token"] as? String, "attach-token")
                legacyAssertEqual(params["surface_id"] as? String, surfaceId)
                return self.v2Response(id: id, ok: true, result: ["resized": true])
            case "workspace.remote.pty_sessions":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "sessions": [],
                    ]
                )
            case "workspace.remote.pty_attach_end":
                let params = payload["params"] as? [String: Any] ?? [:]
                legacyAssertEqual(params["workspace_id"] as? String, workspaceId)
                legacyAssertEqual(params["surface_id"] as? String, surfaceId)
                legacyAssertEqual(params["session_id"] as? String, sessionId)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceId,
                        "surface_id": surfaceId,
                        "session_id": sessionId,
                        "cleared_remote_pty_session": true,
                    ]
                )
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
        }
        let bridgeHandled = startBridgeReadyThenCloseServer(listenerFD: bridge.fd)

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-pty-attach",
                "--workspace", workspaceId,
                "--session-id", sessionId,
                "--attachment-id", surfaceId,
            ],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [socketHandled, bridgeHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertTrue(result.stdout.isEmpty, result.stdout)
        legacyAssertTrue(result.stderr.isEmpty, result.stderr)
        let methods = state.snapshot().compactMap { self.jsonObject($0)?["method"] as? String }
        legacyAssertEqual(methods, ["workspace.remote.pty_bridge", "workspace.remote.pty_resize", "workspace.remote.pty_sessions", "workspace.remote.pty_attach_end"])
    }

    @Test
    func testSSHPTYAttachWithoutSurfaceDoesNotSendLocalAttachEnd() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshptynosurface")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let bridge = try bindLoopbackTCP()
        let state = MockSocketServerState()
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "ssh-manual-session"
        let token = "bridge-token"

        defer {
            Darwin.close(listenerFD)
            Darwin.close(bridge.fd)
            unlink(socketPath)
        }

        let socketHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "workspace.remote.pty_bridge":
                legacyAssertNil(params["surface_id"])
                legacyAssertEqual(params["workspace_id"] as? String, workspaceId)
                legacyAssertEqual(params["session_id"] as? String, sessionId)
                let attachmentID = params["attachment_id"] as? String
                legacyAssertNotNil(attachmentID.flatMap { UUID(uuidString: $0) })
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "host": "127.0.0.1",
                        "port": bridge.port,
                        "token": token,
                        "session_id": sessionId,
                        "attachment_id": attachmentID ?? "attachment",
                    ]
                )
            case "workspace.remote.pty_resize":
                legacyAssertEqual(params["attachment_token"] as? String, "attach-token")
                legacyAssertNil(params["surface_id"])
                return self.v2Response(id: id, ok: true, result: ["resized": true])
            case "workspace.remote.pty_sessions":
                legacyAssertNil(params["surface_id"])
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "sessions": [],
                    ]
                )
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
        }
        let bridgeHandled = startBridgeReadyThenCloseServer(listenerFD: bridge.fd)

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment.removeValue(forKey: "CMUX_SURFACE_ID")

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-pty-attach",
                "--workspace", workspaceId,
                "--session-id", sessionId,
            ],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [socketHandled, bridgeHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertTrue(result.stdout.isEmpty, result.stdout)
        legacyAssertTrue(result.stderr.isEmpty, result.stderr)
        let methods = state.snapshot().compactMap { self.jsonObject($0)?["method"] as? String }
        legacyAssertEqual(methods, ["workspace.remote.pty_bridge", "workspace.remote.pty_resize", "workspace.remote.pty_sessions"])
    }

    @Test
    func testSSHPTYAttachBridgeResetWhenSessionGoneClearsLocalState() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshptyrst")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let bridge = try bindLoopbackTCP()
        let state = MockSocketServerState()
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let surfaceId = "33333333-3333-3333-3333-333333333333"
        let sessionId = "ssh-\(workspaceId)-\(surfaceId)"
        let token = "bridge-token"

        defer {
            Darwin.close(listenerFD)
            Darwin.close(bridge.fd)
            unlink(socketPath)
        }

        let socketHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            switch method {
            case "workspace.remote.pty_bridge":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "host": "127.0.0.1",
                        "port": bridge.port,
                        "token": token,
                        "session_id": sessionId,
                        "attachment_id": surfaceId,
                    ]
                )
            case "workspace.remote.pty_resize":
                let params = payload["params"] as? [String: Any] ?? [:]
                legacyAssertEqual(params["attachment_token"] as? String, "attach-token")
                legacyAssertEqual(params["surface_id"] as? String, surfaceId)
                return self.v2Response(id: id, ok: true, result: ["resized": true])
            case "workspace.remote.pty_sessions":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "sessions": [],
                    ]
                )
            case "workspace.remote.pty_attach_end":
                let params = payload["params"] as? [String: Any] ?? [:]
                legacyAssertEqual(params["workspace_id"] as? String, workspaceId)
                legacyAssertEqual(params["surface_id"] as? String, surfaceId)
                legacyAssertEqual(params["session_id"] as? String, sessionId)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceId,
                        "surface_id": surfaceId,
                        "session_id": sessionId,
                        "cleared_remote_pty_session": true,
                    ]
                )
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
        }
        let bridgeHandled = startBridgeReadyThenResetAfterClientEOFServer(listenerFD: bridge.fd)

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-pty-attach",
                "--workspace", workspaceId,
                "--session-id", sessionId,
                "--attachment-id", surfaceId,
            ],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [socketHandled, bridgeHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertTrue(result.stdout.isEmpty, result.stdout)
        legacyAssertTrue(result.stderr.isEmpty, result.stderr)
        let methods = state.snapshot().compactMap { self.jsonObject($0)?["method"] as? String }
        legacyAssertEqual(methods, ["workspace.remote.pty_bridge", "workspace.remote.pty_resize", "workspace.remote.pty_sessions", "workspace.remote.pty_attach_end"])
    }

    @Test
    func testSSHPTYAttachWaitUsesCurrentTerminalSizeForBridgeHandshake() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshptysize")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let bridge = try bindLoopbackTCP()
        let state = MockSocketServerState()
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let surfaceId = "33333333-3333-3333-3333-333333333333"
        let sessionId = "ssh-\(workspaceId)-\(surfaceId)"
        let token = "bridge-token"
        let bridgeRequestReceived = DispatchSemaphore(value: 0)
        let allowBridgeResponse = DispatchSemaphore(value: 0)
        let handshakeReceived = DispatchSemaphore(value: 0)
        let handshakeLock = NSLock()
        var handshakePayload: [String: Any]?
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1

        defer {
            if masterFD >= 0 { Darwin.close(masterFD) }
            if slaveFD >= 0 { Darwin.close(slaveFD) }
            Darwin.close(listenerFD)
            Darwin.close(bridge.fd)
            unlink(socketPath)
        }

        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else {
            throw NSError(domain: "cmux.tests", code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "openpty failed: \(String(cString: strerror(errno)))",
            ])
        }

        func setPTYSize(cols: Int, rows: Int) throws {
            var size = winsize(
                ws_row: UInt16(rows),
                ws_col: UInt16(cols),
                ws_xpixel: 0,
                ws_ypixel: 0
            )
            guard ioctl(masterFD, TIOCSWINSZ, &size) == 0 else {
                throw NSError(domain: "cmux.tests", code: Int(errno), userInfo: [
                    NSLocalizedDescriptionKey: "TIOCSWINSZ failed: \(String(cString: strerror(errno)))",
                ])
            }
        }

        try setPTYSize(cols: 40, rows: 12)

        let socketHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            switch method {
            case "workspace.remote.pty_bridge":
                bridgeRequestReceived.signal()
                _ = allowBridgeResponse.wait(timeout: .now() + 5)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "host": "127.0.0.1",
                        "port": bridge.port,
                        "token": token,
                        "session_id": sessionId,
                        "attachment_id": surfaceId,
                    ]
                )
            case "workspace.remote.pty_resize":
                let params = payload["params"] as? [String: Any] ?? [:]
                legacyAssertEqual(params["attachment_token"] as? String, "attach-token")
                legacyAssertEqual(params["cols"] as? Int, 132)
                legacyAssertEqual(params["rows"] as? Int, 43)
                return self.v2Response(id: id, ok: true, result: ["resized": true])
            case "workspace.remote.pty_sessions":
                return self.v2Response(id: id, ok: true, result: ["sessions": []])
            case "workspace.remote.pty_attach_end":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceId,
                        "surface_id": surfaceId,
                        "session_id": sessionId,
                        "cleared_remote_pty_session": true,
                    ]
                )
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
        }

        let bridgeHandled = legacyExpectation(description: "bridge handshake captured")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { bridgeHandled.fulfill() }
            var clientAddr = sockaddr_in()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(bridge.fd, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else { return }
            defer { Darwin.close(clientFD) }

            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while !pending.contains(0x0A) {
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if count == 0 { return }
                pending.append(buffer, count: count)
            }
            if let lineEnd = pending.firstIndex(of: 0x0A) {
                let line = pending.prefix(upTo: lineEnd)
                let payload = try? JSONSerialization.jsonObject(with: Data(line), options: []) as? [String: Any]
                handshakeLock.lock()
                handshakePayload = payload
                handshakeLock.unlock()
                handshakeReceived.signal()
            }

            let ready = #"{"type":"ready","attachment_token":"attach-token"}"# + "\n"
            _ = ready.withCString { ptr in
                Darwin.write(clientFD, ptr, strlen(ptr))
            }
        }

        let process = Process()
        let stderrPipe = Pipe()
        let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        slaveFD = -1
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = [
            "ssh-pty-attach",
            "--wait",
            "--workspace", workspaceId,
            "--session-id", sessionId,
            "--attachment-id", surfaceId,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = slaveHandle
        process.standardError = stderrPipe

        try process.run()
        slaveHandle.closeFile()
        legacyAssertEqual(bridgeRequestReceived.wait(timeout: .now() + 5), .success)
        try setPTYSize(cols: 132, rows: 43)
        allowBridgeResponse.signal()
        legacyAssertEqual(handshakeReceived.wait(timeout: .now() + 5), .success)

        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exited.signal()
        }
        legacyAssertEqual(exited.wait(timeout: .now() + 5), .success)
        legacyWait(for: [socketHandled, bridgeHandled], timeout: 5)

        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        legacyAssertEqual(process.terminationStatus, 0, stderr)
        handshakeLock.lock()
        let capturedHandshake = handshakePayload
        handshakeLock.unlock()
        legacyAssertEqual(capturedHandshake?["token"] as? String, token)
        legacyAssertEqual(capturedHandshake?["cols"] as? Int, 132)
        legacyAssertEqual(capturedHandshake?["rows"] as? Int, 43)
    }

    @Test
    func testSSHPTYAttachSendsResizeWithoutBlockingEOFLocalCleanup() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshptyresize")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let bridge = try bindLoopbackTCP()
        let state = MockSocketServerState()
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let surfaceId = "33333333-3333-3333-3333-333333333333"
        let sessionId = "ssh-\(workspaceId)-\(surfaceId)"
        let token = "bridge-token"
        let resizeRequestReceived = DispatchSemaphore(value: 0)
        let allowResizeResponse = DispatchSemaphore(value: 0)
        let bridgeReady = DispatchSemaphore(value: 0)
        let closeBridge = DispatchSemaphore(value: 0)

        defer {
            Darwin.close(listenerFD)
            Darwin.close(bridge.fd)
            unlink(socketPath)
        }

        let socketHandler: (String) -> String = { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            switch method {
            case "workspace.remote.pty_bridge":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "host": "127.0.0.1",
                        "port": bridge.port,
                        "token": token,
                        "session_id": sessionId,
                        "attachment_id": surfaceId,
                    ]
            )
            case "workspace.remote.pty_resize":
                guard let params = payload["params"] as? [String: Any],
                      params["attachment_token"] as? String == "attach-token" else {
                    return self.v2Response(
                        id: id,
                        ok: false,
                        error: ["code": "missing_token", "message": "Missing attachment token"]
                    )
                }
                resizeRequestReceived.signal()
                _ = allowResizeResponse.wait(timeout: .now() + 5)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["errors": [["error": "resize response marker"]]]
                )
            case "workspace.remote.pty_sessions":
                return self.v2Response(id: id, ok: true, result: ["sessions": []])
            case "workspace.remote.pty_attach_end":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceId,
                        "surface_id": surfaceId,
                        "session_id": sessionId,
                        "cleared_remote_pty_session": true,
                    ]
                )
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
        }
        let socketHandled = (0..<2).map { _ in startMockServer(listenerFD: listenerFD, state: state, handler: socketHandler) }

        let bridgeHandled = legacyExpectation(description: "controlled bridge handled")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { bridgeHandled.fulfill() }
            var clientAddr = sockaddr_in()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(bridge.fd, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else { return }
            defer { Darwin.close(clientFD) }

            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while !pending.contains(0x0A) {
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if count == 0 { return }
                pending.append(buffer, count: count)
            }

            let ready = #"{"type":"ready","attachment_token":"attach-token"}"# + "\n"
            _ = ready.withCString { ptr in
                Darwin.write(clientFD, ptr, strlen(ptr))
            }
            bridgeReady.signal()
            _ = closeBridge.wait(timeout: .now() + 5)
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = [
            "ssh-pty-attach",
            "--workspace", workspaceId,
            "--session-id", sessionId,
            "--attachment-id", surfaceId,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }
        legacyAssertEqual(bridgeReady.wait(timeout: .now() + 5), .success)

        legacyAssertEqual(
            resizeRequestReceived.wait(timeout: .now() + 5),
            .success,
            "Expected ssh-pty-attach to issue its initial resize RPC after bridge ready"
        )

        closeBridge.signal()
        legacyWait(for: [bridgeHandled], timeout: 5)
        allowResizeResponse.signal()

        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exited.signal()
        }
        legacyAssertEqual(exited.wait(timeout: .now() + 5), .success)

        legacyWait(for: socketHandled, timeout: 5)
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        legacyAssertEqual(process.terminationStatus, 0, stderr)
        legacyAssertEqual(stdout, "")
        legacyAssertEqual(stderr, "")
        let methods = state.snapshot().compactMap { self.jsonObject($0)?["method"] as? String }
        legacyAssertEqual(methods.filter { $0 == "workspace.remote.pty_bridge" }.count, 1)
        legacyAssertEqual(methods.filter { $0 == "workspace.remote.pty_resize" }.count, 1)
        legacyAssertEqual(methods.filter { $0 == "workspace.remote.pty_sessions" }.count, 1)
        legacyAssertEqual(methods.filter { $0 == "workspace.remote.pty_attach_end" }.count, 1)
    }

    @Test
    func testSSHSessionAttachCreatesSurfaceWithPersistedPTYSessionID() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshattach")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let surfaceId = "33333333-3333-3333-3333-333333333333"
        let sessionId = "ssh-existing-session"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            legacyAssertEqual(method, "surface.create")
            let params = payload["params"] as? [String: Any] ?? [:]
            legacyAssertEqual(params["workspace_id"] as? String, workspaceId)
            legacyAssertEqual(params["remote_pty_session_id"] as? String, sessionId)
            legacyAssertEqual(params["focus"] as? Bool, true)
            let initialCommand = params["initial_command"] as? String ?? ""
            legacyAssertTrue(initialCommand.hasPrefix("/bin/sh -c "), initialCommand)
            legacyAssertTrue(initialCommand.contains("ssh-pty-attach"), initialCommand)
            legacyAssertTrue(initialCommand.contains("--require-existing"), initialCommand)
            legacyAssertTrue(initialCommand.contains(sessionId), initialCommand)
            legacyAssertTrue(initialCommand.contains("CMUX_WORKSPACE_ID"), initialCommand)
            legacyAssertTrue(initialCommand.contains("CMUX_SURFACE_ID"), initialCommand)
            legacyAssertTrue(initialCommand.contains("254|255"), initialCommand)
            return self.v2Response(
                id: id,
                ok: true,
                result: [
                    "workspace_id": workspaceId,
                    "workspace_ref": "workspace:1",
                    "pane_id": "44444444-4444-4444-4444-444444444444",
                    "pane_ref": "pane:1",
                    "surface_id": surfaceId,
                    "surface_ref": "surface:1",
                    "type": "terminal",
                ]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-session-attach",
                "--workspace", workspaceId,
                "--session-id", sessionId,
            ],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertTrue(result.stderr.isEmpty, result.stderr)
        legacyAssertEqual(state.snapshot().count, 1)
    }

    @Test
    func testSSHPTYAttachRequireExistingPassesBridgeFlag() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshreq")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let bridge = try bindLoopbackTCP()
        let state = MockSocketServerState()
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let surfaceId = "33333333-3333-3333-3333-333333333333"
        let sessionId = "ssh-existing-session"
        let token = "bridge-token"

        defer {
            Darwin.close(listenerFD)
            Darwin.close(bridge.fd)
            unlink(socketPath)
        }

        let socketHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "workspace.remote.pty_bridge":
                legacyAssertEqual(params["workspace_id"] as? String, workspaceId)
                legacyAssertEqual(params["session_id"] as? String, sessionId)
                legacyAssertEqual(params["attachment_id"] as? String, surfaceId)
                legacyAssertEqual(params["require_existing"] as? Bool, true)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "host": "127.0.0.1",
                        "port": bridge.port,
                        "token": token,
                        "session_id": sessionId,
                        "attachment_id": surfaceId,
                    ]
                )
            case "workspace.remote.pty_attach_end":
                legacyAssertEqual(params["workspace_id"] as? String, workspaceId)
                legacyAssertEqual(params["surface_id"] as? String, surfaceId)
                legacyAssertEqual(params["session_id"] as? String, sessionId)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceId,
                        "surface_id": surfaceId,
                        "session_id": sessionId,
                        "cleared_remote_pty_session": true,
                    ]
                )
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
        }
        let bridgeHandled = startBridgeErrorServer(listenerFD: bridge.fd, message: "missing session")

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-pty-attach",
                "--wait",
                "--require-existing",
                "--workspace", workspaceId,
                "--session-id", sessionId,
                "--attachment-id", surfaceId,
            ],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [socketHandled, bridgeHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 1, result.stderr)
        legacyAssertTrue(result.stderr.contains("ssh-pty-attach: missing session"), result.stderr)
        let methods = state.snapshot().compactMap { self.jsonObject($0)?["method"] as? String }
        legacyAssertEqual(methods, ["workspace.remote.pty_bridge", "workspace.remote.pty_attach_end"])
    }

    @Test
    func testSSHPTYAttachRequireExistingSessionNotFoundFailsWithoutWaitRetry() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshreqmissing")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let surfaceId = "33333333-3333-3333-3333-333333333333"
        let sessionId = "ssh-missing-session"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let socketHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "workspace.remote.pty_bridge":
                legacyAssertEqual(params["workspace_id"] as? String, workspaceId)
                legacyAssertEqual(params["session_id"] as? String, sessionId)
                legacyAssertEqual(params["attachment_id"] as? String, surfaceId)
                legacyAssertEqual(params["require_existing"] as? Bool, true)
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: [
                        "code": "pty_session_not_found",
                        "message": "persistent PTY session \"\(sessionId)\" is not running",
                    ]
                )
            case "workspace.remote.pty_attach_end":
                legacyAssertEqual(params["workspace_id"] as? String, workspaceId)
                legacyAssertEqual(params["surface_id"] as? String, surfaceId)
                legacyAssertEqual(params["session_id"] as? String, sessionId)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceId,
                        "surface_id": surfaceId,
                        "session_id": sessionId,
                        "cleared_remote_pty_session": true,
                    ]
                )
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-pty-attach",
                "--wait",
                "--require-existing",
                "--workspace", workspaceId,
                "--session-id", sessionId,
                "--attachment-id", surfaceId,
            ],
            environment: environment,
            timeout: 3
        )

        legacyWait(for: [socketHandled], timeout: 3)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 1, result.stderr)
        legacyAssertTrue(result.stderr.contains("persistent SSH PTY session is no longer running"), result.stderr)
        let methods = state.snapshot().compactMap { self.jsonObject($0)?["method"] as? String }
        legacyAssertEqual(methods, ["workspace.remote.pty_bridge", "workspace.remote.pty_attach_end"])
    }

    @Test
    func testSSHSessionListAllWorkspacesReportsQueryErrors() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshlist")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceId = "22222222-2222-2222-2222-222222222222"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            legacyAssertEqual(method, "workspace.remote.pty_sessions")
            let params = payload["params"] as? [String: Any] ?? [:]
            legacyAssertEqual(params["all_workspaces"] as? Bool, true)
            return self.v2Response(
                id: id,
                ok: true,
                result: [
                    "sessions": [],
                    "errors": [
                        [
                            "workspace_id": workspaceId,
                            "workspace_ref": "workspace:4",
                            "error": "remote connection is not active",
                        ],
                    ],
                ]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-session-list",
                "--all-workspaces",
            ],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 1, result.stderr)
        legacyAssertFalse(result.stdout.contains("No persisted SSH PTY sessions"), result.stdout)
        legacyAssertTrue(result.stderr.contains("ssh-session-list failed for 1 remote workspace"), result.stderr)
        legacyAssertTrue(result.stderr.contains("workspace:4"), result.stderr)
        legacyAssertTrue(result.stderr.contains("remote connection is not active"), result.stderr)
    }

    @Test
    func testSSHSessionCleanupAllReportsPartialFailures() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshclean")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let closedSessionId = "ssh-session-closed"
        let failedSessionId = "ssh-session-failed"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "workspace.remote.pty_sessions":
                legacyAssertEqual(params["workspace_id"] as? String, workspaceId)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "sessions": [
                            [
                                "workspace_id": workspaceId,
                                "session_id": closedSessionId,
                            ],
                            [
                                "workspace_id": workspaceId,
                                "session_id": failedSessionId,
                            ],
                            [
                                "workspace_id": workspaceId,
                                "session_id": "   ",
                            ],
                        ],
                    ]
                )
            case "workspace.remote.pty_close":
                legacyAssertEqual(params["workspace_id"] as? String, workspaceId)
                let sessionId = params["session_id"] as? String
                if sessionId == closedSessionId {
                    return self.v2Response(id: id, ok: true, result: ["closed": true])
                }
                legacyAssertEqual(sessionId, failedSessionId)
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "remote_pty_error", "message": "close failed"]
                )
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-session-cleanup",
                "--workspace", workspaceId,
                "--all",
            ],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 1, result.stderr)
        legacyAssertTrue(result.stdout.contains("Closed 1 persisted SSH PTY session"), result.stdout)
        legacyAssertTrue(result.stderr.contains("ssh-session-cleanup failed for 2 persisted SSH PTY sessions"), result.stderr)
        legacyAssertTrue(result.stderr.contains(failedSessionId), result.stderr)
        legacyAssertTrue(result.stderr.contains("missing session_id in SSH PTY session list response"), result.stderr)
        legacyAssertTrue(result.stderr.contains("remote PTY operation failed"), result.stderr)
        legacyAssertFalse(result.stderr.contains("close failed"), result.stderr)
    }

    @Test
    func testSSHSessionCleanupAllWorkspacesReportsListErrors() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshcleanall")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let closedSessionId = "ssh-session-closed"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "workspace.remote.pty_sessions":
                legacyAssertEqual(params["all_workspaces"] as? Bool, true)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "sessions": [
                            [
                                "workspace_id": workspaceId,
                                "session_id": closedSessionId,
                            ],
                        ],
                        "errors": [
                            [
                                "workspace_ref": "workspace:4",
                                "error": "remote connection is not active",
                            ],
                        ],
                    ]
                )
            case "workspace.remote.pty_close":
                legacyAssertEqual(params["workspace_id"] as? String, workspaceId)
                legacyAssertEqual(params["session_id"] as? String, closedSessionId)
                return self.v2Response(id: id, ok: true, result: ["closed": true])
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-session-cleanup",
                "--all-workspaces",
                "--all",
            ],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 1, result.stderr)
        legacyAssertTrue(result.stdout.contains("Closed 1 persisted SSH PTY session"), result.stdout)
        legacyAssertTrue(result.stderr.contains("ssh-session-cleanup failed for 1 persisted SSH PTY session"), result.stderr)
        legacyAssertTrue(result.stderr.contains("workspace-query"), result.stderr)
        legacyAssertTrue(result.stderr.contains("workspace:4"), result.stderr)
        legacyAssertTrue(result.stderr.contains("remote connection is not active"), result.stderr)
    }

    @Test
    func testSSHSessionCleanupAllWorkspacesAllRejectsMissingWorkspaceID() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshcleanallmissing")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let sessionId = "ssh-session-missing-workspace"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "workspace.remote.pty_sessions":
                legacyAssertEqual(params["all_workspaces"] as? Bool, true)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "sessions": [
                            [
                                "workspace_ref": "workspace:missing",
                                "session_id": sessionId,
                            ],
                        ],
                    ]
                )
            case "workspace.remote.pty_close":
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_close", "message": "cleanup sent unscoped close"]
                )
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-session-cleanup",
                "--all-workspaces",
                "--all",
            ],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 1, result.stderr)
        legacyAssertFalse(state.snapshot().contains { $0.contains("workspace.remote.pty_close") })
        legacyAssertTrue(result.stderr.contains("ssh-session-cleanup failed for 1 persisted SSH PTY session"), result.stderr)
        legacyAssertTrue(result.stderr.contains(sessionId), result.stderr)
        legacyAssertTrue(result.stderr.contains("workspace:missing"), result.stderr)
        legacyAssertTrue(result.stderr.contains("missing workspace_id in SSH PTY session list response"), result.stderr)
    }

    @Test
    func testSSHSessionCleanupAllWorkspacesSessionIDRejectsMissingWorkspaceID() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshcleansessionmissing")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let sessionId = "ssh-session-missing-workspace"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "workspace.remote.pty_sessions":
                legacyAssertEqual(params["all_workspaces"] as? Bool, true)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "sessions": [
                            [
                                "workspace_ref": "workspace:missing",
                                "session_id": sessionId,
                            ],
                        ],
                    ]
                )
            case "workspace.remote.pty_close":
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_close", "message": "cleanup sent unscoped close"]
                )
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-session-cleanup",
                "--all-workspaces",
                "--session-id", sessionId,
            ],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 1, result.stderr)
        legacyAssertFalse(state.snapshot().contains { $0.contains("workspace.remote.pty_close") })
        legacyAssertTrue(result.stderr.contains("ssh-session-cleanup failed for 1 persisted SSH PTY session"), result.stderr)
        legacyAssertTrue(result.stderr.contains(sessionId), result.stderr)
        legacyAssertTrue(result.stderr.contains("workspace:missing"), result.stderr)
        legacyAssertTrue(result.stderr.contains("missing workspace_id in SSH PTY session list response"), result.stderr)
    }

    @Test
    func testSSHSessionCleanupAllWorkspacesSessionIDReportsNotFound() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshcleansessiongone")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let sessionId = "ssh-session-gone"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            switch method {
            case "workspace.remote.pty_sessions":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "sessions": [],
                    ]
                )
            case "workspace.remote.pty_close":
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_close", "message": "cleanup sent close for missing session"]
                )
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-session-cleanup",
                "--all-workspaces",
                "--session-id", sessionId,
            ],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 1, result.stderr)
        legacyAssertFalse(state.snapshot().contains { $0.contains("workspace.remote.pty_close") })
        legacyAssertTrue(result.stderr.contains("ssh-session-cleanup failed for 1 persisted SSH PTY session"), result.stderr)
        legacyAssertTrue(result.stderr.contains(sessionId), result.stderr)
        legacyAssertTrue(result.stderr.contains("persistent SSH PTY session is no longer running"), result.stderr)
    }

    @Test
    func testSSHSessionCleanupAllWorkspacesSessionIDCountsDuplicateIDsPerWorkspace() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshcleandup")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let sessionId = "shared-session-id"
        let workspaceA = "22222222-2222-2222-2222-222222222222"
        let workspaceB = "33333333-3333-3333-3333-333333333333"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "workspace.remote.pty_sessions":
                legacyAssertEqual(params["all_workspaces"] as? Bool, true)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "sessions": [
                            [
                                "workspace_id": workspaceA,
                                "session_id": sessionId,
                            ],
                            [
                                "workspace_id": workspaceB,
                                "session_id": sessionId,
                            ],
                        ],
                    ]
                )
            case "workspace.remote.pty_close":
                legacyAssertEqual(params["session_id"] as? String, sessionId)
                legacyAssertTrue([workspaceA, workspaceB].contains(params["workspace_id"] as? String))
                return self.v2Response(id: id, ok: true, result: ["closed": true])
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-session-cleanup",
                "--all-workspaces",
                "--session-id", sessionId,
            ],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertTrue(result.stdout.contains("Closed 2 persisted SSH PTY sessions"), result.stdout)

        let closedWorkspaces = state.snapshot().compactMap { line -> String? in
            guard let payload = self.jsonObject(line),
                  payload["method"] as? String == "workspace.remote.pty_close",
                  let params = payload["params"] as? [String: Any],
                  params["session_id"] as? String == sessionId else {
                return nil
            }
            return params["workspace_id"] as? String
        }
        legacyAssertEqual(closedWorkspaces.count, 2)
        legacyAssertEqual(Set(closedWorkspaces), Set([workspaceA, workspaceB]))
    }

    @Test
    func testRightSidebarCLIResolvesWindowAndWorkspaceHandlesBeforeForwarding() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("rs-target")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let windowId = "11111111-1111-1111-1111-111111111111"
        let workspaceId = "22222222-2222-2222-2222-222222222222"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let payload = self.jsonObject(line),
               let id = payload["id"] as? String,
               let method = payload["method"] as? String {
                switch method {
                case "window.list":
                    return self.v2Response(
                        id: id,
                        ok: true,
                        result: [
                            "windows": [
                                ["id": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", "index": 1],
                                ["id": windowId, "index": 3],
                            ]
                        ]
                    )
                case "workspace.list":
                    let params = payload["params"] as? [String: Any] ?? [:]
                    legacyAssertEqual(params["window_id"] as? String, windowId)
                    return self.v2Response(
                        id: id,
                        ok: true,
                        result: [
                            "workspaces": [
                                ["id": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", "index": 1],
                                ["id": workspaceId, "index": 2],
                            ]
                        ]
                    )
                default:
                    return self.v2Response(
                        id: id,
                        ok: false,
                        error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                    )
                }
            }

            legacyAssertEqual(line, "right_sidebar set find --tab=\(workspaceId) --window=\(windowId)")
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["right-sidebar", "set", "find", "--window", "window:3", "--workspace", "workspace:2"],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertTrue(result.stdout.isEmpty, result.stdout)
        legacyAssertTrue(result.stderr.isEmpty, result.stderr)
        legacyAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["window.list", "workspace.list"]
        )
        legacyAssertEqual(state.commands.last, "right_sidebar set find --tab=\(workspaceId) --window=\(windowId)")
    }

    @Test
    func testRightSidebarCLIRejectsUnresolvedWorkspaceHandleBeforeForwarding() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("rs-miss")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return "ERROR: Unexpected command \(line)"
            }
            legacyAssertEqual(method, "workspace.list")
            return self.v2Response(
                id: id,
                ok: true,
                result: [
                    "workspaces": [
                        ["id": "11111111-1111-1111-1111-111111111111", "index": 1]
                    ]
                ]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["right-sidebar", "show", "--workspace", "workspace:99"],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 1, result.stderr)
        legacyAssertTrue(result.stdout.isEmpty, result.stdout)
        legacyAssertTrue(result.stderr.contains("Workspace ref not found"), result.stderr)
        legacyAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["workspace.list"]
        )
        legacyAssertFalse(
            state.commands.contains { $0.hasPrefix("right_sidebar ") },
            "Expected no right_sidebar command after target resolution failed, saw \(state.commands)"
        )
    }

    @MainActor
    @Test
    func testNotifyWithUUIDSurfaceDoesNotRequireCallerWorkspaceOrWindow() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("notify-uuid-surface")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let callerWorkspace = "11111111-1111-1111-1111-111111111111"
        let callerSurface = "22222222-2222-2222-2222-222222222222"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String,
               let method = payload["method"] as? String {
                guard method == "notification.create" else {
                    return self.v2Response(
                        id: id,
                        ok: false,
                        error: ["code": "unexpected", "message": "Unexpected method \(method)"]
                    )
                }

                let params = payload["params"] as? [String: Any] ?? [:]
                legacyAssertNil(params["workspace_id"], "surface UUIDs should not be constrained to the caller workspace")
                legacyAssertNil(params["window_id"], "surface UUIDs should not require an explicit window")
                legacyAssertEqual(params["surface_id"] as? String, callerSurface)
                legacyAssertEqual(params["body"] as? String, "Body")
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["workspace_id": callerWorkspace, "surface_id": callerSurface]
                )
            }

            return "ERROR: Unexpected command \(line)"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = callerWorkspace
        environment["CMUX_SURFACE_ID"] = callerSurface
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["notify", "--surface", callerSurface, "--title", "UUID", "--body", "Body"],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertEqual(result.stdout, "OK\n")
        legacyAssertTrue(result.stderr.isEmpty, result.stderr)
        legacyAssertTrue(
            state.commands.contains { $0.contains("\"method\":\"notification.create\"") },
            "Expected notify to use single-call UUID notification path, saw \(state.commands)"
        )
    }

    @Test
    func testNotificationCLIActionsUseSocketAPIAndParseExtendedFields() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("notif-actions")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let notificationId = UUID().uuidString
        let workspaceId = UUID().uuidString
        let surfaceId = UUID().uuidString
        let openNotificationId = UUID().uuidString
        let openWorkspaceId = UUID().uuidString
        let openSurfaceId = UUID().uuidString
        let jumpNotificationId = UUID().uuidString

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        func run(
            _ arguments: [String],
            handler: @escaping @Sendable (String) -> String
        ) -> ProcessRunResult {
            let serverHandled = startMockServer(listenerFD: listenerFD, state: state, handler: handler)
            let result = runProcess(
                executablePath: cliPath,
                arguments: ["--socket", socketPath] + arguments,
                environment: environment,
                timeout: 5
            )
            legacyWait(for: [serverHandled], timeout: 5)
            return result
        }

        var result = run(["list-notifications", "--json", "--id-format", "uuids"]) { line in
            guard line == "list_notifications" else {
                return "ERROR: Unexpected command \(line)"
            }
            return "0:\(notificationId)|\(workspaceId)|\(surfaceId)|unread|List Fields|cli-test|body|2026-01-01T00:00:00Z|pct:CLI%7CNotification Workspace"
        }
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        var rows = try notificationRows(from: result.stdout)
        var row = try legacyUnwrap(rows.first(where: { $0["id"] as? String == notificationId }))
        legacyAssertEqual(row["workspace_id"] as? String, workspaceId)
        legacyAssertEqual(row["surface_id"] as? String, surfaceId)
        legacyAssertEqual(row["created_at"] as? String, "2026-01-01T00:00:00Z")
        legacyAssertEqual(row["tab_title"] as? String, "CLI|Notification Workspace")

        result = run(["--json", "list-notifications", "--id-format", "uuids"]) { line in
            guard line == "list_notifications" else {
                return "ERROR: Unexpected command \(line)"
            }
            return "0:\(notificationId)|\(workspaceId)|\(surfaceId)|unread|List Fields|cli-test|body|2026-01-01T00:00:00Z|pct:CLI%7CNotification Workspace"
        }
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        rows = try notificationRows(from: result.stdout)
        row = try legacyUnwrap(rows.first(where: { $0["id"] as? String == notificationId }))
        legacyAssertEqual(row["created_at"] as? String, "2026-01-01T00:00:00Z")

        result = run(["mark-notification-read", "--id", notificationId, "--json", "--id-format", "uuids"]) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            legacyAssertEqual(method, "notification.mark_read")
            let params = payload["params"] as? [String: Any] ?? [:]
            legacyAssertEqual(params["id"] as? String, notificationId)
            return self.v2Response(id: id, ok: true, result: ["marked_read": 1, "id": notificationId])
        }
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        let markByIdPayload = try jsonPayload(from: result.stdout)
        legacyAssertEqual(markByIdPayload["marked_read"] as? Int, 1)
        legacyAssertEqual(markByIdPayload["id"] as? String, notificationId)

        result = run(["dismiss-notification", "--all-read", "--json", "--id-format", "uuids"]) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            legacyAssertEqual(method, "notification.dismiss")
            let params = payload["params"] as? [String: Any] ?? [:]
            legacyAssertEqual(params["all_read"] as? Bool, true)
            return self.v2Response(id: id, ok: true, result: ["dismissed": 1, "all_read": true])
        }
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        let dismissPayload = try jsonPayload(from: result.stdout)
        legacyAssertEqual(dismissPayload["dismissed"] as? Int, 1)
        legacyAssertEqual(dismissPayload["all_read"] as? Bool, true)

        result = run([
            "mark-notification-read",
            "--workspace", workspaceId,
            "--surface", surfaceId,
            "--json",
            "--id-format",
            "uuids",
        ]) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            legacyAssertEqual(method, "notification.mark_read")
            let params = payload["params"] as? [String: Any] ?? [:]
            legacyAssertEqual(params["tab_id"] as? String, workspaceId)
            legacyAssertEqual(params["surface_id"] as? String, surfaceId)
            return self.v2Response(
                id: id,
                ok: true,
                result: ["marked_read": 1, "workspace_id": workspaceId, "surface_id": surfaceId]
            )
        }
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        let markScopedPayload = try jsonPayload(from: result.stdout)
        legacyAssertEqual(markScopedPayload["workspace_id"] as? String, workspaceId)
        legacyAssertEqual(markScopedPayload["surface_id"] as? String, surfaceId)

        result = run(["open-notification", "--id", openNotificationId, "--json", "--id-format", "uuids"]) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            legacyAssertEqual(method, "notification.open")
            let params = payload["params"] as? [String: Any] ?? [:]
            legacyAssertEqual(params["id"] as? String, openNotificationId)
            return self.v2Response(
                id: id,
                ok: true,
                result: [
                    "id": openNotificationId,
                    "workspace_id": openWorkspaceId,
                    "surface_id": openSurfaceId,
                    "opened": true,
                    "is_read": true,
                ]
            )
        }
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        let openPayload = try jsonPayload(from: result.stdout)
        legacyAssertEqual(openPayload["workspace_id"] as? String, openWorkspaceId)
        legacyAssertEqual(openPayload["surface_id"] as? String, openSurfaceId)
        legacyAssertEqual(openPayload["is_read"] as? Bool, true)

        result = run(["jump-to-unread", "--json", "--id-format", "uuids"]) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            legacyAssertEqual(method, "notification.jump_to_unread")
            let params = payload["params"] as? [String: Any] ?? [:]
            legacyAssertTrue(params.isEmpty, "jump-to-unread should not send selector params")
            return self.v2Response(
                id: id,
                ok: true,
                result: [
                    "id": jumpNotificationId,
                    "workspace_id": openWorkspaceId,
                    "surface_id": openSurfaceId,
                    "opened": true,
                    "is_read": true,
                ]
            )
        }
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        let jumpPayload = try jsonPayload(from: result.stdout)
        legacyAssertEqual(jumpPayload["id"] as? String, jumpNotificationId)
        legacyAssertEqual(jumpPayload["workspace_id"] as? String, openWorkspaceId)
        legacyAssertEqual(jumpPayload["surface_id"] as? String, openSurfaceId)
        legacyAssertEqual(jumpPayload["is_read"] as? Bool, true)

        let methods = state.snapshot().map { command -> String in
            if command == "list_notifications" {
                return command
            }
            return self.jsonObject(command)?["method"] as? String ?? "invalid"
        }
        legacyAssertEqual(
            methods,
            [
                "list_notifications",
                "list_notifications",
                "notification.mark_read",
                "notification.dismiss",
                "notification.mark_read",
                "notification.open",
                "notification.jump_to_unread",
            ]
        )
    }

    @Test
    func testListNotificationsKeepsOldServerPipeBodiesAsBody() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("notif-old-pipe")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let notificationId = UUID().uuidString
        let workspaceId = UUID().uuidString

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard line == "list_notifications" else {
                return "ERROR: Unexpected command \(line)"
            }
            return "0:\(notificationId)|\(workspaceId)|none|unread|Legacy|Pipe|alpha|beta|gamma"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--socket", socketPath, "list-notifications", "--json", "--id-format", "uuids"],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        let rows = try notificationRows(from: result.stdout)
        let row = try legacyUnwrap(rows.first)
        legacyAssertEqual(row["id"] as? String, notificationId)
        legacyAssertEqual(row["workspace_id"] as? String, workspaceId)
        legacyAssertEqual(row["body"] as? String, "alpha|beta|gamma")
        legacyAssertTrue(row["created_at"] is NSNull)
        legacyAssertTrue(row["tab_title"] is NSNull)
    }

    @Test
    func testCodexPromptSubmitRebindsRestoredSessionToCurrentCallerSurface() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex-rebind")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-rebind-\(UUID().uuidString)", isDirectory: true)
        let staleWorkspaceId = "11111111-1111-1111-1111-111111111111"
        let staleSurfaceId = "22222222-2222-2222-2222-222222222222"
        let currentWorkspaceId = "33333333-3333-3333-3333-333333333333"
        let currentSurfaceId = "44444444-4444-4444-4444-444444444444"
        let sessionId = "codex-restored-session-rebind"
        let ttyName = "ttys-test-codex-rebind"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let storeURL = root.appendingPathComponent("codex-hook-sessions.json", isDirectory: false)
        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": staleWorkspaceId,
                    "surfaceId": staleSurfaceId,
                    "cwd": root.path,
                    "startedAt": now,
                    "updatedAt": now,
                    "launchCommand": [
                        "launcher": "codex",
                        "executablePath": "/usr/local/bin/codex",
                        "arguments": ["/usr/local/bin/codex", "--model", "gpt-5.4"],
                        "workingDirectory": root.path,
                        "environment": ["CODEX_HOME": root.appendingPathComponent("codex-home", isDirectory: true).path],
                        "capturedAt": now,
                        "source": "test",
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted]).write(to: storeURL, options: .atomic)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else {
                return line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
                    ? self.malformedRequestResponse(raw: line)
                    : "OK"
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                let params = payload["params"] as? [String: Any] ?? [:]
                if params["workspace_id"] as? String == currentWorkspaceId {
                    return self.surfaceListResponse(id: id, surfaceId: currentSurfaceId)
                }
                return self.v2Response(id: id, ok: false, error: ["code": "not_found", "message": "workspace not found"])
            case "debug.terminals":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["terminals": [["tty": ttyName, "workspace_id": currentWorkspaceId, "surface_id": currentSurfaceId]]]
                )
            case "workspace.current":
                return self.v2Response(id: id, ok: true, result: ["workspace_id": currentWorkspaceId])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = currentWorkspaceId
        environment["CMUX_SURFACE_ID"] = currentSurfaceId
        environment["CMUX_CLI_TTY_NAME"] = ttyName
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CODEX_HOME"] = root.appendingPathComponent("codex-home", isDirectory: true).path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"UserPromptSubmit","prompt":"continue"}"#,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertEqual(result.stdout, "{}\n")

        let json = try legacyUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
        let sessions = try legacyUnwrap(json["sessions"] as? [String: Any])
        let session = try legacyUnwrap(sessions[sessionId] as? [String: Any])
        legacyAssertEqual(session["workspaceId"] as? String, currentWorkspaceId)
        legacyAssertEqual(session["surfaceId"] as? String, currentSurfaceId)
        legacyAssertTrue(
            state.commands.contains { $0.contains("set_status codex Running") && $0.contains("--tab=\(currentWorkspaceId)") },
            "Expected Codex prompt status to target current workspace, saw \(state.commands)"
        )
    }

    @Test
    func testNewPaneWindowFlagScopesWorkspaceIndex() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("pane-window")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let windowId = "11111111-1111-1111-1111-111111111111"
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let paneId = "33333333-3333-3333-3333-333333333333"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }

            switch method {
            case "workspace.list":
                let params = payload["params"] as? [String: Any] ?? [:]
                legacyAssertEqual(params["window_id"] as? String, windowId)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspaces": [
                            [
                                "id": workspaceId,
                                "ref": "workspace:1",
                                "index": 0,
                            ],
                        ],
                    ]
                )
            case "pane.create":
                let params = payload["params"] as? [String: Any] ?? [:]
                legacyAssertEqual(params["window_id"] as? String, windowId)
                legacyAssertEqual(params["workspace_id"] as? String, workspaceId)
                legacyAssertEqual(params["direction"] as? String, "right")
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "window_id": windowId,
                        "workspace_id": workspaceId,
                        "pane_id": paneId,
                    ]
                )
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected method: \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["new-pane", "--window", windowId, "--workspace", "0", "--direction", "right"],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertTrue(result.stderr.isEmpty, result.stderr)
        legacyAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["workspace.list", "pane.create"]
        )
    }

    @Test
    func testFocusPaneWindowFlagRejectsPaneFromOtherWindow() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("pane-other-window")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let targetWindowId = "11111111-1111-1111-1111-111111111111"
        let targetWorkspaceId = "22222222-2222-2222-2222-222222222222"
        let targetPaneId = "33333333-3333-3333-3333-333333333333"
        let otherPaneId = "44444444-4444-4444-4444-444444444444"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "workspace.list":
                legacyAssertEqual(params["window_id"] as? String, targetWindowId)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspaces": [
                            [
                                "id": targetWorkspaceId,
                                "ref": "workspace:1",
                                "index": 0,
                            ],
                        ],
                    ]
                )
            case "pane.list":
                legacyAssertEqual(params["window_id"] as? String, targetWindowId)
                legacyAssertEqual(params["workspace_id"] as? String, targetWorkspaceId)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "panes": [
                            [
                                "id": targetPaneId,
                                "ref": "pane:1",
                                "index": 0,
                            ],
                        ],
                    ]
                )
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected method: \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["focus-pane", "--window", targetWindowId, "--pane", otherPaneId],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertNotEqual(result.status, 0)
        legacyAssertTrue(result.stderr.contains("Pane not found in window"), result.stderr)
        legacyAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["workspace.list", "pane.list"]
        )
    }

    @Test
    func testReorderSurfaceWindowFlagRejectsSurfaceFromOtherWindow() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("surface-other-window")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let targetWindowId = "11111111-1111-1111-1111-111111111111"
        let targetWorkspaceId = "22222222-2222-2222-2222-222222222222"
        let targetSurfaceId = "33333333-3333-3333-3333-333333333333"
        let otherSurfaceId = "44444444-4444-4444-4444-444444444444"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "workspace.list":
                legacyAssertEqual(params["window_id"] as? String, targetWindowId)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspaces": [
                            [
                                "id": targetWorkspaceId,
                                "ref": "workspace:1",
                                "index": 0,
                            ],
                        ],
                    ]
                )
            case "surface.list":
                legacyAssertEqual(params["window_id"] as? String, targetWindowId)
                legacyAssertEqual(params["workspace_id"] as? String, targetWorkspaceId)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "surfaces": [
                            [
                                "id": targetSurfaceId,
                                "ref": "surface:1",
                                "index": 0,
                            ],
                        ],
                    ]
                )
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected method: \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["reorder-surface", "--window", targetWindowId, "--surface", otherSurfaceId, "--index", "0"],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertNotEqual(result.status, 0)
        legacyAssertTrue(result.stderr.contains("Surface not found in window"), result.stderr)
        legacyAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["workspace.list", "surface.list"]
        )
    }

    @Test
    func testSendWindowFlagRejectsUnknownWindowRefBeforeMutation() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("send-window-ref")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let existingWindowId = "11111111-1111-1111-1111-111111111111"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }

            switch method {
            case "window.list":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "windows": [
                            [
                                "id": existingWindowId,
                                "ref": "window:1",
                                "index": 0,
                            ],
                        ],
                    ]
                )
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected method: \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["send", "--window", "window:2", "--", "should-not-send"],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertNotEqual(result.status, 0)
        legacyAssertTrue(result.stderr.contains("Window not found: window:2"), result.stderr)
        legacyAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["window.list"]
        )
    }

    @Test
    func testVMNewWindowFlagValidatesBeforeCreate() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-window-validate")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let missingWindowId = "11111111-1111-1111-1111-111111111111"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }

            guard method == "window.list" else {
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected method: \(method)"])
            }
            return self.v2Response(id: id, ok: true, result: ["windows": []])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "new", "--window", missingWindowId],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 1, result.stderr)
        legacyAssertTrue(result.stderr.contains("Window not found: \(missingWindowId)"), result.stderr)
        legacyAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["window.list"]
        )
    }

    @Test
    func testVMNewWindowFlagAcceptsCaseInsensitiveUUID() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-window-case")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let listedWindowId = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        let requestedWindowId = listedWindowId.lowercased()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }

            switch method {
            case "window.list":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "windows": [
                            [
                                "id": listedWindowId,
                                "ref": "window:1",
                                "index": 0,
                            ],
                        ],
                    ]
                )
            case "vm.create":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "id": "vm-test-case-window",
                        "provider": "freestyle",
                        "image": "default",
                    ]
                )
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected method: \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "new", "--window", requestedWindowId, "--detach"],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertTrue(result.stdout.contains("OK vm-test-case-window"), result.stdout)
        legacyAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["window.list", "vm.create"]
        )
    }

    @Test
    func testPipePaneWindowFlagDoesNotBecomePositionalCommandText() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("pipe-window")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let windowId = "11111111-1111-1111-1111-111111111111"
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let surfaceId = "33333333-3333-3333-3333-333333333333"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            let params = payload["params"] as? [String: Any] ?? [:]

            switch method {
            case "window.list":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "windows": [
                            [
                                "id": windowId,
                                "ref": "window:2",
                                "index": 2,
                            ],
                        ],
                    ]
                )
            case "system.identify":
                legacyAssertEqual(params["window_id"] as? String, windowId)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "focused": [
                            "window_id": windowId,
                            "workspace_id": workspaceId,
                            "surface_id": surfaceId,
                        ],
                    ]
                )
            case "surface.read_text":
                legacyAssertEqual(params["window_id"] as? String, windowId)
                legacyAssertEqual(params["surface_id"] as? String, surfaceId)
                return self.v2Response(id: id, ok: true, result: ["text": "hello\n"])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected method: \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["pipe-pane", "--window", "window:2", "cat"],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertEqual(result.stdout, "hello\nOK\n")
        legacyAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["window.list", "system.identify", "surface.read_text"]
        )
    }

    @Test
    func testPipePaneWindowWorkspaceOmittedSurfaceDoesNotUseSelectedWorkspaceSurface() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("pipe-window-workspace")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let windowId = "11111111-1111-1111-1111-111111111111"
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let selectedWorkspaceSurfaceId = "33333333-3333-3333-3333-333333333333"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            let params = payload["params"] as? [String: Any] ?? [:]

            switch method {
            case "window.list":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "windows": [
                            [
                                "id": windowId,
                                "ref": "window:2",
                                "index": 2,
                            ],
                        ],
                    ]
                )
            case "workspace.list":
                legacyAssertEqual(params["window_id"] as? String, windowId)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspaces": [
                            [
                                "id": workspaceId,
                                "ref": "workspace:2",
                                "index": 2,
                            ],
                        ],
                    ]
                )
            case "system.identify":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "focused": [
                            "window_id": windowId,
                            "workspace_id": "44444444-4444-4444-4444-444444444444",
                            "surface_id": selectedWorkspaceSurfaceId,
                        ],
                    ]
                )
            case "surface.read_text":
                legacyAssertEqual(params["window_id"] as? String, windowId)
                legacyAssertEqual(params["workspace_id"] as? String, workspaceId)
                legacyAssertNil(params["surface_id"], line)
                return self.v2Response(id: id, ok: true, result: ["text": "workspace text\n"])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected method: \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["pipe-pane", "--window", "window:2", "--workspace", "workspace:2", "cat"],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertEqual(result.stdout, "workspace text\nOK\n")
        legacyAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["window.list", "workspace.list", "surface.read_text"]
        )
    }

    @Test
    func testRespawnPaneWindowFlagDoesNotBecomePositionalCommandText() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("respawn-window")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let windowId = "11111111-1111-1111-1111-111111111111"
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let surfaceId = "33333333-3333-3333-3333-333333333333"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            let params = payload["params"] as? [String: Any] ?? [:]

            switch method {
            case "window.list":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "windows": [
                            [
                                "id": windowId,
                                "ref": "window:2",
                                "index": 2,
                            ],
                        ],
                    ]
                )
            case "system.identify":
                legacyAssertEqual(params["window_id"] as? String, windowId)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "focused": [
                            "window_id": windowId,
                            "workspace_id": workspaceId,
                            "surface_id": surfaceId,
                        ],
                    ]
                )
            case "surface.send_text":
                legacyAssertEqual(params["window_id"] as? String, windowId)
                legacyAssertEqual(params["surface_id"] as? String, surfaceId)
                legacyAssertEqual(params["text"] as? String, "echo fresh\n")
                return self.v2Response(id: id, ok: true, result: ["surface_id": surfaceId])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected method: \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["respawn-pane", "--window", "window:2", "echo", "fresh"],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["window.list", "system.identify", "surface.send_text"]
        )
    }

    @Test
    func testMoveSurfaceWindowFlagKeepsIndexedSourceInCallerContext() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("move-surface-window")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let targetWindowId = "11111111-1111-1111-1111-111111111111"
        let sourceSurfaceId = "22222222-2222-2222-2222-222222222222"
        let targetWorkspaceId = "33333333-3333-3333-3333-333333333333"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            let params = payload["params"] as? [String: Any] ?? [:]

            switch method {
            case "surface.list":
                legacyAssertNil(params["window_id"])
                legacyAssertNil(params["workspace_id"])
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "surfaces": [
                            [
                                "id": sourceSurfaceId,
                                "ref": "surface:1",
                                "index": 0,
                            ],
                        ],
                    ]
                )
            case "surface.move":
                legacyAssertEqual(params["surface_id"] as? String, sourceSurfaceId)
                legacyAssertEqual(params["window_id"] as? String, targetWindowId)
                legacyAssertEqual(params["workspace_id"] as? String, targetWorkspaceId)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "surface_id": sourceSurfaceId,
                        "window_id": targetWindowId,
                        "workspace_id": targetWorkspaceId,
                    ]
                )
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected method: \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["move-surface", "--surface", "0", "--workspace", targetWorkspaceId, "--window", targetWindowId],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertTrue(result.stderr.isEmpty, result.stderr)
        legacyAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["surface.list", "surface.move"]
        )
    }

    @Test
    func testMoveSurfaceWindowFlagAllowsSourceSurfaceRefFromOtherWindow() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("move-surface-cross-window")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let targetWindowId = "11111111-1111-1111-1111-111111111111"
        let sourceSurfaceRef = "surface:1"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            let params = payload["params"] as? [String: Any] ?? [:]

            guard method == "surface.move" else {
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected method: \(method)"])
            }
            legacyAssertEqual(params["surface_id"] as? String, sourceSurfaceRef)
            legacyAssertEqual(params["window_id"] as? String, targetWindowId)
            return self.v2Response(
                id: id,
                ok: true,
                result: [
                    "surface_ref": sourceSurfaceRef,
                    "window_id": targetWindowId,
                ]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["move-surface", "--surface", sourceSurfaceRef, "--window", targetWindowId],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertTrue(result.stderr.isEmpty, result.stderr)
        legacyAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["surface.move"]
        )
    }

    @Test
    func testSidebarMetadataWindowFlagTargetsSelectedWorkspaceInWindow() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("status-window")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let windowId = "11111111-1111-1111-1111-111111111111"
        let workspaceId = "22222222-2222-2222-2222-222222222222"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let payload = self.jsonObject(line),
               let id = payload["id"] as? String,
               let method = payload["method"] as? String {
                guard method == "workspace.current" else {
                    return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected method: \(method)"])
                }
                let params = payload["params"] as? [String: Any] ?? [:]
                legacyAssertEqual(params["window_id"] as? String, windowId)
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceId])
            }

            legacyAssertTrue(line.hasPrefix("set_status build running"), line)
            legacyAssertTrue(line.contains("--tab=\(workspaceId)"), line)
            legacyAssertFalse(line.contains("--window"), line)
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["set-status", "build", "running", "--window", windowId],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertEqual(result.stdout, "OK\n")
        legacyAssertTrue(result.stderr.isEmpty, result.stderr)
    }

    @Test
    func testSidebarMetadataWindowFlagAfterSeparatorStaysMessageText() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("log-separator")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let windowId = "11111111-1111-1111-1111-111111111111"
        let workspaceId = "22222222-2222-2222-2222-222222222222"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let payload = self.jsonObject(line),
               let id = payload["id"] as? String,
               let method = payload["method"] as? String {
                guard method == "workspace.current" else {
                    return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected method: \(method)"])
                }
                let params = payload["params"] as? [String: Any] ?? [:]
                legacyAssertEqual(params["window_id"] as? String, windowId)
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceId])
            }

            legacyAssertEqual(line, "log --tab=\(workspaceId) -- --window target")
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["log", "--window", windowId, "--", "--window", "target"],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertEqual(result.stdout, "OK\n")
        legacyAssertTrue(result.stderr.isEmpty, result.stderr)
    }

    @Test
    func testSidebarMetadataWindowFlagFailsWhenWindowHasNoCurrentWorkspace() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("status-window-empty")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let windowId = "11111111-1111-1111-1111-111111111111"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            guard method == "workspace.current" else {
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected method: \(method)"])
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            legacyAssertEqual(params["window_id"] as? String, windowId)
            return self.v2Response(id: id, ok: true, result: [:])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["set-status", "build", "running", "--window", windowId],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 1, result.stderr)
        legacyAssertTrue(result.stderr.contains("set-status: targeted window has no current workspace"), result.stderr)
        legacyAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["workspace.current"]
        )
    }

    @Test
    func testNotifyWindowFlagResolvesCurrentWorkspaceInWindow() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("notify-window")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let windowId = "11111111-1111-1111-1111-111111111111"
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let surfaceId = "33333333-3333-3333-3333-333333333333"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }

            switch method {
            case "workspace.current":
                let params = payload["params"] as? [String: Any] ?? [:]
                legacyAssertEqual(params["window_id"] as? String, windowId)
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceId])
            case "notification.create":
                let params = payload["params"] as? [String: Any] ?? [:]
                legacyAssertEqual(params["window_id"] as? String, windowId)
                legacyAssertEqual(params["workspace_id"] as? String, workspaceId)
                legacyAssertEqual(params["title"] as? String, "Window Notify")
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["workspace_id": workspaceId, "surface_id": surfaceId]
                )
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected method: \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["notify", "--window", windowId, "--title", "Window Notify"],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertEqual(result.stdout, "OK\n")
        legacyAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["workspace.current", "notification.create"]
        )
    }

    @Test
    func testNotifyWindowSurfaceRefResolvesAcrossTargetWindowWorkspaces() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("notify-window-surface")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let windowId = "11111111-1111-1111-1111-111111111111"
        let selectedWorkspaceId = "22222222-2222-2222-2222-222222222222"
        let targetWorkspaceId = "33333333-3333-3333-3333-333333333333"
        let selectedSurfaceId = "44444444-4444-4444-4444-444444444444"
        let targetSurfaceId = "55555555-5555-5555-5555-555555555555"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                legacyAssertTrue(line.hasPrefix("notify_target \(targetWorkspaceId) \(targetSurfaceId) "), line)
                legacyAssertTrue(line.contains("Window Surface Notify"), line)
                return "OK"
            }
            let params = payload["params"] as? [String: Any] ?? [:]

            switch method {
            case "window.list":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "windows": [
                            [
                                "id": windowId,
                                "ref": "window:2",
                                "index": 2,
                            ],
                        ],
                    ]
                )
            case "workspace.list":
                legacyAssertEqual(params["window_id"] as? String, windowId)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspaces": [
                            [
                                "id": selectedWorkspaceId,
                                "ref": "workspace:1",
                                "index": 1,
                            ],
                            [
                                "id": targetWorkspaceId,
                                "ref": "workspace:2",
                                "index": 2,
                            ],
                        ],
                    ]
                )
            case "surface.list":
                legacyAssertEqual(params["window_id"] as? String, windowId)
                switch params["workspace_id"] as? String {
                case selectedWorkspaceId:
                    return self.v2Response(
                        id: id,
                        ok: true,
                        result: [
                            "surfaces": [
                                [
                                    "id": selectedSurfaceId,
                                    "ref": "surface:1",
                                    "index": 1,
                                ],
                            ],
                        ]
                    )
                case targetWorkspaceId:
                    return self.v2Response(
                        id: id,
                        ok: true,
                        result: [
                            "surfaces": [
                                [
                                    "id": targetSurfaceId,
                                    "ref": "surface:3",
                                    "index": 3,
                                ],
                            ],
                        ]
                    )
                default:
                    legacyFail("Unexpected surface.list params: \(params)")
                    return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected workspace"])
                }
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected method: \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["notify", "--window", "window:2", "--surface", "surface:3", "--title", "Window Surface Notify"],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertEqual(result.stdout, "OK\n")
        let methods = state.commands.compactMap { self.jsonObject($0)?["method"] as? String }
        legacyAssertEqual(methods, ["window.list", "workspace.list", "surface.list", "surface.list"])
    }

    @Test
    func testNotifyWindowSurfaceIndexUsesCurrentWorkspaceInTargetWindow() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("notify-window-surface-index")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let windowId = "11111111-1111-1111-1111-111111111111"
        let selectedWorkspaceId = "22222222-2222-2222-2222-222222222222"
        let selectedSurfaceId = "33333333-3333-3333-3333-333333333333"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                legacyAssertTrue(line.hasPrefix("notify_target \(selectedWorkspaceId) \(selectedSurfaceId) "), line)
                legacyAssertTrue(line.contains("Window Indexed Notify"), line)
                return "OK"
            }
            let params = payload["params"] as? [String: Any] ?? [:]

            switch method {
            case "window.list":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "windows": [
                            [
                                "id": windowId,
                                "ref": "window:2",
                                "index": 2,
                            ],
                        ],
                    ]
                )
            case "workspace.current":
                legacyAssertEqual(params["window_id"] as? String, windowId)
                return self.v2Response(id: id, ok: true, result: ["workspace_id": selectedWorkspaceId])
            case "surface.list":
                legacyAssertEqual(params["window_id"] as? String, windowId)
                legacyAssertEqual(params["workspace_id"] as? String, selectedWorkspaceId)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "surfaces": [
                            [
                                "id": selectedSurfaceId,
                                "ref": "surface:8",
                                "index": 0,
                            ],
                        ],
                    ]
                )
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected method: \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["notify", "--window", "window:2", "--surface", "0", "--title", "Window Indexed Notify"],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertEqual(result.stdout, "OK\n")
        let methods = state.commands.compactMap { self.jsonObject($0)?["method"] as? String }
        legacyAssertEqual(methods, ["window.list", "workspace.current", "surface.list"])
    }

    @Test
    func testWorkspaceActionWindowFlagResolvesCurrentWorkspaceInWindow() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("action-window")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let windowId = "11111111-1111-1111-1111-111111111111"
        let workspaceId = "22222222-2222-2222-2222-222222222222"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }

            switch method {
            case "workspace.current":
                let params = payload["params"] as? [String: Any] ?? [:]
                legacyAssertEqual(params["window_id"] as? String, windowId)
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceId])
            case "workspace.action":
                let params = payload["params"] as? [String: Any] ?? [:]
                legacyAssertEqual(params["window_id"] as? String, windowId)
                legacyAssertEqual(params["workspace_id"] as? String, workspaceId)
                legacyAssertEqual(params["action"] as? String, "pin")
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["window_id": windowId, "workspace_id": workspaceId, "action": "pin"]
                )
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected method: \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["workspace-action", "--window", windowId, "--action", "pin"],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertTrue(result.stderr.isEmpty, result.stderr)
        legacyAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["workspace.current", "workspace.action"]
        )
    }

    @Test
    func testClearNotificationsWindowFlagFailsWhenWindowHasNoCurrentWorkspace() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("clear-window-empty")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let windowId = "11111111-1111-1111-1111-111111111111"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            guard method == "workspace.current" else {
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected method: \(method)"])
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            legacyAssertEqual(params["window_id"] as? String, windowId)
            return self.v2Response(id: id, ok: true, result: [:])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["clear-notifications", "--window", windowId],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 1, result.stderr)
        legacyAssertTrue(result.stderr.contains("clear-notifications: targeted window has no current workspace"), result.stderr)
        legacyAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["workspace.current"]
        )
    }

    @Test
    func testTreeCommandForwardsWindowFlag() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("tree-window")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let windowId = "11111111-1111-1111-1111-111111111111"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }

            guard method == "system.tree" else {
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected method: \(method)"])
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            legacyAssertEqual(params["window_id"] as? String, windowId)
            legacyAssertEqual(params["all_windows"] as? Bool, false)
            return self.v2Response(
                id: id,
                ok: true,
                result: [
                    "active": NSNull(),
                    "caller": NSNull(),
                    "windows": [],
                ]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["tree", "--json", "--window", windowId],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertTrue(result.stderr.isEmpty, result.stderr)
    }

    @Test
    func testTreeCommandWindowFlagSurvivesLegacyFallback() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("tree-legacy-window")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let windowId = "11111111-1111-1111-1111-111111111111"
        let otherWindowId = "22222222-2222-2222-2222-222222222222"
        let workspaceId = "33333333-3333-3333-3333-333333333333"
        let paneId = "44444444-4444-4444-4444-444444444444"
        let surfaceId = "55555555-5555-5555-5555-555555555555"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            let params = payload["params"] as? [String: Any] ?? [:]

            switch method {
            case "system.tree":
                legacyAssertEqual(params["window_id"] as? String, windowId)
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "method_not_found", "message": "system.tree"]
                )
            case "system.identify":
                legacyAssertEqual(params["window_id"] as? String, windowId)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "focused": [
                            "window_id": windowId,
                            "workspace_id": workspaceId,
                            "pane_id": paneId,
                            "surface_id": surfaceId,
                        ],
                        "caller": NSNull(),
                    ]
                )
            case "window.list":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "windows": [
                            ["id": otherWindowId, "ref": "window:1", "index": 0],
                            ["id": windowId, "ref": "window:2", "index": 1],
                        ],
                    ]
                )
            case "workspace.list":
                legacyAssertEqual(params["window_id"] as? String, "window:2")
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "window_id": windowId,
                        "window_ref": "window:2",
                        "workspaces": [
                            ["id": workspaceId, "ref": "workspace:1", "index": 0, "selected": true],
                        ],
                    ]
                )
            case "pane.list":
                legacyAssertTrue([workspaceId, "workspace:1"].contains(params["workspace_id"] as? String))
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "panes": [
                            ["id": paneId, "ref": "pane:1", "index": 0],
                        ],
                    ]
                )
            case "surface.list":
                legacyAssertTrue([workspaceId, "workspace:1"].contains(params["workspace_id"] as? String))
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "surfaces": [
                            [
                                "id": surfaceId,
                                "ref": "surface:1",
                                "pane_id": paneId,
                                "pane_ref": "pane:1",
                                "index": 0,
                                "type": "terminal",
                                "focused": true,
                            ],
                        ],
                    ]
                )
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected method: \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--id-format", "uuids", "tree", "--json", "--window", windowId],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertTrue(result.stderr.isEmpty, result.stderr)

        let payload = try jsonPayload(from: result.stdout)
        let windows = try legacyUnwrap(payload["windows"] as? [[String: Any]])
        legacyAssertEqual(windows.count, 1, result.stdout)
        legacyAssertEqual(windows.first?["id"] as? String, windowId)
        legacyAssertFalse(result.stdout.contains(otherWindowId), result.stdout)
    }

    @Test
    func testCodexPromptSubmitWithForeignCmuxEnvDoesNotFallbackToSelectedWorkspace() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex-foreign-env")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-foreign-env-\(UUID().uuidString)", isDirectory: true)
        let foreignWorkspaceId = "11111111-1111-1111-1111-111111111111"
        let foreignSurfaceId = "22222222-2222-2222-2222-222222222222"
        let selectedWorkspaceId = "33333333-3333-3333-3333-333333333333"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else {
                return line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
                    ? self.malformedRequestResponse(raw: line)
                    : "OK"
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                return self.v2Response(id: id, ok: false, error: ["code": "not_found", "message": "workspace not found"])
            case "workspace.current":
                return self.v2Response(id: id, ok: true, result: ["workspace_id": selectedWorkspaceId])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = foreignWorkspaceId
        environment["CMUX_SURFACE_ID"] = foreignSurfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CODEX_HOME"] = root.appendingPathComponent("codex-home", isDirectory: true).path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"codex-foreign-env","cwd":"\#(root.path)","hook_event_name":"UserPromptSubmit","prompt":"continue"}"#,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertEqual(result.stdout, "{}\n")
        legacyAssertFalse(
            state.commands.contains { $0.contains("set_status codex Running") || $0.contains("notify_target_async") },
            "Foreign cmux env must not mutate the selected workspace, saw \(state.commands)"
        )
    }

    @Test
    func testCodexPromptSubmitWithForeignCmuxEnvIgnoresStaleMappedSession() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex-foreign-mapped")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-foreign-mapped-\(UUID().uuidString)", isDirectory: true)
        let foreignWorkspaceId = "11111111-1111-1111-1111-111111111111"
        let foreignSurfaceId = "22222222-2222-2222-2222-222222222222"
        let selectedWorkspaceId = "33333333-3333-3333-3333-333333333333"
        let selectedSurfaceId = "44444444-4444-4444-4444-444444444444"
        let sessionId = "codex-foreign-mapped-session"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let storeURL = root.appendingPathComponent("codex-hook-sessions.json", isDirectory: false)
        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": selectedWorkspaceId,
                    "surfaceId": selectedSurfaceId,
                    "cwd": root.path,
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted]).write(to: storeURL, options: .atomic)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else {
                return line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
                    ? self.malformedRequestResponse(raw: line)
                    : "OK"
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                let params = payload["params"] as? [String: Any] ?? [:]
                if params["workspace_id"] as? String == selectedWorkspaceId {
                    return self.surfaceListResponse(id: id, surfaceId: selectedSurfaceId)
                }
                return self.v2Response(id: id, ok: false, error: ["code": "not_found", "message": "workspace not found"])
            case "workspace.current":
                return self.v2Response(id: id, ok: true, result: ["workspace_id": selectedWorkspaceId])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = foreignWorkspaceId
        environment["CMUX_SURFACE_ID"] = foreignSurfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CODEX_HOME"] = root.appendingPathComponent("codex-home", isDirectory: true).path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"UserPromptSubmit","prompt":"continue"}"#,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertEqual(result.stdout, "{}\n")
        legacyAssertFalse(
            state.commands.contains { $0.contains("set_status codex Running") || $0.contains("notify_target_async") },
            "Foreign cmux env must not reuse stale mapped sessions, saw \(state.commands)"
        )
    }

    @Test
    func testCodexPromptSubmitWithInvalidSurfaceDoesNotFallbackToFocusedSurface() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex-invalid-surface")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-invalid-surface-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "33333333-3333-3333-3333-333333333333"
        let focusedSurfaceId = "44444444-4444-4444-4444-444444444444"
        let foreignSurfaceId = "22222222-2222-2222-2222-222222222222"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else {
                return line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
                    ? self.malformedRequestResponse(raw: line)
                    : "OK"
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                let params = payload["params"] as? [String: Any] ?? [:]
                if params["workspace_id"] as? String == workspaceId {
                    return self.surfaceListResponse(id: id, surfaceId: focusedSurfaceId)
                }
                return self.v2Response(id: id, ok: false, error: ["code": "not_found", "message": "workspace not found"])
            case "workspace.current":
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceId])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = foreignSurfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CODEX_HOME"] = root.appendingPathComponent("codex-home", isDirectory: true).path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"codex-invalid-surface","cwd":"\#(root.path)","hook_event_name":"UserPromptSubmit","prompt":"continue"}"#,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertEqual(result.stdout, "{}\n")
        legacyAssertFalse(
            state.commands.contains { $0.contains("set_status codex Running") || $0.contains("notify_target_async") },
            "Invalid surface must not fall back to the focused surface, saw \(state.commands)"
        )
    }

    @Test
    func testCodexPromptSubmitWithInvalidMappedWorkspaceDoesNotFallbackToSelectedWorkspace() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex-invalid-mapped")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-invalid-mapped-\(UUID().uuidString)", isDirectory: true)
        let staleWorkspaceId = "11111111-1111-1111-1111-111111111111"
        let staleSurfaceId = "22222222-2222-2222-2222-222222222222"
        let selectedWorkspaceId = "33333333-3333-3333-3333-333333333333"
        let sessionId = "codex-invalid-mapped-session"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var listenerClosed = false
        defer {
            if !listenerClosed {
                Darwin.close(listenerFD)
            }
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let storeURL = root.appendingPathComponent("codex-hook-sessions.json", isDirectory: false)
        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": staleWorkspaceId,
                    "surfaceId": staleSurfaceId,
                    "cwd": root.path,
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted]).write(to: storeURL, options: .atomic)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else {
                return line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
                    ? self.malformedRequestResponse(raw: line)
                    : "OK"
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                return self.v2Response(id: id, ok: false, error: ["code": "not_found", "message": "workspace not found"])
            case "workspace.current":
                return self.v2Response(id: id, ok: true, result: ["workspace_id": selectedWorkspaceId])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CODEX_HOME"] = root.appendingPathComponent("codex-home", isDirectory: true).path
        environment.removeValue(forKey: "CMUX_WORKSPACE_ID")
        environment.removeValue(forKey: "CMUX_SURFACE_ID")

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"UserPromptSubmit","prompt":"continue"}"#,
            timeout: 5
        )

        Darwin.close(listenerFD)
        listenerClosed = true
        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertEqual(result.stdout, "{}\n")
        legacyAssertFalse(
            state.commands.contains { $0.contains("set_status codex Running") || $0.contains("notify_target_async") },
            "Invalid mapped workspace must not mutate the selected workspace, saw \(state.commands)"
        )
    }

    @Test
    func testCodexTeamsForkPromptPublishesResumeBinding() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex-team-resume")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-teams-resume-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "33333333-3333-3333-3333-333333333333"
        let surfaceId = "44444444-4444-4444-4444-444444444444"
        let sessionId = "019dad34-d218-7943-b81a-eddac5c87951"
        let parentSessionId = "019dad34-d218-7943-b81a-parent-session"
        let ttyName = "ttys-test-codex-teams-resume"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let storeURL = root.appendingPathComponent("codex-hook-sessions.json", isDirectory: false)
        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": root.path,
                    "startedAt": now,
                    "updatedAt": now,
                    "launchCommand": [
                        "launcher": "codexTeams",
                        "executablePath": "/usr/local/bin/cmux",
                        "arguments": [
                            "/usr/local/bin/cmux",
                            "codex-teams",
                            "fork",
                            parentSessionId,
                            "--model",
                            "gpt-5.4",
                            "stale fork prompt",
                            "--sandbox",
                            "danger-full-access",
                            "initial prompt should not replay"
                        ],
                        "workingDirectory": root.path,
                        "environment": ["CODEX_HOME": root.appendingPathComponent("codex-home", isDirectory: true).path],
                        "capturedAt": now,
                        "source": "test",
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted]).write(to: storeURL, options: .atomic)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else {
                return line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
                    ? self.malformedRequestResponse(raw: line)
                    : "OK"
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                let params = payload["params"] as? [String: Any] ?? [:]
                if params["workspace_id"] as? String == workspaceId {
                    return self.surfaceListResponse(id: id, surfaceId: surfaceId)
                }
                return self.v2Response(id: id, ok: false, error: ["code": "not_found", "message": "workspace not found"])
            case "debug.terminals":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["terminals": [["tty": ttyName, "workspace_id": workspaceId, "surface_id": surfaceId]]]
                )
            case "workspace.current":
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceId])
            case "surface.resume.set":
                return self.v2Response(id: id, ok: true, result: ["ok": true])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_CLI_TTY_NAME"] = ttyName
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_LAUNCH_KIND"] = "codexTeams"
        environment["CMUX_AGENT_LAUNCH_EXECUTABLE"] = "/usr/local/bin/cmux"
        environment["CMUX_AGENT_LAUNCH_CWD"] = root.path
        environment["CMUX_AGENT_LAUNCH_ARGV_B64"] = base64NULSeparated([
            "/usr/local/bin/cmux",
            "codex-teams",
            "fork",
            parentSessionId,
            "--model",
            "gpt-5.4",
            "stale fork prompt",
            "--sandbox",
            "danger-full-access",
            "initial prompt should not replay"
        ])
        environment["CODEX_HOME"] = root.appendingPathComponent("codex-home", isDirectory: true).path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"UserPromptSubmit","prompt":"continue"}"#,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)

        let resumeBindingRequests = state.commands.compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.set" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        legacyAssertEqual(resumeBindingRequests.count, 1, state.commands.joined(separator: "\n"))
        let request = try legacyUnwrap(resumeBindingRequests.first)
        legacyAssertEqual(request["checkpoint_id"] as? String, sessionId)
        legacyAssertEqual(request["auto_resume"] as? Bool, true)
        legacyAssertEqual(
            request["command"] as? String,
            "{ cd -- '\(root.path)' 2>/dev/null || [ ! -d '\(root.path)' ]; } && '/usr/local/bin/cmux' 'codex-teams' 'resume' '\(sessionId)' '--model' 'gpt-5.4' '--sandbox' 'danger-full-access'"
        )
    }

    @Test
    func testAgentPromptClearsSurfaceResumeBindingWhenResumeCommandUnavailable() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("agent-resume-unavailable")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-resume-unavailable-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "nonresumable-agent-session"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": root.path,
                    "startedAt": now,
                    "updatedAt": now,
                    "launchCommand": [
                        "launcher": "omx",
                        "executablePath": "/usr/local/bin/cmux",
                        "arguments": ["/usr/local/bin/cmux", "omx", "hud"],
                        "workingDirectory": root.path,
                        "capturedAt": now,
                        "source": "test",
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted])
            .write(to: root.appendingPathComponent("claude-hook-sessions.json"), options: .atomic)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else {
                return "OK"
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                let params = payload["params"] as? [String: Any] ?? [:]
                if params["workspace_id"] as? String == workspaceId {
                    return self.surfaceListResponse(id: id, surfaceId: surfaceId)
                }
                return self.v2Response(id: id, ok: false, error: ["code": "not_found", "message": "workspace not found"])
            case "surface.resume.clear":
                return self.v2Response(id: id, ok: true, result: ["cleared": true])
            case "surface.resume.set":
                legacyFail("Non-resumable launcher should not publish a resume binding")
                return self.v2Response(id: id, ok: true, result: ["ok": true])
            case "feed.push":
                return self.v2Response(id: id, ok: true, result: [:])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        let environment = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_WORKSPACE_ID": workspaceId,
            "CMUX_SURFACE_ID": surfaceId,
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
        ]

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "claude", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"UserPromptSubmit"}"#,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)

        let clearRequests = state.commands.compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.clear" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        let request = try legacyUnwrap(clearRequests.first)
        legacyAssertNil(request["workspace_id"])
        legacyAssertEqual(request["surface_id"] as? String, surfaceId)
        legacyAssertEqual(request["source"] as? String, "agent-hook")
        legacyAssertEqual(request["checkpoint_id"] as? String, sessionId)
    }

    @Test
    func testGenericAgentSessionEndClearsMatchingSurfaceResumeBinding() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("agent-resume-clear")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-resume-clear-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-ending-session"
        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": root.path,
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted])
            .write(to: root.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else {
                return "OK"
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.resume.clear":
                return self.v2Response(id: id, ok: true, result: ["cleared": true])
            case "feed.push":
                return self.v2Response(id: id, ok: true, result: [:])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "session-end"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"SessionEnd"}"#,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        let clearRequests = state.commands.compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.clear" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        let request = try legacyUnwrap(clearRequests.first)
        legacyAssertNil(request["workspace_id"])
        legacyAssertEqual(request["surface_id"] as? String, surfaceId)
        legacyAssertEqual(request["checkpoint_id"] as? String, sessionId)
        legacyAssertEqual(request["source"] as? String, "agent-hook")
    }

    @Test
    func testSurfaceResumeClearCLIForwardsCheckpointAndSourceGuards() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("resume-clear-guards")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            legacyAssertEqual(method, "surface.resume.clear")
            return self.v2Response(id: id, ok: true, result: ["cleared": false])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "surface", "resume", "clear",
                "--workspace", workspaceId,
                "--surface", surfaceId,
                "--checkpoint", "old-session",
                "--checkpoint-id", "new-session",
                "--source", "agent-hook",
            ],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertEqual(result.stdout, "OK\n")

        let clearRequests = state.commands.compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.clear" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        let request = try legacyUnwrap(clearRequests.first)
        legacyAssertEqual(request["workspace_id"] as? String, workspaceId)
        legacyAssertEqual(request["surface_id"] as? String, surfaceId)
        legacyAssertEqual(request["checkpoint_id"] as? String, "new-session")
        legacyAssertEqual(request["source"] as? String, "agent-hook")
    }

    @Test
    func testSurfaceResumeSetCLIPreservesQuotedShellCommand() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("resume-set-shell")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            legacyAssertEqual(method, "surface.resume.set")
            return self.v2Response(id: id, ok: true, result: ["resume_binding": [:]])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "surface", "resume", "set",
                "--workspace", workspaceId,
                "--surface", surfaceId,
                "--kind", "tmux",
                "--shell", "tmux attach -t work",
            ],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertEqual(result.stdout, "OK\n")

        let setRequests = state.commands.compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.set" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        legacyAssertEqual(setRequests.count, 1)
        let request = try legacyUnwrap(setRequests.first)
        legacyAssertEqual(request["workspace_id"] as? String, workspaceId)
        legacyAssertEqual(request["surface_id"] as? String, surfaceId)
        legacyAssertEqual(request["kind"] as? String, "tmux")
        legacyAssertEqual(request["command"] as? String, "tmux attach -t work")
    }

    @Test
    func testSurfaceResumeSetCLIStopsParsingOptionsAfterTerminator() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("resume-set-terminator")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            legacyAssertEqual(method, "surface.resume.set")
            return self.v2Response(id: id, ok: true, result: ["resume_binding": [:]])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "surface", "resume", "set",
                "--workspace", workspaceId,
                "--surface", surfaceId,
                "--",
                "myapp",
                "--name", "foo",
                "--kind", "bar",
                "--cwd", "/tmp/ignored",
                "--surface", "not-a-target",
            ],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertEqual(result.stdout, "OK\n")

        let setRequests = state.commands.compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.set" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        let request = try legacyUnwrap(setRequests.first)
        legacyAssertEqual(request["workspace_id"] as? String, workspaceId)
        legacyAssertEqual(request["surface_id"] as? String, surfaceId)
        legacyAssertNil(request["name"])
        legacyAssertNil(request["kind"])
        legacyAssertEqual(
            request["command"] as? String,
            "'myapp' '--name' 'foo' '--kind' 'bar' '--cwd' '/tmp/ignored' '--surface' 'not-a-target'"
        )
    }

    @Test
    func testSurfaceResumeSetCLIDoesNotScopeExplicitSurfaceToEnvWorkspace() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("resume-set-surface")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let staleWorkspaceId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let movedSurfaceId = "22222222-2222-2222-2222-222222222222"
        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            legacyAssertEqual(method, "surface.resume.set")
            return self.v2Response(id: id, ok: true, result: ["resume_binding": [:]])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_WORKSPACE_ID"] = staleWorkspaceId
        environment["CMUX_SURFACE_ID"] = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "surface", "resume", "set",
                "--surface", movedSurfaceId,
                "--shell", "tmux attach -t moved",
            ],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)

        let setRequests = state.commands.compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.set" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        let request = try legacyUnwrap(setRequests.first)
        legacyAssertNil(request["workspace_id"])
        legacyAssertEqual(request["surface_id"] as? String, movedSurfaceId)
    }

    @Test
    func testSurfaceResumeSetCLIRejectsTrailingShellTokens() throws {
        let cliPath = try bundledCLIPath()
        let missingSocketPath = "/tmp/cmux-test-missing-\(UUID().uuidString).sock"

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = missingSocketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "surface", "resume", "set",
                "--workspace", "11111111-1111-1111-1111-111111111111",
                "--surface", "22222222-2222-2222-2222-222222222222",
                "--shell", "tmux",
                "attach",
                "-t",
                "work",
            ],
            environment: environment,
            timeout: 5
        )

        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertNotEqual(result.status, 0, result.stderr)
        legacyAssertTrue(result.stderr.contains("surface resume set: unexpected argument 'attach' after --shell"))
        legacyAssertFalse(result.stderr.contains("Socket"), result.stderr)
    }

    @Test
    func testSurfaceResumeSetCLIRejectsPreTerminatorCommandTokens() throws {
        let cliPath = try bundledCLIPath()
        let missingSocketPath = "/tmp/cmux-test-missing-\(UUID().uuidString).sock"
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = missingSocketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "surface", "resume", "set",
                "--workspace", "11111111-1111-1111-1111-111111111111",
                "--surface", "22222222-2222-2222-2222-222222222222",
                "myapp",
                "--",
                "--flag",
            ],
            environment: environment,
            timeout: 5
        )

        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 1, result.stderr)
        legacyAssertTrue(result.stderr.contains("surface resume set: unexpected argument 'myapp' before --"))
        legacyAssertFalse(result.stderr.contains("Socket"), result.stderr)
    }

    @Test
    func testSurfaceResumeSetCLIRejectsDanglingValueOptionsBeforeSocketRequest() throws {
        let cliPath = try bundledCLIPath()
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let missingSocketPath = "/tmp/cmux-test-missing-\(UUID().uuidString).sock"
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = missingSocketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let cases: [(arguments: [String], expected: String)] = [
            (
                [
                    "surface", "resume", "set",
                    "--workspace", workspaceId,
                    "--surface",
                ],
                "surface resume set: --surface requires a value"
            ),
            (
                [
                    "surface", "resume", "set",
                    "--workspace", workspaceId,
                    "--surface", surfaceId,
                    "--shell",
                ],
                "surface resume set: --shell requires a value"
            ),
            (
                [
                    "surface", "resume", "set",
                    "--workspace", workspaceId,
                    "--surface", surfaceId,
                    "--shell", "--",
                ],
                "surface resume set: --shell requires a value"
            ),
        ]

        for item in cases {
            let result = runProcess(
                executablePath: cliPath,
                arguments: item.arguments,
                environment: environment,
                timeout: 5
            )

            legacyAssertFalse(result.timedOut, result.stderr)
            legacyAssertEqual(result.status, 1, result.stderr)
            legacyAssertTrue(result.stdout.isEmpty, result.stdout)
            legacyAssertTrue(result.stderr.contains(item.expected), result.stderr)
            legacyAssertFalse(result.stderr.contains("Socket"), result.stderr)
        }
    }

    @Test
    func testSurfaceResumeClearCLIRejectsMalformedGuardsBeforeClearing() throws {
        let cliPath = try bundledCLIPath()
        let missingSocketPath = "/tmp/cmux-test-missing-\(UUID().uuidString).sock"

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = missingSocketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "surface", "resume", "clear",
                "--workspace", "11111111-1111-1111-1111-111111111111",
                "--surface", "22222222-2222-2222-2222-222222222222",
                "--checkpoint",
            ],
            environment: environment,
            timeout: 5
        )

        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertNotEqual(result.status, 0, result.stderr)
        legacyAssertTrue(result.stderr.contains("surface resume clear: --checkpoint requires a value"))
        legacyAssertFalse(result.stderr.contains("Socket"), result.stderr)
    }

    @Test
    func testSurfaceResumeClearCLINormalizesWindowIndex() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("resume-clear-window")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let windowId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let surfaceId = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let surfaceRef = "surface:7"
        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            switch method {
            case "window.list":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["windows": [["id": windowId, "ref": "window:1", "index": 0]]]
                )
            case "window.focus":
                return self.v2Response(id: id, ok: true, result: ["window_id": windowId])
            case "surface.list":
                let params = payload["params"] as? [String: Any] ?? [:]
                legacyAssertEqual(params["window_id"] as? String, windowId)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["surfaces": [["id": surfaceId, "ref": surfaceRef, "index": 0]]]
                )
            case "surface.resume.clear":
                return self.v2Response(id: id, ok: true, result: ["cleared": true])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--window", "0", "surface", "resume", "clear", "--surface", "0"],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertEqual(result.stdout, "OK\n")

        let clearRequests = state.commands.compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.clear" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        legacyAssertFalse(
            state.commands.contains { command in
                jsonObject(command)?["method"] as? String == "window.focus"
            },
            "surface resume metadata commands should route by window_id without focusing the window"
        )
        let request = try legacyUnwrap(clearRequests.first)
        legacyAssertEqual(request["window_id"] as? String, windowId)
        legacyAssertNotEqual(request["window_id"] as? String, "0")
        legacyAssertEqual(request["surface_id"] as? String, surfaceId)
    }

    @Test
    func testSurfaceResumeClearCLIParsesLocalWindowOption() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("resume-clear-local-window")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let windowId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let surfaceId = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            switch method {
            case "window.list":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["windows": [["id": windowId, "ref": "window:1", "index": 0]]]
                )
            case "surface.list":
                let params = payload["params"] as? [String: Any] ?? [:]
                legacyAssertEqual(params["window_id"] as? String, windowId)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["surfaces": [["id": surfaceId, "ref": "surface:7", "index": 0]]]
                )
            case "surface.resume.clear":
                return self.v2Response(id: id, ok: true, result: ["cleared": true])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["surface", "resume", "clear", "--window", "0", "--surface", "0"],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertEqual(result.stdout, "OK\n")
        legacyAssertFalse(
            state.commands.contains { command in
                jsonObject(command)?["method"] as? String == "window.focus"
            },
            "local --window should route surface resume metadata without focusing the window"
        )

        let clearRequests = state.commands.compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.clear" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        let request = try legacyUnwrap(clearRequests.first)
        legacyAssertEqual(request["window_id"] as? String, windowId)
        legacyAssertEqual(request["surface_id"] as? String, surfaceId)
    }

    private struct ClaudeHookContext {
        let cliPath: String
        let socketPath: String
        let listenerFD: Int32
        let state: MockSocketServerState
        let root: URL
        let workspaceId: String
        let surfaceId: String

        func cleanup() {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func codexLaunchEnvironment(context: ClaudeHookContext, sessionId: String) -> [String: String] {
        agentLaunchEnvironment(
            context: context,
            kind: "codex",
            executable: "/usr/local/bin/codex",
            arguments: ["/usr/local/bin/codex", "--model", "gpt-5.4"]
        )
    }

    private func agentLaunchEnvironment(
        context: ClaudeHookContext,
        kind: String,
        executable: String,
        arguments: [String]? = nil
    ) -> [String: String] {
        [
            "CMUX_AGENT_LAUNCH_KIND": kind,
            "CMUX_AGENT_LAUNCH_EXECUTABLE": executable,
            "CMUX_AGENT_LAUNCH_CWD": context.root.path,
            "CMUX_AGENT_LAUNCH_ARGV_B64": base64NULSeparated(arguments ?? [executable]),
        ]
    }

    private func writeCodexTerminalTranscript(
        context: ClaudeHookContext,
        name: String,
        turnId: String,
        eventType: String = "turn_complete"
    ) throws -> URL {
        let transcriptURL = context.root.appendingPathComponent(name)
        try [
            #"{"type":"turn_context","payload":{"turn_id":"\#(turnId)"}}"#,
            #"{"type":"event_msg","payload":{"type":"\#(eventType)","turn_id":"\#(turnId)"}}"#,
        ].joined(separator: "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        return transcriptURL
    }

    private func runCodexHook(
        context: ClaudeHookContext,
        subcommand: String,
        standardInput: String,
        extraEnvironment: [String: String] = [:]
    ) -> ProcessRunResult {
        runAgentHook(
            context: context,
            agent: "codex",
            subcommand: subcommand,
            standardInput: standardInput,
            extraEnvironment: extraEnvironment
        )
    }

    private func runAgentHook(
        context: ClaudeHookContext,
        agent: String,
        subcommand: String,
        standardInput: String,
        extraEnvironment: [String: String] = [:]
    ) -> ProcessRunResult {
        var environment = [
            "HOME": context.root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": context.root.path,
            "CMUX_SOCKET_PATH": context.socketPath,
            "CMUX_WORKSPACE_ID": context.workspaceId,
            "CMUX_SURFACE_ID": context.surfaceId,
            "CMUX_AGENT_HOOK_STATE_DIR": context.root.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
        ]
        environment.merge(extraEnvironment, uniquingKeysWith: { _, new in new })

        return runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", agent, subcommand],
            environment: environment,
            standardInput: standardInput,
            timeout: 5
        )
    }

    private func startAgentHookMockServerAccepting(
        context: ClaudeHookContext,
        connectionLimit: Int
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var accepted = 0
            while accepted < connectionLimit {
                var clientAddr = sockaddr_un()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.accept(context.listenerFD, sockaddrPtr, &clientAddrLen)
                    }
                }
                if clientFD < 0 {
                    if errno == EINTR { continue }
                    return
                }
                accepted += 1

                DispatchQueue.global(qos: .userInitiated).async {
                    defer { Darwin.close(clientFD) }
                    var pending = Data()
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let count = Darwin.read(clientFD, &buffer, buffer.count)
                        if count < 0 {
                            if errno == EINTR { continue }
                            return
                        }
                        if count == 0 { return }
                        pending.append(buffer, count: count)
                        while let newlineRange = pending.firstRange(of: Data([0x0A])) {
                            let lineData = pending.subdata(in: 0..<newlineRange.lowerBound)
                            pending.removeSubrange(0...newlineRange.lowerBound)
                            guard let line = String(data: lineData, encoding: .utf8) else { continue }
                            context.state.append(line)
                            let response = self.agentHookMockResponse(line: line, context: context) + "\n"
                            _ = response.withCString { ptr in
                                Darwin.write(clientFD, ptr, strlen(ptr))
                            }
                        }
                    }
                }
            }
        }
    }

    private func agentHookMockResponse(line: String, context: ClaudeHookContext) -> String {
        guard let payload = jsonObject(line) else {
            return "OK"
        }
        guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
            return malformedRequestResponse(id: payload["id"] as? String, raw: line)
        }
        switch method {
        case "surface.list":
            return surfaceListResponse(id: id, surfaceId: context.surfaceId)
        case "feed.push":
            return v2Response(id: id, ok: true, result: [:])
        case "surface.resume.set":
            return v2Response(id: id, ok: true, result: ["resume_binding": [:]])
        case "surface.resume.clear":
            return v2Response(id: id, ok: true, result: ["cleared": true])
        default:
            return v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
        }
    }

    private func makeClaudeHookContext(name: String) throws -> ClaudeHookContext {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-\(name)-\(UUID().uuidString)", isDirectory: true)
        let socketPath = makeSocketPath(String(name.prefix(6)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return ClaudeHookContext(
            cliPath: try bundledCLIPath(),
            socketPath: socketPath,
            listenerFD: try bindUnixSocket(at: socketPath),
            state: MockSocketServerState(),
            root: root,
            workspaceId: "11111111-1111-1111-1111-111111111111",
            surfaceId: "22222222-2222-2222-2222-222222222222"
        )
    }

    private func runClaudeHook(
        context: ClaudeHookContext,
        arguments: [String],
        standardInput: String,
        extraEnvironment: [String: String] = [:]
    ) -> ProcessRunResult {
        let serverHandled = startMockServer(listenerFD: context.listenerFD, state: context.state) { line in
            guard let payload = self.jsonObject(line) else {
                return "OK"
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                return self.surfaceListResponse(id: id, surfaceId: context.surfaceId)
            case "feed.push":
                return self.v2Response(id: id, ok: true, result: [:])
            case "surface.resume.clear":
                return self.v2Response(id: id, ok: true, result: ["cleared": true])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        var environment = [
            "HOME": context.root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_SOCKET_PATH": context.socketPath,
            "CMUX_WORKSPACE_ID": context.workspaceId,
            "CMUX_SURFACE_ID": context.surfaceId,
            "CMUX_CLAUDE_HOOK_STATE_PATH": context.root.appendingPathComponent("claude-hook-sessions.json").path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
        ]
        for (key, value) in extraEnvironment {
            environment[key] = value
        }

        let result = runProcess(
            executablePath: context.cliPath,
            arguments: arguments,
            environment: environment,
            standardInput: standardInput,
            timeout: 5
        )
        legacyWait(for: [serverHandled], timeout: 5)
        return result
    }

    private func readClaudeHookSession(_ sessionId: String, context: ClaudeHookContext) throws -> [String: Any] {
        let stateURL = context.root.appendingPathComponent("claude-hook-sessions.json")
        let state = try legacyUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        let sessions = try legacyUnwrap(state["sessions"] as? [String: Any])
        return try legacyUnwrap(sessions[sessionId] as? [String: Any])
    }

    private func feedPushEvents(in context: ClaudeHookContext) -> [[String: Any]] {
        context.state.snapshot().compactMap { line in
            guard let payload = jsonObject(line),
                  payload["method"] as? String == "feed.push",
                  let params = payload["params"] as? [String: Any],
                  let event = params["event"] as? [String: Any] else {
                return nil
            }
            return event
        }
    }

    @Test
    func testBrowserImportDefaultsNonInteractiveInCodingAgent() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("browser-import-agent")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }

            legacyAssertEqual(method, "browser.import.cookies")
            guard method == "browser.import.cookies" else {
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            legacyAssertEqual(params["scope"] as? String, "cookiesOnly")
            legacyAssertEqual(params["browser"] as? String, "Chrome")
            legacyAssertEqual(params["source_profiles"] as? [String], ["Default"])
            legacyAssertEqual(params["domain_filters"] as? [String], ["github.com"])
            legacyAssertEqual(params["destination_profile"] as? String, "Dev")
            return self.v2Response(
                id: id,
                ok: true,
                result: [
                    "browser": "Chrome",
                    "imported_cookies": 3,
                    "skipped_cookies": 1,
                    "warnings": ["Skipped 1 duplicate cookie"],
                ]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CODEX_THREAD_ID"] = "codex-thread-browser-import"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "--json",
                "browser",
                "import",
                "--from",
                "Chrome",
                "--profile",
                "Default",
                "--domain",
                "github.com",
                "--to-profile",
                "Dev",
            ],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertTrue(result.stderr.isEmpty, result.stderr)

        let stdoutJSON = try legacyUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        legacyAssertEqual(stdoutJSON["browser"] as? String, "Chrome")
        legacyAssertEqual(stdoutJSON["imported_cookies"] as? Int, 3)
        legacyAssertEqual(stdoutJSON["skipped_cookies"] as? Int, 1)
        legacyAssertTrue(
            state.commands.contains { $0.contains(#""method":"browser.import.cookies""#) },
            "Expected coding-agent import to use non-interactive import, saw \(state.commands)"
        )
    }

    @Test
    func testBrowserImportUsesInteractiveDialogOutsideCodingAgent() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("browser-import-human")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }

            legacyAssertEqual(method, "browser.import.dialog")
            guard method == "browser.import.dialog" else {
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            legacyAssertNil(params["scope"])
            return self.v2Response(id: id, ok: true, result: ["opened": true])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment.removeValue(forKey: "CMUX_AGENT_LAUNCH_KIND")
        environment.removeValue(forKey: "CODEX_CI")
        environment.removeValue(forKey: "CODEX_THREAD_ID")
        environment.removeValue(forKey: "CODEX_SESSION_ID")
        environment.removeValue(forKey: "CODEX_SANDBOX")
        environment.removeValue(forKey: "CODEX_MANAGED_BY_BUN")
        environment.removeValue(forKey: "CLAUDECODE")
        environment.removeValue(forKey: "CLAUDE_CODE")
        environment.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        environment.removeValue(forKey: "CLAUDE_CODE_SESSION_ID")
        environment.removeValue(forKey: "OPENCODE")
        environment.removeValue(forKey: "OPENCODE_PORT")
        environment.removeValue(forKey: "OPENCODE_SESSION_ID")

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["browser", "import"],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertEqual(result.stdout, "OK\n")
        legacyAssertTrue(result.stderr.isEmpty, result.stderr)
        legacyAssertTrue(
            state.commands.contains { $0.contains(#""method":"browser.import.dialog""#) },
            "Expected human import to open the interactive dialog, saw \(state.commands)"
        )
    }

    @Test
    func testBrowserImportInteractiveFlagForcesDialogInCodingAgent() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("browser-import-agent-interactive")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }

            legacyAssertEqual(method, "browser.import.dialog")
            guard method == "browser.import.dialog" else {
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            legacyAssertNil(params["scope"])
            return self.v2Response(id: id, ok: true, result: ["opened": true])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CODEX_THREAD_ID"] = "codex-thread-browser-import"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["browser", "import", "--interactive"],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertEqual(result.stdout, "OK\n")
        legacyAssertTrue(result.stderr.isEmpty, result.stderr)
        legacyAssertTrue(
            state.commands.contains { $0.contains(#""method":"browser.import.dialog""#) },
            "Expected --interactive to force the dialog in coding-agent env, saw \(state.commands)"
        )
    }

    @Test
    func testBrowserProfilesListRoutesToSocketMethod() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("browser-profile-list")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }

            legacyAssertEqual(method, "browser.profiles.list")
            return self.v2Response(
                id: id,
                ok: true,
                result: [
                    "current_profile_id": "52B43C05-4A1D-45D3-8FD5-9EF94952E445",
                    "profiles": [[
                        "id": "52B43C05-4A1D-45D3-8FD5-9EF94952E445",
                        "name": "Default",
                        "slug": "default",
                        "built_in_default": true,
                        "current": true,
                    ]],
                ]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["browser", "profiles", "list"],
            environment: environment,
            timeout: 5
        )

        legacyWait(for: [serverHandled], timeout: 5)
        legacyAssertFalse(result.timedOut, result.stderr)
        legacyAssertEqual(result.status, 0, result.stderr)
        legacyAssertTrue(result.stdout.contains("default\tDefault\t52B43C05-4A1D-45D3-8FD5-9EF94952E445"), result.stdout)
        legacyAssertTrue(
            state.commands.contains { $0.contains(#""method":"browser.profiles.list""#) },
            "Expected browser profiles list to call browser.profiles.list, saw \(state.commands)"
        )
    }

    @Test
    func testBrowserProfilesCreateClearAndDeleteRouteToSocketMethods() throws {
        let cliPath = try bundledCLIPath()
        let cases: [(name: String, arguments: [String], expectedMethod: String, expectedParams: [String], responseResult: [String: Any])] = [
            (
                "create",
                ["browser", "profiles", "add", "Agent Smoke"],
                "browser.profiles.create",
                [#""name":"Agent Smoke""#],
                [
                    "created": true,
                    "profile": [
                        "id": "11111111-1111-1111-1111-111111111111",
                        "name": "Agent Smoke",
                        "slug": "agent-smoke",
                        "built_in_default": false,
                        "current": true,
                    ],
                ]
            ),
            (
                "clear",
                ["browser", "profiles", "clear", "Agent Smoke"],
                "browser.profiles.clear",
                [#""profile":"Agent Smoke""#],
                ["cleared": true, "count": 1, "profiles": []]
            ),
            (
                "clear-force",
                ["browser", "profiles", "clear", "Agent Smoke", "--force"],
                "browser.profiles.clear",
                [#""profile":"Agent Smoke""#, #""force":true"#],
                ["cleared": true, "count": 1, "profiles": []]
            ),
            (
                "delete",
                ["browser", "profiles", "delete", "Agent Smoke"],
                "browser.profiles.delete",
                [#""profile":"Agent Smoke""#],
                [
                    "deleted": true,
                    "profile": [
                        "id": "11111111-1111-1111-1111-111111111111",
                        "name": "Agent Smoke",
                        "slug": "agent-smoke",
                        "built_in_default": false,
                        "current": false,
                    ],
                ]
            ),
        ]

        for testCase in cases {
            let socketPath = makeSocketPath("browser-profile-\(testCase.name)")
            let listenerFD = try bindUnixSocket(at: socketPath)
            let state = MockSocketServerState()

            defer {
                Darwin.close(listenerFD)
                unlink(socketPath)
            }

            let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
                guard let payload = self.jsonObject(line),
                      let id = payload["id"] as? String,
                      let method = payload["method"] as? String else {
                    return self.malformedRequestResponse(raw: line)
                }

                legacyAssertEqual(method, testCase.expectedMethod)
                for expectedParam in testCase.expectedParams {
                    legacyAssertTrue(line.contains(expectedParam), line)
                }
                return self.v2Response(id: id, ok: true, result: testCase.responseResult)
            }

            var environment = ProcessInfo.processInfo.environment
            environment["CMUX_SOCKET_PATH"] = socketPath
            environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

            let result = runProcess(
                executablePath: cliPath,
                arguments: testCase.arguments,
                environment: environment,
                timeout: 5
            )

            legacyWait(for: [serverHandled], timeout: 5)
            legacyAssertFalse(result.timedOut, result.stderr)
            legacyAssertEqual(result.status, 0, result.stderr)
            legacyAssertTrue(
                state.commands.contains { $0.contains(#""method":"\#(testCase.expectedMethod)""#) },
                "Expected \(testCase.expectedMethod), saw \(state.commands)"
            )
        }
    }

    private struct MockedSSHRun {
        let requests: [[String: Any]]
        let stdout: String
        let workspaceId: String
        let surfaceId: String
    }

    private func runMockedSSH(
        arguments sshArguments: [String],
        jsonOutput: Bool = false,
        omitWorkspaceCreateSurfaceID: Bool = false,
        environmentOverrides: [String: String] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> MockedSSHRun {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("ssh")
        let homeURL = try makeTemporaryDirectory(prefix: "cmux-ssh-home")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "33333333-3333-3333-3333-333333333333"
        let windowId = "22222222-2222-2222-2222-222222222222"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        startDetachedMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }

            switch method {
            case "workspace.create":
                var result: [String: Any] = [
                    "workspace_id": workspaceId,
                    "window_id": windowId,
                ]
                if !omitWorkspaceCreateSurfaceID {
                    result["surface_id"] = surfaceId
                }
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: result
                )
            case "surface.list":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "surfaces": [
                            [
                                "id": surfaceId,
                                "ref": "surface:1",
                                "index": 1,
                                "focused": true,
                            ],
                        ],
                    ]
                )
            case "workspace.remote.configure":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["remote": ["state": "connected"]]
                )
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["HOME"] = homeURL.path
        for (key, value) in environmentOverrides {
            environment[key] = value
        }

        let commandArguments = jsonOutput
            ? ["--json", "--id-format", "uuids", "ssh", "example.test", "--no-focus"] + sshArguments
            : ["ssh", "example.test", "--no-focus"] + sshArguments
        let result = runProcess(
            executablePath: cliPath,
            arguments: commandArguments,
            environment: environment,
            timeout: 5
        )

        let sawConfigureRequest = waitForMockSocketCommand(in: state) { line in
            line.contains(#""method":"workspace.remote.configure""#)
        }
        legacyAssertTrue(sawConfigureRequest, "Expected workspace.remote.configure, saw \(state.snapshot())", file: file, line: line)
        legacyAssertFalse(result.timedOut, result.stderr, file: file, line: line)
        legacyAssertEqual(result.status, 0, result.stderr, file: file, line: line)
        legacyAssertTrue(result.stderr.isEmpty, result.stderr, file: file, line: line)

        let requests = state.snapshot().compactMap { jsonObject($0) }
        return MockedSSHRun(
            requests: requests,
            stdout: result.stdout,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
    }

    private func makeExistingAgentSocketPath() throws -> String {
        let directory = try makeTemporaryDirectory(prefix: "cmux-agent")
        let url = directory.appendingPathComponent("agent.sock")
        try createExistingFile(at: url)
        return url.path
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func createExistingFile(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        legacyAssertTrue(
            FileManager.default.createFile(atPath: url.path, contents: Data()),
            "Expected to create \(url.path)"
        )
    }

    private func waitForMockSocketCommand(
        in state: MockSocketServerState,
        timeout: TimeInterval = 5,
        predicate: (String) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if state.snapshot().contains(where: predicate) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return state.snapshot().contains(where: predicate)
    }

    private func decodedReusableStartupScript(from command: String) -> String? {
        guard let markerRange = command.range(of: "printf %s ") else {
            return nil
        }
        let remainder = command[markerRange.upperBound...]
        guard let encoded = remainder.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first,
              let data = Data(base64Encoded: String(encoded)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func params(for method: String, in requests: [[String: Any]]) -> [String: Any]? {
        requests
            .first { $0["method"] as? String == method }?["params"] as? [String: Any]
    }

    private func notificationRows(from stdout: String) throws -> [[String: Any]] {
        let data = Data(stdout.utf8)
        return try legacyUnwrap(
            JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]],
            "Expected notification JSON array, got: \(stdout)"
        )
    }

    private func jsonPayload(from stdout: String) throws -> [String: Any] {
        let data = Data(stdout.utf8)
        return try legacyUnwrap(
            JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
            "Expected JSON object, got: \(stdout)"
        )
    }

}

extension CLINotifyProcessIntegrationRegressionTests {
    // E2E for #4920: the REAL CLI launcher env builder (configureTmuxCompatEnvironment, exercised via
    // the hidden __debug-tmux-compat-env seam) must stamp the LAUNCH surface (the launcher's own
    // inherited env), not the operator's focused pane returned by system.identify. Without the fix it
    // stamped the focused surface (A), desyncing CMUX_SURFACE_ID from CMUX_PANEL_ID and jumbling codex
    // into the wrong surface on reload.
    @Test
    func testTmuxCompatEnvStampsLaunchSurfaceNotFocusedPane() throws {
        let cliPath = try bundledCLIPath()
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-spawn-id-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let socketPath = tmpDir.appendingPathComponent("sock").path
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer { Darwin.close(listenerFD); unlink(socketPath) }
        let state = MockSocketServerState()

        // The operator's FOCUSED pane is surface A (what system.identify returns).
        let focusedWorkspace = "11111111-1111-1111-1111-111111111111"
        let focusedSurface = "22222222-2222-2222-2222-222222222222"
        let handled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            if method == "system.identify" {
                return self.v2Response(id: id, ok: true, result: [
                    "focused": [
                        "workspace_id": focusedWorkspace,
                        "surface_id": focusedSurface,
                        "pane_id": "%1",
                    ],
                ])
            }
            // resolveWorkspaceId / tmuxCanonicalPaneId fail gracefully (CLI uses try?).
            return self.v2Response(id: id, ok: false, error: ["code": "unsupported", "message": method])
        }

        // ...but the launcher RUNS in surface B (its own inherited env). Tab id is surface-scoped, so
        // it is distinct from the workspace id.
        let launchWorkspace = "33333333-3333-3333-3333-333333333333"
        let launchSurface = "44444444-4444-4444-4444-444444444444"
        let launchTab = "55555555-5555-5555-5555-555555555555"
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["__debug-tmux-compat-env"],
            environment: [
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": launchWorkspace,
                "CMUX_SURFACE_ID": launchSurface,
                "CMUX_PANEL_ID": launchSurface,
                "CMUX_TAB_ID": launchTab,
                "HOME": tmpDir.path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            ],
            timeout: 30
        )
        legacyWait(for: [handled], timeout: 30)

        legacyAssertTrue(
            result.stdout.contains("CMUX_SURFACE_ID=\(launchSurface)"),
            "launcher must stamp the LAUNCH surface; stdout:\n\(result.stdout)\nstderr:\n\(result.stderr)"
        )
        legacyAssertFalse(
            result.stdout.contains("CMUX_SURFACE_ID=\(focusedSurface)"),
            "launcher must NOT stamp the focused surface; stdout:\n\(result.stdout)"
        )
        legacyAssertTrue(result.stdout.contains("CMUX_WORKSPACE_ID=\(launchWorkspace)"), result.stdout)
        // Matched-pair invariant: SURFACE == PANEL (the desync is exactly the bug). The surface-scoped
        // tab id passes through untouched.
        legacyAssertTrue(result.stdout.contains("CMUX_PANEL_ID=\(launchSurface)"), result.stdout)
        legacyAssertTrue(result.stdout.contains("CMUX_TAB_ID=\(launchTab)"), result.stdout)
    }
}
