import Darwin
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    func testCodexHookDoesNotPublishResumeBindingForWeakEnvironmentOnlyCapture() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex-weak-env")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-weak-env-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("worktrees/task-shift-tab-submit-actions", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-weak-env-session"

        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else { return "OK" }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                return self.surfaceListResponse(id: id, surfaceId: surfaceId)
            case "debug.terminals":
                return self.v2Response(id: id, ok: true, result: ["terminals": []])
            case "surface.resume.set", "surface.resume.clear":
                return self.v2Response(id: id, ok: true, result: ["ok": true])
            case "feed.push":
                return self.v2Response(id: id, ok: true, result: [:])
            default:
                return self.v2Response(
                    id: id, ok: false,
                    error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = root.path
        environment["PWD"] = workspace.path
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment.removeValue(forKey: "CMUX_CLI_TTY_NAME")
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["ANTHROPIC_BASE_URL"] = "http://subrouter-team:31415"
        environment["CLAUDE_CONFIG_DIR"] = root.appendingPathComponent(".codex-accounts/claude/work", isDirectory: true).path
        environment.removeValue(forKey: "CODEX_HOME")
        for key in ["CMUX_AGENT_LAUNCH_KIND", "CMUX_AGENT_LAUNCH_EXECUTABLE", "CMUX_AGENT_LAUNCH_ARGV_B64", "CMUX_AGENT_LAUNCH_CWD"] {
            environment.removeValue(forKey: key)
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(workspace.path)","hook_event_name":"UserPromptSubmit","prompt":"review this"}"#,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let commands = state.snapshot()
        XCTAssertFalse(
            commands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.set" },
            "weak env-only Codex captures must not become durable restore bindings: \(commands)"
        )
    }

    func testCodexWeakCurrentCapturePreservesDurableMappedResumeBinding() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex-weak-env-preserve")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-weak-env-preserve-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent("cmuxterm-hq", isDirectory: true)
        let worktree = repo.appendingPathComponent("worktrees/task-shift-tab-submit-actions", isDirectory: true)
        let transcript = root.appendingPathComponent("codex-transcript.jsonl", isDirectory: false)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-durable-mapped-session"
        let ttyName = "ttys306"

        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try #"{"type":"event_msg","payload":{"type":"task_complete"}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)
        try writeCodexHookStore(
            root: root,
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: repo.path,
            transcriptPath: transcript.path,
            launchCommand: nil
        )
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else { return "OK" }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                return self.surfaceListResponse(id: id, surfaceId: surfaceId)
            case "debug.terminals":
                return self.v2Response(
                    id: id, ok: true,
                    result: ["terminals": [["tty": ttyName, "workspace_id": workspaceId, "surface_id": surfaceId]]]
                )
            case "surface.resume.set", "surface.resume.clear":
                return self.v2Response(id: id, ok: true, result: ["ok": true])
            case "feed.push":
                return self.v2Response(id: id, ok: true, result: [:])
            default:
                return self.v2Response(
                    id: id, ok: false,
                    error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = root.path
        environment["PWD"] = worktree.path
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_CLI_TTY_NAME"] = ttyName
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["ANTHROPIC_BASE_URL"] = "http://subrouter-team:31415"
        environment["CLAUDE_CONFIG_DIR"] = root.appendingPathComponent(".codex-accounts/claude/work", isDirectory: true).path
        environment.removeValue(forKey: "CODEX_HOME")
        for key in ["CMUX_AGENT_LAUNCH_KIND", "CMUX_AGENT_LAUNCH_EXECUTABLE", "CMUX_AGENT_LAUNCH_ARGV_B64", "CMUX_AGENT_LAUNCH_CWD"] {
            environment.removeValue(forKey: key)
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(worktree.path)","hook_event_name":"UserPromptSubmit","prompt":"review this"}"#,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let commands = state.snapshot()
        XCTAssertFalse(
            commands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.clear" },
            "weak current Codex captures must not clear durable mapped bindings: \(commands)"
        )
        let resumeRequests = commands.compactMap { command -> [String: Any]? in
            guard let payload = self.jsonObject(command),
                  payload["method"] as? String == "surface.resume.set" else { return nil }
            return payload["params"] as? [String: Any]
        }
        let resume = try XCTUnwrap(resumeRequests.last, "expected durable mapped resume binding, saw \(commands)")
        XCTAssertEqual(resume["checkpoint_id"] as? String, sessionId)
        XCTAssertEqual(resume["cwd"] as? String, repo.path)
        XCTAssertTrue((resume["command"] as? String)?.contains("codex") == true)
    }

    func testCodexPlainHookWithoutLaunchCapturePublishesDefaultResumeBinding() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex-plain-no-launch")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-plain-no-launch-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent("cmuxterm-hq", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-plain-default-session"
        let ttyName = "ttys307"

        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else { return "OK" }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                return self.surfaceListResponse(id: id, surfaceId: surfaceId)
            case "debug.terminals":
                return self.v2Response(
                    id: id, ok: true,
                    result: ["terminals": [["tty": ttyName, "workspace_id": workspaceId, "surface_id": surfaceId]]]
                )
            case "surface.resume.set", "surface.resume.clear":
                return self.v2Response(id: id, ok: true, result: ["ok": true])
            case "feed.push":
                return self.v2Response(id: id, ok: true, result: [:])
            default:
                return self.v2Response(
                    id: id, ok: false,
                    error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = root.path
        environment["PWD"] = repo.path
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_CLI_TTY_NAME"] = ttyName
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        for key in ["ANTHROPIC_BASE_URL", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "CMUX_AGENT_LAUNCH_KIND", "CMUX_AGENT_LAUNCH_EXECUTABLE", "CMUX_AGENT_LAUNCH_ARGV_B64", "CMUX_AGENT_LAUNCH_CWD"] {
            environment.removeValue(forKey: key)
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(repo.path)","hook_event_name":"UserPromptSubmit","prompt":"review this"}"#,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let commands = state.snapshot()
        XCTAssertFalse(commands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.clear" })
        let resumeRequests = commands.compactMap { command -> [String: Any]? in
            guard let payload = self.jsonObject(command),
                  payload["method"] as? String == "surface.resume.set" else { return nil }
            return payload["params"] as? [String: Any]
        }
        let resume = try XCTUnwrap(resumeRequests.last, "expected default resume binding, saw \(commands)")
        XCTAssertEqual(resume["checkpoint_id"] as? String, sessionId)
        XCTAssertEqual(resume["cwd"] as? String, repo.path)
        XCTAssertTrue((resume["command"] as? String)?.contains("codex") == true)
        XCTAssertTrue((resume["command"] as? String)?.contains("resume") == true)
        let storeJSON = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("codex-hook-sessions.json"))
        ) as? [String: Any])
        let sessions = try XCTUnwrap(storeJSON["sessions"] as? [String: Any])
        let persisted = try XCTUnwrap(sessions[sessionId] as? [String: Any])
        XCTAssertEqual((persisted["launchCommand"] as? [String: Any])?["source"] as? String, "default")
    }

    private func writeCodexHookStore(
        root: URL,
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String,
        transcriptPath: String? = nil,
        launchCommand: [String: Any]?
    ) throws {
        var session: [String: Any] = [
            "sessionId": sessionId,
            "workspaceId": workspaceId,
            "surfaceId": surfaceId,
            "cwd": cwd,
            "startedAt": Date().timeIntervalSince1970,
            "updatedAt": Date().timeIntervalSince1970,
        ]
        if let transcriptPath { session["transcriptPath"] = transcriptPath }
        if let launchCommand { session["launchCommand"] = launchCommand }
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: session,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)
    }
}
