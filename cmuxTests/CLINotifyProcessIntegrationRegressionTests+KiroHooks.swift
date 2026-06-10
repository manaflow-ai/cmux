import XCTest
import Darwin


// MARK: - Kiro hook install shape and feed allow/deny gating
extension CLINotifyProcessIntegrationRegressionTests {
    func testKiroHookInstallUsesAgentConfigShapeAndPreservesDenyExit() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-kiro-hook-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "kiro", "install", "--yes"],
            environment: [
                "HOME": root.path,
                "KIRO_HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(
            result.stdout.contains("kiro-cli chat --agent cmux"),
            "Expected Kiro install to print the --agent cmux activation hint, saw: \(result.stdout)"
        )

        let hookURL = root
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent("cmux.json", isDirectory: false)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: hookURL)) as? [String: Any])
        XCTAssertEqual(json["name"] as? String, "cmux")
        XCTAssertNil(json["version"], "Kiro agent configs should not receive Cursor's hooks version field")
        XCTAssertEqual(
            json["tools"] as? [String], ["*"],
            "Kiro cmux agent must grant the full tool set so `--agent cmux` can run tools and fire preToolUse hooks"
        )

        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        let preToolUse = try XCTUnwrap(hooks["preToolUse"] as? [[String: Any]])
        XCTAssertTrue(
            preToolUse.contains {
                ($0["command"] as? String)?.contains("hooks feed --source kiro --event preToolUse") == true
                    && ($0["timeout_ms"] as? Int) == 120_000
                    && (($0["command"] as? String)?.contains("|| echo '{}'") == false)
                    && (($0["command"] as? String)?.contains("status=$?") == true)
                    && (($0["command"] as? String)?.contains("exit 2") == true)
            },
            "Expected Kiro preToolUse feed hook to preserve cmux's exit status for deny decisions, saw \(preToolUse)"
        )
        XCTAssertNotNil(hooks["agentSpawn"])
        XCTAssertNotNil(hooks["userPromptSubmit"])
        XCTAssertNotNil(hooks["postToolUse"])
        XCTAssertNotNil(hooks["stop"])
    }

    func testKiroFeedDenyUsesPreToolUseExitCodeTwo() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("kiro-feed-deny")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-kiro-feed-deny-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "33333333-3333-3333-3333-333333333333"
        let surfaceId = "44444444-4444-4444-4444-444444444444"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else {
                return self.malformedRequestResponse(raw: line)
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            XCTAssertEqual(method, "feed.push")
            return self.v2Response(
                id: id,
                ok: true,
                result: [
                    "status": "resolved",
                    "decision": [
                        "kind": "permission",
                        "mode": "deny",
                    ],
                ]
            )
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "feed", "--source", "kiro", "--event", "preToolUse"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId,
                "CMUX_KIRO_PID": "525252",
                "CMUX_KIRO_NOTIFICATION_LEVEL": "standard",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            standardInput: #"{"hook_event_name":"preToolUse","session_id":"kiro-session-123","cwd":"\#(root.path)","tool_name":"fs_write","tool_input":{"operations":[{"mode":"Line","path":"\#(root.appendingPathComponent("README.md").path)"}]}}"#,
            timeout: 5
        )
        wait(for: [serverHandled], timeout: 5)

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 2, result.stderr)
        XCTAssertTrue(result.stderr.contains("User denied permission via cmux Feed."), result.stderr)

        let feedEvents = state.commands.compactMap { command -> [String: Any]? in
            guard let payload = self.jsonObject(command),
                  payload["method"] as? String == "feed.push",
                  let params = payload["params"] as? [String: Any],
                  let event = params["event"] as? [String: Any] else {
                return nil
            }
            return event
        }
        XCTAssertEqual(feedEvents.count, 1, "Expected one Kiro Feed event, saw \(state.commands)")
        XCTAssertEqual(feedEvents.first?["hook_event_name"] as? String, "PermissionRequest")
        XCTAssertEqual(feedEvents.first?["_source"] as? String, "kiro")
        XCTAssertEqual(feedEvents.first?["_ppid"] as? Int, 525252)
    }

    /// The Feed permission modes that allow a tool (`once` / `always` / `all`
    /// / `bypass`, the WorkstreamPermissionMode raw values) must exit 0 so
    /// Kiro proceeds; an unrecognized/malformed mode must fail closed with
    /// exit 2 rather than silently allowing the tool.
    func testKiroFeedAllowModesProceedAndUnknownModeDenies() throws {
        func runKiroDecision(mode: String) throws -> ProcessRunResult {
            let cliPath = try bundledCLIPath()
            let socketPath = makeSocketPath("kiro-feed-mode")
            let listenerFD = try bindUnixSocket(at: socketPath)
            let state = MockSocketServerState()
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-kiro-feed-mode-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer {
                Darwin.close(listenerFD)
                unlink(socketPath)
                try? FileManager.default.removeItem(at: root)
            }
            let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
                guard let payload = self.jsonObject(line), let id = payload["id"] as? String else {
                    return self.malformedRequestResponse(raw: line)
                }
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "status": "resolved",
                        "decision": ["kind": "permission", "mode": mode],
                    ]
                )
            }
            let result = runProcess(
                executablePath: cliPath,
                arguments: ["hooks", "feed", "--source", "kiro", "--event", "preToolUse"],
                environment: [
                    "HOME": root.path,
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "PWD": root.path,
                    "CMUX_SOCKET_PATH": socketPath,
                    "CMUX_WORKSPACE_ID": "33333333-3333-3333-3333-333333333333",
                    "CMUX_SURFACE_ID": "44444444-4444-4444-4444-444444444444",
                    "CMUX_KIRO_PID": "525252",
                    "CMUX_KIRO_NOTIFICATION_LEVEL": "standard",
                    "CMUX_CLI_SENTRY_DISABLED": "1",
                ],
                standardInput: #"{"hook_event_name":"preToolUse","session_id":"kiro-session-mode","cwd":"\#(root.path)","tool_name":"fs_write","tool_input":{"operations":[{"mode":"Line","path":"\#(root.appendingPathComponent("README.md").path)"}]}}"#,
                timeout: 5
            )
            wait(for: [serverHandled], timeout: 5)
            return result
        }

        for mode in ["once", "always", "all", "bypass"] {
            let result = try runKiroDecision(mode: mode)
            XCTAssertFalse(result.timedOut, "\(mode): \(result.stderr)")
            XCTAssertEqual(result.status, 0, "mode \(mode) should allow (exit 0): \(result.stderr)")
            XCTAssertEqual(result.stdout, "{}\n", "mode \(mode) should print {}")
        }

        let unknown = try runKiroDecision(mode: "totally-bogus-mode")
        XCTAssertFalse(unknown.timedOut, unknown.stderr)
        XCTAssertEqual(unknown.status, 2, "unrecognized mode must fail closed (exit 2): \(unknown.stderr)")
        XCTAssertTrue(unknown.stderr.contains("unrecognized"), unknown.stderr)
    }

    /// At the default `standard` notification level, Kiro read-only tool
    /// events (`fs_read`) are suppressed (no Feed telemetry) while mutating
    /// tools (`fs_write`) still emit. Guards that suppression keys off the
    /// classified wire name (`PostToolUse`) rather than the raw camelCase hook
    /// event — i.e. the suppression actually triggers for real Kiro events.
    func testKiroStandardLevelSuppressesReadOnlyToolFeedEvents() throws {
        func feedPushCount(forTool tool: String) throws -> Int {
            let cliPath = try bundledCLIPath()
            let socketPath = makeSocketPath("kiro-suppress")
            let listenerFD = try bindUnixSocket(at: socketPath)
            let state = MockSocketServerState()
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-kiro-suppress-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer {
                Darwin.close(listenerFD)
                unlink(socketPath)
                try? FileManager.default.removeItem(at: root)
            }
            let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
                guard let payload = self.jsonObject(line), let id = payload["id"] as? String else {
                    return self.malformedRequestResponse(raw: line)
                }
                return self.v2Response(id: id, ok: true, result: ["status": "acknowledged"])
            }
            let result = runProcess(
                executablePath: cliPath,
                arguments: ["hooks", "feed", "--source", "kiro", "--event", "postToolUse"],
                environment: [
                    "HOME": root.path,
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "PWD": root.path,
                    "CMUX_SOCKET_PATH": socketPath,
                    "CMUX_WORKSPACE_ID": "33333333-3333-3333-3333-333333333333",
                    "CMUX_SURFACE_ID": "44444444-4444-4444-4444-444444444444",
                    "CMUX_KIRO_PID": "525252",
                    "CMUX_KIRO_NOTIFICATION_LEVEL": "standard",
                    "CMUX_CLI_SENTRY_DISABLED": "1",
                ],
                standardInput: #"{"hook_event_name":"postToolUse","session_id":"kiro-suppress","cwd":"\#(root.path)","tool_name":"\#(tool)"}"#,
                timeout: 5
            )
            XCTAssertFalse(result.timedOut, "\(tool): \(result.stderr)")
            XCTAssertEqual(result.status, 0, "\(tool): \(result.stderr)")
            XCTAssertEqual(result.stdout, "{}\n", "\(tool) stdout")
            // A non-suppressed event sends one feed.push, so wait for the
            // server to record it (generous timeout to avoid flaking on the
            // socket/process round-trip under CI load). A suppressed event
            // sends nothing, so this wait simply times out silently.
            _ = XCTWaiter().wait(for: [serverHandled], timeout: 5)
            return state.commands.filter { $0.contains("feed.push") }.count
        }

        XCTAssertEqual(try feedPushCount(forTool: "fs_read"), 0,
                       "read-only kiro tool at standard level must be suppressed")
        XCTAssertGreaterThan(try feedPushCount(forTool: "fs_write"), 0,
                             "mutating kiro tool at standard level must still emit telemetry")
    }

    func testLowercaseGenericFeedToolsStayTelemetryOutsideKiro() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("generic-lowercase-feed-tool")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-generic-lowercase-feed-tool-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "33333333-3333-3333-3333-333333333333"
        let surfaceId = "44444444-4444-4444-4444-444444444444"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else {
                return self.malformedRequestResponse(raw: line)
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            XCTAssertEqual(method, "feed.push")
            return self.v2Response(id: id, ok: true, result: ["status": "acknowledged"])
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "feed", "--source", "gemini", "--event", "PreToolUse"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId,
                "CMUX_GEMINI_PID": "626262",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            standardInput: #"{"hook_event_name":"PreToolUse","session_id":"gemini-session-123","cwd":"\#(root.path)","tool_name":"write","tool_input":{"path":"\#(root.appendingPathComponent("README.md").path)"}}"#,
            timeout: 5
        )
        wait(for: [serverHandled], timeout: 5)

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")

        let feedPushes = state.commands.compactMap { command -> [String: Any]? in
            guard let payload = self.jsonObject(command),
                  payload["method"] as? String == "feed.push",
                  let params = payload["params"] as? [String: Any] else {
                return nil
            }
            return params
        }
        XCTAssertEqual(feedPushes.count, 1, "Expected one generic Feed event, saw \(state.commands)")
        let event = try XCTUnwrap(feedPushes.first?["event"] as? [String: Any])
        let waitTimeout = try XCTUnwrap(feedPushes.first?["wait_timeout_seconds"] as? NSNumber)
        XCTAssertEqual(event["hook_event_name"] as? String, "PreToolUse")
        XCTAssertEqual(event["_source"] as? String, "gemini")
        XCTAssertEqual(event["tool_name"] as? String, "write")
        XCTAssertEqual(event["_ppid"] as? Int, 626262)
        XCTAssertEqual(waitTimeout.doubleValue, 0)
    }

}
