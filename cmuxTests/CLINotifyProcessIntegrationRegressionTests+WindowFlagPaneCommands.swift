import XCTest
import Darwin
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Window flag pane commands
extension CLINotifyProcessIntegrationRegressionTests {
    func testNewPaneWindowFlagScopesWorkspaceIndex() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("pane-window")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let windowId = "11111111-1111-1111-1111-111111111111"
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let paneId = "33333333-3333-3333-3333-333333333333"

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
            case "workspace.list":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["window_id"] as? String, windowId)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspaces": [
                            [
                                "id": workspaceId,
                                "ref": "workspace:1",
                                "index": 0,
                            ],
                        ],
                    ]
                )
            case "pane.create":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["window_id"] as? String, windowId)
                XCTAssertEqual(params["workspace_id"] as? String, workspaceId)
                XCTAssertEqual(params["direction"] as? String, "right")
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "window_id": windowId,
                        "workspace_id": workspaceId,
                        "pane_id": paneId,
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
            arguments: ["new-pane", "--window", windowId, "--workspace", "0", "--direction", "right"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["workspace.list", "pane.create"]
        )
    }

    func testFocusPaneWindowFlagRejectsPaneFromOtherWindow() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("pane-other-window")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let targetWindowId = "11111111-1111-1111-1111-111111111111"
        let targetWorkspaceId = "22222222-2222-2222-2222-222222222222"
        let targetPaneId = "33333333-3333-3333-3333-333333333333"
        let otherPaneId = "44444444-4444-4444-4444-444444444444"

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
            case "workspace.list":
                XCTAssertEqual(params["window_id"] as? String, targetWindowId)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspaces": [
                            [
                                "id": targetWorkspaceId,
                                "ref": "workspace:1",
                                "index": 0,
                            ],
                        ],
                    ]
                )
            case "pane.list":
                XCTAssertEqual(params["window_id"] as? String, targetWindowId)
                XCTAssertEqual(params["workspace_id"] as? String, targetWorkspaceId)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "panes": [
                            [
                                "id": targetPaneId,
                                "ref": "pane:1",
                                "index": 0,
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
            arguments: ["focus-pane", "--window", targetWindowId, "--pane", otherPaneId],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("Pane not found in window"), result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["workspace.list", "pane.list"]
        )
    }

    func testSendWindowFlagRejectsUnknownWindowRefBeforeMutation() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("send-window-ref")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let existingWindowId = "11111111-1111-1111-1111-111111111111"

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
                                "id": existingWindowId,
                                "ref": "window:1",
                                "index": 0,
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
            arguments: ["send", "--window", "window:2", "--", "should-not-send"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("Window not found: window:2"), result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["window.list"]
        )
    }

    func testPipePaneWindowFlagDoesNotBecomePositionalCommandText() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("pipe-window")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let windowId = "11111111-1111-1111-1111-111111111111"
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let surfaceId = "33333333-3333-3333-3333-333333333333"

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
            case "window.list":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "windows": [
                            [
                                "id": windowId,
                                "ref": "window:2",
                                "index": 2,
                            ],
                        ],
                    ]
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
                            "surface_id": surfaceId,
                        ],
                    ]
                )
            case "surface.read_text":
                XCTAssertEqual(params["window_id"] as? String, windowId)
                XCTAssertEqual(params["surface_id"] as? String, surfaceId)
                return self.v2Response(id: id, ok: true, result: ["text": "hello\n"])
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
            arguments: ["pipe-pane", "--window", "window:2", "cat"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "hello\nOK\n")
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["window.list", "system.identify", "surface.read_text"]
        )
    }

    func testPipePaneWindowWorkspaceOmittedSurfaceDoesNotUseSelectedWorkspaceSurface() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("pipe-window-workspace")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let windowId = "11111111-1111-1111-1111-111111111111"
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let selectedWorkspaceSurfaceId = "33333333-3333-3333-3333-333333333333"

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
            case "window.list":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "windows": [
                            [
                                "id": windowId,
                                "ref": "window:2",
                                "index": 2,
                            ],
                        ],
                    ]
                )
            case "workspace.list":
                XCTAssertEqual(params["window_id"] as? String, windowId)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspaces": [
                            [
                                "id": workspaceId,
                                "ref": "workspace:2",
                                "index": 2,
                            ],
                        ],
                    ]
                )
            case "system.identify":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "focused": [
                            "window_id": windowId,
                            "workspace_id": "44444444-4444-4444-4444-444444444444",
                            "surface_id": selectedWorkspaceSurfaceId,
                        ],
                    ]
                )
            case "surface.read_text":
                XCTAssertEqual(params["window_id"] as? String, windowId)
                XCTAssertEqual(params["workspace_id"] as? String, workspaceId)
                XCTAssertNil(params["surface_id"], line)
                return self.v2Response(id: id, ok: true, result: ["text": "workspace text\n"])
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
            arguments: ["pipe-pane", "--window", "window:2", "--workspace", "workspace:2", "cat"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "workspace text\nOK\n")
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["window.list", "workspace.list", "surface.read_text"]
        )
    }

    func testRespawnPaneWindowFlagDoesNotBecomePositionalCommandText() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("respawn-window")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let windowId = "11111111-1111-1111-1111-111111111111"
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let surfaceId = "33333333-3333-3333-3333-333333333333"

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
            case "window.list":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "windows": [
                            [
                                "id": windowId,
                                "ref": "window:2",
                                "index": 2,
                            ],
                        ],
                    ]
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
                            "surface_id": surfaceId,
                        ],
                    ]
                )
            case "surface.send_text":
                XCTAssertEqual(params["window_id"] as? String, windowId)
                XCTAssertEqual(params["surface_id"] as? String, surfaceId)
                XCTAssertEqual(params["text"] as? String, "echo fresh\n")
                return self.v2Response(id: id, ok: true, result: ["surface_id": surfaceId])
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
            arguments: ["respawn-pane", "--window", "window:2", "echo", "fresh"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["window.list", "system.identify", "surface.send_text"]
        )
    }

}
