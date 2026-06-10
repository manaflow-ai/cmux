import XCTest
import Darwin


// MARK: - Codex hook install CLI preference and env-surface persistence
extension CLINotifyProcessIntegrationRegressionTests {
    func testCodexHookInstallPrefersLaunchingAppBundledCLI() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-install-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let previousBundledHookCommand = "cmux_cli=\"${CMUX_BUNDLED_CLI_PATH:-}\"; if [ -z \"$cmux_cli\" ] || [ ! -x \"$cmux_cli\" ]; then cmux_cli=\"$(command -v cmux 2>/dev/null || true)\"; fi; [ -n \"$CMUX_SURFACE_ID\" ] && [ \"$CMUX_CODEX_HOOKS_DISABLED\" != \"1\" ] && [ -n \"$cmux_cli\" ] && \"$cmux_cli\" hooks codex prompt-submit || echo '{}'"
        let legacyHookJSON: [String: Any] = [
            "hooks": [
                "UserPromptSubmit": [
                    [
                        "hooks": [
                            [
                                "command": previousBundledHookCommand,
                                "timeout": 5000,
                                "type": "command",
                            ],
                        ],
                    ],
                    [
                        "hooks": [
                            [
                                "command": previousBundledHookCommand,
                                "timeout": 5000,
                                "type": "command",
                            ],
                        ],
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: legacyHookJSON, options: [.prettyPrinted, .sortedKeys])
            .write(to: codexHome.appendingPathComponent("hooks.json", isDirectory: false), options: .atomic)

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: [
                "HOME": root.path,
                "CODEX_HOME": codexHome.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let hookURL = codexHome.appendingPathComponent("hooks.json", isDirectory: false)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: hookURL)) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        let allCommands = hooks.values
            .compactMap { $0 as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["command"] as? String }

        XCTAssertTrue(
            allCommands.contains {
                $0.contains("CMUX_BUNDLED_CLI_PATH")
                    && $0.contains("\"$cmux_cli\" --socket \"$CMUX_SOCKET_PATH\" hooks codex prompt-submit")
            },
            "Codex hooks should route through the launching app's bundled CLI, saw \(allCommands)"
        )
        XCTAssertFalse(
            allCommands.contains { $0.contains("command -v cmux >/dev/null 2>&1 && cmux hooks codex") },
            "Codex hooks must not use the reload-global cmux shim directly, saw \(allCommands)"
        )
        XCTAssertFalse(
            allCommands.contains { $0 == previousBundledHookCommand },
            "Codex setup should replace bundled-CLI hooks that did not pin CMUX_SOCKET_PATH, saw \(allCommands)"
        )
        XCTAssertEqual(
            allCommands.filter { $0.contains("hooks codex prompt-submit") }.count,
            1,
            "Codex setup should collapse duplicate cmux-owned prompt hooks to one entry, saw \(allCommands)"
        )
    }

    /// G2 (https://github.com/manaflow-ai/cmux/issues/5350): plain `codex` under the subrouter account
    /// manager points CODEX_HOME at ~/.codex-accounts/<account>, not ~/.codex. When the launch argv
    /// can't be captured (no CMUX_AGENT_LAUNCH_ARGV_B64 and an exited PID), the session record used to
    /// drop CODEX_HOME, so the resume/fork binding fell back to a bare `codex resume <id>` against the
    /// default home and failed with "No saved session found". The hook must still carry the captured
    /// CODEX_HOME into the resume binding's environment.
    func testCodexHookPreservesCodexHomeWhenLaunchCommandUnavailable() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex-home")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-home-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-home-session"
        let ttyName = "ttys301"
        let codexHome = root.appendingPathComponent("codex-accounts/work", isDirectory: true).path

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        // A reaped, definitely-exited PID forces the no-argv capture path: processArguments() returns
        // nil for a dead process, so the hook can only carry CODEX_HOME via the env-only record.
        let deadHelper = Process()
        deadHelper.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try deadHelper.run()
        deadHelper.waitUntilExit()
        let deadPID = Int(deadHelper.processIdentifier)

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
                    "pid": deadPID,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted])
            .write(to: root.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)

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
            case "surface.resume.set":
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
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_CLI_TTY_NAME"] = ttyName
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CODEX_HOME"] = codexHome
        for key in ["CMUX_AGENT_LAUNCH_KIND", "CMUX_AGENT_LAUNCH_EXECUTABLE", "CMUX_AGENT_LAUNCH_ARGV_B64", "CMUX_AGENT_LAUNCH_CWD"] {
            environment.removeValue(forKey: key)
        }

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

        let resumeRequests = state.snapshot().compactMap { command -> [String: Any]? in
            guard let payload = self.jsonObject(command),
                  payload["method"] as? String == "surface.resume.set" else { return nil }
            return payload["params"] as? [String: Any]
        }
        let params = try XCTUnwrap(resumeRequests.last, "expected a surface.resume.set; saw \(state.snapshot())")
        let boundEnvironment = params["environment"] as? [String: String]
        XCTAssertEqual(
            boundEnvironment?["CODEX_HOME"], codexHome,
            "resume binding must carry the captured CODEX_HOME; params=\(params)"
        )
        let command = try XCTUnwrap(params["command"] as? String)
        XCTAssertTrue(command.contains("'resume' '\(sessionId)'"), command)

        // The env-only record must also be PERSISTED to the hook session store (its arguments are
        // empty, so the store's "only assign launchCommand when arguments is non-empty" gate would
        // otherwise drop it) — a later fork/resume that reads the store rather than re-deriving from a
        // live hook env still needs CODEX_HOME.
        let storeURL = root.appendingPathComponent("codex-hook-sessions.json")
        let storeJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
        let sessions = try XCTUnwrap(storeJSON["sessions"] as? [String: Any])
        let persisted = try XCTUnwrap(sessions[sessionId] as? [String: Any])
        let persistedLaunch = try XCTUnwrap(
            persisted["launchCommand"] as? [String: Any],
            "env-only launchCommand must be persisted for the fork path"
        )
        XCTAssertEqual(
            (persistedLaunch["environment"] as? [String: String])?["CODEX_HOME"], codexHome,
            "persisted launchCommand must carry CODEX_HOME"
        )
    }

    /// G3 (https://github.com/manaflow-ai/cmux/issues/5333): the codex surface jumble. CMUX_SURFACE_ID
    /// can be leaked into the hook env as the operator's FOCUSED pane rather than the agent's own pane.
    /// When the agent process's controlling TTY is bound to a different, accessible surface in the same
    /// workspace, that TTY is ground truth and must override the leaked env surface — otherwise the
    /// session routes to the wrong pane and the no-pid-gate resume binding persists it across reload.
    func testCodexHookOverridesLeakedEnvSurfaceWithProcessTTYBinding() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex-surface")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-surface-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let leakedSurfaceId = "22222222-2222-2222-2222-222222222222"   // env CMUX_SURFACE_ID (wrong)
        let ttySurfaceId = "33333333-3333-3333-3333-333333333333"      // the agent's real pane
        let sessionId = "codex-surface-session"
        let ttyName = "ttys302"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
                // Both surfaces are accessible in this workspace, so the env surface is "valid" — the
                // only thing distinguishing the right pane is the TTY binding.
                return self.v2Response(
                    id: id, ok: true,
                    result: ["surfaces": [
                        ["id": leakedSurfaceId, "ref": "surface:1", "focused": true],
                        ["id": ttySurfaceId, "ref": "surface:2", "focused": false],
                    ]]
                )
            case "debug.terminals":
                return self.v2Response(
                    id: id, ok: true,
                    result: ["terminals": [["tty": ttyName, "workspace_id": workspaceId, "surface_id": ttySurfaceId]]]
                )
            case "surface.resume.set":
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
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = leakedSurfaceId
        environment["CMUX_CLI_TTY_NAME"] = ttyName
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_LAUNCH_KIND"] = "codex"
        environment["CMUX_AGENT_LAUNCH_EXECUTABLE"] = "/usr/local/bin/codex"
        environment["CMUX_AGENT_LAUNCH_CWD"] = root.path
        environment["CMUX_AGENT_LAUNCH_ARGV_B64"] = base64NULSeparated(["/usr/local/bin/codex"])

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

        let resumeRequests = state.snapshot().compactMap { command -> [String: Any]? in
            guard let payload = self.jsonObject(command),
                  payload["method"] as? String == "surface.resume.set" else { return nil }
            return payload["params"] as? [String: Any]
        }
        let params = try XCTUnwrap(resumeRequests.last, "expected a surface.resume.set; saw \(state.snapshot())")
        XCTAssertEqual(
            params["surface_id"] as? String, ttySurfaceId,
            "PID/TTY ground truth must override the leaked env CMUX_SURFACE_ID; params=\(params)"
        )
    }

    /// G3 stale-env variant (https://github.com/manaflow-ai/cmux/issues/5333): when the ambient
    /// CMUX_SURFACE_ID is stale/invalid (the surface was closed, or belongs to another workspace) it no
    /// longer resolves to an accessible surface. That must NOT abort hook routing — the agent's own
    /// TTY-bound pane is valid, so the hook recovers and still publishes the resume binding there
    /// instead of no-op'ing (which would silently lose the session across reload).
    func testCodexHookRecoversFromStaleEnvSurfaceViaProcessTTYBinding() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex-stale")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-stale-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let staleSurfaceId = "22222222-2222-2222-2222-222222222222"   // env CMUX_SURFACE_ID, no longer exists
        let ttySurfaceId = "33333333-3333-3333-3333-333333333333"      // the agent's real, live pane
        let sessionId = "codex-stale-session"
        let ttyName = "ttys303"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
                // The stale env surface is NOT listed — only the live TTY pane is accessible.
                return self.surfaceListResponse(id: id, surfaceId: ttySurfaceId)
            case "debug.terminals":
                return self.v2Response(
                    id: id, ok: true,
                    result: ["terminals": [["tty": ttyName, "workspace_id": workspaceId, "surface_id": ttySurfaceId]]]
                )
            case "surface.resume.set":
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
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = staleSurfaceId
        environment["CMUX_CLI_TTY_NAME"] = ttyName
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_LAUNCH_KIND"] = "codex"
        environment["CMUX_AGENT_LAUNCH_EXECUTABLE"] = "/usr/local/bin/codex"
        environment["CMUX_AGENT_LAUNCH_CWD"] = root.path
        environment["CMUX_AGENT_LAUNCH_ARGV_B64"] = base64NULSeparated(["/usr/local/bin/codex"])

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

        let resumeRequests = state.snapshot().compactMap { command -> [String: Any]? in
            guard let payload = self.jsonObject(command),
                  payload["method"] as? String == "surface.resume.set" else { return nil }
            return payload["params"] as? [String: Any]
        }
        let params = try XCTUnwrap(
            resumeRequests.last,
            "stale ambient surface must not drop the hook; expected a surface.resume.set, saw \(state.snapshot())"
        )
        XCTAssertEqual(
            params["surface_id"] as? String, ttySurfaceId,
            "a stale ambient CMUX_SURFACE_ID must fall through to the TTY pane; params=\(params)"
        )
    }

    /// `codex exec` (and `review`, `login`, …) are non-restorable: AgentLaunchSanitizer rejects their
    /// argv so they never get a resume/fork binding. The CODEX_HOME env-only fallback must NOT bypass
    /// that — a captured-but-rejected argv keeps returning nil even when CODEX_HOME is present, so no
    /// env-only record is persisted for the one-shot command.
    func testCodexHookDoesNotPersistEnvOnlyRecordForNonRestorableExec() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("codex-exec")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-exec-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-exec-session"
        let ttyName = "ttys304"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_CLI_TTY_NAME"] = ttyName
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CODEX_HOME"] = root.appendingPathComponent("codex-accounts/work", isDirectory: true).path
        environment["CMUX_AGENT_LAUNCH_KIND"] = "codex"
        environment["CMUX_AGENT_LAUNCH_EXECUTABLE"] = "/usr/local/bin/codex"
        environment["CMUX_AGENT_LAUNCH_CWD"] = root.path
        // A captured but NON-RESTORABLE codex invocation: the sanitizer rejects `exec`.
        environment["CMUX_AGENT_LAUNCH_ARGV_B64"] = base64NULSeparated(["/usr/local/bin/codex", "exec", "do a one-shot task"])

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

        // No env-only CODEX_HOME record may be persisted for the rejected non-restorable argv.
        let storeURL = root.appendingPathComponent("codex-hook-sessions.json")
        if let data = try? Data(contentsOf: storeURL),
           let storeJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sessions = storeJSON["sessions"] as? [String: Any],
           let persisted = sessions[sessionId] as? [String: Any] {
            let env = (persisted["launchCommand"] as? [String: Any])?["environment"] as? [String: String]
            XCTAssertNil(
                env?["CODEX_HOME"],
                "non-restorable codex exec must not persist an env-only CODEX_HOME record; launchCommand=\(persisted["launchCommand"] ?? "nil")"
            )
        }
    }
}
