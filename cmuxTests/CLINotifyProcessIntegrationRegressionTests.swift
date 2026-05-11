import XCTest
import Darwin

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
            standardInput: #"{"session_id":"unknown-late-session","cwd":"\#(context.root.path)","hook_event_name":"SessionEnd"}"#
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
            arguments: ["notify", "--surface", callerSurface, "--title", "UUID"],
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

}
