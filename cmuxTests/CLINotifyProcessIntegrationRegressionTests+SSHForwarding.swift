import XCTest
import Darwin
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - SSH agent forwarding and persistent PTY
extension CLINotifyProcessIntegrationRegressionTests {
    func testSSHPersistentPTYUsesReusableForegroundAuthControlConnection() throws {
        let run = try runMockedSSH(arguments: [])
        try assertSSHPersistentPTYUsesReusableForegroundAuthControlConnection(run: run)
    }

    func testSSHPersistentPTYTreatsControlPersistZeroAsReusable() throws {
        let run = try runMockedSSH(arguments: ["--ssh-option", "ControlPersist=0"])
        try assertSSHPersistentPTYUsesReusableForegroundAuthControlConnection(run: run)
    }

    func testSSHPersistentPTYJSONReportsResolvedSessionID() throws {
        let run = try runMockedSSH(arguments: [], jsonOutput: true)
        let payload = try jsonPayload(from: run.stdout)
        let sessionID = try XCTUnwrap(payload["ssh_pty_session_id"] as? String)
        let persistentDaemonSlot = try XCTUnwrap(payload["persistent_daemon_slot"] as? String)

        XCTAssertEqual(sessionID, "ssh-\(run.workspaceId)-\(run.surfaceId)")
        XCTAssertFalse(sessionID.contains("$"), sessionID)
        XCTAssertFalse(sessionID.contains("{"), sessionID)
        XCTAssertTrue(persistentDaemonSlot.hasPrefix("ssh-"), persistentDaemonSlot)
        XCTAssertNotNil(UUID(uuidString: String(persistentDaemonSlot.dropFirst(4))))
    }

    func testSSHPersistentPTYJSONResolvesSessionIDWhenWorkspaceCreateOmitsSurfaceID() throws {
        let run = try runMockedSSH(arguments: [], jsonOutput: true, omitWorkspaceCreateSurfaceID: true)
        let payload = try jsonPayload(from: run.stdout)
        let sessionID = try XCTUnwrap(payload["ssh_pty_session_id"] as? String)
        let persistentDaemonSlot = try XCTUnwrap(payload["persistent_daemon_slot"] as? String)

        XCTAssertEqual(sessionID, "ssh-\(run.workspaceId)-\(run.surfaceId)")
        XCTAssertTrue(persistentDaemonSlot.hasPrefix("ssh-"), persistentDaemonSlot)
        XCTAssertNotNil(UUID(uuidString: String(persistentDaemonSlot.dropFirst(4))))
    }

    func testSSHForwardAgentFlagPropagatesCallerAgentSocket() throws {
        let agentSocketPath = try makeExistingAgentSocketPath()
        let run = try runMockedSSH(
            arguments: ["--forward-agent"],
            environmentOverrides: ["SSH_AUTH_SOCK": agentSocketPath]
        )
        let createParams = try XCTUnwrap(params(for: "workspace.create", in: run.requests))
        let configureParams = try XCTUnwrap(params(for: "workspace.remote.configure", in: run.requests))
        let sshOptions = try XCTUnwrap(configureParams["ssh_options"] as? [String])
        let initialEnv = try XCTUnwrap(createParams["initial_env"] as? [String: String])

        XCTAssertTrue(sshOptions.contains("ForwardAgent=yes"), "ssh_options: \(sshOptions)")
        XCTAssertEqual(initialEnv["SSH_AUTH_SOCK"], agentSocketPath)
        XCTAssertEqual(configureParams["ssh_auth_sock"] as? String, agentSocketPath)
    }

