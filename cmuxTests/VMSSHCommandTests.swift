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
        XCTAssertTrue(result.stdout.contains("ref:     help"), result.stdout)
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
            arguments: ["vm", "ssh", vmID],
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
