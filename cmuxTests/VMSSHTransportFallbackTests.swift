import XCTest
import Darwin

extension CLINotifyProcessIntegrationRegressionTests {
    func testVMSSHAliasUsesCmuxRemoteWhenProviderSSHIsUnmanaged() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-ssh-freestyle-remote")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let vmID = "vm-freestyle-remote"
        let homeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vm-ssh-home-\(UUID().uuidString)", isDirectory: true)

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
            case "vm.ssh_info":
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: [
                        "code": "vm_error",
                        "message": "Freestyle provider SSH is unmanaged; use cmux-remote for a managed session.",
                        "data": ["backend_code": "vm_attach_transport_unsupported", "http_status": 409],
                    ]
                )
            case "vm.cmux_remote_info":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "route": "ws://10.0.0.8:1337/v1/link",
                        "session": "cloud",
                        "trusted_carrier": true,
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
            case "surface.catalog":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["machine"] as? String, vmID)
                return self.v2Response(id: id, ok: true, result: [
                    "machines": [["id": vmID, "link_state": "connected", "remote_workspaces": []]],
                    "resources": [],
                ])
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
        // The successful fallback persists the trusted route via NSHomeDirectory().
        environment["CFFIXED_USER_HOME"] = homeURL.path

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
            ["vm.ssh_info", "vm.cmux_remote_info", "workspace.create", "workspace.cloud_vm_bind", "surface.catalog", "surface.new_terminal", "workspace.cloud_vm_bind", "workspace.select"]
        )
        let bindCommands = state.commands
            .compactMap { self.jsonObject($0) }
            .filter { $0["method"] as? String == "workspace.cloud_vm_bind" }
        XCTAssertEqual(bindCommands.count, 2)
        let initialBind = try XCTUnwrap(bindCommands.first)
        let terminalBind = try XCTUnwrap(bindCommands.dropFirst().first)
        XCTAssertNil((initialBind["params"] as? [String: Any])?["remote_workspace_id"])
        XCTAssertEqual(
            (terminalBind["params"] as? [String: Any])?["remote_workspace_id"] as? String,
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
}