    func testSSHForwardAgentOptionPropagatesCallerAgentSocket() throws {
        let agentSocketPath = try makeExistingAgentSocketPath()
        let run = try runMockedSSH(
            arguments: ["--ssh-option", "ForwardAgent=yes"],
            environmentOverrides: ["SSH_AUTH_SOCK": agentSocketPath]
        )
        let createParams = try XCTUnwrap(params(for: "workspace.create", in: run.requests))
        let configureParams = try XCTUnwrap(params(for: "workspace.remote.configure", in: run.requests))
        let sshOptions = try XCTUnwrap(configureParams["ssh_options"] as? [String])
        let initialEnv = try XCTUnwrap(createParams["initial_env"] as? [String: String])

        XCTAssertTrue(sshOptions.contains("ForwardAgent=yes"), "ssh_options: \(sshOptions)")
        XCTAssertEqual(initialEnv["SSH_AUTH_SOCK"], agentSocketPath)
        XCTAssertEqual(configureParams["ssh_auth_sock"] as? String, agentSocketPath)
    }

    func testSSHForwardAgentRepeatedOptionUsesLastValue() throws {
        let run = try runMockedSSH(
            arguments: [
                "--ssh-option", "ForwardAgent=yes",
                "--ssh-option", "ForwardAgent=no",
            ],
            environmentOverrides: [
                "SSH_AUTH_SOCK": "/tmp/cmux-test-agent-\(UUID().uuidString).sock",
            ]
        )
        let createParams = try XCTUnwrap(params(for: "workspace.create", in: run.requests))
        let configureParams = try XCTUnwrap(params(for: "workspace.remote.configure", in: run.requests))
        let sshOptions = try XCTUnwrap(configureParams["ssh_options"] as? [String])

        XCTAssertEqual(sshOptions.filter { $0.hasPrefix("ForwardAgent=") }, [
            "ForwardAgent=yes",
            "ForwardAgent=no",
        ])
        XCTAssertNil(createParams["initial_env"])
        XCTAssertNil(configureParams["ssh_auth_sock"])
    }

    func testSSHPreservesCallerAgentSocketForOpenSSHConfigResolution() throws {
        let agentSocketPath = try makeExistingAgentSocketPath()
        let run = try runMockedSSH(
            arguments: [],
            environmentOverrides: [
                "SSH_AUTH_SOCK": agentSocketPath,
            ]
        )
        let createParams = try XCTUnwrap(params(for: "workspace.create", in: run.requests))
        let configureParams = try XCTUnwrap(params(for: "workspace.remote.configure", in: run.requests))
        let initialEnv = try XCTUnwrap(createParams["initial_env"] as? [String: String])

        XCTAssertNil(configureParams["ssh_options"])
        XCTAssertEqual(initialEnv["SSH_AUTH_SOCK"], agentSocketPath)
        XCTAssertEqual(configureParams["ssh_auth_sock"] as? String, agentSocketPath)
    }

    func testSSHForwardAgentLiteralSocketPathPropagatesSocketPath() throws {
        let agentSocketPath = try makeExistingAgentSocketPath()
        let run = try runMockedSSH(
            arguments: ["--ssh-option", "ForwardAgent=\(agentSocketPath)"]
        )
        let createParams = try XCTUnwrap(params(for: "workspace.create", in: run.requests))
        let configureParams = try XCTUnwrap(params(for: "workspace.remote.configure", in: run.requests))
        let sshOptions = try XCTUnwrap(configureParams["ssh_options"] as? [String])
        let initialEnv = try XCTUnwrap(createParams["initial_env"] as? [String: String])

        XCTAssertTrue(sshOptions.contains("ForwardAgent=\(agentSocketPath)"), "ssh_options: \(sshOptions)")
        XCTAssertEqual(initialEnv["SSH_AUTH_SOCK"], agentSocketPath)
        XCTAssertEqual(configureParams["ssh_auth_sock"] as? String, agentSocketPath)
    }

