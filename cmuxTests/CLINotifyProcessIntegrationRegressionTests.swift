import XCTest
import Darwin
import SQLite3
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

    func testMemorySnapshotPersistsSystemTopWorkspaceSamplesWithoutCommandLines() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("mem-snapshot")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let dbURL = temporaryMemoryTelemetryDatabaseURL(name: "snapshot")
        let secretCommandLine = "/usr/local/bin/codex --api-key SECRET_TOKEN_DO_NOT_STORE"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent())
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            guard method == "system.top" else {
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            XCTAssertEqual((params["all_windows"] as? NSNumber)?.boolValue, true)
            XCTAssertEqual((params["include_processes"] as? NSNumber)?.boolValue, true)
            XCTAssertNil(params["workspace_id"])
            return self.v2Response(
                id: id,
                ok: true,
                result: self.memorySystemTopFixture(
                    workspaceId: workspaceId,
                    workspaceRef: "workspace:2",
                    surfaceId: surfaceId,
                    agentKey: "codex",
                    agentPID: 424_242,
                    secretCommandLine: secretCommandLine
                )
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_MEMORY_TELEMETRY_DB_PATH"] = dbURL.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["memory", "snapshot", "--json", "--id-format", "uuids"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)

        let payload = try jsonPayload(from: result.stdout)
        XCTAssertEqual(payload["sample_count"] as? Int, 1)
        let samples = try XCTUnwrap(payload["samples"] as? [[String: Any]])
        let sample = try XCTUnwrap(samples.first)
        XCTAssertEqual(sample["workspace_id"] as? String, workspaceId)
        XCTAssertEqual(sample["resident_bytes"] as? Int, 314_572_800)
        XCTAssertEqual(sample["memory_percent"] as? Double, 1.8)
        XCTAssertTrue((sample["top_process_names"] as? [String] ?? []).contains("codex"))

        let persistedProcessNames = try memoryTelemetryTopProcessNames(in: dbURL)
        XCTAssertTrue(persistedProcessNames.contains("codex"))
        XCTAssertTrue(persistedProcessNames.contains("node"))
        XCTAssertFalse(persistedProcessNames.contains(secretCommandLine))
        XCTAssertFalse(
            persistedProcessNames.contains { $0.contains("SECRET_TOKEN_DO_NOT_STORE") },
            "Persisted process names must not include command-line secrets: \(persistedProcessNames)"
        )
        XCTAssertFalse(
            persistedProcessNames.contains { $0.hasPrefix("/") || $0.contains(" --") },
            "Persisted process names must be bare process names: \(persistedProcessNames)"
        )
        XCTAssertFalse(result.stdout.contains("SECRET_TOKEN_DO_NOT_STORE"), result.stdout)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["system.top"]
        )
    }

    func testMemorySnapshotLimitOnlyFiltersOutputNotPersistence() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("mem-snapshot-limit")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let primaryWorkspaceId = "11111111-2222-3333-4444-555555555555"
        let secondaryWorkspaceId = "66666666-7777-8888-9999-AAAAAAAAAAAA"
        let surfaceId = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        let dbURL = temporaryMemoryTelemetryDatabaseURL(name: "snapshot-limit")

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent())
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            guard method == "system.top" else {
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
            var topPayload = self.memorySystemTopFixture(
                workspaceId: primaryWorkspaceId,
                workspaceRef: "workspace:1",
                surfaceId: surfaceId,
                agentKey: "codex",
                agentPID: 111_111,
                secretCommandLine: "/usr/local/bin/codex"
            )
            var windows = topPayload["windows"] as? [[String: Any]] ?? []
            var window = windows[0]
            var workspaces = window["workspaces"] as? [[String: Any]] ?? []
            var secondary = workspaces[0]
            secondary["id"] = secondaryWorkspaceId
            secondary["ref"] = "workspace:2"
            secondary["title"] = "Second Memory Workspace"
            secondary["resources"] = [
                "cpu_percent": 2.5,
                "memory_percent": 0.9,
                "resident_bytes": 157_286_400,
                "virtual_bytes": 314_572_800,
                "process_count": 1,
            ]
            secondary["tags"] = []
            secondary["panes"] = []
            workspaces.append(secondary)
            window["workspaces"] = workspaces
            windows[0] = window
            topPayload["windows"] = windows
            return self.v2Response(id: id, ok: true, result: topPayload)
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_MEMORY_TELEMETRY_DB_PATH"] = dbURL.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["memory", "snapshot", "--limit", "1", "--json", "--id-format", "uuids"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)

        let payload = try jsonPayload(from: result.stdout)
        XCTAssertEqual(payload["sample_count"] as? Int, 2)
        XCTAssertEqual(payload["display_sample_count"] as? Int, 1)
        let samples = try XCTUnwrap(payload["samples"] as? [[String: Any]])
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(try memoryTelemetrySampleCount(in: dbURL), 2)
    }

    func testMemoryTopReadsPersistedWorkspaceSamples() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("mem-top")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceId = "33333333-3333-3333-3333-333333333333"
        let dbURL = temporaryMemoryTelemetryDatabaseURL(name: "top")

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent())
        }

        let snapshotHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            XCTAssertEqual(method, "system.top")
            return self.v2Response(
                id: id,
                ok: true,
                result: self.memorySystemTopFixture(
                    workspaceId: workspaceId,
                    workspaceRef: "workspace:4",
                    surfaceId: "44444444-4444-4444-4444-444444444444",
                    agentKey: "codex",
                    agentPID: 525_252,
                    secretCommandLine: "/usr/local/bin/codex --secret ignored"
                )
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_MEMORY_TELEMETRY_DB_PATH"] = dbURL.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let snapshotResult = runProcess(
            executablePath: cliPath,
            arguments: ["memory", "snapshot", "--json", "--id-format", "uuids"],
            environment: environment,
            timeout: 5
        )
        wait(for: [snapshotHandled], timeout: 5)
        XCTAssertFalse(snapshotResult.timedOut, snapshotResult.stderr)
        XCTAssertEqual(snapshotResult.status, 0, snapshotResult.stderr)

        let topHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            XCTFail("memory top should read SQLite and not resample system.top, saw \(line)")
            return "{}"
        }
        topHandled.isInverted = true

        let topResult = runProcess(
            executablePath: cliPath,
            arguments: ["memory", "top", "--since", "1d", "--json", "--id-format", "uuids"],
            environment: environment,
            timeout: 5
        )
        wait(for: [topHandled], timeout: 0.1)
        XCTAssertFalse(topResult.timedOut, topResult.stderr)
        XCTAssertEqual(topResult.status, 0, topResult.stderr)
        XCTAssertTrue(topResult.stderr.isEmpty, topResult.stderr)

        let payload = try jsonPayload(from: topResult.stdout)
        let rows = try XCTUnwrap(payload["rows"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row["workspace_id"] as? String, workspaceId)
        XCTAssertEqual(row["sample_count"] as? Int, 1)
        XCTAssertEqual((row["peak_rss_bytes"] as? NSNumber)?.int64Value, 314_572_800)
        XCTAssertEqual(row["peak_memory_percent"] as? Double, 1.8)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["system.top"]
        )
    }

    func testMemoryTopTruncatesFloatBackedResidentBytes() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("mem-top-float-rss")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceId = "55555555-5555-5555-5555-555555555555"
        let dbURL = temporaryMemoryTelemetryDatabaseURL(name: "top-float-rss")

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent())
        }

        let snapshotHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            XCTAssertEqual(method, "system.top")
            return self.v2Response(
                id: id,
                ok: true,
                result: self.memorySystemTopFixture(
                    workspaceId: workspaceId,
                    workspaceRef: "workspace:5",
                    surfaceId: "66666666-6666-6666-6666-666666666666",
                    agentKey: "codex",
                    agentPID: 525_253,
                    secretCommandLine: "/usr/local/bin/codex --secret ignored",
                    workspaceResidentBytes: 314_572_800.75
                )
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_MEMORY_TELEMETRY_DB_PATH"] = dbURL.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let snapshotResult = runProcess(
            executablePath: cliPath,
            arguments: ["memory", "snapshot", "--json", "--id-format", "uuids"],
            environment: environment,
            timeout: 5
        )
        wait(for: [snapshotHandled], timeout: 5)
        XCTAssertFalse(snapshotResult.timedOut, snapshotResult.stderr)
        XCTAssertEqual(snapshotResult.status, 0, snapshotResult.stderr)

        let topHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            XCTFail("memory top should read SQLite and not resample system.top, saw \(line)")
            return "{}"
        }
        topHandled.isInverted = true

        let topResult = runProcess(
            executablePath: cliPath,
            arguments: ["memory", "top", "--since", "1d", "--json", "--id-format", "uuids"],
            environment: environment,
            timeout: 5
        )
        wait(for: [topHandled], timeout: 0.1)
        XCTAssertFalse(topResult.timedOut, topResult.stderr)
        XCTAssertEqual(topResult.status, 0, topResult.stderr)
        XCTAssertTrue(topResult.stderr.isEmpty, topResult.stderr)

        let payload = try jsonPayload(from: topResult.stdout)
        let rows = try XCTUnwrap(payload["rows"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row["workspace_id"] as? String, workspaceId)
        XCTAssertEqual((row["peak_rss_bytes"] as? NSNumber)?.int64Value, 314_572_800)
    }

    func testMemoryTopSortsByAverageRSSBeforeLimit() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("mem-top-sort")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let dbURL = temporaryMemoryTelemetryDatabaseURL(name: "top-sort")
        let steadyWorkspace = "11111111-1111-1111-1111-111111111111"
        let spikyWorkspace = "22222222-2222-2222-2222-222222222222"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent())
        }

        try insertMemoryTelemetrySample(
            in: dbURL,
            sampledAt: Date().addingTimeInterval(-120),
            workspaceId: steadyWorkspace,
            workspaceRef: "workspace:1",
            rssBytes: 900
        )
        try insertMemoryTelemetrySample(
            in: dbURL,
            sampledAt: Date().addingTimeInterval(-60),
            workspaceId: steadyWorkspace,
            workspaceRef: "workspace:1",
            rssBytes: 900
        )
        try insertMemoryTelemetrySample(
            in: dbURL,
            sampledAt: Date().addingTimeInterval(-120),
            workspaceId: spikyWorkspace,
            workspaceRef: "workspace:2",
            rssBytes: 1_000
        )
        try insertMemoryTelemetrySample(
            in: dbURL,
            sampledAt: Date().addingTimeInterval(-60),
            workspaceId: spikyWorkspace,
            workspaceRef: "workspace:2",
            rssBytes: 1
        )

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_MEMORY_TELEMETRY_DB_PATH"] = dbURL.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["memory", "top", "--since", "1h", "--sort", "avg", "--limit", "1", "--json", "--id-format", "uuids"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)

        let payload = try jsonPayload(from: result.stdout)
        XCTAssertEqual(payload["sort"] as? String, "average")
        let rows = try XCTUnwrap(payload["rows"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(row["workspace_id"] as? String, steadyWorkspace)
        XCTAssertEqual((row["peak_rss_bytes"] as? NSNumber)?.int64Value, 900)
    }

    func testMemoryTopPrunesExpiredRowsOnRead() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("mem-top-prune")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let dbURL = temporaryMemoryTelemetryDatabaseURL(name: "top-prune")

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent())
        }

        try insertMemoryTelemetrySample(
            in: dbURL,
            sampledAt: Date().addingTimeInterval(-3600),
            workspaceId: "77777777-7777-7777-7777-777777777777"
        )

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_MEMORY_TELEMETRY_DB_PATH"] = dbURL.path
        environment["CMUX_MEMORY_TELEMETRY_RETENTION_SECONDS"] = "1"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["memory", "top", "--since", "2h", "--json", "--id-format", "uuids"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)

        let payload = try jsonPayload(from: result.stdout)
        let rows = try XCTUnwrap(payload["rows"] as? [[String: Any]])
        XCTAssertTrue(rows.isEmpty, "Expected expired rows to be pruned on read, got \(rows)")
        XCTAssertEqual(try memoryTelemetrySampleCount(in: dbURL), 0)
    }

    func testMemoryTrimDryRunSelectsOwnedAgentWithoutSendingOrKilling() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("mem-trim")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceId = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let lowercaseWorkspaceId = workspaceId.lowercased()
        let surfaceId = "66666666-6666-6666-6666-666666666666"

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
            guard method == "system.top" else {
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            XCTAssertEqual(params["workspace_id"] as? String, lowercaseWorkspaceId)
            var result = self.memorySystemTopFixture(
                workspaceId: workspaceId,
                workspaceRef: "workspace:2",
                surfaceId: surfaceId,
                agentKey: "claude_code",
                agentPID: 626_262,
                secretCommandLine: "/opt/homebrew/bin/claude --dangerous-secret ignored"
            )
            if var windows = result["windows"] as? [[String: Any]] {
                windows.insert(
                    [
                        "id": "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
                        "ref": "window:0",
                        "workspaces": [
                            [
                                "id": "44444444-4444-4444-4444-444444444444",
                                "ref": "workspace:1",
                                "title": "Decoy Workspace",
                                "resources": ["resident_bytes": 1],
                                "tags": [],
                                "panes": [],
                            ],
                        ],
                    ],
                    at: 0
                )
                result["windows"] = windows
            }
            return self.v2Response(
                id: id,
                ok: true,
                result: result
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "memory",
                "trim",
                "--workspace",
                lowercaseWorkspaceId,
                "--agent",
                "claude",
                "--dry-run",
                "--json",
                "--id-format",
                "uuids",
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)

        let payload = try jsonPayload(from: result.stdout)
        XCTAssertEqual(payload["workspace_id"] as? String, workspaceId)
        XCTAssertEqual(payload["dry_run"] as? Bool, true)
        XCTAssertEqual(payload["graceful_action"] as? String, "send /exit")
        let agent = try XCTUnwrap(payload["agent"] as? [String: Any])
        XCTAssertEqual(agent["key"] as? String, "claude")
        XCTAssertEqual(agent["pid"] as? Int, 626_262)
        XCTAssertEqual(agent["surface_id"] as? String, surfaceId)
        XCTAssertFalse(
            state.commands.contains { $0.contains(#""method":"surface.send_text""#) },
            "dry-run trim must not send terminal input, saw \(state.commands)"
        )
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["system.top"]
        )
    }

    func testMemoryTrimAutoPrefersKnownResidentBytesOverUnknown() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("mem-trim-known-rss")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceId = "31313131-3131-3131-3131-313131313131"
        let knownSurfaceId = "32323232-3232-3232-3232-323232323232"

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
            guard method == "system.top" else {
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
            return self.v2Response(
                id: id,
                ok: true,
                result: [
                    "sample": ["sampled_at": "2026-05-13T12:00:00Z"],
                    "windows": [
                        [
                            "id": "33333333-3333-3333-3333-333333333333",
                            "ref": "window:1",
                            "workspaces": [
                                [
                                    "id": workspaceId,
                                    "ref": "workspace:31",
                                    "title": "Memory Workspace",
                                    "tags": [
                                        [
                                            "kind": "tag",
                                            "key": "codex",
                                            "pid": 111,
                                            "surface_id": "34343434-3434-3434-3434-343434343434",
                                            "surface_ref": "surface:unknown-rss",
                                        ],
                                        [
                                            "kind": "tag",
                                            "key": "claude_code",
                                            "pid": 222,
                                            "surface_id": knownSurfaceId,
                                            "surface_ref": "surface:known-rss",
                                            "resources": ["resident_bytes": 0],
                                        ],
                                    ],
                                    "panes": [],
                                ],
                            ],
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
                "memory",
                "trim",
                "--workspace",
                "workspace:31",
                "--dry-run",
                "--json",
                "--id-format",
                "uuids",
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)

        let payload = try jsonPayload(from: result.stdout)
        let agent = try XCTUnwrap(payload["agent"] as? [String: Any])
        XCTAssertEqual(agent["pid"] as? Int, 222)
        XCTAssertEqual(agent["surface_id"] as? String, knownSurfaceId)
        XCTAssertEqual(agent["resident_bytes"] as? Int, 0)
        XCTAssertFalse(
            state.commands.contains { $0.contains(#""method":"surface.send_text""#) },
            "dry-run trim must not send terminal input, saw \(state.commands)"
        )
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["system.top"]
        )
    }

    func testMemoryTrimSendsGracefulExitToSurfaceUUID() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("mem-trim-send")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceId = "12121212-1212-1212-1212-121212121212"
        let surfaceId = "34343434-3434-3434-3434-343434343434"

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
            case "system.top":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: self.memorySystemTopFixture(
                        workspaceId: workspaceId,
                        workspaceRef: "workspace:7",
                        surfaceId: surfaceId,
                        agentKey: "claude_code",
                        agentPID: 626_263,
                        secretCommandLine: "/opt/homebrew/bin/claude --dangerous-secret ignored"
                    )
                )
            case "surface.send_text":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["workspace_id"] as? String, workspaceId)
                XCTAssertEqual(params["surface_id"] as? String, surfaceId)
                XCTAssertEqual(params["text"] as? String, "/exit\r")
                return self.v2Response(id: id, ok: true, result: [:])
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
                "memory",
                "trim",
                "--workspace",
                "workspace:7",
                "--agent",
                "claude",
                "--grace-seconds",
                "0",
                "--json",
                "--id-format",
                "uuids",
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["system.top", "surface.send_text"]
        )
    }

    func testMemoryTrimReturnsResultWhenGracefulRevalidationDisappears() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("mem-trim-revalidate")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceId = "41414141-4141-4141-4141-414141414141"
        let surfaceId = "42424242-4242-4242-4242-424242424242"
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        let agentPID = Int(sleeper.processIdentifier)

        defer {
            terminateProcess(sleeper)
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
            case "system.top":
                let systemTopRequestCount = state.commands
                    .compactMap { self.jsonObject($0)?["method"] as? String }
                    .filter { $0 == "system.top" }
                    .count
                if systemTopRequestCount == 1 {
                    return self.v2Response(
                        id: id,
                        ok: true,
                        result: self.memorySystemTopFixture(
                            workspaceId: workspaceId,
                            workspaceRef: "workspace:12",
                            surfaceId: surfaceId,
                            agentKey: "claude_code",
                            agentPID: agentPID,
                            secretCommandLine: "/opt/homebrew/bin/claude --dangerous-secret ignored"
                        )
                    )
                }
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "sample": ["sampled_at": "2026-05-13T12:00:00Z"],
                        "windows": [
                            [
                                "id": "43434343-4343-4343-4343-434343434343",
                                "ref": "window:1",
                                "workspaces": [
                                    [
                                        "id": workspaceId,
                                        "ref": "workspace:12",
                                        "title": "Memory Workspace",
                                        "resources": [
                                            "cpu_percent": 1,
                                            "memory_percent": 1,
                                            "resident_bytes": 268_435_456,
                                            "virtual_bytes": 536_870_912,
                                            "process_count": 1,
                                        ],
                                        "tags": [],
                                        "panes": [],
                                    ],
                                ],
                            ],
                        ],
                    ]
                )
            case "surface.send_text":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["workspace_id"] as? String, workspaceId)
                XCTAssertEqual(params["surface_id"] as? String, surfaceId)
                XCTAssertEqual(params["text"] as? String, "/exit\r")
                return self.v2Response(id: id, ok: true, result: [:])
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
                "memory",
                "trim",
                "--workspace",
                "workspace:12",
                "--agent",
                "claude",
                "--grace-seconds",
                "0",
                "--json",
                "--id-format",
                "uuids",
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)

        let payload = try jsonPayload(from: result.stdout)
        XCTAssertEqual(payload["attempted_shutdown"] as? Bool, true)
        XCTAssertEqual(payload["graceful_action"] as? String, "send /exit")
        XCTAssertEqual(payload["terminated"] as? Bool, false)
        XCTAssertEqual(payload["killed"] as? Bool, false)
        XCTAssertEqual(payload["still_running"] as? Bool, true)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["system.top", "surface.send_text", "system.top", "system.top"]
        )
    }

    func testMemoryTrimRecoversSurfaceUUIDWhenOwnedTagOnlyHasSurfaceRef() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("mem-trim-surface-ref")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceId = "15151515-1515-1515-1515-151515151515"
        let surfaceId = "25252525-2525-2525-2525-252525252525"

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
            case "system.top":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: self.memorySystemTopFixture(
                        workspaceId: workspaceId,
                        workspaceRef: "workspace:8",
                        surfaceId: surfaceId,
                        agentKey: "claude_code",
                        agentPID: 626_264,
                        secretCommandLine: "/opt/homebrew/bin/claude --dangerous-secret ignored",
                        includeAgentTagSurfaceId: false
                    )
                )
            case "surface.send_text":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["workspace_id"] as? String, workspaceId)
                XCTAssertEqual(params["surface_id"] as? String, surfaceId)
                XCTAssertEqual(params["text"] as? String, "/exit\r")
                return self.v2Response(id: id, ok: true, result: [:])
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
                "memory",
                "trim",
                "--workspace",
                "workspace:8",
                "--agent",
                "claude",
                "--grace-seconds",
                "0",
                "--json",
                "--id-format",
                "uuids",
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["system.top", "surface.send_text"]
        )
    }

    func testMemoryTrimWithoutIdentityOrGracefulActionReportsStillRunning() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("mem-trim-no-identity")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceId = "35353535-3535-3535-3535-353535353535"
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()

        defer {
            terminateProcess(sleeper)
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            guard method == "system.top" else {
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
            return self.v2Response(
                id: id,
                ok: true,
                result: [
                    "sample": ["sampled_at": "2026-05-13T12:00:00Z"],
                    "windows": [
                        [
                            "id": "36363636-3636-3636-3636-363636363636",
                            "ref": "window:1",
                            "workspaces": [
                                [
                                    "id": workspaceId,
                                    "ref": "workspace:11",
                                    "title": "Memory Workspace",
                                    "tags": [
                                        [
                                            "kind": "tag",
                                            "key": "opencode",
                                            "pid": Int(sleeper.processIdentifier),
                                            "surface_ref": "surface:11",
                                            "resources": ["resident_bytes": 268_435_456],
                                        ],
                                    ],
                                    "panes": [],
                                ],
                            ],
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
                "memory",
                "trim",
                "--workspace",
                "workspace:11",
                "--agent",
                "opencode",
                "--json",
                "--id-format",
                "uuids",
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)

        let payload = try jsonPayload(from: result.stdout)
        XCTAssertEqual(payload["attempted_shutdown"] as? Bool, false)
        XCTAssertEqual(payload["terminated"] as? Bool, false)
        XCTAssertEqual(payload["killed"] as? Bool, false)
        XCTAssertEqual(payload["still_running"] as? Bool, true)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["system.top"]
        )
    }

    func testMemoryTrimTextOutputDistinguishesNoShutdownAction() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("mem-trim-no-action")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceId = "33333333-3333-3333-3333-333333333333"
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()

        defer {
            terminateProcess(sleeper)
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            guard method == "system.top" else {
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
            return self.v2Response(
                id: id,
                ok: true,
                result: [
                    "sample": ["sampled_at": "2026-05-13T12:00:00Z"],
                    "windows": [
                        [
                            "id": "36363636-3636-3636-3636-363636363636",
                            "ref": "window:1",
                            "workspaces": [
                                [
                                    "id": workspaceId,
                                    "ref": "workspace:11",
                                    "title": "Memory Workspace",
                                    "tags": [
                                        [
                                            "kind": "tag",
                                            "key": "opencode",
                                            "pid": Int(sleeper.processIdentifier),
                                            "surface_ref": "surface:11",
                                            "resources": ["resident_bytes": 268_435_456],
                                        ],
                                    ],
                                    "panes": [],
                                ],
                            ],
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
                "memory",
                "trim",
                "--workspace",
                "workspace:11",
                "--agent",
                "opencode",
                "--id-format",
                "refs",
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertTrue(result.stdout.hasPrefix("No trim action opencode"), result.stdout)
        XCTAssertTrue(result.stdout.contains("attempted=no"), result.stdout)
        XCTAssertTrue(result.stdout.contains("still_running=yes"), result.stdout)
        XCTAssertFalse(result.stdout.hasPrefix("Trimmed "), result.stdout)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["system.top"]
        )
    }

    func testMemoryTrimAutoRejectsProcessNameFallbackWithoutOwnedTag() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("mem-trim-auto")
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
            guard method == "system.top" else {
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
            return self.v2Response(
                id: id,
                ok: true,
                result: self.memorySystemTopFixture(
                    workspaceId: "88888888-8888-8888-8888-888888888888",
                    workspaceRef: "workspace:9",
                    surfaceId: "99999999-9999-9999-9999-999999999999",
                    agentKey: "codex",
                    agentPID: 737_373,
                    secretCommandLine: "/usr/local/bin/codex --secret ignored",
                    includeAgentTag: false
                )
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "memory",
                "trim",
                "--workspace",
                "workspace:9",
                "--dry-run",
                "--json",
                "--id-format",
                "uuids",
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("no cmux-owned recoverable agent PIDs"), result.stderr)
        XCTAssertFalse(
            state.commands.contains { $0.contains(#""method":"surface.send_text""#) },
            "auto trim must not act on process-name-only fallback candidates, saw \(state.commands)"
        )
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["system.top"]
        )
    }

    func testMemoryTrimExplicitSelectionRejectsProcessNameFallbackWithoutOwnedTag() throws {
        let cliPath = try bundledCLIPath()
        let cases = [
            ("pid", "737373"),
            ("name", "codex"),
        ]

        for testCase in cases {
            let socketPath = makeSocketPath("mem-trim-explicit-\(testCase.0)")
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
                guard method == "system.top" else {
                    return self.v2Response(
                        id: id,
                        ok: false,
                        error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                    )
                }
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: self.memorySystemTopFixture(
                        workspaceId: "88888888-8888-8888-8888-888888888888",
                        workspaceRef: "workspace:9",
                        surfaceId: "99999999-9999-9999-9999-999999999999",
                        agentKey: "codex",
                        agentPID: 737_373,
                        secretCommandLine: "/usr/local/bin/codex --secret ignored",
                        includeAgentTag: false
                    )
                )
            }

            var environment = ProcessInfo.processInfo.environment
            environment["CMUX_SOCKET_PATH"] = socketPath
            environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

            let result = runProcess(
                executablePath: cliPath,
                arguments: [
                    "memory",
                    "trim",
                    "--workspace",
                    "workspace:9",
                    "--agent",
                    testCase.1,
                    "--dry-run",
                    "--json",
                    "--id-format",
                    "uuids",
                ],
                environment: environment,
                timeout: 5
            )

            wait(for: [serverHandled], timeout: 5)
            XCTAssertFalse(result.timedOut, result.stderr)
            XCTAssertNotEqual(result.status, 0)
            XCTAssertTrue(result.stderr.contains("not a cmux-owned recoverable agent"), result.stderr)
            XCTAssertFalse(
                state.commands.contains { $0.contains(#""method":"surface.send_text""#) },
                "explicit trim must not act on process-name-only fallback candidates, saw \(state.commands)"
            )
            XCTAssertEqual(
                state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
                ["system.top"]
            )
        }
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
    func testNotifyWithUUIDSurfaceKeepsCallerWorkspaceFallback() throws {
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
                XCTAssertEqual(params["workspace_id"] as? String, callerWorkspace)
                XCTAssertEqual(params["surface_id"] as? String, callerSurface)
                XCTAssertEqual(params["body"] as? String, "--json")
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
            arguments: ["notify", "--surface", callerSurface, "--title", "UUID", "--body", "--json"],
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
                XCTAssertEqual(params["window_id"] as? String, "window:1")
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["surfaces": [["id": "ignored-id", "ref": surfaceRef, "index": 0]]]
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
        XCTAssertEqual(request["window_id"] as? String, "window:1")
        XCTAssertNotEqual(request["window_id"] as? String, "0")
        XCTAssertEqual(request["surface_id"] as? String, surfaceRef)
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

    private func terminateProcess(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }

    private func temporaryMemoryTelemetryDatabaseURL(name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-memory-\(name)-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("telemetry.db", isDirectory: false)
    }

    private func memorySystemTopFixture(
        workspaceId: String,
        workspaceRef: String,
        surfaceId: String,
        agentKey: String,
        agentPID: Int,
        secretCommandLine: String,
        includeAgentTag: Bool = true,
        includeAgentTagSurfaceId: Bool = true,
        workspaceResidentBytes: Any = 314_572_800
    ) -> [String: Any] {
        var tags: [[String: Any]] = []
        if includeAgentTag {
            var tag: [String: Any] = [
                "kind": "tag",
                "key": agentKey,
                "pid": agentPID,
                "surface_ref": "surface:3",
                "resources": ["resident_bytes": 268_435_456],
                "command_line": secretCommandLine,
            ]
            if includeAgentTagSurfaceId {
                tag["surface_id"] = surfaceId
            }
            tags = [tag]
        }
        return [
            "sample": ["sampled_at": "2026-05-13T12:00:00Z"],
            "windows": [
                [
                    "id": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                    "ref": "window:1",
                    "workspaces": [
                        [
                            "id": workspaceId,
                            "ref": workspaceRef,
                            "title": "Memory Workspace",
                            "resources": [
                                "cpu_percent": 12.5,
                                "memory_percent": 1.8,
                                "resident_bytes": workspaceResidentBytes,
                                "virtual_bytes": 629_145_600,
                                "process_count": 3,
                            ],
                            "tags": tags,
                            "panes": [
                                [
                                    "id": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                                    "surfaces": [
                                        [
                                            "id": surfaceId,
                                            "ref": "surface:3",
                                            "processes": [
                                                [
                                                    "pid": 101,
                                                    "name": "zsh",
                                                    "start_seconds": 100,
                                                    "start_microseconds": 1,
                                                    "resources": ["resident_bytes": 2_097_152],
                                                    "command_line": "/bin/zsh",
                                                    "children": [
                                                        [
                                                            "pid": agentPID,
                                                            "name": agentKey == "claude_code" ? "claude" : "codex",
                                                            "start_seconds": 200,
                                                            "start_microseconds": 2,
                                                            "resources": ["resident_bytes": 268_435_456],
                                                            "command_line": secretCommandLine,
                                                            "children": [
                                                                [
                                                                    "pid": 202,
                                                                    "name": "node",
                                                                    "start_seconds": 300,
                                                                    "start_microseconds": 3,
                                                                    "resources": ["resident_bytes": 44_040_192],
                                                                    "command_line": "node server.js --token SECRET_TOKEN_DO_NOT_STORE",
                                                                ],
                                                            ],
                                                        ],
                                                    ],
                                                ],
                                            ],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]
    }

    private func memoryTelemetryTopProcessNames(in dbURL: URL) throws -> [String] {
        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil)
        XCTAssertEqual(openResult, SQLITE_OK)
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT top_process_names FROM workspace_memory_samples LIMIT 1"
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        XCTAssertEqual(prepareResult, SQLITE_OK)
        defer { sqlite3_finalize(stmt) }

        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        let textPointer = try XCTUnwrap(sqlite3_column_text(stmt, 0))
        let text = String(cString: textPointer)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8), options: []) as? [String],
            "Expected process-name JSON array, got: \(text)"
        )
    }

    private func insertMemoryTelemetrySample(
        in dbURL: URL,
        sampledAt: Date,
        workspaceId: String,
        workspaceRef: String = "workspace:7",
        rssBytes: Int64 = 1024,
        memoryPercent: Double = 0.1,
        cpuPercent: Double = 1
    ) throws {
        try FileManager.default.createDirectory(
            at: dbURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil)
        XCTAssertEqual(openResult, SQLITE_OK)
        defer { sqlite3_close(db) }

        try sqliteExec(
            db,
            """
            CREATE TABLE IF NOT EXISTS workspace_memory_samples (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                sampled_at REAL NOT NULL,
                workspace_id TEXT NOT NULL,
                workspace_ref TEXT,
                workspace_title TEXT,
                window_id TEXT,
                window_ref TEXT,
                rss_bytes INTEGER NOT NULL,
                virtual_bytes INTEGER NOT NULL,
                memory_percent REAL NOT NULL DEFAULT 0,
                cpu_percent REAL NOT NULL,
                process_count INTEGER NOT NULL,
                top_process_names TEXT NOT NULL
            )
            """
        )

        var stmt: OpaquePointer?
        let insert = """
        INSERT INTO workspace_memory_samples (
            sampled_at, workspace_id, workspace_ref, workspace_title, window_id, window_ref,
            rss_bytes, virtual_bytes, memory_percent, cpu_percent, process_count, top_process_names
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        XCTAssertEqual(sqlite3_prepare_v2(db, insert, -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(OpaquePointer(bitPattern: -1)!, to: sqlite3_destructor_type.self)
        sqlite3_bind_double(stmt, 1, sampledAt.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, workspaceId, -1, transient)
        sqlite3_bind_text(stmt, 3, workspaceRef, -1, transient)
        sqlite3_bind_text(stmt, 4, "Expired Memory Workspace", -1, transient)
        sqlite3_bind_text(stmt, 5, "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", -1, transient)
        sqlite3_bind_text(stmt, 6, "window:1", -1, transient)
        sqlite3_bind_int64(stmt, 7, rssBytes)
        sqlite3_bind_int64(stmt, 8, rssBytes * 2)
        sqlite3_bind_double(stmt, 9, memoryPercent)
        sqlite3_bind_double(stmt, 10, cpuPercent)
        sqlite3_bind_int64(stmt, 11, 1)
        sqlite3_bind_text(stmt, 12, #"["codex"]"#, -1, transient)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
    }

    private func memoryTelemetrySampleCount(in dbURL: URL) throws -> Int {
        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil)
        XCTAssertEqual(openResult, SQLITE_OK)
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM workspace_memory_samples", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func sqliteExec(_ db: OpaquePointer?, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        defer {
            if let errorMessage {
                sqlite3_free(errorMessage)
            }
        }
        XCTAssertEqual(result, SQLITE_OK, errorMessage.map { String(cString: $0) } ?? "")
    }

}
