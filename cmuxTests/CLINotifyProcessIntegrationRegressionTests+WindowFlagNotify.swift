import XCTest
import Darwin
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Window flag notify
extension CLINotifyProcessIntegrationRegressionTests {
    func testNotifyWindowFlagResolvesCurrentWorkspaceInWindow() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("notify-window")
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

            switch method {
            case "workspace.current":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["window_id"] as? String, windowId)
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceId])
            case "notification.create":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["window_id"] as? String, windowId)
                XCTAssertEqual(params["workspace_id"] as? String, workspaceId)
                XCTAssertEqual(params["title"] as? String, "Window Notify")
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["workspace_id": workspaceId, "surface_id": surfaceId]
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
            arguments: ["notify", "--window", windowId, "--title", "Window Notify"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["workspace.current", "notification.create"]
        )
    }

    func testNotifyWindowSurfaceRefResolvesAcrossTargetWindowWorkspaces() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("notify-window-surface")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let windowId = "11111111-1111-1111-1111-111111111111"
        let selectedWorkspaceId = "22222222-2222-2222-2222-222222222222"
        let targetWorkspaceId = "33333333-3333-3333-3333-333333333333"
        let selectedSurfaceId = "44444444-4444-4444-4444-444444444444"
        let targetSurfaceId = "55555555-5555-5555-5555-555555555555"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                XCTAssertTrue(line.hasPrefix("notify_target \(targetWorkspaceId) \(targetSurfaceId) "), line)
                XCTAssertTrue(line.contains("Window Surface Notify"), line)
                return "OK"
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
                                "id": selectedWorkspaceId,
                                "ref": "workspace:1",
                                "index": 1,
                            ],
                            [
                                "id": targetWorkspaceId,
                                "ref": "workspace:2",
                                "index": 2,
                            ],
                        ],
                    ]
                )
            case "surface.list":
                XCTAssertEqual(params["window_id"] as? String, windowId)
                switch params["workspace_id"] as? String {
                case selectedWorkspaceId:
                    return self.v2Response(
                        id: id,
                        ok: true,
                        result: [
                            "surfaces": [
                                [
                                    "id": selectedSurfaceId,
                                    "ref": "surface:1",
                                    "index": 1,
                                ],
                            ],
                        ]
                    )
                case targetWorkspaceId:
                    return self.v2Response(
                        id: id,
                        ok: true,
                        result: [
                            "surfaces": [
                                [
                                    "id": targetSurfaceId,
                                    "ref": "surface:3",
                                    "index": 3,
                                ],
                            ],
                        ]
                    )
                default:
                    XCTFail("Unexpected surface.list params: \(params)")
                    return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "unexpected workspace"])
                }
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
            arguments: ["notify", "--window", "window:2", "--surface", "surface:3", "--title", "Window Surface Notify"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        let methods = state.commands.compactMap { self.jsonObject($0)?["method"] as? String }
        XCTAssertEqual(methods, ["window.list", "workspace.list", "surface.list", "surface.list"])
    }

    func testNotifyWindowSurfaceIndexUsesCurrentWorkspaceInTargetWindow() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("notify-window-surface-index")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let windowId = "11111111-1111-1111-1111-111111111111"
        let selectedWorkspaceId = "22222222-2222-2222-2222-222222222222"
        let selectedSurfaceId = "33333333-3333-3333-3333-333333333333"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                XCTAssertTrue(line.hasPrefix("notify_target \(selectedWorkspaceId) \(selectedSurfaceId) "), line)
                XCTAssertTrue(line.contains("Window Indexed Notify"), line)
                return "OK"
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
            case "workspace.current":
                XCTAssertEqual(params["window_id"] as? String, windowId)
                return self.v2Response(id: id, ok: true, result: ["workspace_id": selectedWorkspaceId])
            case "surface.list":
                XCTAssertEqual(params["window_id"] as? String, windowId)
                XCTAssertEqual(params["workspace_id"] as? String, selectedWorkspaceId)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "surfaces": [
                            [
                                "id": selectedSurfaceId,
                                "ref": "surface:8",
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
            arguments: ["notify", "--window", "window:2", "--surface", "0", "--title", "Window Indexed Notify"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        let methods = state.commands.compactMap { self.jsonObject($0)?["method"] as? String }
        XCTAssertEqual(methods, ["window.list", "workspace.current", "surface.list"])
    }

}
