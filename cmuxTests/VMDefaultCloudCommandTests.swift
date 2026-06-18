import XCTest
import Darwin

extension CLINotifyProcessIntegrationRegressionTests {
    func testVMNewDefaultCreatesPinnedSSHDWorkspaceOverFreestyleSSH() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-new-sshd")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let vmID = "vm-persistent-freestyle"
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let workspaceRef = "workspace:sshd"
        let windowID = "22222222-2222-2222-2222-222222222222"

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

            switch method {
            case "vm.create":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["provider"] as? String, "freestyle")
                XCTAssertEqual(params["idempotency_key"] as? String, "cmux-default-freestyle-sshd-v1")
                XCTAssertNil(params["image"])
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "id": vmID,
                        "provider": "freestyle",
                        "image": "snapshot-default",
                    ]
                )
            case "vm.ssh_info":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["id"] as? String, vmID)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "transport": "ssh",
                        "host": "vm-ssh.freestyle.sh",
                        "port": 22,
                        "username": "\(vmID)+cmux",
                        "credential": [
                            "kind": "password",
                            "value": "lease-token",
                        ],
                    ]
                )
            case "workspace.list":
                return self.v2Response(id: id, ok: true, result: ["workspaces": []])
            case "workspace.create":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceID,
                        "workspace_ref": workspaceRef,
                        "window_id": windowID,
                    ]
                )
            case "workspace.rename":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["workspace_id"] as? String, workspaceID)
                XCTAssertEqual(params["title"] as? String, "sshd")
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceID])
            case "workspace.action":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["workspace_id"] as? String, workspaceID)
                XCTAssertEqual(params["window_id"] as? String, windowID)
                let action = params["action"] as? String
                XCTAssertTrue(action == "pin" || action == "move_top")
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceID, "action": action ?? ""])
            case "workspace.remote.configure":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["workspace_id"] as? String, workspaceID)
                XCTAssertEqual(params["destination"] as? String, "\(vmID)+cmux@vm-ssh.freestyle.sh")
                XCTAssertEqual(params["skip_daemon_bootstrap"] as? Bool, true)
                let terminalStartupCommand = params["terminal_startup_command"] as? String ?? ""
                let decodedStartupCommand = self.decodedReusableShellStartupCommand(terminalStartupCommand)
                XCTAssertFalse(terminalStartupCommand.isEmpty, "\(params)")
                XCTAssertTrue(decodedStartupCommand.contains("vm ssh-attach"), decodedStartupCommand)
                XCTAssertFalse(decodedStartupCommand.contains(":lease-token@"), decodedStartupCommand)
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
            arguments: ["vm", "new"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("Created Cloud VM \(vmID)"), result.stdout)
        XCTAssertTrue(result.stdout.contains("OK workspace=\(workspaceRef) target=\(vmID)+cmux@vm-ssh.freestyle.sh state=connecting"), result.stdout)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            [
                "vm.create",
                "vm.ssh_info",
                "workspace.list",
                "workspace.create",
                "workspace.rename",
                "workspace.action",
                "workspace.action",
                "workspace.remote.configure",
                "workspace.select",
            ]
        )
    }

    func testVMNewDefaultReusesPinnedSSHDWorkspaceOverFreestyleSSH() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-new-sshd-reuse")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let vmID = "vm-persistent-freestyle"
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let workspaceRef = "workspace:sshd"
        let surfaceID = "33333333-3333-3333-3333-333333333333"
        let windowID = "22222222-2222-2222-2222-222222222222"

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

            switch method {
            case "vm.create":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "id": vmID,
                        "provider": "freestyle",
                        "image": "snapshot-default",
                    ]
                )
            case "vm.ssh_info":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "transport": "ssh",
                        "host": "vm-ssh.freestyle.sh",
                        "port": 22,
                        "username": "\(vmID)+cmux",
                        "credential": [
                            "kind": "password",
                            "value": "lease-token",
                        ],
                    ]
                )
            case "workspace.list":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspaces": [
                            [
                                "id": workspaceID,
                                "workspace_ref": workspaceRef,
                                "window_id": windowID,
                                "title": "sshd",
                                "is_pinned": true,
                            ],
                        ],
                    ]
                )
            case "workspace.action":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["workspace_id"] as? String, workspaceID)
                XCTAssertEqual(params["window_id"] as? String, windowID)
                let action = params["action"] as? String
                XCTAssertTrue(action == "pin" || action == "move_top")
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceID, "action": action ?? ""])
            case "workspace.remote.configure":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["workspace_id"] as? String, workspaceID)
                XCTAssertEqual(params["destination"] as? String, "\(vmID)+cmux@vm-ssh.freestyle.sh")
                XCTAssertEqual(params["skip_daemon_bootstrap"] as? Bool, true)
                let terminalStartupCommand = params["terminal_startup_command"] as? String ?? ""
                let decodedStartupCommand = self.decodedReusableShellStartupCommand(terminalStartupCommand)
                XCTAssertFalse(terminalStartupCommand.isEmpty, "\(params)")
                XCTAssertTrue(decodedStartupCommand.contains("vm ssh-attach"), decodedStartupCommand)
                XCTAssertFalse(decodedStartupCommand.contains(":lease-token@"), decodedStartupCommand)
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
            case "workspace.select":
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceID])
            case "surface.list":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["workspace_id"] as? String, workspaceID)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "surfaces": [
                            [
                                "id": surfaceID,
                                "ref": "surface:sshd",
                                "index": 0,
                                "focused": true,
                            ],
                        ],
                    ]
                )
            case "surface.respawn":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["workspace_id"] as? String, workspaceID)
                XCTAssertEqual(params["surface_id"] as? String, surfaceID)
                let command = params["command"] as? String ?? ""
                let tmuxStartCommand = params["tmux_start_command"] as? String ?? ""
                let decodedStartupCommand = self.decodedReusableShellStartupCommand(command)
                XCTAssertEqual(command, tmuxStartCommand)
                XCTAssertTrue(decodedStartupCommand.contains("vm ssh-attach"), decodedStartupCommand)
                XCTAssertFalse(decodedStartupCommand.contains(":lease-token@"), decodedStartupCommand)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceID,
                        "surface_id": surfaceID,
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
            arguments: ["vm", "new"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("OK workspace=\(workspaceRef) target=\(vmID)+cmux@vm-ssh.freestyle.sh state=connecting"), result.stdout)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            [
                "vm.create",
                "vm.ssh_info",
                "workspace.list",
                "workspace.action",
                "workspace.action",
                "workspace.remote.configure",
                "workspace.select",
                "surface.list",
                "surface.respawn",
            ]
        )
    }

    func decodedReusableShellStartupCommand(_ command: String) -> String {
        var decoded = command
        for _ in 0..<4 {
            let next = decodedSingleEmbeddedStartupScript(decoded)
            guard next != decoded else {
                return decoded
            }
            decoded = next
        }
        return decoded
    }

    private func decodedSingleEmbeddedStartupScript(_ command: String) -> String {
        guard let marker = command.range(of: "printf %s ") else {
            return command
        }
        let suffix = command[marker.upperBound...]
        guard let end = suffix.firstIndex(where: { $0 == " " || $0 == "\n" || $0 == "'" }),
              end > suffix.startIndex else {
            return command
        }
        let encoded = String(suffix[..<end])
        guard let data = Data(base64Encoded: encoded),
              let decoded = String(data: data, encoding: .utf8) else {
            return command
        }
        return decoded
    }
}