    func testSSHForwardAgentTildeSocketPathExpandsSocketPath() throws {
        let homeURL = try makeTemporaryDirectory(prefix: "cmux-ssh-home")
        let tildeSocketPath = "~/.ssh/cmux-test-agent.sock"
        let expandedSocketURL = homeURL.appendingPathComponent(".ssh/cmux-test-agent.sock")
        try createExistingFile(at: expandedSocketURL)
        let run = try runMockedSSH(
            arguments: ["--ssh-option", "ForwardAgent=\(tildeSocketPath)"],
            environmentOverrides: [
                "HOME": homeURL.path,
            ]
        )
        let createParams = try XCTUnwrap(params(for: "workspace.create", in: run.requests))
        let configureParams = try XCTUnwrap(params(for: "workspace.remote.configure", in: run.requests))
        let sshOptions = try XCTUnwrap(configureParams["ssh_options"] as? [String])
        let initialEnv = try XCTUnwrap(createParams["initial_env"] as? [String: String])

        XCTAssertTrue(sshOptions.contains("ForwardAgent=\(tildeSocketPath)"), "ssh_options: \(sshOptions)")
        XCTAssertEqual(initialEnv["SSH_AUTH_SOCK"], expandedSocketURL.path)
        XCTAssertEqual(configureParams["ssh_auth_sock"] as? String, expandedSocketURL.path)
    }

    func testSSHForwardAgentAskDoesNotPropagateInvalidSocketPath() throws {
        let run = try runMockedSSH(
            arguments: ["--ssh-option", "ForwardAgent=ask"],
            environmentOverrides: [
                "SSH_AUTH_SOCK": "/tmp/cmux-test-agent-\(UUID().uuidString).sock",
            ]
        )
        let createParams = try XCTUnwrap(params(for: "workspace.create", in: run.requests))
        let configureParams = try XCTUnwrap(params(for: "workspace.remote.configure", in: run.requests))
        let sshOptions = try XCTUnwrap(configureParams["ssh_options"] as? [String])

        XCTAssertTrue(sshOptions.contains("ForwardAgent=ask"), "ssh_options: \(sshOptions)")
        XCTAssertNil(createParams["initial_env"])
        XCTAssertNil(configureParams["ssh_auth_sock"])
    }

    func testSSHNoForwardAgentFlagOverridesConfig() throws {
        let agentSocketPath = try makeExistingAgentSocketPath()
        let run = try runMockedSSH(
            arguments: ["--no-forward-agent"],
            environmentOverrides: [
                "SSH_AUTH_SOCK": agentSocketPath,
            ]
        )
        let createParams = try XCTUnwrap(params(for: "workspace.create", in: run.requests))
        let configureParams = try XCTUnwrap(params(for: "workspace.remote.configure", in: run.requests))
        let sshOptions = try XCTUnwrap(configureParams["ssh_options"] as? [String])
        let initialEnv = try XCTUnwrap(createParams["initial_env"] as? [String: String])

        XCTAssertTrue(sshOptions.contains("ForwardAgent=no"), "ssh_options: \(sshOptions)")
        XCTAssertEqual(initialEnv["SSH_AUTH_SOCK"], agentSocketPath)
        XCTAssertEqual(configureParams["ssh_auth_sock"] as? String, agentSocketPath)
    }

