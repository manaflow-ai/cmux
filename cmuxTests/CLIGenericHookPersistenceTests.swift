import XCTest
import Darwin

extension CLINotifyProcessIntegrationRegressionTests {
    struct GenericHookPersistenceScenario {
        let agent: String
        let subcommand: String
        let sessionId: String
        let executable: String
        let launchArguments: [String]
        let extraEnvironment: [String: String]
        let expectedArguments: [String]
        let expectedEnvironment: [String: String]?
    }

    func testGenericHookAgentsPersistSanitizedLaunchCommandsForSessionRestore() throws {
        let scenarios: [GenericHookPersistenceScenario] = [
            GenericHookPersistenceScenario(
                agent: "cursor",
                subcommand: "prompt-submit",
                sessionId: "cursor-session-123",
                executable: "/Users/example/.local/bin/cursor-agent",
                launchArguments: [
                    "/Users/example/.local/bin/cursor-agent",
                    "agent",
                    "--model",
                    "gpt-5.4",
                    "--resume",
                    "old-chat",
                    "--workspace",
                    "/tmp/old repo",
                    "--sandbox",
                    "enabled",
                    "initial prompt should not persist"
                ],
                extraEnvironment: [:],
                expectedArguments: [
                    "/Users/example/.local/bin/cursor-agent",
                    "--model",
                    "gpt-5.4",
                    "--sandbox",
                    "enabled"
                ],
                expectedEnvironment: nil
            ),
            GenericHookPersistenceScenario(
                agent: "gemini",
                subcommand: "session-start",
                sessionId: "gemini-session-123",
                executable: "/Users/example/.bun/bin/gemini",
                launchArguments: [
                    "/Users/example/.bun/bin/gemini",
                    "--model",
                    "gemini-2.5-pro",
                    "--resume",
                    "old-session",
                    "--sandbox",
                    "danger-full-access",
                    "initial prompt should not persist"
                ],
                extraEnvironment: [
                    "GEMINI_CLI_HOME": "/tmp/gemini home",
                    "GEMINI_API_KEY": "secret"
                ],
                expectedArguments: [
                    "/Users/example/.bun/bin/gemini",
                    "--model",
                    "gemini-2.5-pro",
                    "--sandbox",
                    "danger-full-access"
                ],
                expectedEnvironment: ["GEMINI_CLI_HOME": "/tmp/gemini home"]
            ),
            GenericHookPersistenceScenario(
                agent: "copilot",
                subcommand: "session-start",
                sessionId: "copilot-session-123",
                executable: "/tmp/cmux-agent-upstreams/copilot-install/bin/copilot",
                launchArguments: [
                    "/tmp/cmux-agent-upstreams/copilot-install/bin/copilot",
                    "--model",
                    "gpt-5.4",
                    "--resume=old-session",
                    "--allow-all-tools",
                    "-i",
                    "old prompt",
                    "initial prompt should not persist"
                ],
                extraEnvironment: [
                    "COPILOT_HOME": "/tmp/copilot home",
                    "COPILOT_GITHUB_TOKEN": "secret"
                ],
                expectedArguments: [
                    "/tmp/cmux-agent-upstreams/copilot-install/bin/copilot",
                    "--model",
                    "gpt-5.4",
                    "--allow-all-tools"
                ],
                expectedEnvironment: ["COPILOT_HOME": "/tmp/copilot home"]
            ),
            GenericHookPersistenceScenario(
                agent: "codebuddy",
                subcommand: "session-start",
                sessionId: "codebuddy-session-123",
                executable: "/Users/example/.npm/bin/codebuddy",
                launchArguments: [
                    "/Users/example/.npm/bin/codebuddy",
                    "--model",
                    "gpt-5.4",
                    "--resume",
                    "old-session",
                    "--permission-mode",
                    "plan",
                    "--worktree",
                    "scratch",
                    "initial prompt should not persist"
                ],
                extraEnvironment: [
                    "CODEBUDDY_CONFIG_DIR": "/tmp/codebuddy config",
                    "CODEBUDDY_API_KEY": "secret"
                ],
                expectedArguments: [
                    "/Users/example/.npm/bin/codebuddy",
                    "--model",
                    "gpt-5.4",
                    "--permission-mode",
                    "plan"
                ],
                expectedEnvironment: ["CODEBUDDY_CONFIG_DIR": "/tmp/codebuddy config"]
            ),
            GenericHookPersistenceScenario(
                agent: "factory",
                subcommand: "session-start",
                sessionId: "factory-session-123",
                executable: "/Users/example/.npm/bin/droid",
                launchArguments: [
                    "/Users/example/.npm/bin/droid",
                    "--resume",
                    "old-session",
                    "--cwd",
                    "/tmp/factory repo",
                    "--append-system-prompt",
                    "be terse",
                    "initial prompt should not persist"
                ],
                extraEnvironment: [
                    "FACTORY_API_KEY": "secret"
                ],
                expectedArguments: [
                    "/Users/example/.npm/bin/droid",
                    "--cwd",
                    "/tmp/factory repo",
                    "--append-system-prompt",
                    "be terse"
                ],
                expectedEnvironment: nil
            ),
            GenericHookPersistenceScenario(
                agent: "qoder",
                subcommand: "session-start",
                sessionId: "qoder-session-123",
                executable: "/Users/example/.npm/bin/qodercli",
                launchArguments: [
                    "/Users/example/.npm/bin/qodercli",
                    "--model",
                    "gemini-2.5-pro",
                    "--resume",
                    "old-session",
                    "--permission-mode",
                    "plan",
                    "--workspace",
                    "/tmp/qoder repo",
                    "initial prompt should not persist"
                ],
                extraEnvironment: [
                    "QODER_CONFIG_DIR": "/tmp/qoder config",
                    "GEMINI_API_KEY": "secret"
                ],
                expectedArguments: [
                    "/Users/example/.npm/bin/qodercli",
                    "--model",
                    "gemini-2.5-pro",
                    "--permission-mode",
                    "plan",
                    "--workspace",
                    "/tmp/qoder repo"
                ],
                expectedEnvironment: ["QODER_CONFIG_DIR": "/tmp/qoder config"]
            ),
        ]

        for scenario in scenarios {
            try XCTContext.runActivity(named: scenario.agent) { _ in
                try runGenericHookPersistenceScenario(scenario)
            }
        }
    }

