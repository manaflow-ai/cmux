import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - trigger-flash command caller and workspace routing
extension CLINotifyProcessIntegrationTests {
    @MainActor
    func testTriggerFlashFallsBackFromStaleCallerWorkspaceAndSurfaceIDs() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("flash")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let currentWorkspace = "11111111-1111-1111-1111-111111111111"
        let currentSurface = "22222222-2222-2222-2222-222222222222"
        let staleWorkspace = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let staleSurface = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.v2Response(
                    id: "unknown",
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected payload"]
                )
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "surface.list":
                let workspaceId = params["workspace_id"] as? String
                if workspaceId == staleWorkspace {
                    return self.v2Response(
                        id: id,
                        ok: false,
                        error: ["code": "not_found", "message": "Workspace not found"]
                    )
                }
                if workspaceId == currentWorkspace {
                    return self.v2Response(
                        id: id,
                        ok: true,
                        result: [
                            "surfaces": [
                                [
                                    "id": currentSurface,
                                    "ref": "surface:1",
                                    "index": 0,
                                    "focused": true
                                ]
                            ]
                        ]
                    )
                }
            case "workspace.current":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["workspace_id": currentWorkspace]
                )
            case "surface.trigger_flash":
                let workspaceId = params["workspace_id"] as? String
                let surfaceId = params["surface_id"] as? String
                if workspaceId == currentWorkspace, surfaceId == currentSurface {
                    return self.v2Response(id: id, ok: true, result: [:])
                }
            default:
                break
            }

            return self.v2Response(
                id: id,
                ok: false,
                error: ["code": "unexpected", "message": "Unexpected method \(method)"]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = staleWorkspace
        environment["CMUX_SURFACE_ID"] = staleSurface
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["trigger-flash"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertTrue(
            state.commands.contains { command in
                guard let data = command.data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                      let method = payload["method"] as? String,
                      method == "surface.trigger_flash" else {
                    return false
                }
                let params = payload["params"] as? [String: Any] ?? [:]
                return (params["workspace_id"] as? String) == currentWorkspace
                    && (params["surface_id"] as? String) == currentSurface
            },
            "Expected surface.trigger_flash to use current workspace and surface, saw \(state.commands)"
        )
    }

    @MainActor
    func testTriggerFlashPrefersCallerTTYOverFocusedSurfaceWhenCallerIDsAreStale() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("flash-tty")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let callerTTY = "/dev/ttys777"
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let callerSurface = "22222222-2222-2222-2222-222222222222"
        let focusedSurface = "33333333-3333-3333-3333-333333333333"
        let staleWorkspace = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let staleSurface = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.v2Response(
                    id: "unknown",
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected payload"]
                )
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "surface.list":
                let requestedWorkspace = params["workspace_id"] as? String
                if requestedWorkspace == staleWorkspace {
                    return self.v2Response(
                        id: id,
                        ok: false,
                        error: ["code": "not_found", "message": "Workspace not found"]
                    )
                }
                if requestedWorkspace == workspaceId {
                    return self.v2Response(
                        id: id,
                        ok: true,
                        result: [
                            "surfaces": [
                                [
                                    "id": callerSurface,
                                    "ref": "surface:1",
                                    "index": 0,
                                    "focused": false
                                ],
                                [
                                    "id": focusedSurface,
                                    "ref": "surface:2",
                                    "index": 1,
                                    "focused": true
                                ]
                            ]
                        ]
                    )
                }
            case "workspace.current":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["workspace_id": workspaceId]
                )
            case "debug.terminals":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "count": 2,
                        "terminals": [
                            [
                                "workspace_id": workspaceId,
                                "surface_id": callerSurface,
                                "tty": callerTTY
                            ],
                            [
                                "workspace_id": workspaceId,
                                "surface_id": focusedSurface,
                                "tty": "/dev/ttys778"
                            ]
                        ]
                    ]
                )
            case "surface.trigger_flash":
                let requestedWorkspace = params["workspace_id"] as? String
                let requestedSurface = params["surface_id"] as? String
                if requestedWorkspace == workspaceId, requestedSurface == callerSurface {
                    return self.v2Response(id: id, ok: true, result: [:])
                }
            default:
                break
            }

            return self.v2Response(
                id: id,
                ok: false,
                error: ["code": "unexpected", "message": "Unexpected method \(method)"]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = staleWorkspace
        environment["CMUX_SURFACE_ID"] = staleSurface
        environment["CMUX_CLI_TTY_NAME"] = callerTTY
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["trigger-flash"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertTrue(
            state.commands.contains { command in
                guard let data = command.data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                      let method = payload["method"] as? String,
                      method == "surface.trigger_flash" else {
                    return false
                }
                let params = payload["params"] as? [String: Any] ?? [:]
                return (params["workspace_id"] as? String) == workspaceId
                    && (params["surface_id"] as? String) == callerSurface
            },
            "Expected surface.trigger_flash to use caller tty surface, saw \(state.commands)"
        )
        XCTAssertFalse(
            state.commands.contains { command in
                guard let data = command.data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                      let method = payload["method"] as? String,
                      method == "surface.trigger_flash" else {
                    return false
                }
                let params = payload["params"] as? [String: Any] ?? [:]
                return (params["workspace_id"] as? String) == workspaceId
                    && (params["surface_id"] as? String) == focusedSurface
            },
            "Focused surface should not win over caller tty, saw \(state.commands)"
        )
    }

    @MainActor
    func testTriggerFlashInTmuxPrefersCallerTTYOverStaleValidSurfaceID() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("flash-tmux-tty")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let callerTTY = "/dev/ttys777"
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let callerSurface = "22222222-2222-2222-2222-222222222222"
        let staleSurface = "33333333-3333-3333-3333-333333333333"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.v2Response(
                    id: "unknown",
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected payload"]
                )
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "surface.list":
                let requestedWorkspace = params["workspace_id"] as? String
                if requestedWorkspace == workspaceId {
                    return self.v2Response(
                        id: id,
                        ok: true,
                        result: [
                            "surfaces": [
                                [
                                    "id": callerSurface,
                                    "ref": "surface:1",
                                    "index": 0,
                                    "focused": false
                                ],
                                [
                                    "id": staleSurface,
                                    "ref": "surface:2",
                                    "index": 1,
                                    "focused": true
                                ]
                            ]
                        ]
                    )
                }
            case "debug.terminals":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "count": 2,
                        "terminals": [
                            [
                                "workspace_id": workspaceId,
                                "surface_id": callerSurface,
                                "tty": callerTTY
                            ],
                            [
                                "workspace_id": workspaceId,
                                "surface_id": staleSurface,
                                "tty": "/dev/ttys778"
                            ]
                        ]
                    ]
                )
            case "surface.trigger_flash":
                let requestedWorkspace = params["workspace_id"] as? String
                let requestedSurface = params["surface_id"] as? String
                if requestedWorkspace == workspaceId,
                   (requestedSurface == callerSurface || requestedSurface == staleSurface) {
                    return self.v2Response(id: id, ok: true, result: [:])
                }
            default:
                break
            }

            return self.v2Response(
                id: id,
                ok: false,
                error: ["code": "unexpected", "message": "Unexpected method \(method)"]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = staleSurface
        environment["CMUX_CLI_TTY_NAME"] = callerTTY
        environment["TMUX"] = "/tmp/tmux-current,123,0"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["trigger-flash"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertTrue(
            state.commands.contains { command in
                guard let data = command.data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                      let method = payload["method"] as? String,
                      method == "surface.trigger_flash" else {
                    return false
                }
                let params = payload["params"] as? [String: Any] ?? [:]
                return (params["workspace_id"] as? String) == workspaceId
                    && (params["surface_id"] as? String) == callerSurface
            },
            "Expected trigger-flash to use caller tty surface in tmux, saw \(state.commands)"
        )
        XCTAssertFalse(
            state.commands.contains { command in
                guard let data = command.data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                      let method = payload["method"] as? String,
                      method == "surface.trigger_flash" else {
                    return false
                }
                let params = payload["params"] as? [String: Any] ?? [:]
                return (params["workspace_id"] as? String) == workspaceId
                    && (params["surface_id"] as? String) == staleSurface
            },
            "Stale env surface should not win inside tmux, saw \(state.commands)"
        )
    }
}
