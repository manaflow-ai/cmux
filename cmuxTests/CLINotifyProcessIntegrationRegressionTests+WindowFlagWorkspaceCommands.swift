import XCTest
import Darwin
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Window flag workspace commands
extension CLINotifyProcessIntegrationRegressionTests {
    func testVMNewWindowFlagValidatesBeforeCreate() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-window-validate")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let missingWindowId = "11111111-1111-1111-1111-111111111111"

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

            guard method == "window.list" else {
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected method: \(method)"])
            }
            return self.v2Response(id: id, ok: true, result: ["windows": []])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "new", "--window", missingWindowId],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertTrue(result.stderr.contains("Window not found: \(missingWindowId)"), result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["window.list"]
        )
    }

    func testVMNewWindowFlagAcceptsCaseInsensitiveUUID() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-window-case")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let listedWindowId = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        let requestedWindowId = listedWindowId.lowercased()

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
            case "window.list":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "windows": [
                            [
                                "id": listedWindowId,
                                "ref": "window:1",
                                "index": 0,
                            ],
                        ],
                    ]
                )
            case "vm.create":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "id": "vm-test-case-window",
                        "provider": "freestyle",
                        "image": "default",
                    ]
                )
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected method: \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "new", "--window", requestedWindowId, "--detach"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("OK vm-test-case-window"), result.stdout)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["window.list", "vm.create"]
        )
    }

    func testSidebarMetadataWindowFlagTargetsSelectedWorkspaceInWindow() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("status-window")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let windowId = "11111111-1111-1111-1111-111111111111"
        let workspaceId = "22222222-2222-2222-2222-222222222222"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let payload = self.jsonObject(line),
               let id = payload["id"] as? String,
               let method = payload["method"] as? String {
                guard method == "workspace.current" else {
                    return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected method: \(method)"])
                }
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["window_id"] as? String, windowId)
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceId])
            }

            XCTAssertTrue(line.hasPrefix("set_status build running"), line)
            XCTAssertTrue(line.contains("--tab=\(workspaceId)"), line)
            XCTAssertFalse(line.contains("--window"), line)
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["set-status", "build", "running", "--window", windowId],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
    }

    func testSidebarMetadataWindowFlagAfterSeparatorStaysMessageText() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("log-separator")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let windowId = "11111111-1111-1111-1111-111111111111"
        let workspaceId = "22222222-2222-2222-2222-222222222222"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let payload = self.jsonObject(line),
               let id = payload["id"] as? String,
               let method = payload["method"] as? String {
                guard method == "workspace.current" else {
                    return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected method: \(method)"])
                }
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["window_id"] as? String, windowId)
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceId])
            }

            XCTAssertEqual(line, "log --tab=\(workspaceId) -- --window target")
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["log", "--window", windowId, "--", "--window", "target"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
    }

    func testSidebarMetadataWindowFlagFailsWhenWindowHasNoCurrentWorkspace() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("status-window-empty")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let windowId = "11111111-1111-1111-1111-111111111111"

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
            guard method == "workspace.current" else {
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected method: \(method)"])
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            XCTAssertEqual(params["window_id"] as? String, windowId)
            return self.v2Response(id: id, ok: true, result: [:])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["set-status", "build", "running", "--window", windowId],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertTrue(result.stderr.contains("set-status: targeted window has no current workspace"), result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["workspace.current"]
        )
    }

    func testWorkspaceActionWindowFlagResolvesCurrentWorkspaceInWindow() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("action-window")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let windowId = "11111111-1111-1111-1111-111111111111"
        let workspaceId = "22222222-2222-2222-2222-222222222222"

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
            case "workspace.current":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["window_id"] as? String, windowId)
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceId])
            case "workspace.action":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["window_id"] as? String, windowId)
                XCTAssertEqual(params["workspace_id"] as? String, workspaceId)
                XCTAssertEqual(params["action"] as? String, "pin")
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["window_id": windowId, "workspace_id": workspaceId, "action": "pin"]
                )
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected method: \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["workspace-action", "--window", windowId, "--action", "pin"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["workspace.current", "workspace.action"]
        )
    }

    func testClearNotificationsWindowFlagFailsWhenWindowHasNoCurrentWorkspace() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("clear-window-empty")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let windowId = "11111111-1111-1111-1111-111111111111"

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
            guard method == "workspace.current" else {
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected method: \(method)"])
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            XCTAssertEqual(params["window_id"] as? String, windowId)
            return self.v2Response(id: id, ok: true, result: [:])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["clear-notifications", "--window", windowId],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertTrue(result.stderr.contains("clear-notifications: targeted window has no current workspace"), result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["workspace.current"]
        )
    }

    func testTreeCommandForwardsWindowFlag() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("tree-window")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let windowId = "11111111-1111-1111-1111-111111111111"

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

            guard method == "system.tree" else {
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected method: \(method)"])
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            XCTAssertEqual(params["window_id"] as? String, windowId)
            XCTAssertEqual(params["all_windows"] as? Bool, false)
            return self.v2Response(
                id: id,
                ok: true,
                result: [
                    "active": NSNull(),
                    "caller": NSNull(),
                    "windows": [],
                ]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["tree", "--json", "--window", windowId],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
    }

    func testTreeCommandWindowFlagSurvivesLegacyFallback() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("tree-legacy-window")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let windowId = "11111111-1111-1111-1111-111111111111"
        let otherWindowId = "22222222-2222-2222-2222-222222222222"
        let workspaceId = "33333333-3333-3333-3333-333333333333"
        let paneId = "44444444-4444-4444-4444-444444444444"
        let surfaceId = "55555555-5555-5555-5555-555555555555"

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
            let params = payload["params"] as? [String: Any] ?? [:]

            switch method {
            case "system.tree":
                XCTAssertEqual(params["window_id"] as? String, windowId)
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "method_not_found", "message": "system.tree"]
                )
            case "system.identify":
                XCTAssertEqual(params["window_id"] as? String, windowId)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "focused": [
                            "window_id": windowId,
                            "workspace_id": workspaceId,
                            "pane_id": paneId,
                            "surface_id": surfaceId,
                        ],
                        "caller": NSNull(),
                    ]
                )
            case "window.list":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "windows": [
                            ["id": otherWindowId, "ref": "window:1", "index": 0],
                            ["id": windowId, "ref": "window:2", "index": 1],
                        ],
                    ]
                )
            case "workspace.list":
                XCTAssertEqual(params["window_id"] as? String, "window:2")
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "window_id": windowId,
                        "window_ref": "window:2",
                        "workspaces": [
                            ["id": workspaceId, "ref": "workspace:1", "index": 0, "selected": true],
                        ],
                    ]
                )
            case "pane.list":
                XCTAssertTrue([workspaceId, "workspace:1"].contains(params["workspace_id"] as? String))
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "panes": [
                            ["id": paneId, "ref": "pane:1", "index": 0],
                        ],
                    ]
                )
            case "surface.list":
                XCTAssertTrue([workspaceId, "workspace:1"].contains(params["workspace_id"] as? String))
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "surfaces": [
                            [
                                "id": surfaceId,
                                "ref": "surface:1",
                                "pane_id": paneId,
                                "pane_ref": "pane:1",
                                "index": 0,
                                "type": "terminal",
                                "focused": true,
                            ],
                        ],
                    ]
                )
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected method: \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--id-format", "uuids", "tree", "--json", "--window", windowId],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)

        let payload = try jsonPayload(from: result.stdout)
        let windows = try XCTUnwrap(payload["windows"] as? [[String: Any]])
        XCTAssertEqual(windows.count, 1, result.stdout)
        XCTAssertEqual(windows.first?["id"] as? String, windowId)
        XCTAssertFalse(result.stdout.contains(otherWindowId), result.stdout)
    }

}
