import XCTest
import Darwin
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CLINotifyProcessIntegrationRegressionTests: XCTestCase {
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

    func testNestedCodexPromptAndStopDoNotReplaceParentResumeBinding() throws {
        let context = try makeClaudeHookContext(name: "codex-nested-resume-guard")
        defer { context.cleanup() }

        let sessionId = "same-process-session"
        let launchEnvironment = codexLaunchEnvironment(context: context, sessionId: sessionId)
        startAgentHookMockServerAccepting(context: context, connectionLimit: 32)

        let parentPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"spawn subagent"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(parentPrompt.timedOut, parentPrompt.stderr)
        XCTAssertEqual(parentPrompt.status, 0, parentPrompt.stderr)
        XCTAssertTrue(
            context.state.commands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.set" },
            "Parent Codex prompt should publish a resume binding, saw \(context.state.commands)"
        )

        let childPromptStart = context.state.commands.count
        let childPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit","prompt":"return 1+1"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(childPrompt.timedOut, childPrompt.stderr)
        XCTAssertEqual(childPrompt.status, 0, childPrompt.stderr)
        let childPromptCommands = Array(context.state.commands.dropFirst(childPromptStart))
        XCTAssertFalse(
            childPromptCommands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.set" },
            "Nested Codex prompt should not replace the parent resume binding, saw \(childPromptCommands)"
        )
        XCTAssertFalse(
            childPromptCommands.contains { $0.hasPrefix("set_status codex Running ") },
            "Nested Codex prompt should not rewrite parent Running status, saw \(childPromptCommands)"
        )

        let childStopStart = context.state.commands.count
        let childStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"2"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(childStop.timedOut, childStop.stderr)
        XCTAssertEqual(childStop.status, 0, childStop.stderr)
        let childStopCommands = Array(context.state.commands.dropFirst(childStopStart))
        XCTAssertTrue(
            childStopCommands.contains { $0.contains(#""method":"feed.push""#) && $0.contains(#""hook_event_name":"Stop""#) },
            "Nested Codex Stop should remain Feed telemetry, saw \(childStopCommands)"
        )
        XCTAssertFalse(
            childStopCommands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.set" },
            "Nested Codex Stop should not replace the parent resume binding, saw \(childStopCommands)"
        )
        XCTAssertFalse(
            childStopCommands.contains { $0.hasPrefix("notify_target") || $0.hasPrefix("set_status codex ") },
            "Nested Codex Stop should not notify or mark the parent idle, saw \(childStopCommands)"
        )

        let parentStopStart = context.state.commands.count
        let parentStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"parent done"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(parentStop.timedOut, parentStop.stderr)
        XCTAssertEqual(parentStop.status, 0, parentStop.stderr)
        let parentStopCommands = Array(context.state.commands.dropFirst(parentStopStart))
        XCTAssertTrue(
            parentStopCommands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.set" },
            "Parent Codex Stop should still refresh the resume binding, saw \(parentStopCommands)"
        )
        XCTAssertTrue(
            parentStopCommands.contains { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Codex|") },
            "Parent Codex Stop should still notify, saw \(parentStopCommands)"
        )
        XCTAssertTrue(
            parentStopCommands.contains { $0.hasPrefix("set_status codex ") && $0.contains(" Idle ") },
            "Parent Codex Stop should mark Codex idle, saw \(parentStopCommands)"
        )
    }

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

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertTrue(
            context.state.commands.contains { $0.contains(#""method":"feed.push""#) && $0.contains(#""hook_event_name":"Stop""#) },
            "Managed subagent Stop should remain Feed telemetry, saw \(context.state.commands)"
        )
        XCTAssertFalse(
            context.state.commands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.set" },
            "Managed subagent Stop should not publish a child resume binding, saw \(context.state.commands)"
        )
        XCTAssertFalse(
            context.state.commands.contains { $0.hasPrefix("notify_target") || $0.hasPrefix("set_status codex ") },
            "Managed subagent Stop should not notify or clobber visible status, saw \(context.state.commands)"
        )
    }

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
        XCTAssertFalse(prompt.timedOut, prompt.stderr)
        XCTAssertEqual(prompt.status, 0, prompt.stderr)

        let stopStart = context.state.commands.count
        let stop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(context.root.path)","transcript_path":"\#(transcriptURL.path)","hook_event_name":"Stop","last_assistant_message":"parent done"}"#,
            extraEnvironment: launchEnvironment
        )
        XCTAssertFalse(stop.timedOut, stop.stderr)
        XCTAssertEqual(stop.status, 0, stop.stderr)

        let stopCommands = Array(context.state.commands.dropFirst(stopStart))
        XCTAssertTrue(
            stopCommands.contains { $0.hasPrefix("notify_target_async \(context.workspaceId) \(context.surfaceId) Codex|") },
            "Stale completed-turn subagent relay should not suppress the parent completion notification, saw \(stopCommands)"
        )
    }

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

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertFalse(
            context.state.commands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.clear" },
            "Managed subagent SessionEnd should not clear the parent resume binding, saw \(context.state.commands)"
        )
        XCTAssertFalse(
            context.state.commands.contains { $0.hasPrefix("clear_agent_pid codex.") },
            "Managed subagent SessionEnd should not clear the visible parent PID, saw \(context.state.commands)"
        )
        let savedState = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        let savedSessions = try XCTUnwrap(savedState["sessions"] as? [String: Any])
        XCTAssertNotNil(savedSessions[sessionId], "Suppressed SessionEnd should leave the stored parent session intact")
    }

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
                XCTAssertEqual(line, item.expectedCommand)
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

            wait(for: [serverHandled], timeout: 5)
            XCTAssertFalse(result.timedOut, "\(item.name): \(result.stderr)")
            XCTAssertEqual(result.status, 0, "\(item.name): \(result.stderr)")
            XCTAssertEqual(result.stdout, item.stdout, item.name)
            XCTAssertTrue(result.stderr.isEmpty, "\(item.name): \(result.stderr)")
            XCTAssertEqual(state.commands, [item.expectedCommand], item.name)
        }
    }

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

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertTrue(result.stdout.isEmpty, result.stdout)
        XCTAssertTrue(result.stderr.contains("Unknown right-sidebar command 'unknown'"), result.stderr)
        XCTAssertFalse(result.stderr.contains("Socket"), result.stderr)
    }

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

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertTrue(result.stdout.isEmpty, result.stdout)
        XCTAssertTrue(result.stderr.contains("Unknown right-sidebar mode 'unknown'"), result.stderr)
        XCTAssertFalse(result.stderr.contains("Socket"), result.stderr)
    }

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
                    XCTAssertEqual(params["window_id"] as? String, windowId)
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

            XCTAssertEqual(line, "right_sidebar set find --tab=\(workspaceId) --window=\(windowId)")
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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.isEmpty, result.stdout)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["window.list", "workspace.list"]
        )
        XCTAssertEqual(state.commands.last, "right_sidebar set find --tab=\(workspaceId) --window=\(windowId)")
    }

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
            XCTAssertEqual(method, "workspace.list")
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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertTrue(result.stdout.isEmpty, result.stdout)
        XCTAssertTrue(result.stderr.contains("Workspace ref not found"), result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["workspace.list"]
        )
        XCTAssertFalse(
            state.commands.contains { $0.hasPrefix("right_sidebar ") },
            "Expected no right_sidebar command after target resolution failed, saw \(state.commands)"
        )
    }

    @MainActor
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
                XCTAssertNil(params["workspace_id"], "surface UUIDs should not be constrained to the caller workspace")
                XCTAssertNil(params["window_id"], "surface UUIDs should not require an explicit window")
                XCTAssertEqual(params["surface_id"] as? String, callerSurface)
                XCTAssertEqual(params["body"] as? String, "Body")
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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertTrue(
            state.commands.contains { $0.contains("\"method\":\"notification.create\"") },
            "Expected notify to use single-call UUID notification path, saw \(state.commands)"
        )
    }

    @MainActor
    func testNotificationCLIActionsMutateSocketStateAndListExtendedFields() async throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("notif-actions")
        let store = TerminalNotificationStore.shared
        let previousShared = AppDelegate.shared
        let appDelegate = previousShared ?? AppDelegate()
        let manager = TabManager()
        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        AppDelegate.shared = appDelegate
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false

        let workspace = manager.addWorkspace(title: "CLI|Notification Workspace", select: true)
        let surfaceId = try XCTUnwrap(workspace.focusedPanelId)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")
        window.makeKeyAndOrderFront(nil)

        defer {
            TerminalController.shared.stop()
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            window.close()
            for workspace in manager.tabs {
                manager.closeWorkspace(workspace)
            }
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            store.resetSuppressedNotificationFeedbackHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
            AppDelegate.shared = previousShared
            unlink(socketPath)
        }

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        XCTAssertTrue(waitForSocketFile(at: socketPath), "Socket did not appear at \(socketPath)")

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        func run(_ arguments: [String], timeout: TimeInterval = 5) async -> ProcessRunResult {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = self.runProcess(
                        executablePath: cliPath,
                        arguments: ["--socket", socketPath] + arguments,
                        environment: environment,
                        timeout: timeout
                    )
                    continuation.resume(returning: result)
                }
            }
        }

        let createdAt = Date(timeIntervalSince1970: 1_767_225_600)
        let listedNotification = TerminalNotification(
            id: UUID(),
            tabId: workspace.id,
            surfaceId: surfaceId,
            title: "List Fields",
            subtitle: "cli-test",
            body: "body",
            createdAt: createdAt,
            isRead: false
        )
        store.replaceNotificationsForTesting([listedNotification])

        var result = await run(["list-notifications", "--json", "--id-format", "uuids"])
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        var rows = try notificationRows(from: result.stdout)
        var row = try XCTUnwrap(rows.first(where: { $0["id"] as? String == listedNotification.id.uuidString }))
        XCTAssertEqual(row["workspace_id"] as? String, workspace.id.uuidString)
        XCTAssertEqual(row["surface_id"] as? String, surfaceId.uuidString)
        XCTAssertEqual(row["created_at"] as? String, "2026-01-01T00:00:00Z")
        XCTAssertEqual(row["tab_title"] as? String, "CLI|Notification Workspace")

        result = await run(["--json", "list-notifications", "--id-format", "uuids"])
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        rows = try notificationRows(from: result.stdout)
        row = try XCTUnwrap(rows.first(where: { $0["id"] as? String == listedNotification.id.uuidString }))
        XCTAssertEqual(row["created_at"] as? String, "2026-01-01T00:00:00Z")

        result = await run(["mark-notification-read", "--id", listedNotification.id.uuidString, "--json", "--id-format", "uuids"])
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        rows = try notificationRows(from: await run(["list-notifications", "--json", "--id-format", "uuids"]).stdout)
        row = try XCTUnwrap(rows.first(where: { $0["id"] as? String == listedNotification.id.uuidString }))
        XCTAssertEqual(row["is_read"] as? Bool, true)

        result = await run(["dismiss-notification", "--all-read", "--json", "--id-format", "uuids"])
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let dismissPayload = try jsonPayload(from: result.stdout)
        XCTAssertEqual(dismissPayload["dismissed"] as? Int, 1)
        XCTAssertEqual(dismissPayload["all_read"] as? Bool, true)
        rows = try notificationRows(from: await run(["list-notifications", "--json", "--id-format", "uuids"]).stdout)
        XCTAssertTrue(rows.isEmpty)

        let scopedNotification = TerminalNotification(
            id: UUID(),
            tabId: workspace.id,
            surfaceId: surfaceId,
            title: "Scoped",
            subtitle: "cli-test",
            body: "body",
            createdAt: createdAt,
            isRead: false
        )
        let siblingNotification = TerminalNotification(
            id: UUID(),
            tabId: workspace.id,
            surfaceId: UUID(),
            title: "Sibling",
            subtitle: "cli-test",
            body: "body",
            createdAt: createdAt,
            isRead: false
        )
        store.replaceNotificationsForTesting([scopedNotification, siblingNotification])

        result = await run([
            "mark-notification-read",
            "--workspace",
            workspace.id.uuidString,
            "--surface",
            surfaceId.uuidString,
            "--json",
            "--id-format",
            "uuids",
        ])
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        rows = try notificationRows(from: await run(["list-notifications", "--json", "--id-format", "uuids"]).stdout)
        row = try XCTUnwrap(rows.first(where: { $0["id"] as? String == scopedNotification.id.uuidString }))
        XCTAssertEqual(row["is_read"] as? Bool, true)
        row = try XCTUnwrap(rows.first(where: { $0["id"] as? String == siblingNotification.id.uuidString }))
        XCTAssertEqual(row["is_read"] as? Bool, false)

        let targetWorkspace = manager.addWorkspace(title: "CLI Open Target", select: false)
        let targetSurfaceId = try XCTUnwrap(targetWorkspace.focusedPanelId)
        let openNotification = TerminalNotification(
            id: UUID(),
            tabId: targetWorkspace.id,
            surfaceId: targetSurfaceId,
            title: "Open",
            subtitle: "cli-test",
            body: "body",
            createdAt: createdAt,
            isRead: false
        )
        store.replaceNotificationsForTesting([openNotification])
        manager.selectTab(workspace)

        result = await run(["open-notification", "--id", openNotification.id.uuidString, "--json", "--id-format", "uuids"])
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let openPayload = try jsonPayload(from: result.stdout)
        XCTAssertEqual(openPayload["workspace_id"] as? String, targetWorkspace.id.uuidString)
        XCTAssertEqual(openPayload["surface_id"] as? String, targetSurfaceId.uuidString)
        rows = try notificationRows(from: await run(["list-notifications", "--json", "--id-format", "uuids"]).stdout)
        row = try XCTUnwrap(rows.first(where: { $0["id"] as? String == openNotification.id.uuidString }))
        XCTAssertEqual(row["is_read"] as? Bool, true)

        let jumpNotification = TerminalNotification(
            id: UUID(),
            tabId: targetWorkspace.id,
            surfaceId: targetSurfaceId,
            title: "Jump",
            subtitle: "cli-test",
            body: "body",
            createdAt: createdAt,
            isRead: false
        )
        store.replaceNotificationsForTesting([jumpNotification])
        manager.selectTab(workspace)

        result = await run(["jump-to-unread", "--json", "--id-format", "uuids"])
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let jumpPayload = try jsonPayload(from: result.stdout)
        XCTAssertEqual(jumpPayload["workspace_id"] as? String, targetWorkspace.id.uuidString)
        XCTAssertEqual(jumpPayload["surface_id"] as? String, targetSurfaceId.uuidString)
        rows = try notificationRows(from: await run(["list-notifications", "--json", "--id-format", "uuids"]).stdout)
        row = try XCTUnwrap(rows.first(where: { $0["id"] as? String == jumpNotification.id.uuidString }))
        XCTAssertEqual(row["is_read"] as? Bool, true)
    }

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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let rows = try notificationRows(from: result.stdout)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row["id"] as? String, notificationId)
        XCTAssertEqual(row["workspace_id"] as? String, workspaceId)
        XCTAssertEqual(row["body"] as? String, "alpha|beta|gamma")
        XCTAssertTrue(row["created_at"] is NSNull)
        XCTAssertTrue(row["tab_title"] is NSNull)
    }

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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
        let sessions = try XCTUnwrap(json["sessions"] as? [String: Any])
        let session = try XCTUnwrap(sessions[sessionId] as? [String: Any])
        XCTAssertEqual(session["workspaceId"] as? String, currentWorkspaceId)
        XCTAssertEqual(session["surfaceId"] as? String, currentSurfaceId)
        XCTAssertTrue(
            state.commands.contains { $0.contains("set_status codex Running") && $0.contains("--tab=\(currentWorkspaceId)") },
            "Expected Codex prompt status to target current workspace, saw \(state.commands)"
        )
    }

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
                XCTAssertEqual(params["window_id"] as? String, windowId)
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
                XCTAssertEqual(params["window_id"] as? String, windowId)
                XCTAssertEqual(params["workspace_id"] as? String, workspaceId)
                XCTAssertEqual(params["direction"] as? String, "right")
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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["workspace.list", "pane.create"]
        )
    }

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
                XCTAssertEqual(params["window_id"] as? String, targetWindowId)
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
                XCTAssertEqual(params["window_id"] as? String, targetWindowId)
                XCTAssertEqual(params["workspace_id"] as? String, targetWorkspaceId)
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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("Pane not found in window"), result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["workspace.list", "pane.list"]
        )
    }

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
                XCTAssertEqual(params["window_id"] as? String, targetWindowId)
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
                XCTAssertEqual(params["window_id"] as? String, targetWindowId)
                XCTAssertEqual(params["workspace_id"] as? String, targetWorkspaceId)
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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("Surface not found in window"), result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["workspace.list", "surface.list"]
        )
    }

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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("Window not found: window:2"), result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["window.list"]
        )
    }

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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertTrue(result.stderr.contains("Window not found: \(missingWindowId)"), result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["window.list"]
        )
    }

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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("OK vm-test-case-window"), result.stdout)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["window.list", "vm.create"]
        )
    }

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
                XCTAssertEqual(params["window_id"] as? String, windowId)
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
                XCTAssertEqual(params["window_id"] as? String, windowId)
                XCTAssertEqual(params["surface_id"] as? String, surfaceId)
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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "hello\nOK\n")
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["window.list", "system.identify", "surface.read_text"]
        )
    }

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
                XCTAssertEqual(params["window_id"] as? String, windowId)
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
                XCTAssertEqual(params["window_id"] as? String, windowId)
                XCTAssertEqual(params["workspace_id"] as? String, workspaceId)
                XCTAssertNil(params["surface_id"], line)
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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "workspace text\nOK\n")
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["window.list", "workspace.list", "surface.read_text"]
        )
    }

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
                XCTAssertEqual(params["window_id"] as? String, windowId)
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
                XCTAssertEqual(params["window_id"] as? String, windowId)
                XCTAssertEqual(params["surface_id"] as? String, surfaceId)
                XCTAssertEqual(params["text"] as? String, "echo fresh\n")
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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["window.list", "system.identify", "surface.send_text"]
        )
    }

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
                XCTAssertNil(params["window_id"])
                XCTAssertNil(params["workspace_id"])
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
                XCTAssertEqual(params["surface_id"] as? String, sourceSurfaceId)
                XCTAssertEqual(params["window_id"] as? String, targetWindowId)
                XCTAssertEqual(params["workspace_id"] as? String, targetWorkspaceId)
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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["surface.list", "surface.move"]
        )
    }

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
            XCTAssertEqual(params["surface_id"] as? String, sourceSurfaceRef)
            XCTAssertEqual(params["window_id"] as? String, targetWindowId)
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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["surface.move"]
        )
    }

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
                XCTAssertEqual(params["window_id"] as? String, windowId)
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceId])
            }

            XCTAssertTrue(line.hasPrefix("set_status build running"), line)
            XCTAssertTrue(line.contains("--tab=\(workspaceId)"), line)
            XCTAssertFalse(line.contains("--window"), line)
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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
    }

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
                XCTAssertEqual(params["window_id"] as? String, windowId)
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceId])
            }

            XCTAssertEqual(line, "log --tab=\(workspaceId) -- --window target")
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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
    }

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
            XCTAssertEqual(params["window_id"] as? String, windowId)
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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertTrue(result.stderr.contains("set-status: targeted window has no current workspace"), result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["workspace.current"]
        )
    }

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
                XCTAssertEqual(params["window_id"] as? String, windowId)
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceId])
            case "notification.create":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["window_id"] as? String, windowId)
                XCTAssertEqual(params["workspace_id"] as? String, workspaceId)
                XCTAssertEqual(params["title"] as? String, "Window Notify")
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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["workspace.current", "notification.create"]
        )
    }

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
                XCTAssertTrue(line.hasPrefix("notify_target \(targetWorkspaceId) \(targetSurfaceId) "), line)
                XCTAssertTrue(line.contains("Window Surface Notify"), line)
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
                XCTAssertEqual(params["window_id"] as? String, windowId)
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
                XCTAssertEqual(params["window_id"] as? String, windowId)
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
                    XCTFail("Unexpected surface.list params: \(params)")
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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        let methods = state.commands.compactMap { self.jsonObject($0)?["method"] as? String }
        XCTAssertEqual(methods, ["window.list", "workspace.list", "surface.list", "surface.list"])
    }

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
                XCTAssertTrue(line.hasPrefix("notify_target \(selectedWorkspaceId) \(selectedSurfaceId) "), line)
                XCTAssertTrue(line.contains("Window Indexed Notify"), line)
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
                XCTAssertEqual(params["window_id"] as? String, windowId)
                return self.v2Response(id: id, ok: true, result: ["workspace_id": selectedWorkspaceId])
            case "surface.list":
                XCTAssertEqual(params["window_id"] as? String, windowId)
                XCTAssertEqual(params["workspace_id"] as? String, selectedWorkspaceId)
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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        let methods = state.commands.compactMap { self.jsonObject($0)?["method"] as? String }
        XCTAssertEqual(methods, ["window.list", "workspace.current", "surface.list"])
    }

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
                XCTAssertEqual(params["window_id"] as? String, windowId)
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceId])
            case "workspace.action":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["window_id"] as? String, windowId)
                XCTAssertEqual(params["workspace_id"] as? String, workspaceId)
                XCTAssertEqual(params["action"] as? String, "pin")
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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["workspace.current", "workspace.action"]
        )
    }

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
            XCTAssertEqual(params["window_id"] as? String, windowId)
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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertTrue(result.stderr.contains("clear-notifications: targeted window has no current workspace"), result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["workspace.current"]
        )
    }

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
            XCTAssertEqual(params["window_id"] as? String, windowId)
            XCTAssertEqual(params["all_windows"] as? Bool, false)
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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
    }

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
                XCTAssertEqual(params["window_id"] as? String, windowId)
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "method_not_found", "message": "system.tree"]
                )
            case "system.identify":
                XCTAssertEqual(params["window_id"] as? String, windowId)
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
                XCTAssertEqual(params["window_id"] as? String, "window:2")
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
                XCTAssertTrue([workspaceId, "workspace:1"].contains(params["workspace_id"] as? String))
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
                XCTAssertTrue([workspaceId, "workspace:1"].contains(params["workspace_id"] as? String))
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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)

        let payload = try jsonPayload(from: result.stdout)
        let windows = try XCTUnwrap(payload["windows"] as? [[String: Any]])
        XCTAssertEqual(windows.count, 1, result.stdout)
        XCTAssertEqual(windows.first?["id"] as? String, windowId)
        XCTAssertFalse(result.stdout.contains(otherWindowId), result.stdout)
    }

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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertFalse(
            state.commands.contains { $0.contains("set_status codex Running") || $0.contains("notify_target_async") },
            "Foreign cmux env must not mutate the selected workspace, saw \(state.commands)"
        )
    }

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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertFalse(
            state.commands.contains { $0.contains("set_status codex Running") || $0.contains("notify_target_async") },
            "Foreign cmux env must not reuse stale mapped sessions, saw \(state.commands)"
        )
    }

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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertFalse(
            state.commands.contains { $0.contains("set_status codex Running") || $0.contains("notify_target_async") },
            "Invalid surface must not fall back to the focused surface, saw \(state.commands)"
        )
    }

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
        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
        XCTAssertFalse(
            state.commands.contains { $0.contains("set_status codex Running") || $0.contains("notify_target_async") },
            "Invalid mapped workspace must not mutate the selected workspace, saw \(state.commands)"
        )
    }

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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let resumeBindingRequests = state.commands.compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.set" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        XCTAssertEqual(resumeBindingRequests.count, 1, state.commands.joined(separator: "\n"))
        let request = try XCTUnwrap(resumeBindingRequests.first)
        XCTAssertEqual(request["checkpoint_id"] as? String, sessionId)
        XCTAssertEqual(request["auto_resume"] as? Bool, true)
        XCTAssertEqual(
            request["command"] as? String,
            "cd '\(root.path)' && '/usr/local/bin/cmux' 'codex-teams' 'resume' '\(sessionId)' '--model' 'gpt-5.4' '--sandbox' 'danger-full-access'"
        )
    }

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
                XCTFail("Non-resumable launcher should not publish a resume binding")
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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let clearRequests = state.commands.compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.clear" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        let request = try XCTUnwrap(clearRequests.first)
        XCTAssertNil(request["workspace_id"])
        XCTAssertEqual(request["surface_id"] as? String, surfaceId)
        XCTAssertEqual(request["source"] as? String, "agent-hook")
        XCTAssertEqual(request["checkpoint_id"] as? String, sessionId)
    }

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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let clearRequests = state.commands.compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.clear" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        let request = try XCTUnwrap(clearRequests.first)
        XCTAssertNil(request["workspace_id"])
        XCTAssertEqual(request["surface_id"] as? String, surfaceId)
        XCTAssertEqual(request["checkpoint_id"] as? String, sessionId)
        XCTAssertEqual(request["source"] as? String, "agent-hook")
    }

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
            XCTAssertEqual(method, "surface.resume.clear")
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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")

        let clearRequests = state.commands.compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.clear" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        let request = try XCTUnwrap(clearRequests.first)
        XCTAssertEqual(request["workspace_id"] as? String, workspaceId)
        XCTAssertEqual(request["surface_id"] as? String, surfaceId)
        XCTAssertEqual(request["checkpoint_id"] as? String, "new-session")
        XCTAssertEqual(request["source"] as? String, "agent-hook")
    }

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
            XCTAssertEqual(method, "surface.resume.set")
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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")

        let setRequests = state.commands.compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.set" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        XCTAssertEqual(setRequests.count, 1)
        let request = try XCTUnwrap(setRequests.first)
        XCTAssertEqual(request["workspace_id"] as? String, workspaceId)
        XCTAssertEqual(request["surface_id"] as? String, surfaceId)
        XCTAssertEqual(request["kind"] as? String, "tmux")
        XCTAssertEqual(request["command"] as? String, "tmux attach -t work")
    }

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
            XCTAssertEqual(method, "surface.resume.set")
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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")

        let setRequests = state.commands.compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.set" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        let request = try XCTUnwrap(setRequests.first)
        XCTAssertEqual(request["workspace_id"] as? String, workspaceId)
        XCTAssertEqual(request["surface_id"] as? String, surfaceId)
        XCTAssertNil(request["name"])
        XCTAssertNil(request["kind"])
        XCTAssertEqual(
            request["command"] as? String,
            "'myapp' '--name' 'foo' '--kind' 'bar' '--cwd' '/tmp/ignored' '--surface' 'not-a-target'"
        )
    }

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
            XCTAssertEqual(method, "surface.resume.set")
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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let setRequests = state.commands.compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.set" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        let request = try XCTUnwrap(setRequests.first)
        XCTAssertNil(request["workspace_id"])
        XCTAssertEqual(request["surface_id"] as? String, movedSurfaceId)
    }

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

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.contains("surface resume set: unexpected argument 'attach' after --shell"))
        XCTAssertFalse(result.stderr.contains("Socket"), result.stderr)
    }

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

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertTrue(result.stderr.contains("surface resume set: unexpected argument 'myapp' before --"))
        XCTAssertFalse(result.stderr.contains("Socket"), result.stderr)
    }

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

            XCTAssertFalse(result.timedOut, result.stderr)
            XCTAssertEqual(result.status, 1, result.stderr)
            XCTAssertTrue(result.stdout.isEmpty, result.stdout)
            XCTAssertTrue(result.stderr.contains(item.expected), result.stderr)
            XCTAssertFalse(result.stderr.contains("Socket"), result.stderr)
        }
    }

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

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.contains("surface resume clear: --checkpoint requires a value"))
        XCTAssertFalse(result.stderr.contains("Socket"), result.stderr)
    }

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
                XCTAssertEqual(params["window_id"] as? String, windowId)
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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")

        let clearRequests = state.commands.compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.clear" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        XCTAssertFalse(
            state.commands.contains { command in
                jsonObject(command)?["method"] as? String == "window.focus"
            },
            "surface resume metadata commands should route by window_id without focusing the window"
        )
        let request = try XCTUnwrap(clearRequests.first)
        XCTAssertEqual(request["window_id"] as? String, windowId)
        XCTAssertNotEqual(request["window_id"] as? String, "0")
        XCTAssertEqual(request["surface_id"] as? String, surfaceId)
    }

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
                XCTAssertEqual(params["window_id"] as? String, windowId)
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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        XCTAssertFalse(
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
        let request = try XCTUnwrap(clearRequests.first)
        XCTAssertEqual(request["window_id"] as? String, windowId)
        XCTAssertEqual(request["surface_id"] as? String, surfaceId)
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
        [
            "CMUX_AGENT_LAUNCH_KIND": "codex",
            "CMUX_AGENT_LAUNCH_EXECUTABLE": "/usr/local/bin/codex",
            "CMUX_AGENT_LAUNCH_CWD": context.root.path,
            "CMUX_AGENT_LAUNCH_ARGV_B64": base64NULSeparated([
                "/usr/local/bin/codex",
                "--model",
                "gpt-5.4",
            ]),
        ]
    }

    private func runCodexHook(
        context: ClaudeHookContext,
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
            arguments: ["hooks", "codex", subcommand],
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
        wait(for: [serverHandled], timeout: 5)
        return result
    }

    private func readClaudeHookSession(_ sessionId: String, context: ClaudeHookContext) throws -> [String: Any] {
        let stateURL = context.root.appendingPathComponent("claude-hook-sessions.json")
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        let sessions = try XCTUnwrap(state["sessions"] as? [String: Any])
        return try XCTUnwrap(sessions[sessionId] as? [String: Any])
    }

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

            XCTAssertEqual(method, "browser.import.cookies")
            guard method == "browser.import.cookies" else {
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            XCTAssertEqual(params["scope"] as? String, "cookiesOnly")
            XCTAssertEqual(params["browser"] as? String, "Chrome")
            XCTAssertEqual(params["source_profiles"] as? [String], ["Default"])
            XCTAssertEqual(params["domain_filters"] as? [String], ["github.com"])
            XCTAssertEqual(params["destination_profile"] as? String, "Dev")
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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)

        let stdoutJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(stdoutJSON["browser"] as? String, "Chrome")
        XCTAssertEqual(stdoutJSON["imported_cookies"] as? Int, 3)
        XCTAssertEqual(stdoutJSON["skipped_cookies"] as? Int, 1)
        XCTAssertTrue(
            state.commands.contains { $0.contains(#""method":"browser.import.cookies""#) },
            "Expected coding-agent import to use non-interactive import, saw \(state.commands)"
        )
    }

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

            XCTAssertEqual(method, "browser.import.dialog")
            guard method == "browser.import.dialog" else {
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            XCTAssertNil(params["scope"])
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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertTrue(
            state.commands.contains { $0.contains(#""method":"browser.import.dialog""#) },
            "Expected human import to open the interactive dialog, saw \(state.commands)"
        )
    }

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

            XCTAssertEqual(method, "browser.import.dialog")
            guard method == "browser.import.dialog" else {
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            XCTAssertNil(params["scope"])
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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertTrue(
            state.commands.contains { $0.contains(#""method":"browser.import.dialog""#) },
            "Expected --interactive to force the dialog in coding-agent env, saw \(state.commands)"
        )
    }

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

            XCTAssertEqual(method, "browser.profiles.list")
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

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("default\tDefault\t52B43C05-4A1D-45D3-8FD5-9EF94952E445"), result.stdout)
        XCTAssertTrue(
            state.commands.contains { $0.contains(#""method":"browser.profiles.list""#) },
            "Expected browser profiles list to call browser.profiles.list, saw \(state.commands)"
        )
    }

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

                XCTAssertEqual(method, testCase.expectedMethod)
                for expectedParam in testCase.expectedParams {
                    XCTAssertTrue(line.contains(expectedParam), line)
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

            wait(for: [serverHandled], timeout: 5)
            XCTAssertFalse(result.timedOut, result.stderr)
            XCTAssertEqual(result.status, 0, result.stderr)
            XCTAssertTrue(
                state.commands.contains { $0.contains(#""method":"\#(testCase.expectedMethod)""#) },
                "Expected \(testCase.expectedMethod), saw \(state.commands)"
            )
        }
    }

    private func notificationRows(from stdout: String) throws -> [[String: Any]] {
        let data = Data(stdout.utf8)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]],
            "Expected notification JSON array, got: \(stdout)"
        )
    }

    private func jsonPayload(from stdout: String) throws -> [String: Any] {
        let data = Data(stdout.utf8)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
            "Expected JSON object, got: \(stdout)"
        )
    }

}
