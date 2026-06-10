import XCTest
import Darwin
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Codex prompt-submit routing
extension CLINotifyProcessIntegrationRegressionTests {
    func testCodexPromptSubmitRefreshesLastTurnDiffBaseline() throws {
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
            XCTAssertFalse(result.timedOut, result.stderr)
            XCTAssertEqual(result.status, 0, result.stderr)
            guard result.status == 0 else {
                throw NSError(domain: "CLINotifyProcessIntegrationRegressionTests.git", code: Int(result.status))
            }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func baselineRecords() throws -> [[String: Any]] {
            let storeURL = context.root.appendingPathComponent("agent-turn-diff-baselines.json")
            let store = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
            return try XCTUnwrap(store["records"] as? [[String: Any]])
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
        XCTAssertFalse(sessionStart.timedOut, sessionStart.stderr)
        XCTAssertEqual(sessionStart.status, 0, sessionStart.stderr)

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
        XCTAssertFalse(promptSubmit.timedOut, promptSubmit.stderr)
        XCTAssertEqual(promptSubmit.status, 0, promptSubmit.stderr)

        let records = try baselineRecords()
        let startRecord = try XCTUnwrap(records.first { $0["turnId"] as? String == "turn-0" })
        let promptRecord = try XCTUnwrap(records.first { $0["turnId"] as? String == "turn-1" })
        XCTAssertEqual(startRecord["baseCommit"] as? String, initialCommit)
        XCTAssertEqual(promptRecord["baseCommit"] as? String, promptCommit)
        XCTAssertEqual(promptRecord["workspaceId"] as? String, context.workspaceId)
        XCTAssertEqual(promptRecord["surfaceId"] as? String, context.surfaceId)

        try "one\ntwo\nnested\n".write(to: storyURL, atomically: true, encoding: .utf8)
        _ = try runGit(["add", "story.txt"])
        _ = try runGit(["commit", "-m", "nested child change"])
        let childPrompt = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"child-turn","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit"}"#,
            extraEnvironment: codexLaunchEnvironment(context: context, sessionId: sessionId)
        )
        XCTAssertFalse(childPrompt.timedOut, childPrompt.stderr)
        XCTAssertEqual(childPrompt.status, 0, childPrompt.stderr)

        let childRecords = try baselineRecords()
        XCTAssertNil(
            childRecords.first { $0["turnId"] as? String == "child-turn" },
            "Nested Codex prompts should not create a last-turn diff baseline."
        )
        let parentRecordAfterChild = try XCTUnwrap(childRecords.first { $0["turnId"] as? String == "turn-1" })
        XCTAssertEqual(parentRecordAfterChild["baseCommit"] as? String, promptCommit)

        let childStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"child-turn","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"child done"}"#,
            extraEnvironment: codexLaunchEnvironment(context: context, sessionId: sessionId)
        )
        XCTAssertFalse(childStop.timedOut, childStop.stderr)
        XCTAssertEqual(childStop.status, 0, childStop.stderr)

        let parentStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"parent done"}"#,
            extraEnvironment: codexLaunchEnvironment(context: context, sessionId: sessionId)
        )
        XCTAssertFalse(parentStop.timedOut, parentStop.stderr)
        XCTAssertEqual(parentStop.status, 0, parentStop.stderr)

        try "one\ntwo\nthree\n".write(to: storyURL, atomically: true, encoding: .utf8)
        let dirtyPromptSubmit = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit"}"#,
            extraEnvironment: codexLaunchEnvironment(context: context, sessionId: sessionId)
        )
        XCTAssertFalse(dirtyPromptSubmit.timedOut, dirtyPromptSubmit.stderr)
        XCTAssertEqual(dirtyPromptSubmit.status, 0, dirtyPromptSubmit.stderr)

        let dirtyRecords = try baselineRecords()
        let dirtyRecord = try XCTUnwrap(dirtyRecords.first { $0["turnId"] as? String == "turn-1" })
        let dirtyBaseCommit = try XCTUnwrap(dirtyRecord["baseCommit"] as? String)
        XCTAssertEqual(
            try runGit(["show-ref", "--verify", "--hash", "refs/cmux/last-turn/\(dirtyBaseCommit)"]),
            dirtyBaseCommit
        )

        let dirtyStop = runCodexHook(
            context: context,
            subcommand: "stop",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"Stop","last_assistant_message":"dirty done"}"#,
            extraEnvironment: codexLaunchEnvironment(context: context, sessionId: sessionId)
        )
        XCTAssertFalse(dirtyStop.timedOut, dirtyStop.stderr)
        XCTAssertEqual(dirtyStop.status, 0, dirtyStop.stderr)

        try "one\ntwo\nthree\nfour\n".write(to: storyURL, atomically: true, encoding: .utf8)
        let refreshedDirtyPromptSubmit = runCodexHook(
            context: context,
            subcommand: "prompt-submit",
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-1","cwd":"\#(context.root.path)","hook_event_name":"UserPromptSubmit"}"#,
            extraEnvironment: codexLaunchEnvironment(context: context, sessionId: sessionId)
        )
        XCTAssertFalse(refreshedDirtyPromptSubmit.timedOut, refreshedDirtyPromptSubmit.stderr)
        XCTAssertEqual(refreshedDirtyPromptSubmit.status, 0, refreshedDirtyPromptSubmit.stderr)

        let refreshedRecords = try baselineRecords()
        let refreshedRecord = try XCTUnwrap(refreshedRecords.first { $0["turnId"] as? String == "turn-1" })
        let refreshedBaseCommit = try XCTUnwrap(refreshedRecord["baseCommit"] as? String)
        XCTAssertNotEqual(refreshedBaseCommit, dirtyBaseCommit)
        let oldRef = runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["git", "-C", context.root.path, "show-ref", "--verify", "--hash", "refs/cmux/last-turn/\(dirtyBaseCommit)"],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            timeout: 10
        )
        XCTAssertFalse(oldRef.timedOut, oldRef.stderr)
        XCTAssertNotEqual(oldRef.status, 0, oldRef.stdout)
        XCTAssertEqual(
            try runGit(["show-ref", "--verify", "--hash", "refs/cmux/last-turn/\(refreshedBaseCommit)"]),
            refreshedBaseCommit
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

}
