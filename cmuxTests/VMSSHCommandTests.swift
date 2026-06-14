import XCTest
import Darwin

extension CLINotifyProcessIntegrationRegressionTests {
    func testVMSSHOpensManagedWorkspaceThroughSharedSSHPath() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-ssh")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let vmID = "vm-test-1234567890"
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let workspaceRef = "workspace:vm"
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
            case "vm.attach_info":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["id"] as? String, vmID)
                XCTAssertEqual(params["require_daemon"] as? Bool, true)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "transport": "ssh",
                        "host": "gateway.freestyle.sh",
                        "port": 2222,
                        "username": "cmux",
                        "credential": [
                            "kind": "password",
                            "value": "lease-token",
                        ],
                    ]
                )
            case "workspace.create":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["window_id"] as? String, windowID)
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
            arguments: ["vm", "ssh", vmID, "--window", windowID],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK workspace=\(workspaceRef) target=cmux@gateway.freestyle.sh state=connecting\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)

        let requests = try state.commands.map { line -> [String: Any] in
            let data = try XCTUnwrap(line.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
        }
        XCTAssertEqual(
            requests.compactMap { $0["method"] as? String },
            ["vm.attach_info", "workspace.create", "workspace.rename", "workspace.remote.configure", "workspace.select"]
        )

        let configureRequest = try XCTUnwrap(
            requests.first { $0["method"] as? String == "workspace.remote.configure" },
            "Expected workspace.remote.configure RPC request"
        )
        let configureParams = try XCTUnwrap(configureRequest["params"] as? [String: Any])
        XCTAssertEqual(configureParams["workspace_id"] as? String, workspaceID)
        XCTAssertEqual(configureParams["destination"] as? String, "cmux@gateway.freestyle.sh")
        XCTAssertEqual(configureParams["port"] as? Int, 2222)
        XCTAssertEqual(configureParams["local_socket_path"] as? String, socketPath)
        XCTAssertEqual(configureParams["skip_daemon_bootstrap"] as? Bool, true)
        XCTAssertNotNil(configureParams["terminal_startup_command"] as? String)
        XCTAssertNotNil(configureParams["relay_port"] as? Int)
    }

    func testSSHCommandGlobalWindowOverridesCallerEnvironment() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("ssh-global-window")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let workspaceRef = "workspace:8"
        let windowID = "22222222-2222-2222-2222-222222222222"
        let callerWorkspaceID = "33333333-3333-3333-3333-333333333333"
        let callerSurfaceID = "44444444-4444-4444-4444-444444444444"

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
            case "window.focus":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["window_id"] as? String, windowID)
                return self.v2Response(id: id, ok: true, result: ["window_id": windowID])
            case "workspace.create":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["window_id"] as? String, windowID)
                XCTAssertNil(params["workspace_id"])
                XCTAssertNil(params["surface_id"])
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceID,
                        "window_id": windowID,
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
        environment["CMUX_WORKSPACE_ID"] = callerWorkspaceID
        environment["CMUX_SURFACE_ID"] = callerSurfaceID
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "--window", windowID,
                "ssh",
                "--no-focus",
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
            ["window.focus", "workspace.create", "workspace.remote.configure"]
        )
    }

    func testSSHViaTshRejectsIdentityOption() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("ssh-via-tsh-identity")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        // The server must never be asked to create a workspace: the CLI should
        // fail fast before any RPC because tsh cannot honor an identity file. Use a
        // detached server (no XCTestExpectation to wait on) since no response is sent.
        startDetachedMockServer(listenerFD: listenerFD, state: state) { line in
            self.v2Response(
                id: (self.jsonObject(line)?["id"] as? String) ?? "unknown",
                ok: false,
                error: ["code": "unexpected", "message": "no RPC expected"]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        environment.removeValue(forKey: "CMUX_WORKSPACE_ID")
        environment.removeValue(forKey: "CMUX_SURFACE_ID")

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["ssh", "--via", "tsh", "--identity", "/tmp/id_ed25519", "tester@example.com"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(result.status, 0, "tsh transport must reject --identity instead of silently dropping it")
        XCTAssertTrue(result.stdout.isEmpty, result.stdout)
        XCTAssertTrue(result.stderr.lowercased().contains("identity"), result.stderr)
        // Fail-fast: no workspace should be created when the request is rejected.
        XCTAssertFalse(
            state.commands.contains { (self.jsonObject($0)?["method"] as? String) == "workspace.create" },
            "Expected no workspace.create RPC for a rejected tsh request"
        )
    }

    func testSSHViaTshOpensInteractiveWorkspaceWithoutRelay() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("ssh-via-tsh")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let workspaceRef = "workspace:1"
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
        // A tsh workspace must not inherit caller workspace/surface context that would
        // turn into an extra focus RPC and perturb the asserted call sequence.
        environment.removeValue(forKey: "CMUX_WORKSPACE_ID")
        environment.removeValue(forKey: "CMUX_SURFACE_ID")

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["ssh", "--via", "tsh", "--no-focus", "tester@example.com"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            result.stdout,
            "OK workspace=\(workspaceRef) target=tester@example.com transport=tsh\n"
        )
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)

        let requests = try state.commands.map { line -> [String: Any] in
            let data = try XCTUnwrap(line.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
        }
        // Interactive tsh is a plain terminal running `tsh ssh`: no relay/daemon wiring,
        // so no workspace.remote.configure and (with --no-focus) no workspace.select.
        XCTAssertEqual(
            requests.compactMap { $0["method"] as? String },
            ["workspace.create"]
        )

        let createRequest = try XCTUnwrap(
            requests.first { $0["method"] as? String == "workspace.create" },
            "Expected workspace.create RPC request"
        )
        let createParams = try XCTUnwrap(createRequest["params"] as? [String: Any])
        let initialCommand = try XCTUnwrap(createParams["initial_command"] as? String)
        XCTAssertTrue(initialCommand.contains("tsh ssh"), initialCommand)
        XCTAssertTrue(initialCommand.contains("tester@example.com"), initialCommand)
        // None of the OpenSSH-only machinery tsh cannot honor should leak into the command.
        XCTAssertFalse(initialCommand.contains("/usr/bin/ssh"), initialCommand)
        XCTAssertFalse(initialCommand.contains("RemoteCommand"), initialCommand)
        XCTAssertFalse(initialCommand.contains("ControlMaster"), initialCommand)
        XCTAssertFalse(initialCommand.contains("PermitLocalCommand"), initialCommand)
    }

    func testVMSSHInfoRemainsPrintOnly() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-info")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let vmID = "vm-test-ssh-info"

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
            guard method == "vm.ssh_info" else {
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "Unexpected method \(method)"])
            }
            return self.v2Response(
                id: id,
                ok: true,
                result: [
                    "host": "gateway.freestyle.sh",
                    "port": 2222,
                    "username": "cmux",
                    "credential": [
                        "kind": "password",
                        "value": "lease-token",
                    ],
                ]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "ssh-info", vmID],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("ssh cmux@gateway.freestyle.sh -p 2222"), result.stdout)
        XCTAssertTrue(result.stdout.contains("password:  lease-token"), result.stdout)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["vm.ssh_info"]
        )
    }
}