    private func assertSSHPersistentPTYUsesReusableForegroundAuthControlConnection(
        run: MockedSSHRun,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let createParams = try XCTUnwrap(params(for: "workspace.create", in: run.requests))
        let configureParams = try XCTUnwrap(params(for: "workspace.remote.configure", in: run.requests))
        let initialCommand = try XCTUnwrap(createParams["initial_command"] as? String)
        let terminalStartupCommand = try XCTUnwrap(configureParams["terminal_startup_command"] as? String)
        let initialScript = try XCTUnwrap(decodedReusableStartupScript(from: initialCommand))
        let terminalStartupScript = try XCTUnwrap(decodedReusableStartupScript(from: terminalStartupCommand))

        XCTAssertTrue(initialScript.contains("ssh-pty-attach"), initialScript)
        XCTAssertTrue(initialScript.contains("--wait"), initialScript)
        XCTAssertTrue(initialScript.contains("ssh-session-end"), initialScript)
        XCTAssertTrue(initialScript.contains("CMUX_WORKSPACE_ID"), initialScript)
        XCTAssertTrue(initialScript.contains("CMUX_SURFACE_ID"), initialScript)
        XCTAssertTrue(
            initialScript.contains("required workspace context missing for SSH PTY attach"),
            initialScript
        )
        XCTAssertTrue(
            initialScript.contains("required terminal context missing for SSH PTY attach"),
            initialScript
        )
        XCTAssertTrue(
            initialScript.contains("ssh-$cmux_ssh_pty_workspace_id-$cmux_ssh_pty_surface_id"),
            initialScript
        )
        XCTAssertTrue(initialScript.contains("254|255"), initialScript)
        XCTAssertFalse(initialScript.contains("-surface"), initialScript)
        XCTAssertTrue(
            initialScript.contains("--workspace \"$cmux_ssh_pty_workspace_id\""),
            initialScript
        )
        XCTAssertEqual(
            initialScript.components(separatedBy: "workspace.remote.foreground_auth_ready").count - 1,
            1,
            initialScript
        )
        XCTAssertTrue(terminalStartupScript.contains("ssh-pty-attach"), terminalStartupScript)
        XCTAssertTrue(terminalStartupScript.contains("ssh-session-end"), terminalStartupScript)
        XCTAssertTrue(terminalStartupScript.contains("CMUX_WORKSPACE_ID"), terminalStartupScript)
        XCTAssertTrue(terminalStartupScript.contains("CMUX_SURFACE_ID"), terminalStartupScript)
        XCTAssertTrue(
            terminalStartupScript.contains("required workspace context missing for SSH PTY attach"),
            terminalStartupScript
        )
        XCTAssertTrue(
            terminalStartupScript.contains("required terminal context missing for SSH PTY attach"),
            terminalStartupScript
        )
        XCTAssertTrue(
            terminalStartupScript.contains("ssh-$cmux_ssh_pty_workspace_id-$cmux_ssh_pty_surface_id"),
            terminalStartupScript
        )
        XCTAssertTrue(terminalStartupScript.contains("254|255"), terminalStartupScript)
        XCTAssertFalse(terminalStartupScript.contains("-surface"), terminalStartupScript)
        XCTAssertTrue(
            terminalStartupScript.contains("--workspace \"$cmux_ssh_pty_workspace_id\""),
            terminalStartupScript
        )
        XCTAssertEqual(
            terminalStartupScript.components(separatedBy: "workspace.remote.foreground_auth_ready").count - 1,
            1,
            terminalStartupScript
        )
        XCTAssertEqual(configureParams["auto_connect"] as? Bool, false)
        XCTAssertNotNil(configureParams["foreground_auth_token"] as? String)
        XCTAssertEqual(configureParams["preserve_after_terminal_exit"] as? Bool, true)
        let persistentDaemonSlot = try XCTUnwrap(configureParams["persistent_daemon_slot"] as? String)
        XCTAssertTrue(persistentDaemonSlot.hasPrefix("ssh-"), persistentDaemonSlot)
        XCTAssertNotNil(UUID(uuidString: String(persistentDaemonSlot.dropFirst(4))))
    }

    func testSSHPersistentPTYFallsBackWhenForegroundAuthCannotBeReused() throws {
        let cases: [(name: String, arguments: [String])] = [
            ("control-master-no", ["--ssh-option", "ControlMaster=no"]),
            ("control-persist-no", ["--ssh-option", "ControlPersist=no"]),
            ("local-command", ["--ssh-option", "LocalCommand=echo cmux-test"]),
            ("permit-local-command", ["--ssh-option", "PermitLocalCommand=no"]),
        ]

        for testCase in cases {
            let run = try runMockedSSH(arguments: testCase.arguments)
            let createParams = try XCTUnwrap(
                params(for: "workspace.create", in: run.requests),
                testCase.name
            )
            let configureParams = try XCTUnwrap(
                params(for: "workspace.remote.configure", in: run.requests),
                testCase.name
            )
            let initialCommand = try XCTUnwrap(createParams["initial_command"] as? String, testCase.name)
            let terminalStartupCommand = try XCTUnwrap(
                configureParams["terminal_startup_command"] as? String,
                testCase.name
            )
            let initialScript = decodedReusableStartupScript(from: initialCommand) ?? initialCommand
            let terminalStartupScript = decodedReusableStartupScript(from: terminalStartupCommand) ?? terminalStartupCommand

            XCTAssertFalse(initialScript.contains("ssh-pty-attach"), testCase.name)
            XCTAssertFalse(terminalStartupScript.contains("ssh-pty-attach"), testCase.name)
            XCTAssertEqual(configureParams["auto_connect"] as? Bool, true, testCase.name)
            XCTAssertNil(configureParams["foreground_auth_token"], testCase.name)
            XCTAssertNil(configureParams["preserve_after_terminal_exit"], testCase.name)
            XCTAssertNil(configureParams["persistent_daemon_slot"], testCase.name)
        }
    }

