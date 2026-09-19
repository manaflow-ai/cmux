import XCTest
import Darwin

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CLINotifyProcessIntegrationRegressionTests {
    func testActionsListDoesNotRequireSocket() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("actions-list-missing")
        unlink(socketPath)

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["actions", "list"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("hexclave/stack-auth:fresh-env"), result.stdout)
        XCTAssertTrue(result.stdout.contains("Fresh Stack Auth environment"), result.stdout)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
    }

    func testActionsRunUsageDoesNotRequireSocket() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("actions-run-missing")
        unlink(socketPath)

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["actions", "run"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("Usage: cmux actions run <action>"), result.stderr)
        XCTAssertTrue(result.stderr.contains("hexclave/stack-auth:fresh-env"), result.stderr)
        XCTAssertEqual(result.stdout, "")
    }

    func testActionsRunHelpDoesNotRequireSocket() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("actions-run-help-missing")
        unlink(socketPath)

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        for args in [["actions", "run", "--help"], ["actions", "run", "help"]] {
            let result = runProcess(
                executablePath: cliPath,
                arguments: args,
                environment: environment,
                timeout: 5
            )

            XCTAssertFalse(result.timedOut, result.stderr)
            XCTAssertEqual(result.status, 0, result.stderr)
            XCTAssertTrue(result.stdout.contains("Usage: cmux actions run <action>"), result.stdout)
            XCTAssertTrue(result.stdout.contains("hexclave/stack-auth:fresh-env"), result.stdout)
            XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        }
    }

    func testActionsRunRefNamedHelpStillUsesSocket() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("actions-run-ref-help")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let homeURL = try makeTemporaryCLIHome("actions-run-ref-help")

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: homeURL)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            guard method == "actions.run" else {
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "Unexpected method \(method)"])
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            XCTAssertEqual(params["action"] as? String, "hexclave/stack-auth:fresh-env")
            XCTAssertEqual(params["ref"] as? String, "help")
            XCTAssertEqual(params["dry_run"] as? Bool, true)
            return self.v2Response(
                id: id,
                ok: true,
                result: [
                    "action": "hexclave/stack-auth:fresh-env",
                    "title": "Fresh Stack Auth environment",
                    "ref": "help",
                    "mode": "full",
                    "dry_run": true,
                    "cache": [
                        "hit": false,
                    ],
                    "setup_ran": false,
                    "started": false,
                    "ports": [],
                    "instructions": [],
                ]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["HOME"] = homeURL.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["actions", "run", "hexclave/stack-auth:fresh-env", "--ref", "help", "--dry-run"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.split(separator: "\n").contains { line in
            line.replacingOccurrences(of: " ", with: "") == "ref:help"
        }, result.stdout)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["actions.run"]
        )
        XCTAssertEqual(try vmCreateIdempotencyRecordCount(homeURL: homeURL), 0)
    }

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

    func testVMSSHAliasUsesCmuxRemoteWhenProviderSSHIsUnmanaged() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-ssh-freestyle-remote")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let vmID = "vm-freestyle-remote"

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
                        "code": "vm_attach_transport_unsupported",
                        "message": "Freestyle provider SSH is unmanaged; use cmux-remote for a managed session.",
                    ]
                )
            case "vm.cmux_remote_info":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "route": "ws://10.0.0.8:1337/v1/link",
                        "token": "route-token",
                        "session": "cloud",
                    ]
                )
            case "workspace.create":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": "workspace-cloud",
                        "workspace_ref": "workspace:cloud",
                    ]
                )
            case "workspace.cloud_vm_bind":
                let result: [String: Any] = [
                    "workspace_id": "workspace-cloud",
                    "remote_workspace_id": (payload["params"] as? [String: Any])?["remote_workspace_id"] ?? NSNull(),
                ]
                return self.v2Response(id: id, ok: true, result: result)
            case "surface.new_terminal":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "terminal_id": "term_cloud",
                        "remote_workspace_id": "remote-workspace",
                        "surface_id": "surface-cloud",
                    ]
                )
            case "workspace.select":
                return self.v2Response(id: id, ok: true, result: ["workspace_id": "workspace-cloud"])
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
            arguments: ["vm", "ssh", vmID],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stdout + result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("transport=cmux-remote"), result.stdout)
        XCTAssertTrue(result.stdout.contains("terminal=term_cloud"), result.stdout)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["vm.ssh_info", "vm.cmux_remote_info", "workspace.create", "workspace.cloud_vm_bind", "surface.new_terminal", "workspace.cloud_vm_bind", "workspace.select"]
        )
        let bindCommands = state.commands
            .compactMap { self.jsonObject($0) }
            .filter { $0["method"] as? String == "workspace.cloud_vm_bind" }
        XCTAssertEqual(bindCommands.count, 2)
        XCTAssertNil((bindCommands[0]["params"] as? [String: Any])?["remote_workspace_id"])
        XCTAssertEqual(
            (bindCommands[1]["params"] as? [String: Any])?["remote_workspace_id"] as? String,
            "remote-workspace"
        )
    }

    func testVMSSHAliasPreservesProviderFailureThatMentionsUnsupportedSSH() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-ssh-provider-failure")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let vmID = "vm-freestyle-provider-failure"

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
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected method \(method)"]
                )
            }
            return self.v2Response(
                id: id,
                ok: false,
                error: [
                    "code": "vm_error",
                    "message": "Freestyle SSH gateway rejected this credential as not supported.",
                ]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "ssh", vmID],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stdout + result.stderr)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("rejected this credential"), result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["vm.ssh_info"]
        )
    }

    func testVMSSHAliasDoesNotFallbackForGenericHTTP404() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-ssh-generic-404")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let vmID = "vm-freestyle-generic-404"

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
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected", "message": "fallback must not probe cmux-remote"]
                )
            }
            return self.v2Response(
                id: id,
                ok: false,
                error: [
                    "code": "vm_error",
                    "message": "provider metadata endpoint returned HTTP 404.",
                    "data": ["http_status": 404],
                ]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "ssh", vmID],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stdout + result.stderr)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("provider metadata endpoint returned HTTP 404"), result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["vm.ssh_info"]
        )
    }

    func testActionsRunDryRunUsesActionsSocketMethod() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("actions-run-dry")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let homeURL = try makeTemporaryCLIHome("actions-run-dry")

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: homeURL)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            guard method == "actions.run" else {
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "Unexpected method \(method)"])
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            XCTAssertEqual(params["action"] as? String, "hexclave/stack-auth:fresh-env")
            XCTAssertEqual(params["ref"] as? String, "dev")
            XCTAssertEqual(params["mode"] as? String, "basic")
            XCTAssertEqual(params["dry_run"] as? Bool, true)
            XCTAssertEqual(params["no_cache"] as? Bool, false)
            XCTAssertNotNil(params["idempotency_key"] as? String)
            return self.v2Response(
                id: id,
                ok: true,
                result: [
                    "action": "hexclave/stack-auth:fresh-env",
                    "title": "Fresh Stack Auth environment",
                    "ref": "dev",
                    "mode": "basic",
                    "dry_run": true,
                    "cache": [
                        "hit": false,
                    ],
                    "setup_ran": false,
                    "started": false,
                    "ports": [],
                    "instructions": [],
                ]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["HOME"] = homeURL.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["actions", "run", "hexclave/stack-auth:fresh-env", "--ref", "dev", "--mode", "basic", "--dry-run"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("Fresh Stack Auth environment"), result.stdout)
        XCTAssertTrue(result.stdout.contains("Dry run complete. No Cloud VM was created."), result.stdout)
        XCTAssertFalse(result.stdout.contains("cmux-actions-stack-auth-test"), result.stdout)
        XCTAssertFalse(result.stdout.contains("docker compose version"), result.stdout)
        XCTAssertFalse(result.stdout.contains("pnpm run dev:basic"), result.stdout)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["actions.run"]
        )
        XCTAssertEqual(try vmCreateIdempotencyRecordCount(homeURL: homeURL), 0)
    }

    func testActionsRunRejectsInvalidPortResponses() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("actions-run-invalid-port")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let homeURL = try makeTemporaryCLIHome("actions-run-invalid-port")

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: homeURL)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            guard method == "actions.run" else {
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "Unexpected method \(method)"])
            }
            return self.v2Response(
                id: id,
                ok: true,
                result: [
                    "action": "hexclave/stack-auth:fresh-env",
                    "title": "Fresh Stack Auth environment",
                    "ref": "dev",
                    "mode": "basic",
                    "dry_run": true,
                    "cache": [
                        "hit": false,
                    ],
                    "setup_ran": false,
                    "started": false,
                    "ports": [
                        ["name": "Bad", "port": 8_100, "url": "http://localhost:8101"],
                    ],
                    "instructions": [],
                ]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["HOME"] = homeURL.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["actions", "run", "hexclave/stack-auth:fresh-env", "--dry-run"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("invalid port URL"), result.stderr)
        XCTAssertTrue(result.stderr.contains("Bad"), result.stderr)
        XCTAssertTrue(result.stderr.contains("8100"), result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["actions.run"]
        )
        XCTAssertEqual(try vmCreateIdempotencyRecordCount(homeURL: homeURL), 0)
    }

    func testActionsRunKeepsIdempotencyWhenAttachFails() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("actions-run-attach-fail")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let homeURL = try makeTemporaryCLIHome("actions-run-attach-fail")
        let vmID = "vm-action-attach-fail"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: homeURL)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            switch method {
            case "actions.run":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "action": "hexclave/stack-auth:fresh-env",
                        "title": "Fresh Stack Auth environment",
                        "ref": "dev",
                        "mode": "basic",
                        "dry_run": false,
                        "vm_id": vmID,
                        "cache": [
                            "hit": true,
                        ],
                        "setup_ran": false,
                        "started": true,
                        "ports": [],
                        "instructions": [],
                    ]
                )
            case "vm.attach_info":
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "attach_failed", "message": "attach unavailable"]
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
        environment["HOME"] = homeURL.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["actions", "run", "hexclave/stack-auth:fresh-env", "--mode", "basic"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["actions.run", "vm.attach_info"]
        )
        XCTAssertEqual(try vmCreateIdempotencyRecordCount(homeURL: homeURL), 1)
    }

    func testActionsRunTimeoutCoversColdStartBudget() {
        XCTAssertGreaterThanOrEqual(CloudActionRunTimeouts.runResponseSeconds, 30 * 60)
        XCTAssertLessThanOrEqual(CloudActionRunTimeouts.runResponseSeconds, 40 * 60)
        XCTAssertEqual(VMClient.actionRunTimeoutSeconds, CloudActionRunTimeouts.runResponseSeconds)
        XCTAssertEqual(TerminalController.actionRunSocketTimeoutSeconds, CloudActionRunTimeouts.runResponseSeconds)
    }

    private func makeTemporaryCLIHome(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func vmCreateIdempotencyRecordCount(homeURL: URL) throws -> Int {
        let url = homeURL
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("vm-create-idempotency.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return 0
        }
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        let records = object?["records"] as? [String: Any]
        return records?.count ?? 0
    }
}
