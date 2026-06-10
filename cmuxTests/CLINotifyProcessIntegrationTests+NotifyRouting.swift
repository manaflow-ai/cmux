import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - notify command caller and workspace routing
extension CLINotifyProcessIntegrationTests {
    @MainActor
    func testNotifyWithWorkspaceHandleKeepsCallerSurfaceFallback() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("notify")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let currentWorkspace = "11111111-1111-1111-1111-111111111111"
        let currentSurface = "22222222-2222-2222-2222-222222222222"
        let staleSurface = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String,
               let method = payload["method"] as? String {
                if method == "workspace.list" { return self.v2Response(id: id, ok: true, result: ["workspaces": [["id": currentWorkspace, "index": 1]]]) }
                if method == "notification.create_for_caller" {
                    let params = payload["params"] as? [String: Any] ?? [:]
                    XCTAssertEqual(params["preferred_workspace_id"] as? String, currentWorkspace)
                    XCTAssertEqual(params["preferred_surface_id"] as? String, staleSurface)
                    XCTAssertEqual(params["prefer_tty"] as? Bool, false)
                    return self.v2Response(
                        id: id,
                        ok: true,
                        result: ["workspace_id": currentWorkspace, "surface_id": currentSurface]
                    )
                }
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected method \(method)"]
                )
            }

            return "ERROR: Unexpected command \(line)"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        environment["CMUX_SURFACE_ID"] = staleSurface
        environment["TMUX"] = "/tmp/tmux-current,123,0"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["notify", "--workspace", "1"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertTrue(
            state.commands.contains { $0.contains("\"method\":\"notification.create_for_caller\"") },
            "Expected notify to use single-call caller notification path, saw \(state.commands)"
        )
    }

    @MainActor
    func testNotifyWithWorkspaceHandlePreservesSyncTargetValidation() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("notify-handle")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let staleSurface = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if let data = line.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let id = payload["id"] as? String,
               let method = payload["method"] as? String {
                switch method {
                case "workspace.list":
                    return self.v2Response(
                        id: id,
                        ok: true,
                        result: [
                            "workspaces": [
                                ["id": workspaceId, "index": 1]
                            ]
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

            if line.hasPrefix("notify_target \(workspaceId) \(staleSurface) ") {
                return "ERROR: Panel not found"
            }
            if line.hasPrefix("notify_target_async ") {
                return "OK"
            }
            return "ERROR: Unexpected command \(line)"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["notify", "--workspace", "1", "--surface", staleSurface, "--title", "Mixed"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("ERROR: Panel not found"), result.stderr)
        XCTAssertTrue(
            state.commands.contains { $0.hasPrefix("notify_target \(workspaceId) \(staleSurface) ") },
            "Expected notify to use synchronous target validation, saw \(state.commands)"
        )
        XCTAssertFalse(
            state.commands.contains { $0.hasPrefix("notify_target_async ") },
            "Expected no async target dispatch for mixed handles, saw \(state.commands)"
        )
    }

    @MainActor
    func testNotifyPrefersCallerTTYOverFocusedSurfaceWhenCallerIDsAreStale() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("notify-tty")
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
                return "ERROR: Unexpected command \(line)"
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "notification.create_for_caller":
                XCTAssertEqual(params["preferred_workspace_id"] as? String, staleWorkspace)
                XCTAssertEqual(params["preferred_surface_id"] as? String, staleSurface)
                XCTAssertEqual(params["caller_tty"] as? String, "ttys777")
                XCTAssertEqual(params["prefer_tty"] as? Bool, false)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["workspace_id": workspaceId, "surface_id": callerSurface]
                )
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
            arguments: ["notify"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertTrue(
            state.commands.contains { $0.contains("\"method\":\"notification.create_for_caller\"") },
            "Expected notify to use single-call caller notification path, saw \(state.commands)"
        )
    }

    @MainActor
    func testNotifyInTmuxPrefersCallerTTYOverStaleValidSurfaceID() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("notify-tmux-tty")
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
                return "ERROR: Unexpected command \(line)"
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "notification.create_for_caller":
                XCTAssertEqual(params["preferred_workspace_id"] as? String, workspaceId)
                XCTAssertEqual(params["preferred_surface_id"] as? String, staleSurface)
                XCTAssertEqual(params["caller_tty"] as? String, "ttys777")
                XCTAssertEqual(params["prefer_tty"] as? Bool, true)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["workspace_id": workspaceId, "surface_id": callerSurface]
                )
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
            arguments: ["notify"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertTrue(
            state.commands.contains { $0.contains("\"method\":\"notification.create_for_caller\"") },
            "Expected notify to use single-call caller notification path in tmux, saw \(state.commands)"
        )
    }

}
