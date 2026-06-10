import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - ssh command workspace creation via CLI
extension CLINotifyProcessIntegrationTests {
    @MainActor
    func testSSHCommandCreatesConfiguresAndSelectsRemoteWorkspaceViaCLI() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("ssh")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let workspaceRef = "workspace:7"
        let windowID = "22222222-2222-2222-2222-222222222222"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.v2Response(
                    id: "unknown",
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected payload"]
                )
            }

            switch method {
            case "workspace.create":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceID,
                        "window_id": windowID,
                    ]
                )
            case "workspace.rename":
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceID])
            case "workspace.remote.configure":
                let params = payload["params"] as? [String: Any] ?? [:]
                let autoConnect = (params["auto_connect"] as? Bool) ?? true
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceID,
                        "workspace_ref": workspaceRef,
                        "remote": [
                            "enabled": true,
                            "state": autoConnect ? "connecting" : "disconnected",
                        ],
                    ]
                )
            case "workspace.select":
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceID])
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected method \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh",
                "--name", "SSH Workspace",
                "--port", "2222",
                "--identity", "/Users/test/.ssh/id_ed25519",
                "--ssh-option", "ControlPath /tmp/cmux-ssh-%C",
                "--ssh-option", "StrictHostKeyChecking=accept-new",
                "--window", windowID,
                "cmux-macmini",
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK workspace=\(workspaceRef) target=cmux-macmini state=disconnected\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)

        let requests = try state.commands.map { line -> [String: Any] in
            let data = try XCTUnwrap(line.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
        }
        XCTAssertEqual(
            requests.compactMap { $0["method"] as? String },
            ["workspace.create", "workspace.rename", "workspace.remote.configure", "workspace.select"]
        )

        let createParams = try XCTUnwrap(requests[0]["params"] as? [String: Any])
        XCTAssertEqual(createParams["window_id"] as? String, windowID)
        let initialCommand = try XCTUnwrap(createParams["initial_command"] as? String)
        XCTAssertFalse(initialCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let renameParams = try XCTUnwrap(requests[1]["params"] as? [String: Any])
        XCTAssertEqual(renameParams["workspace_id"] as? String, workspaceID)
        XCTAssertEqual(renameParams["title"] as? String, "SSH Workspace")

        let configureParams = try XCTUnwrap(requests[2]["params"] as? [String: Any])
        XCTAssertEqual(configureParams["workspace_id"] as? String, workspaceID)
        XCTAssertEqual(configureParams["destination"] as? String, "cmux-macmini")
        XCTAssertEqual(configureParams["port"] as? Int, 2222)
        XCTAssertEqual(configureParams["identity_file"] as? String, "/Users/test/.ssh/id_ed25519")
        XCTAssertEqual(configureParams["local_socket_path"] as? String, socketPath)
        XCTAssertEqual(configureParams["auto_connect"] as? Bool, false)
        let relayPort = try XCTUnwrap(configureParams["relay_port"] as? Int)
        XCTAssertGreaterThan(relayPort, 0)
        let relayID = try XCTUnwrap(configureParams["relay_id"] as? String)
        XCTAssertFalse(relayID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let relayToken = try XCTUnwrap(configureParams["relay_token"] as? String)
        XCTAssertEqual(relayToken.count, 64)
        let foregroundAuthToken = try XCTUnwrap(configureParams["foreground_auth_token"] as? String)
        XCTAssertFalse(foregroundAuthToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let terminalStartupCommand = try XCTUnwrap(configureParams["terminal_startup_command"] as? String)
        XCTAssertFalse(terminalStartupCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let sshOptions = try XCTUnwrap(configureParams["ssh_options"] as? [String])
        XCTAssertTrue(sshOptions.contains("ControlMaster=auto"))
        XCTAssertTrue(sshOptions.contains("ControlPersist=600"))
        XCTAssertTrue(sshOptions.contains("ControlPath /tmp/cmux-ssh-%C"))
        XCTAssertTrue(sshOptions.contains("StrictHostKeyChecking=accept-new"))

        // `cmux ssh` should land the user in the new SSH workspace immediately.
        let selectParams = try XCTUnwrap(requests[3]["params"] as? [String: Any])
        XCTAssertEqual(selectParams["workspace_id"] as? String, workspaceID)
        XCTAssertEqual(selectParams["window_id"] as? String, windowID)
    }

    @MainActor
    func testSSHCommandDoesNotDeferReconnectWhenWhitespaceControlMasterDisablesMultiplexing() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("ssh-controlmaster-no")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let workspaceRef = "workspace:9"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.v2Response(
                    id: "unknown",
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected payload"]
                )
            }

            switch method {
            case "workspace.create":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceID,
                    ]
                )
            case "workspace.remote.configure":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceID,
                        "workspace_ref": workspaceRef,
                        "remote": [
                            "enabled": true,
                            "state": "connecting",
                        ],
                    ]
                )
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected method \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh",
                "--no-focus",
                "--port", "2222",
                "--ssh-option", "ControlMaster no",
                "--ssh-option", "ControlPath /tmp/cmux-ssh-%C",
                "cmux-macmini",
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK workspace=\(workspaceRef) target=cmux-macmini state=connecting\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)

        let requests = try state.commands.map { line -> [String: Any] in
            let data = try XCTUnwrap(line.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
        }
        XCTAssertEqual(
            requests.compactMap { $0["method"] as? String },
            ["workspace.create", "workspace.remote.configure"]
        )

        let configureParams = try XCTUnwrap(requests[1]["params"] as? [String: Any])
        XCTAssertEqual(configureParams["auto_connect"] as? Bool, true)
        XCTAssertNil(configureParams["foreground_auth_token"])
        let sshOptions = try XCTUnwrap(configureParams["ssh_options"] as? [String])
        XCTAssertTrue(sshOptions.contains("ControlMaster no"))
        XCTAssertTrue(sshOptions.contains("ControlPath /tmp/cmux-ssh-%C"))
    }

}
