import Darwin
import CMUXAgentLaunch
import SQLite3
import XCTest

/// Regression coverage for Codex hook checkpoints that are not safe to own a
/// pane resume binding.  The fixtures deliberately live under a temporary
/// `CODEX_HOME`; no test reads or writes the developer's real Codex state.
extension CLINotifyProcessIntegrationRegressionTests {
    func testCodexEffectiveHomeUsesLaunchOnlyHomeAndIndexedState() throws {
        let sessionID = "019ff9f0-d355-75c2-9315-dd44f488c9aa"
        let fixture = try makeCodexBindingFixture(name: "launch-only-home", existingCheckpoint: nil)
        defer { fixture.cleanup() }
        try writeCodexRollout(
            fixture: fixture,
            sessionID: sessionID,
            source: "cli",
            originator: "codex-tui"
        )

        // Do not provide CODEX_HOME. The hook must retain the launch HOME as a
        // verification-only hint and inspect `<HOME>/.codex/state_5.sqlite`.
        let result = runCodexBindingHook(
            fixture: fixture,
            sessionID: sessionID,
            inputEvent: "SessionStart",
            includeCodexHome: false
        )
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            fixture.binding.snapshot()?["checkpoint_id"] as? String,
            sessionID,
            "launch-only HOME must resolve to the durable Codex state database"
        )
    }

    func testCodexEphemeralChildWithoutRolloutKeepsParentBinding() throws {
        let parentID = "019ff98a-d827-7831-960d-fd9bdf7d54e2"
        let childID = "019ff9a1-cbe1-7231-9478-0c55a8c44560"
        let fixture = try makeCodexBindingFixture(name: "ephemeral", existingCheckpoint: parentID)
        defer { fixture.cleanup() }
        try writeCodexRollout(
            fixture: fixture,
            sessionID: parentID,
            source: "cli",
            originator: "codex-tui"
        )

        let result = runCodexBindingHook(
            fixture: fixture,
            sessionID: childID,
            inputEvent: "SessionStart"
        )
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            fixture.binding.snapshot()?["checkpoint_id"] as? String,
            parentID,
            "the last-known-good parent checkpoint must remain authoritative"
        )
        XCTAssertFalse(
            fixture.state.snapshot().contains { jsonObject($0)?["method"] as? String == "surface.resume.set" },
            "an ephemeral child with no durable rollout must not replace the parent binding"
        )
        let clearRequest = try XCTUnwrap(
            fixture.state.snapshot().compactMap { line -> [String: Any]? in
                guard let payload = jsonObject(line),
                      payload["method"] as? String == "surface.resume.clear" else { return nil }
                return payload["params"] as? [String: Any]
            }.last,
            "a missing child must issue a checkpoint-guarded stale-binding clear"
        )
        XCTAssertEqual(clearRequest["checkpoint_id"] as? String, childID)
    }

    func testCodexMissingCurrentCheckpointClearsSameSessionBinding() throws {
        let sessionID = "019ff9a5-cbe1-7231-9478-0c55a8c44560"
        let fixture = try makeCodexBindingFixture(name: "missing-current", existingCheckpoint: sessionID)
        defer { fixture.cleanup() }

        let result = runCodexBindingHook(
            fixture: fixture,
            sessionID: sessionID,
            inputEvent: "SessionStart"
        )
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertNil(fixture.binding.snapshot())
        let clearRequest = try XCTUnwrap(
            fixture.state.snapshot().compactMap { line -> [String: Any]? in
                guard let payload = jsonObject(line),
                      payload["method"] as? String == "surface.resume.clear" else { return nil }
                return payload["params"] as? [String: Any]
            }.last
        )
        XCTAssertEqual(clearRequest["checkpoint_id"] as? String, sessionID)
    }

    func testCodexPersistedExecChildKeepsTUIParentBinding() throws {
        let parentID = "019ff98a-d827-7831-960d-fd9bdf7d54e2"
        let childID = "019ff9b0-cbe1-7231-9478-0c55a8c44560"
        let fixture = try makeCodexBindingFixture(name: "exec-child", existingCheckpoint: parentID)
        defer { fixture.cleanup() }
        try writeCodexRollout(
            fixture: fixture,
            sessionID: parentID,
            source: "cli",
            originator: "codex-tui"
        )
        try writeCodexRollout(
            fixture: fixture,
            sessionID: childID,
            source: "exec",
            originator: "codex_exec",
            extraPayload: ["parent_thread_id": parentID]
        )

        let result = runCodexBindingHook(
            fixture: fixture,
            sessionID: childID,
            inputEvent: "SessionStart"
        )
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            fixture.binding.snapshot()?["checkpoint_id"] as? String,
            parentID,
            "an exec child must not downgrade the TUI checkpoint"
        )
        XCTAssertFalse(
            fixture.state.snapshot().contains { jsonObject($0)?["method"] as? String == "surface.resume.set" },
            "an exec-originated child must not downgrade a TUI-originated checkpoint"
        )
        XCTAssertFalse(
            fixture.state.snapshot().contains { jsonObject($0)?["method"] as? String == "surface.resume.clear" },
            "a lower-provenance child must leave the verified parent binding intact"
        )
    }

    func testCodexTUISessionWithDurableRolloutPublishesNormally() throws {
        let sessionID = "019ff9c0-d827-7831-960d-fd9bdf7d54e2"
        let fixture = try makeCodexBindingFixture(name: "tui-first-bind", existingCheckpoint: nil)
        defer { fixture.cleanup() }
        try writeCodexRollout(
            fixture: fixture,
            sessionID: sessionID,
            source: "cli",
            originator: "codex-tui"
        )

        let result = runCodexBindingHook(
            fixture: fixture,
            sessionID: sessionID,
            inputEvent: "SessionStart"
        )
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let requests = fixture.state.snapshot().compactMap { line -> [String: Any]? in
            guard let payload = jsonObject(line),
                  payload["method"] as? String == "surface.resume.set" else { return nil }
            return payload["params"] as? [String: Any]
        }
        let request = try XCTUnwrap(requests.last, fixture.state.snapshot().joined(separator: "\n"))
        XCTAssertEqual(request["checkpoint_id"] as? String, sessionID)
        XCTAssertEqual(
            fixture.binding.snapshot()?["checkpoint_id"] as? String,
            sessionID,
            "a verified TUI session must be able to establish the first binding"
        )
    }

    func testSubrouterCodexBindingPublishesCapturedRoutingEnvironment() throws {
        let sessionID = "019ff9c1-d827-7831-960d-fd9bdf7d54e2"
        let fixture = try makeCodexBindingFixture(name: "subrouter-routing", existingCheckpoint: nil)
        defer { fixture.cleanup() }
        try writeCodexRollout(
            fixture: fixture,
            sessionID: sessionID,
            source: "cli",
            originator: "codex-tui"
        )

        let routingEnvironment = [
            "SUBROUTER_CODEX_ACCOUNT_ID": "team-codex-1",
            "SUBROUTER_CODEX_BASE_URL": "https://router.example.test/v1",
            "SUBROUTER_CODEX_RESUME_COMMAND": "sr codex resume",
            "SUBROUTER_CODEX_SERVER": "team",
            "SUBROUTER_CODEX_USER_EMAIL": "operator@example.test",
        ]
        let result = runCodexBindingHook(
            fixture: fixture,
            sessionID: sessionID,
            inputEvent: "SessionStart",
            launchArguments: ["/usr/local/bin/codex", "-c", "model_provider=subrouter"],
            additionalEnvironment: routingEnvironment
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let binding = try XCTUnwrap(fixture.binding.snapshot())
        XCTAssertTrue((binding["command"] as? String)?.contains("'sr' 'codex' 'resume' '\(sessionID)'") == true)
        let publishedEnvironment = try XCTUnwrap(binding["environment"] as? [String: String])
        for (key, value) in routingEnvironment where key != "SUBROUTER_CODEX_RESUME_COMMAND" {
            XCTAssertEqual(publishedEnvironment[key], value, key)
        }
        XCTAssertNil(publishedEnvironment["SUBROUTER_CODEX_RESUME_COMMAND"])
    }

    func testCodexTUISessionCanRebindAnOlderVerifiedTUICheckpoint() throws {
        let oldSessionID = "019ff98a-d827-7831-960d-fd9bdf7d54e2"
        let newSessionID = "019ff9c0-d827-7831-960d-fd9bdf7d54e2"
        let fixture = try makeCodexBindingFixture(name: "tui-rebind", existingCheckpoint: oldSessionID)
        defer { fixture.cleanup() }
        try writeCodexRollout(
            fixture: fixture,
            sessionID: oldSessionID,
            source: "cli",
            originator: "codex-tui"
        )
        try writeCodexRollout(
            fixture: fixture,
            sessionID: newSessionID,
            source: "cli",
            originator: "codex-tui"
        )

        let result = runCodexBindingHook(
            fixture: fixture,
            sessionID: newSessionID,
            inputEvent: "SessionStart"
        )
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(fixture.binding.snapshot()?["checkpoint_id"] as? String, newSessionID)
    }

    func testCodexVSCodeSessionCanReplaceUnverifiableExistingBinding() throws {
        let existingID = "019ff98a-d827-7831-960d-fd9bdf7d54e2"
        let incomingID = "019ff9e0-cbe1-7231-9478-0c55a8c44560"
        let fixture = try makeCodexBindingFixture(name: "unknown-no-downgrade", existingCheckpoint: existingID)
        defer { fixture.cleanup() }
        try writeCodexRollout(
            fixture: fixture,
            sessionID: incomingID,
            source: "vscode",
            originator: "codex-vscode"
        )

        let result = runCodexBindingHook(
            fixture: fixture,
            sessionID: incomingID,
            inputEvent: "SessionStart"
        )
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            fixture.binding.snapshot()?["checkpoint_id"] as? String,
            incomingID,
            "a classified top-level VS Code session may replace legacy evidence"
        )
        XCTAssertTrue(
            fixture.state.snapshot().contains { jsonObject($0)?["method"] as? String == "surface.resume.set" }
        )
    }

    func testCodexVSCodeSessionCanEstablishFirstBinding() throws {
        let sessionID = "019ff9e0-cbe1-7231-9478-0c55a8c44560"
        let fixture = try makeCodexBindingFixture(name: "unknown-first-bind", existingCheckpoint: nil)
        defer { fixture.cleanup() }
        try writeCodexRollout(
            fixture: fixture,
            sessionID: sessionID,
            source: "vscode",
            originator: "codex-vscode"
        )

        let result = runCodexBindingHook(
            fixture: fixture,
            sessionID: sessionID,
            inputEvent: "SessionStart"
        )
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(fixture.binding.snapshot()?["checkpoint_id"] as? String, sessionID)
    }

    private struct CodexBindingFixture {
        let cliPath: String
        let root: URL
        let codexHome: URL
        let socketPath: String
        let listenerFD: Int32
        let state: MockSocketServerState
        let binding: MockResumeBindingState
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let surfaceID = "22222222-2222-2222-2222-222222222222"
        let existingCheckpoint: String?

        func cleanup() {
            CLIMockAcceptLoopRegistry.shared.stop(listenerFD: listenerFD)
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeCodexBindingFixture(
        name: String,
        existingCheckpoint: String?
    ) throws -> CodexBindingFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-binding-\(name)-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(
            at: codexHome.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        try createCodexStateDatabase(at: codexHome.appendingPathComponent("state_5.sqlite"))
        let socketPath = makeSocketPath("codex-binding-\(name)")
        let fixture = CodexBindingFixture(
            cliPath: try bundledCLIPath(),
            root: root,
            codexHome: codexHome,
            socketPath: socketPath,
            listenerFD: try bindUnixSocket(at: socketPath),
            state: MockSocketServerState(),
            binding: MockResumeBindingState(initial: nil),
            existingCheckpoint: existingCheckpoint
        )
        if let existingCheckpoint {
            fixture.binding.set(parentBinding(fixture: fixture, sessionID: existingCheckpoint))
        }
        return fixture
    }

    private final class MockResumeBindingState: @unchecked Sendable {
        // The lock guards every access to `value`. `snapshot()` intentionally
        // returns the immutable-for-this-test payload; callers must not mutate
        // that dictionary (or any nested values) after taking the snapshot.
        private let lock = NSLock()
        private var value: [String: Any]?

        init(initial: [String: Any]?) { value = initial }

        deinit {}

        func snapshot() -> [String: Any]? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ params: [String: Any]) {
            lock.lock()
            value = params
            lock.unlock()
        }

        func clear() {
            lock.lock()
            value = nil
            lock.unlock()
        }
    }

    private func writeCodexRollout(
        fixture: CodexBindingFixture,
        sessionID: String,
        source: String,
        originator: String,
        extraPayload: [String: Any] = [:],
        seedThread: Bool = true
    ) throws {
        let directory = fixture.codexHome
            .appendingPathComponent("sessions/2026/08/12", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var payload: [String: Any] = [
            "id": sessionID,
            "cwd": fixture.root.path,
            "source": source,
            "originator": originator,
        ]
        for (key, value) in extraPayload { payload[key] = value }
        let line: [String: Any] = [
            "timestamp": "2026-08-12T22:41:00.000Z",
            "type": "session_meta",
            "payload": payload,
        ]
        var data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
        data.append(0x0A)
        let path = directory.appendingPathComponent("rollout-\(sessionID).jsonl")
        try data.write(to: path, options: .atomic)
        if seedThread {
            try insertCodexThread(
                at: fixture.codexHome.appendingPathComponent("state_5.sqlite"),
                sessionID: sessionID,
                rolloutPath: path.path,
                source: source
            )
        }
    }

    private func createCodexStateDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            sqlite3_close(database)
            throw NSError(domain: "CodexResumeBindingFixture", code: 1)
        }
        defer { sqlite3_close(database) }
        let schema = "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, source TEXT, thread_source TEXT)"
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "CodexResumeBindingFixture", code: 2)
        }
    }

    private func insertCodexThread(
        at url: URL,
        sessionID: String,
        rolloutPath: String,
        source: String
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            sqlite3_close(database)
            throw NSError(domain: "CodexResumeBindingFixture", code: 3)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT INTO threads (id, rollout_path, source, thread_source) VALUES (?, ?, ?, ?)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw NSError(domain: "CodexResumeBindingFixture", code: 4)
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, sessionID, -1, transient) == SQLITE_OK,
              sqlite3_bind_text(statement, 2, rolloutPath, -1, transient) == SQLITE_OK,
              sqlite3_bind_text(statement, 3, source, -1, transient) == SQLITE_OK,
              sqlite3_bind_text(statement, 4, source, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(domain: "CodexResumeBindingFixture", code: 5)
        }
    }

    private func runCodexBindingHook(
        fixture: CodexBindingFixture,
        sessionID: String,
        inputEvent: String,
        includeCodexHome: Bool = true,
        launchArguments: [String] = ["/usr/local/bin/codex"],
        additionalEnvironment: [String: String] = [:]
    ) -> ProcessRunResult {
        let state = fixture.state
        let serverHandled = startMockServer(listenerFD: fixture.listenerFD, state: state) { [self] line in
            guard let payload = jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return malformedRequestResponse(raw: line)
            }
            switch method {
            case "surface.list":
                return surfaceListResponse(id: id, surfaceId: fixture.surfaceID)
            case "debug.terminals":
                return v2Response(id: id, ok: true, result: ["terminals": []])
            case "surface.resume.get":
                let binding: Any = fixture.binding.snapshot() ?? NSNull()
                return v2Response(id: id, ok: true, result: [
                    "resume_binding": binding,
                    "restore_record": NSNull(),
                ])
            case "surface.resume.set":
                if let params = payload["params"] as? [String: Any] {
                    if mockAllowsCodexBindingReplacement(
                        incoming: params["resume_evidence_provenance"] as? String,
                        existing: fixture.binding.snapshot()?["resume_evidence_provenance"] as? String
                    ) {
                        fixture.binding.set(params)
                    }
                }
                return v2Response(id: id, ok: true, result: ["ok": true])
            case "surface.resume.clear":
                let requestedCheckpoint = (payload["params"] as? [String: Any])?["checkpoint_id"] as? String
                let currentCheckpoint = fixture.binding.snapshot()?["checkpoint_id"] as? String
                let cleared = requestedCheckpoint != nil && requestedCheckpoint == currentCheckpoint
                if cleared {
                    fixture.binding.clear()
                }
                return v2Response(id: id, ok: true, result: ["cleared": cleared])
            case "feed.push":
                return v2Response(id: id, ok: true, result: [:])
            default:
                return v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"]
                )
            }
        }
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = fixture.root.path
        if includeCodexHome {
            environment["CODEX_HOME"] = fixture.codexHome.path
        } else {
            environment.removeValue(forKey: "CODEX_HOME")
        }
        environment["PWD"] = fixture.root.path
        environment["CMUX_SOCKET_PATH"] = fixture.socketPath
        environment["CMUX_WORKSPACE_ID"] = fixture.workspaceID
        environment["CMUX_SURFACE_ID"] = fixture.surfaceID
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = fixture.root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_LAUNCH_KIND"] = "codex"
        environment["CMUX_AGENT_LAUNCH_EXECUTABLE"] = "/usr/local/bin/codex"
        environment["CMUX_AGENT_LAUNCH_ARGV_B64"] = base64NULSeparated(launchArguments)
        environment["CMUX_AGENT_LAUNCH_CWD"] = fixture.root.path
        for (key, value) in additionalEnvironment {
            environment[key] = value
        }

        let result = runProcess(
            executablePath: fixture.cliPath,
            arguments: ["hooks", "codex", "session-start"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionID)","cwd":"\#(fixture.root.path)","hook_event_name":"\#(inputEvent)"}"#,
            timeout: 5
        )
        wait(for: [serverHandled], timeout: 5)
        return result
    }

    private func mockAllowsCodexBindingReplacement(
        incoming: String?,
        existing: String?
    ) -> Bool {
        guard let incoming = incoming?.lowercased(), incoming == "unknown" || incoming == "tui" else {
            return false
        }
        guard let existing = existing?.lowercased() else { return true }
        switch existing {
        case "tui": return incoming == "tui"
        case "unknown": return true
        default: return false
        }
    }

    private func parentBinding(fixture: CodexBindingFixture, sessionID: String) -> [String: Any] {
        [
            "name": "Codex",
            "kind": "codex",
            "command": "codex resume \(sessionID)",
            "cwd": fixture.root.path,
            "checkpoint_id": sessionID,
            "source": "agent-hook",
            "resume_evidence_provenance": "tui",
            "environment": ["CODEX_HOME": fixture.codexHome.path],
            "launch_command": [
                "launcher": "codex",
                "executable_path": "/usr/local/bin/codex",
                "arguments": ["/usr/local/bin/codex"],
                "working_directory": fixture.root.path,
                "environment": ["CODEX_HOME": fixture.codexHome.path],
                "verification_home": fixture.root.path,
                "source": "environment",
            ],
            "auto_resume": true,
        ]
    }
}