    func runGenericHookPersistenceScenario(_ scenario: GenericHookPersistenceScenario) throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("hook-\(scenario.agent)")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-\(scenario.agent)-hook-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("repo", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"

        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line) else {
                return "OK"
            }
            guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
                return self.malformedRequestResponse(id: payload["id"] as? String, raw: line)
            }
            switch method {
            case "surface.list":
                return self.surfaceListResponse(id: id, surfaceId: surfaceId)
            case "feed.push":
                return self.v2Response(id: id, ok: true, result: [:])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        var environment: [String: String] = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": workspace.path,
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_WORKSPACE_ID": workspaceId,
            "CMUX_SURFACE_ID": surfaceId,
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_AGENT_LAUNCH_KIND": scenario.agent,
            "CMUX_AGENT_LAUNCH_EXECUTABLE": scenario.executable,
            "CMUX_AGENT_LAUNCH_ARGV_B64": base64NULSeparated(scenario.launchArguments),
            "CMUX_AGENT_LAUNCH_CWD": workspace.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
        ]
        for (key, value) in scenario.extraEnvironment {
            environment[key] = value
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", scenario.agent, scenario.subcommand],
            environment: environment,
            standardInput: #"{"session_id":"\#(scenario.sessionId)","cwd":"\#(workspace.path)","hook_event_name":"SessionStart"}"#,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")

        let storeURL = root.appendingPathComponent("\(scenario.agent)-hook-sessions.json", isDirectory: false)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
        let sessions = try XCTUnwrap(json["sessions"] as? [String: Any])
        let session = try XCTUnwrap(sessions[scenario.sessionId] as? [String: Any])
        XCTAssertEqual(session["workspaceId"] as? String, workspaceId)
        XCTAssertEqual(session["surfaceId"] as? String, surfaceId)
        XCTAssertEqual(session["cwd"] as? String, workspace.path)

        let launchCommand = try XCTUnwrap(session["launchCommand"] as? [String: Any])
        XCTAssertEqual(launchCommand["launcher"] as? String, scenario.agent)
        XCTAssertEqual(launchCommand["executablePath"] as? String, scenario.executable)
        XCTAssertEqual(launchCommand["arguments"] as? [String], scenario.expectedArguments)
        XCTAssertEqual(launchCommand["workingDirectory"] as? String, workspace.path)
        XCTAssertEqual(launchCommand["environment"] as? [String: String], scenario.expectedEnvironment)
    }
}
