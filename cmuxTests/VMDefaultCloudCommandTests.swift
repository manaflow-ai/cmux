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
                let params = payload["params"] as? [String: Any] ?? [:]
                let initialCommand = params["initial_command"] as? String ?? ""
                let decodedInitialCommand = self.decodedReusableShellStartupCommand(initialCommand)
                XCTAssertTrue(decodedInitialCommand.contains("vm-pty-attach"), decodedInitialCommand)
                XCTAssertTrue(decodedInitialCommand.contains("--default-freestyle-sshd"), decodedInitialCommand)
                XCTAssertTrue(decodedInitialCommand.contains("CMUX_CLOUD_RECONNECT_ATTEMPT"), decodedInitialCommand)
                XCTAssertFalse(decodedInitialCommand.contains("[cmux] ssh exited with status"), decodedInitialCommand)
                XCTAssertFalse(decodedInitialCommand.contains(":lease-token@"), decodedInitialCommand)
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
                XCTAssertEqual(params["managed_cloud_vm_id"] as? String, vmID)
                XCTAssertEqual(params["skip_daemon_bootstrap"] as? Bool, true)
                let terminalStartupCommand = params["terminal_startup_command"] as? String ?? ""
                let decodedStartupCommand = self.decodedReusableShellStartupCommand(terminalStartupCommand)
                XCTAssertFalse(terminalStartupCommand.isEmpty, "\(params)")
                XCTAssertTrue(decodedStartupCommand.contains("vm-pty-attach"), decodedStartupCommand)
                XCTAssertTrue(decodedStartupCommand.contains("--default-freestyle-sshd"), decodedStartupCommand)
                XCTAssertTrue(decodedStartupCommand.contains("CMUX_CLOUD_RECONNECT_ATTEMPT"), decodedStartupCommand)
                XCTAssertFalse(decodedStartupCommand.contains("Cloud VM reconnecting"), decodedStartupCommand)
                XCTAssertFalse(decodedStartupCommand.contains("cmux_freestyle_notify_reconnect"), decodedStartupCommand)
                XCTAssertFalse(decodedStartupCommand.contains("[cmux] ssh exited with status"), decodedStartupCommand)
                XCTAssertFalse(decodedStartupCommand.contains(":lease-token@"), decodedStartupCommand)
                XCTAssertEqual(params["preserve_after_terminal_exit"] as? Bool, true)
                XCTAssertEqual(params["persistent_daemon_slot"] as? String, "cmux-default-freestyle-sshd-v1")
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
        XCTAssertTrue(result.stdout.contains("OK workspace=\(workspaceRef) target=cloud VM state=connecting"), result.stdout)
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
                                "pinned": true,
                                "remote": [
                                    "managed_cloud_vm_id": vmID,
                                    "persistent_daemon_slot": "cmux-default-freestyle-sshd-v1",
                                ],
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
                XCTAssertEqual(params["managed_cloud_vm_id"] as? String, vmID)
                XCTAssertEqual(params["skip_daemon_bootstrap"] as? Bool, true)
                let terminalStartupCommand = params["terminal_startup_command"] as? String ?? ""
                let decodedStartupCommand = self.decodedReusableShellStartupCommand(terminalStartupCommand)
                XCTAssertFalse(terminalStartupCommand.isEmpty, "\(params)")
                XCTAssertTrue(decodedStartupCommand.contains("vm-pty-attach"), decodedStartupCommand)
                XCTAssertTrue(decodedStartupCommand.contains("--default-freestyle-sshd"), decodedStartupCommand)
                XCTAssertTrue(decodedStartupCommand.contains("CMUX_CLOUD_RECONNECT_ATTEMPT"), decodedStartupCommand)
                XCTAssertFalse(decodedStartupCommand.contains("Cloud VM reconnecting"), decodedStartupCommand)
                XCTAssertFalse(decodedStartupCommand.contains("cmux_freestyle_notify_reconnect"), decodedStartupCommand)
                XCTAssertFalse(decodedStartupCommand.contains("[cmux] ssh exited with status"), decodedStartupCommand)
                XCTAssertFalse(decodedStartupCommand.contains(":lease-token@"), decodedStartupCommand)
                XCTAssertEqual(params["preserve_after_terminal_exit"] as? Bool, true)
                XCTAssertEqual(params["persistent_daemon_slot"] as? String, "cmux-default-freestyle-sshd-v1")
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
                                "initial_command": NSNull(),
                                "title": "lawrence@lawrences-MacBook-Pro-2:~/fun",
                            ],
                        ],
                    ]
                )
            case "workspace.remote.reconnect":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["workspace_id"] as? String, workspaceID)
                XCTAssertEqual(params["surface_id"] as? String, surfaceID)
                XCTAssertNil(params["command"])
                XCTAssertNil(params["tmux_start_command"])
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
        XCTAssertTrue(result.stdout.contains("OK workspace=\(workspaceRef) target=cloud VM state=connecting"), result.stdout)
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
                "workspace.remote.reconnect",
            ]
        )
    }

    func testVMNewDefaultDoesNotReuseTitleOnlySSHDWorkspace() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-new-sshd-title-collision")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let vmID = "vm-persistent-freestyle"
        let localWorkspaceID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let createdWorkspaceID = "11111111-1111-1111-1111-111111111111"
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
                                "id": localWorkspaceID,
                                "window_id": windowID,
                                "title": "sshd",
                                "pinned": true,
                                "remote": [
                                    "enabled": false,
                                    "managed_cloud_vm_id": NSNull(),
                                    "persistent_daemon_slot": NSNull(),
                                ],
                            ],
                        ],
                    ]
                )
            case "workspace.create":
                let params = payload["params"] as? [String: Any] ?? [:]
                let initialCommand = params["initial_command"] as? String ?? ""
                XCTAssertTrue(self.decodedReusableShellStartupCommand(initialCommand).contains("vm-pty-attach"))
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": createdWorkspaceID,
                        "workspace_ref": workspaceRef,
                        "window_id": windowID,
                    ]
                )
            case "workspace.rename":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["workspace_id"] as? String, createdWorkspaceID)
                XCTAssertEqual(params["title"] as? String, "sshd")
                return self.v2Response(id: id, ok: true, result: ["workspace_id": createdWorkspaceID])
            case "workspace.action":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["workspace_id"] as? String, createdWorkspaceID)
                XCTAssertEqual(params["window_id"] as? String, windowID)
                let action = params["action"] as? String
                XCTAssertTrue(action == "pin" || action == "move_top")
                return self.v2Response(id: id, ok: true, result: ["workspace_id": createdWorkspaceID, "action": action ?? ""])
            case "workspace.remote.configure":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["workspace_id"] as? String, createdWorkspaceID)
                XCTAssertEqual(params["managed_cloud_vm_id"] as? String, vmID)
                XCTAssertEqual(params["persistent_daemon_slot"] as? String, "cmux-default-freestyle-sshd-v1")
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": createdWorkspaceID,
                        "workspace_ref": workspaceRef,
                        "remote": [
                            "enabled": true,
                            "state": "connecting",
                        ],
                    ]
                )
            case "workspace.select":
                return self.v2Response(id: id, ok: true, result: ["workspace_id": createdWorkspaceID])
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
        XCTAssertTrue(result.stdout.contains("OK workspace=\(workspaceRef) target=cloud VM state=connecting"), result.stdout)
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

    func testDefaultFreestyleSSHAttachScopesTmuxSessionToCallerSurface() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-attach-surface-tmux")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let vmID = "vm-persistent-freestyle"
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let surfaceID = "33333333-3333-3333-3333-333333333333"
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-fake-ssh-\(UUID().uuidString)", isDirectory: true)
        let fakeSSHPath = tempDirectory.appendingPathComponent("ssh").path
        let capturedArgsPath = tempDirectory.appendingPathComponent("ssh-args").path

        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        : > "$CMUX_FAKE_SSH_ARGS"
        for arg in "$@"; do
          printf '%s\\n' "$arg" >> "$CMUX_FAKE_SSH_ARGS"
        done
        exit 0
        """.write(toFile: fakeSSHPath, atomically: true, encoding: .utf8)
        chmod(fakeSSHPath, 0o755)

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }

            switch method {
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
            case "vm.exec":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["id"] as? String, vmID)
                return self.v2Response(id: id, ok: true, result: ["exit_code": 0, "stdout": "", "stderr": ""])
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
        environment["CMUX_WORKSPACE_ID"] = workspaceID
        environment["CMUX_SURFACE_ID"] = surfaceID
        environment["CMUX_CLOUD_TMUX_SESSION"] = "cmux-cloud"
        environment["CMUX_FAKE_SSH_ARGS"] = capturedArgsPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        environment["PATH"] = "\(tempDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "ssh-attach", "--id", vmID, "--default-freestyle-sshd"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)

        let capturedArgs = try String(contentsOfFile: capturedArgsPath, encoding: .utf8)
        let decodedRemoteBootstrap = try XCTUnwrap(decodedFirstEmbeddedStartupScript(capturedArgs), capturedArgs)
        XCTAssertTrue(decodedRemoteBootstrap.contains("export CMUX_WORKSPACE_ID='\(workspaceID)'"), decodedRemoteBootstrap)
        XCTAssertTrue(decodedRemoteBootstrap.contains("export CMUX_SURFACE_ID='\(surfaceID)'"), decodedRemoteBootstrap)
        XCTAssertFalse(
            decodedRemoteBootstrap.contains("apt-get"),
            "interactive SSH attach must not install packages before the prompt: \(decodedRemoteBootstrap)"
        )
        XCTAssertFalse(
            decodedRemoteBootstrap.contains("sudo"),
            "interactive SSH attach must not depend on foreground sudo before the prompt: \(decodedRemoteBootstrap)"
        )
        XCTAssertFalse(
            decodedRemoteBootstrap.contains("ln -sf /usr/local/bin/cmuxd-remote /usr/local/bin/cmux"),
            "interactive SSH attach must leave cmux CLI provisioning to vm.exec: \(decodedRemoteBootstrap)"
        )
        XCTAssertTrue(
            decodedRemoteBootstrap.contains("cmux-cloud-$cmux_cloud_tty_scope"),
            decodedRemoteBootstrap
        )
        XCTAssertTrue(
            decodedRemoteBootstrap.contains("unset CMUX_CLOUD_TMUX_SESSION"),
            decodedRemoteBootstrap
        )
        XCTAssertTrue(decodedRemoteBootstrap.contains("if [ \"$cmux_cloud_tty_scope\" = default ]; then"), decodedRemoteBootstrap)
        XCTAssertTrue(decodedRemoteBootstrap.contains("cmux_tmux_status=$?"), decodedRemoteBootstrap)
        XCTAssertTrue(decodedRemoteBootstrap.contains("exec zsh -l"), decodedRemoteBootstrap)
    }

    func testDefaultFreestyleSSHAttachRejectedCredentialDoesNotExposePasswordPrompt() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-attach-rejected-credential")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let vmID = "vm-persistent-freestyle"
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-fake-ssh-\(UUID().uuidString)", isDirectory: true)
        let fakeSSHPath = tempDirectory.appendingPathComponent("ssh").path

        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        stty -echo 2>/dev/null || true
        printf "lease@vm-ssh.freestyle.sh's password: " >&2
        IFS= read -r _cmux_password
        printf '\\nPermission denied, please try again.\\n' >&2
        printf "lease@vm-ssh.freestyle.sh's password: " >&2
        IFS= read -r _cmux_password_again
        exit 255
        """.write(toFile: fakeSSHPath, atomically: true, encoding: .utf8)
        chmod(fakeSSHPath, 0o755)

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }

            switch method {
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
                            "value": "expired-lease-token",
                        ],
                    ]
                )
            case "vm.exec":
                return self.v2Response(id: id, ok: true, result: ["exit_code": 0, "stdout": "", "stderr": ""])
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
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_CLOUD_TMUX_SESSION"] = "cmux-cloud"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        environment["PATH"] = "\(tempDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "ssh-attach", "--id", vmID, "--default-freestyle-sshd"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stdout + result.stderr)
        XCTAssertEqual(result.status, 255, result.stdout + result.stderr)
        XCTAssertTrue(result.stderr.contains("Cloud VM SSH credential was rejected"), result.stderr)
        XCTAssertFalse(result.stderr.lowercased().contains("password:"), result.stderr)
    }

    func testDefaultFreestyleSSHAttachRelaysAfterDelayedSuccessfulCredential() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-attach-delayed-success")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let vmID = "vm-persistent-freestyle"
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-fake-ssh-\(UUID().uuidString)", isDirectory: true)
        let fakeSSHPath = tempDirectory.appendingPathComponent("ssh").path

        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        printf "lease@vm-ssh.freestyle.sh's password: " >&2
        IFS= read -r _cmux_password
        sleep 9
        printf 'CMUX_DELAYED_RELAY_OK\\n'
        exit 0
        """.write(toFile: fakeSSHPath, atomically: true, encoding: .utf8)
        chmod(fakeSSHPath, 0o755)

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }

            switch method {
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
            case "vm.exec":
                return self.v2Response(id: id, ok: true, result: ["exit_code": 0, "stdout": "", "stderr": ""])
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
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_CLOUD_TMUX_SESSION"] = "cmux-cloud"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        environment["PATH"] = "\(tempDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "ssh-attach", "--id", vmID, "--default-freestyle-sshd"],
            environment: environment,
            timeout: 15
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stdout + result.stderr)
        XCTAssertEqual(result.status, 0, result.stdout + result.stderr)
        XCTAssertTrue(result.stdout.contains("CMUX_DELAYED_RELAY_OK"), result.stdout + result.stderr)
        XCTAssertFalse(result.stderr.contains("credential prompt timed out"), result.stderr)
        XCTAssertFalse(result.stderr.lowercased().contains("password:"), result.stderr)
    }

    func testDefaultFreestyleSSHAttachFailsClosedWhenVMIsMissing() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-ssh-attach-missing")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let vmID = "missing-default-vm"

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
            case "vm.ssh_info":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["id"] as? String, vmID)
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "vm_not_found", "message": "The requested Cloud VM was not found."]
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
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "ssh-attach", "--id", vmID, "--default-freestyle-sshd"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("no longer exists"), result.stderr)
        XCTAssertTrue(result.stderr.contains("cmux vm new"), result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["vm.ssh_info"]
        )
    }

    func testDefaultFreestyleSSHAttachReportsLocalServerRetryCountdown() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-ssh-attach-local-down")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let vmID = "vm-persistent-freestyle"

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
            case "vm.ssh_info":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["id"] as? String, vmID)
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: [
                        "code": "backend_unreachable",
                        "message": """
                        Cannot reach the cmux Cloud VM service at http://localhost:3777.

                        Details:
                          Could not connect to the server.
                        """,
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
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        environment["CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_LIMIT"] = "1"
        environment["CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_DELAY_SECONDS"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "ssh-attach", "--id", vmID, "--default-freestyle-sshd"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stdout + result.stderr)
        XCTAssertNotEqual(result.status, 0, result.stdout + result.stderr)
        XCTAssertTrue(
            result.stderr.contains("Waiting for the local cmux web server at http://localhost:3777."),
            result.stderr
        )
        XCTAssertTrue(result.stderr.contains("Retrying in 1s (attempt 1/1)."), result.stderr)
        XCTAssertFalse(result.stderr.contains("Cloud VM service is temporarily unavailable; retrying"), result.stderr)
        XCTAssertEqual(
            state.snapshot().compactMap { self.jsonObject($0)?["method"] as? String },
            ["vm.ssh_info", "vm.ssh_info"]
        )
    }

    func testDefaultFreestyleSSHAttachHonorsGenericCloudRetryEnvironment() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-ssh-attach-cloud-retry-env")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let vmID = "vm-cloud-retry-env"

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
            case "vm.ssh_info":
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: [
                        "code": "vm_cloud_service_unavailable",
                        "message": "The Cloud VM service could not complete this request.",
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
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLOUD_ATTACH_RETRY_LIMIT"] = "1"
        environment["CMUX_CLOUD_ATTACH_RETRY_DELAY_SECONDS"] = "0"
        environment["CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_LIMIT"] = "120"
        environment["CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_DELAY_SECONDS"] = "2"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "ssh-attach", "--id", vmID, "--default-freestyle-sshd"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stdout + result.stderr)
        XCTAssertNotEqual(result.status, 0, result.stdout + result.stderr)
        XCTAssertTrue(result.stderr.contains("Retrying in 0s (attempt 1/1)."), result.stderr)
        XCTAssertEqual(
            state.snapshot().compactMap { self.jsonObject($0)?["method"] as? String },
            ["vm.ssh_info", "vm.ssh_info"]
        )
    }

    func testDefaultFreestyleSSHAttachHidesPersistentRetryLimitInCountdown() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-ssh-attach-local-down-persistent")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let vmID = "vm-persistent-freestyle"

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
            case "vm.ssh_info":
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: [
                        "code": "backend_unreachable",
                        "message": """
                        Cannot reach the cmux Cloud VM service at http://localhost:3777.

                        Details:
                          Could not connect to the server.
                        """,
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
        environment["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        environment["CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_LIMIT"] = "86400"
        environment["CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_DELAY_SECONDS"] = "0.1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "ssh-attach", "--id", vmID, "--default-freestyle-sshd"],
            environment: environment,
            timeout: 1
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertTrue(result.timedOut, result.stdout + result.stderr)
        XCTAssertTrue(result.stderr.contains("Retrying in 0.1s (attempt 1)."), result.stderr)
        XCTAssertFalse(result.stderr.contains("attempt 1/86400"), result.stderr)
        XCTAssertGreaterThanOrEqual(
            state.snapshot().compactMap { self.jsonObject($0)?["method"] as? String }.count,
            1
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

    private func decodedFirstEmbeddedStartupScript(_ command: String) -> String? {
        for markerText in ["printf %s ", "printf %%s "] {
            guard let marker = command.range(of: markerText) else {
                continue
            }
            let suffix = command[marker.upperBound...]
            guard let end = suffix.firstIndex(where: { $0 == " " || $0 == "\n" || $0 == "'" }),
                  end > suffix.startIndex else {
                continue
            }
            let encoded = String(suffix[..<end])
            guard let data = Data(base64Encoded: encoded),
                  let decoded = String(data: data, encoding: .utf8) else {
                continue
            }
            return decoded
        }
        return nil
    }
}