    private struct MockedSSHRun {
        let requests: [[String: Any]]
        let stdout: String
        let workspaceId: String
        let surfaceId: String
    }

    private func runMockedSSH(
        arguments sshArguments: [String],
        jsonOutput: Bool = false,
        omitWorkspaceCreateSurfaceID: Bool = false,
        environmentOverrides: [String: String] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> MockedSSHRun {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("ssh")
        let homeURL = try makeTemporaryDirectory(prefix: "cmux-ssh-home")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "33333333-3333-3333-3333-333333333333"
        let windowId = "22222222-2222-2222-2222-222222222222"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        startDetachedMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }

            switch method {
            case "workspace.create":
                var result: [String: Any] = [
                    "workspace_id": workspaceId,
                    "window_id": windowId,
                ]
                if !omitWorkspaceCreateSurfaceID {
                    result["surface_id"] = surfaceId
                }
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: result
                )
            case "surface.list":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "surfaces": [
                            [
                                "id": surfaceId,
                                "ref": "surface:1",
                                "index": 1,
                                "focused": true,
                            ],
                        ],
                    ]
                )
            case "workspace.remote.configure":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["remote": ["state": "connected"]]
                )
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["HOME"] = homeURL.path
        for (key, value) in environmentOverrides {
            environment[key] = value
        }

        let commandArguments = jsonOutput
            ? ["--json", "--id-format", "uuids", "ssh", "example.test", "--no-focus"] + sshArguments
            : ["ssh", "example.test", "--no-focus"] + sshArguments
        let result = runProcess(
            executablePath: cliPath,
            arguments: commandArguments,
            environment: environment,
            timeout: 5
        )

        let sawConfigureRequest = waitForMockSocketCommand(in: state) { line in
            line.contains(#""method":"workspace.remote.configure""#)
        }
        XCTAssertTrue(sawConfigureRequest, "Expected workspace.remote.configure, saw \(state.snapshot())", file: file, line: line)
        XCTAssertFalse(result.timedOut, result.stderr, file: file, line: line)
        XCTAssertEqual(result.status, 0, result.stderr, file: file, line: line)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr, file: file, line: line)

        let requests = state.snapshot().compactMap { jsonObject($0) }
        return MockedSSHRun(
            requests: requests,
            stdout: result.stdout,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
    }

    private func makeExistingAgentSocketPath() throws -> String {
        let directory = try makeTemporaryDirectory(prefix: "cmux-agent")
        let url = directory.appendingPathComponent("agent.sock")
        try createExistingFile(at: url)
        return url.path
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func createExistingFile(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(
            FileManager.default.createFile(atPath: url.path, contents: Data()),
            "Expected to create \(url.path)"
        )
    }

    private func waitForMockSocketCommand(
        in state: MockSocketServerState,
        timeout: TimeInterval = 5,
        predicate: (String) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if state.snapshot().contains(where: predicate) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return state.snapshot().contains(where: predicate)
    }

    private func decodedReusableStartupScript(from command: String) -> String? {
        guard let markerRange = command.range(of: "printf %s ") else {
            return nil
        }
        let remainder = command[markerRange.upperBound...]
        guard let encoded = remainder.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first,
              let data = Data(base64Encoded: String(encoded)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

}
