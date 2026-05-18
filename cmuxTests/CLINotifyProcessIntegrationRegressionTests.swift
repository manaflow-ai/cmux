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
        standardInput: String
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
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        let result = runProcess(
            executablePath: context.cliPath,
            arguments: arguments,
            environment: [
                "HOME": context.root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": context.socketPath,
                "CMUX_WORKSPACE_ID": context.workspaceId,
                "CMUX_SURFACE_ID": context.surfaceId,
                "CMUX_CLAUDE_HOOK_STATE_PATH": context.root.appendingPathComponent("claude-hook-sessions.json").path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
            ],
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
