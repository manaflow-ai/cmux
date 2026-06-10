import XCTest
import Darwin
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Claude hook lifecycle
extension CLINotifyProcessIntegrationRegressionTests {
    func testClaudeClearSessionStartMarksWorkspaceRunning() throws {
        let context = try makeClaudeHookContext(name: "claude-clear-running")
        defer { context.cleanup() }

        let result = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "session-start"],
            standardInput: #"{"session_id":"clear-session","source":"clear","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        XCTAssertTrue(
            context.state.commands.contains { $0 == "clear_notifications --tab=\(context.workspaceId)" },
            "Expected clear SessionStart to clear stale notifications, saw \(context.state.commands)"
        )
        XCTAssertTrue(
            context.state.commands.contains {
                $0.hasPrefix("set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab=\(context.workspaceId)")
                    && $0.contains("--panel=\(context.surfaceId)")
            },
            "Expected clear SessionStart to mark Claude running, saw \(context.state.commands)"
        )
    }

    func testClaudeSessionStartRecordIsNotRestorableUntilPrompt() throws {
        let context = try makeClaudeHookContext(name: "claude-session-restorable")
        defer { context.cleanup() }

        let sessionId = "startup-only-session"
        let start = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "session-start"],
            standardInput: #"{"session_id":"\#(sessionId)","source":"startup","cwd":"\#(context.root.path)","transcript_path":"\#(context.root.path)/projects/startup-only-session.jsonl","hook_event_name":"SessionStart"}"#
        )
        XCTAssertFalse(start.timedOut, start.stderr)
        XCTAssertEqual(start.status, 0, start.stderr)

        var record = try readClaudeHookSession(sessionId, context: context)
        XCTAssertEqual(
            record["isRestorable"] as? Bool,
            false,
            "Startup SessionStart records are only routing state until Claude creates a conversation."
        )
        XCTAssertEqual(
            record["transcriptPath"] as? String,
            "\(context.root.path)/projects/startup-only-session.jsonl"
        )

        let prompt = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "prompt-submit"],
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","cwd":"\#(context.root.path)","transcript_path":"\#(context.root.path)/projects/startup-only-session.jsonl","hook_event_name":"UserPromptSubmit"}"#
        )
        XCTAssertFalse(prompt.timedOut, prompt.stderr)
        XCTAssertEqual(prompt.status, 0, prompt.stderr)

        record = try readClaudeHookSession(sessionId, context: context)
        XCTAssertEqual(
            record["isRestorable"] as? Bool,
            true,
            "UserPromptSubmit marks the session eligible for resume."
        )
    }

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

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let preToolEvent = try XCTUnwrap(
            feedPushEvents(in: context).last { $0["hook_event_name"] as? String == "PreToolUse" }
        )
        let feedContext = try XCTUnwrap(preToolEvent["context"] as? [String: Any])
        XCTAssertEqual(feedContext["lastUserMessage"] as? String, "recent user message")
        XCTAssertEqual(feedContext["assistantPreamble"] as? String, "recent assistant response")
        XCTAssertFalse(String(describing: feedContext).contains("ancient"), "\(feedContext)")
    }

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

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let preToolEvent = try XCTUnwrap(
            feedPushEvents(in: context).last { $0["hook_event_name"] as? String == "PreToolUse" }
        )
        let feedContext = try XCTUnwrap(preToolEvent["context"] as? [String: Any])
        let assistantPreamble = try XCTUnwrap(feedContext["assistantPreamble"] as? String)
        XCTAssertTrue(assistantPreamble.hasPrefix("recent assistant response"), "\(feedContext)")
    }

    func testClaudeStopFromPreviousSessionDoesNotClobberClearRunningStatus() throws {
        let context = try makeClaudeHookContext(name: "claude-clear-stale-stop")
        defer { context.cleanup() }

        let oldStart = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "session-start"],
            standardInput: #"{"session_id":"old-session","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        )
        XCTAssertFalse(oldStart.timedOut, oldStart.stderr)
        XCTAssertEqual(oldStart.status, 0, oldStart.stderr)

        let clearStart = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "session-start"],
            standardInput: #"{"session_id":"clear-session","source":"clear","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        )
        XCTAssertFalse(clearStart.timedOut, clearStart.stderr)
        XCTAssertEqual(clearStart.status, 0, clearStart.stderr)

        let lateOldStart = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "session-start"],
            standardInput: #"{"session_id":"old-session","source":"startup","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        )
        XCTAssertFalse(lateOldStart.timedOut, lateOldStart.stderr)
        XCTAssertEqual(lateOldStart.status, 0, lateOldStart.stderr)

        let staleStop = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "stop"],
            standardInput: #"{"session_id":"old-session","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"old turn finished late"}"#
        )
        XCTAssertFalse(staleStop.timedOut, staleStop.stderr)
        XCTAssertEqual(staleStop.status, 0, staleStop.stderr)

        XCTAssertTrue(
            context.state.commands.contains {
                $0.hasPrefix("set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab=\(context.workspaceId)")
                    && $0.contains("--panel=\(context.surfaceId)")
            },
            "Expected clear SessionStart to mark Claude running, saw \(context.state.commands)"
        )
        XCTAssertFalse(
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
        XCTAssertEqual(resumeBindingRequests.count, 1, context.state.commands.joined(separator: "\n"))
        XCTAssertEqual(resumeBindingRequests.first?["checkpoint_id"] as? String, "clear-session")
        XCTAssertEqual(resumeBindingRequests.first?["auto_resume"] as? Bool, true)
    }

    func testClaudePromptSubmitFromNewSessionCanReplaceStoppedSession() throws {
        let context = try makeClaudeHookContext(name: "claude-new-session-after-stop")
        defer { context.cleanup() }

        let oldStart = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "session-start"],
            standardInput: #"{"session_id":"old-session","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        )
        XCTAssertFalse(oldStart.timedOut, oldStart.stderr)
        XCTAssertEqual(oldStart.status, 0, oldStart.stderr)

        let oldPrompt = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "prompt-submit"],
            standardInput: #"{"session_id":"old-session","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"PromptSubmit"}"#
        )
        XCTAssertFalse(oldPrompt.timedOut, oldPrompt.stderr)
        XCTAssertEqual(oldPrompt.status, 0, oldPrompt.stderr)

        let oldStop = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "stop"],
            standardInput: #"{"session_id":"old-session","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"old turn finished"}"#
        )
        XCTAssertFalse(oldStop.timedOut, oldStop.stderr)
        XCTAssertEqual(oldStop.status, 0, oldStop.stderr)

        let newStart = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "session-start"],
            standardInput: #"{"session_id":"new-session","source":"startup","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#
        )
        XCTAssertFalse(newStart.timedOut, newStart.stderr)
        XCTAssertEqual(newStart.status, 0, newStart.stderr)

        let newPromptStart = context.state.commands.count
        let newPrompt = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "prompt-submit"],
            standardInput: #"{"session_id":"new-session","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"PromptSubmit"}"#
        )
        XCTAssertFalse(newPrompt.timedOut, newPrompt.stderr)
        XCTAssertEqual(newPrompt.status, 0, newPrompt.stderr)

        let newPromptCommands = Array(context.state.commands.dropFirst(newPromptStart))
        XCTAssertTrue(
            newPromptCommands.contains {
                $0.hasPrefix("set_status claude_code Running --icon=bolt.fill --color=#4C8DFF --tab=\(context.workspaceId)")
            },
            "Expected a new Claude session to replace a stopped idle owner on prompt-submit, saw \(newPromptCommands)"
        )
    }

    func testClaudePromptSubmitResumeBindingPersistsAuthSelectionMarkersWithoutValues() throws {
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
        let start = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "session-start"],
            standardInput: #"{"session_id":"\#(sessionId)","source":"startup","cwd":"\#(context.root.path)","hook_event_name":"SessionStart"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(start.timedOut, start.stderr)
        XCTAssertEqual(start.status, 0, start.stderr)

        let commandStart = context.state.commands.count
        let prompt = runClaudeHook(
            context: context,
            arguments: ["hooks", "claude", "prompt-submit"],
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(prompt.timedOut, prompt.stderr)
        XCTAssertEqual(prompt.status, 0, prompt.stderr)

        let promptCommands = Array(context.state.commands.dropFirst(commandStart))
        let resumeBindingRequests = promptCommands.compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.set" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        XCTAssertEqual(resumeBindingRequests.count, 1, promptCommands.joined(separator: "\n"))
        let request = try XCTUnwrap(resumeBindingRequests.first)
        XCTAssertEqual(request["auto_resume"] as? Bool, true)
        let environment = try XCTUnwrap(request["environment"] as? [String: Any])
        XCTAssertEqual(environment["CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV"] as? String, "1")
        XCTAssertEqual(
            environment["CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS"] as? String,
            "ANTHROPIC_BASE_URL,ANTHROPIC_MODEL,CLAUDE_CONFIG_DIR"
        )
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])
        XCTAssertNil(environment["ANTHROPIC_BASE_URL"])
        XCTAssertNil(environment["ANTHROPIC_MODEL"])
        XCTAssertNil(environment["CLAUDE_CONFIG_DIR"])
    }

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

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        let savedState = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        let savedSessions = try XCTUnwrap(savedState["sessions"] as? [String: Any])
        XCTAssertNil(
            savedSessions[staleSessionId],
            "Expected fallback session-end handling to consume the seeded stale session"
        )
        XCTAssertFalse(
            context.state.commands.contains { $0.hasPrefix("clear_status claude_code ") && $0.contains("--tab=\(staleWorkspaceId)") },
            "Expected stale SessionEnd not to clear the consumed workspace, saw \(context.state.commands)"
        )
        XCTAssertFalse(
            context.state.commands.contains { $0.hasPrefix("clear_agent_pid claude_code ") && $0.contains("--tab=\(staleWorkspaceId)") },
            "Expected stale SessionEnd not to clear the consumed workspace PID, saw \(context.state.commands)"
        )
        XCTAssertFalse(
            context.state.commands.contains { $0 == "clear_notifications --tab=\(staleWorkspaceId)" },
            "Expected stale SessionEnd not to clear the consumed workspace notifications, saw \(context.state.commands)"
        )
    }

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

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertFalse(
            context.state.commands.contains { $0.hasPrefix("clear_agent_pid claude_code ") && $0.contains("--tab=\(context.workspaceId)") },
            "Expected stale same-session turn not to clear current PID, saw \(context.state.commands)"
        )
        XCTAssertFalse(
            context.state.commands.contains { $0 == "clear_notifications --tab=\(context.workspaceId)" },
            "Expected stale same-session turn not to clear current notifications, saw \(context.state.commands)"
        )

        let savedState = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        let savedSessions = try XCTUnwrap(savedState["sessions"] as? [String: Any])
        XCTAssertNotNil(
            savedSessions[sessionId],
            "Expected stale same-session SessionEnd not to consume the active session"
        )
        let activeSessions = try XCTUnwrap(savedState["activeSessionsByWorkspace"] as? [String: Any])
        let active = try XCTUnwrap(activeSessions[context.workspaceId] as? [String: Any])
        XCTAssertEqual(active["turnId"] as? String, "turn-2")
    }

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

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let clearRequests = context.state.commands.compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.clear" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        let request = try XCTUnwrap(clearRequests.first)
        XCTAssertNil(request["workspace_id"])
        XCTAssertEqual(request["surface_id"] as? String, context.surfaceId)
        XCTAssertEqual(request["checkpoint_id"] as? String, sessionId)
        XCTAssertEqual(request["source"] as? String, "agent-hook")
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
        wait(for: [serverHandled], timeout: 5)
        return result
    }

    private func readClaudeHookSession(_ sessionId: String, context: ClaudeHookContext) throws -> [String: Any] {
        let stateURL = context.root.appendingPathComponent("claude-hook-sessions.json")
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        let sessions = try XCTUnwrap(state["sessions"] as? [String: Any])
        return try XCTUnwrap(sessions[sessionId] as? [String: Any])
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

}
