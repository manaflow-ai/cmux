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
            case "vm.ssh_info":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["id"] as? String, vmID)
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
            ["vm.ssh_info", "workspace.create", "workspace.rename", "workspace.remote.configure", "workspace.select"]
        )

        let createRequest = try XCTUnwrap(
            requests.first { $0["method"] as? String == "workspace.create" },
            "Expected workspace.create RPC request"
        )
        let createParams = try XCTUnwrap(createRequest["params"] as? [String: Any])
        let initialCommand = try XCTUnwrap(createParams["initial_command"] as? String)
        let initialScriptPath = initialCommand.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        let initialScript = try String(contentsOfFile: initialScriptPath, encoding: .utf8)
        XCTAssertTrue(initialScript.contains("cmux_ssh_cleanup_password() { rm -rf"), initialScript)
        XCTAssertTrue(initialScript.contains("cmux_ssh_session_end() {"), initialScript)
        XCTAssertTrue(initialScript.contains("cmux_ssh_cleanup_password;"), initialScript)
        XCTAssertTrue(initialScript.contains("-o NumberOfPasswordPrompts=1"), initialScript)
        XCTAssertTrue(initialScript.contains("-o LogLevel=QUIET"), initialScript)
        XCTAssertFalse(initialScript.contains("trap 'rm -rf \"$cmux_ssh_askpass_dir\"'"), initialScript)
        try? FileManager.default.removeItem(atPath: initialScriptPath)

        let configureRequest = try XCTUnwrap(
            requests.first { $0["method"] as? String == "workspace.remote.configure" },
            "Expected workspace.remote.configure RPC request"
        )
        let configureParams = try XCTUnwrap(configureRequest["params"] as? [String: Any])
        XCTAssertEqual(configureParams["workspace_id"] as? String, workspaceID)
        XCTAssertEqual(configureParams["destination"] as? String, "cmux@gateway.freestyle.sh")
        XCTAssertEqual(configureParams["managed_cloud_vm_id"] as? String, vmID)
        XCTAssertEqual(configureParams["port"] as? Int, 2222)
        XCTAssertEqual(configureParams["local_socket_path"] as? String, socketPath)
        XCTAssertEqual(configureParams["skip_daemon_bootstrap"] as? Bool, true)
        let terminalStartupCommand = try XCTUnwrap(configureParams["terminal_startup_command"] as? String)
        let decodedStartupCommand = decodedReusableShellStartupCommand(terminalStartupCommand)
        XCTAssertTrue(decodedStartupCommand.contains("vm ssh-attach"), decodedStartupCommand)
        XCTAssertFalse(decodedStartupCommand.contains("lease-token"), decodedStartupCommand)
        XCTAssertFalse(decodedStartupCommand.contains("bGVhc2UtdG9rZW4="), decodedStartupCommand)
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
        let surfaceID = "55555555-5555-5555-5555-555555555555"

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
            case "surface.list":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["workspace_id"] as? String, workspaceID)
                return self.surfaceListResponse(id: id, surfaceId: surfaceID)
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
            case "workspace.close":
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
            ["window.focus", "workspace.create", "surface.list", "workspace.remote.configure"]
        )
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
        XCTAssertTrue(result.stdout.contains("password:  <redacted; run `cmux vm ssh \(vmID)` to connect>"), result.stdout)
        XCTAssertFalse(result.stdout.contains("lease-token"), result.stdout)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["vm.ssh_info"]
        )
    }
}
