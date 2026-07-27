import Darwin
import SQLite3
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
        try assertCodexWeakCapturePreservesFlags(
            currentArguments: nil,
            mappedArguments: ["/usr/local/bin/codex", "--yolo"],
            expectedFlag: "--yolo"
        )
    }

    func testCodexWeakCurrentCaptureUsesSanitizedCurrentFlags() throws {
        try assertCodexWeakCapturePreservesFlags(
            currentArguments: ["/usr/local/bin/codex", "--yolo"],
            mappedArguments: ["/usr/local/bin/codex", "--model", "gpt-5.4"],
            expectedFlag: "--yolo",
            unexpectedFlag: "--model"
        )
    }

    func testCodexWeakMappedCaptureWithoutDurableTargetDoesNotPublishResumeBinding() throws {
        try assertCodexWeakCapturePreservesFlags(
            currentArguments: nil,
            mappedArguments: ["/usr/local/bin/codex", "--yolo"],
            expectedFlag: nil,
            transcriptBacked: false
        )
    }

    private func assertCodexWeakCapturePreservesFlags(
        currentArguments: [String]?,
        mappedArguments: [String],
        expectedFlag: String?,
        unexpectedFlag: String? = nil,
        transcriptBacked: Bool = true
    ) throws {
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
        if transcriptBacked {
            try #"{"type":"event_msg","payload":{"type":"task_complete"}}"#
                .write(to: transcript, atomically: true, encoding: .utf8)
        }
        try writeCodexHookStore(
            root: root,
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            cwd: repo.path,
            transcriptPath: transcriptBacked ? transcript.path : nil,
            launchCommand: [
                "launcher": "codex",
                "executablePath": "/usr/local/bin/codex",
                "arguments": mappedArguments,
                "workingDirectory": repo.path,
                "environment": [
                    "ANTHROPIC_BASE_URL": "http://subrouter-team:31415",
                    "CLAUDE_CONFIG_DIR": root.appendingPathComponent(".codex-accounts/claude/work").path,
                ],
                "capturedAt": Date().timeIntervalSince1970,
                "source": "environment",
            ]
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
        if let currentArguments {
            environment["CMUX_AGENT_LAUNCH_KIND"] = "codex"
            environment["CMUX_AGENT_LAUNCH_EXECUTABLE"] = "/usr/local/bin/codex"
            environment["CMUX_AGENT_LAUNCH_ARGV_B64"] = base64NULSeparated(currentArguments)
            environment["CMUX_AGENT_LAUNCH_CWD"] = worktree.path
        } else {
            for key in ["CMUX_AGENT_LAUNCH_KIND", "CMUX_AGENT_LAUNCH_EXECUTABLE", "CMUX_AGENT_LAUNCH_ARGV_B64", "CMUX_AGENT_LAUNCH_CWD"] {
                environment.removeValue(forKey: key)
            }
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
        if expectedFlag != nil {
            XCTAssertFalse(
                commands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.clear" },
                "weak current Codex captures must not clear durable mapped bindings: \(commands)"
            )
        }
        let resumeRequests = commands.compactMap { command -> [String: Any]? in
            guard let payload = self.jsonObject(command),
                  payload["method"] as? String == "surface.resume.set" else { return nil }
            return payload["params"] as? [String: Any]
        }
        guard let expectedFlag else {
            XCTAssertTrue(
                resumeRequests.isEmpty,
                "weak mapped Codex captures must not become durable without target evidence: \(commands)"
            )
            return
        }
        let resume = try XCTUnwrap(resumeRequests.last, "expected durable mapped resume binding, saw \(commands)")
        XCTAssertEqual(resume["checkpoint_id"] as? String, sessionId)
        XCTAssertEqual(resume["cwd"] as? String, repo.path)
        XCTAssertTrue((resume["command"] as? String)?.contains("codex") == true)
        XCTAssertTrue(
            (resume["command"] as? String)?.contains(expectedFlag) == true,
            "a transcript-backed Codex resume must preserve safe launch flags: \(resume)"
        )
        if let unexpectedFlag {
            XCTAssertFalse(
                (resume["command"] as? String)?.contains(unexpectedFlag) == true,
                "the sanitized current capture must win over weaker mapped flags: \(resume)"
            )
        }
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
        let transcript = root.appendingPathComponent("rollout-2026-07-16T19-29-41-\(sessionId).jsonl")

        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try #"{"type":"session_meta","payload":{"id":"\#(sessionId)"}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)
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
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(repo.path)","transcript_path":"\#(transcript.path)","hook_event_name":"UserPromptSubmit","prompt":"review this"}"#,
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

    func testCodexUnindexedReviewHookDoesNotPublishResumeBinding() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex-unindexed-review")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-unindexed-review-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent("cmuxterm-hq/worktrees/task-modernize-feed", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "019f6dbc-5095-74f3-8035-ab8cdf772bb7"
        let ttyName = "ttys269"

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
                    id: id,
                    ok: true,
                    result: ["terminals": [["tty": ttyName, "workspace_id": workspaceId, "surface_id": surfaceId]]]
                )
            case "surface.resume.set", "surface.resume.clear":
                return self.v2Response(id: id, ok: true, result: ["ok": true])
            case "feed.push":
                return self.v2Response(id: id, ok: true, result: [:])
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
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
        XCTAssertFalse(
            commands.contains { self.jsonObject($0)?["method"] as? String == "surface.resume.set" },
            "unindexed review UUID must not become restore authority: \(commands)"
        )
        XCTAssertTrue(
            commands.contains { command in
                guard let payload = self.jsonObject(command),
                      payload["method"] as? String == "surface.resume.clear",
                      let params = payload["params"] as? [String: Any] else {
                    return false
                }
                return params["checkpoint_id"] as? String == sessionId
            },
            "the invalid checkpoint should be cleared without touching another session: \(commands)"
        )
    }

    func testCodexIndexedSubagentPublishesParentResumeBinding() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex-indexed-subagent")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-indexed-subagent-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent("cmuxterm-hq", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let parentSessionId = "019f652f-e1c3-7521-859c-5f57e33b4c80"
        let childSessionId = "019f8c3d-72d0-7d91-8714-4bf5e541cb4d"
        let ttyName = "ttys318"
        let parentRollout = root.appendingPathComponent("rollout-parent-\(parentSessionId).jsonl")
        let childRollout = root.appendingPathComponent("rollout-child-\(childSessionId).jsonl")

        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try #"{"type":"session_meta","payload":{"id":"\#(parentSessionId)","source":"cli"}}"#
            .write(to: parentRollout, atomically: true, encoding: .utf8)
        try #"{"type":"session_meta","payload":{"id":"\#(childSessionId)","session_id":"\#(parentSessionId)","parent_thread_id":"\#(parentSessionId)","forked_from_id":"\#(parentSessionId)","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\#(parentSessionId)","depth":1}}}}}"#
            .write(to: childRollout, atomically: true, encoding: .utf8)
        try writeCodexThreadIndex(
            root: root,
            threads: [
                (parentSessionId, parentRollout.path, "user"),
                (childSessionId, childRollout.path, "subagent"),
            ]
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
                    id: id,
                    ok: true,
                    result: ["terminals": [["tty": ttyName, "workspace_id": workspaceId, "surface_id": surfaceId]]]
                )
            case "surface.resume.set", "surface.resume.clear":
                return self.v2Response(id: id, ok: true, result: ["ok": true])
            case "feed.push":
                return self.v2Response(id: id, ok: true, result: [:])
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
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
        for key in [
            "ANTHROPIC_BASE_URL",
            "CLAUDE_CONFIG_DIR",
            "CODEX_HOME",
            "CMUX_AGENT_LAUNCH_KIND",
            "CMUX_AGENT_LAUNCH_EXECUTABLE",
            "CMUX_AGENT_LAUNCH_ARGV_B64",
            "CMUX_AGENT_LAUNCH_CWD",
        ] {
            environment.removeValue(forKey: key)
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"\#(childSessionId)","cwd":"\#(repo.path)","transcript_path":"\#(childRollout.path)","hook_event_name":"UserPromptSubmit","prompt":"keep going"}"#,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let commands = state.snapshot()
        let resumeRequests = commands.compactMap { command -> [String: Any]? in
            guard let payload = self.jsonObject(command),
                  payload["method"] as? String == "surface.resume.set" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        let resume = try XCTUnwrap(
            resumeRequests.last,
            "the indexed child hook should publish its interactive parent: \(commands)"
        )
        XCTAssertEqual(resume["checkpoint_id"] as? String, parentSessionId)
        XCTAssertTrue((resume["command"] as? String)?.contains(parentSessionId) == true)
        XCTAssertFalse((resume["command"] as? String)?.contains(childSessionId) == true)
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

    private func writeCodexThreadIndex(
        root: URL,
        threads: [(id: String, rolloutPath: String, source: String)]
    ) throws {
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        var database: OpaquePointer?
        guard sqlite3_open(codexHome.appendingPathComponent("state_5.sqlite").path, &database) == SQLITE_OK,
              let database else {
            throw NSError(domain: "CodexThreadIndexFixture", code: 1)
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(
            database,
            "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, thread_source TEXT)",
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            throw NSError(domain: "CodexThreadIndexFixture", code: 2)
        }

        let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        for thread in threads {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "INSERT INTO threads (id, rollout_path, thread_source) VALUES (?, ?, ?)",
                -1,
                &statement,
                nil
            ) == SQLITE_OK, let statement else {
                throw NSError(domain: "CodexThreadIndexFixture", code: 3)
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, thread.id, -1, transient)
            sqlite3_bind_text(statement, 2, thread.rolloutPath, -1, transient)
            sqlite3_bind_text(statement, 3, thread.source, -1, transient)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw NSError(domain: "CodexThreadIndexFixture", code: 4)
            }
        }
    }
}
