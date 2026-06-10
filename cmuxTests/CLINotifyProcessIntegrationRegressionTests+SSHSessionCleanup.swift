import XCTest
import Darwin
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - SSH session list and cleanup
extension CLINotifyProcessIntegrationRegressionTests {
    func testSSHSessionListAllWorkspacesReportsQueryErrors() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshlist")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
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
            XCTAssertEqual(method, "workspace.remote.pty_sessions")
            let params = payload["params"] as? [String: Any] ?? [:]
            XCTAssertEqual(params["all_workspaces"] as? Bool, true)
            return self.v2Response(
                id: id,
                ok: true,
                result: [
                    "sessions": [],
                    "errors": [
                        [
                            "workspace_id": workspaceId,
                            "workspace_ref": "workspace:4",
                            "error": "remote connection is not active",
                        ],
                    ],
                ]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-session-list",
                "--all-workspaces",
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertFalse(result.stdout.contains("No persisted SSH PTY sessions"), result.stdout)
        XCTAssertTrue(result.stderr.contains("ssh-session-list failed for 1 remote workspace"), result.stderr)
        XCTAssertTrue(result.stderr.contains("workspace:4"), result.stderr)
        XCTAssertTrue(result.stderr.contains("remote connection is not active"), result.stderr)
    }

    func testSSHSessionCleanupAllReportsPartialFailures() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshclean")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let closedSessionId = "ssh-session-closed"
        let failedSessionId = "ssh-session-failed"

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
            case "workspace.remote.pty_sessions":
                XCTAssertEqual(params["workspace_id"] as? String, workspaceId)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "sessions": [
                            [
                                "workspace_id": workspaceId,
                                "session_id": closedSessionId,
                            ],
                            [
                                "workspace_id": workspaceId,
                                "session_id": failedSessionId,
                            ],
                            [
                                "workspace_id": workspaceId,
                                "session_id": "   ",
                            ],
                        ],
                    ]
                )
            case "workspace.remote.pty_close":
                XCTAssertEqual(params["workspace_id"] as? String, workspaceId)
                let sessionId = params["session_id"] as? String
                if sessionId == closedSessionId {
                    return self.v2Response(id: id, ok: true, result: ["closed": true])
                }
                XCTAssertEqual(sessionId, failedSessionId)
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "remote_pty_error", "message": "close failed"]
                )
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-session-cleanup",
                "--workspace", workspaceId,
                "--all",
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertTrue(result.stdout.contains("Closed 1 persisted SSH PTY session"), result.stdout)
        XCTAssertTrue(result.stderr.contains("ssh-session-cleanup failed for 2 persisted SSH PTY sessions"), result.stderr)
        XCTAssertTrue(result.stderr.contains(failedSessionId), result.stderr)
        XCTAssertTrue(result.stderr.contains("missing session_id in SSH PTY session list response"), result.stderr)
        XCTAssertTrue(result.stderr.contains("remote PTY operation failed"), result.stderr)
        XCTAssertFalse(result.stderr.contains("close failed"), result.stderr)
    }

    func testSSHSessionCleanupAllWorkspacesReportsListErrors() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshcleanall")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let closedSessionId = "ssh-session-closed"

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
            case "workspace.remote.pty_sessions":
                XCTAssertEqual(params["all_workspaces"] as? Bool, true)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "sessions": [
                            [
                                "workspace_id": workspaceId,
                                "session_id": closedSessionId,
                            ],
                        ],
                        "errors": [
                            [
                                "workspace_ref": "workspace:4",
                                "error": "remote connection is not active",
                            ],
                        ],
                    ]
                )
            case "workspace.remote.pty_close":
                XCTAssertEqual(params["workspace_id"] as? String, workspaceId)
                XCTAssertEqual(params["session_id"] as? String, closedSessionId)
                return self.v2Response(id: id, ok: true, result: ["closed": true])
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-session-cleanup",
                "--all-workspaces",
                "--all",
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertTrue(result.stdout.contains("Closed 1 persisted SSH PTY session"), result.stdout)
        XCTAssertTrue(result.stderr.contains("ssh-session-cleanup failed for 1 persisted SSH PTY session"), result.stderr)
        XCTAssertTrue(result.stderr.contains("workspace-query"), result.stderr)
        XCTAssertTrue(result.stderr.contains("workspace:4"), result.stderr)
        XCTAssertTrue(result.stderr.contains("remote connection is not active"), result.stderr)
    }

    func testSSHSessionCleanupAllWorkspacesAllRejectsMissingWorkspaceID() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshcleanallmissing")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let sessionId = "ssh-session-missing-workspace"

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
            case "workspace.remote.pty_sessions":
                XCTAssertEqual(params["all_workspaces"] as? Bool, true)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "sessions": [
                            [
                                "workspace_ref": "workspace:missing",
                                "session_id": sessionId,
                            ],
                        ],
                    ]
                )
            case "workspace.remote.pty_close":
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_close", "message": "cleanup sent unscoped close"]
                )
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-session-cleanup",
                "--all-workspaces",
                "--all",
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertFalse(state.snapshot().contains { $0.contains("workspace.remote.pty_close") })
        XCTAssertTrue(result.stderr.contains("ssh-session-cleanup failed for 1 persisted SSH PTY session"), result.stderr)
        XCTAssertTrue(result.stderr.contains(sessionId), result.stderr)
        XCTAssertTrue(result.stderr.contains("workspace:missing"), result.stderr)
        XCTAssertTrue(result.stderr.contains("missing workspace_id in SSH PTY session list response"), result.stderr)
    }

    func testSSHSessionCleanupAllWorkspacesSessionIDRejectsMissingWorkspaceID() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshcleansessionmissing")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let sessionId = "ssh-session-missing-workspace"

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
            case "workspace.remote.pty_sessions":
                XCTAssertEqual(params["all_workspaces"] as? Bool, true)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "sessions": [
                            [
                                "workspace_ref": "workspace:missing",
                                "session_id": sessionId,
                            ],
                        ],
                    ]
                )
            case "workspace.remote.pty_close":
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_close", "message": "cleanup sent unscoped close"]
                )
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-session-cleanup",
                "--all-workspaces",
                "--session-id", sessionId,
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertFalse(state.snapshot().contains { $0.contains("workspace.remote.pty_close") })
        XCTAssertTrue(result.stderr.contains("ssh-session-cleanup failed for 1 persisted SSH PTY session"), result.stderr)
        XCTAssertTrue(result.stderr.contains(sessionId), result.stderr)
        XCTAssertTrue(result.stderr.contains("workspace:missing"), result.stderr)
        XCTAssertTrue(result.stderr.contains("missing workspace_id in SSH PTY session list response"), result.stderr)
    }

    func testSSHSessionCleanupAllWorkspacesSessionIDReportsNotFound() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshcleansessiongone")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let sessionId = "ssh-session-gone"

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
            case "workspace.remote.pty_sessions":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "sessions": [],
                    ]
                )
            case "workspace.remote.pty_close":
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_close", "message": "cleanup sent close for missing session"]
                )
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-session-cleanup",
                "--all-workspaces",
                "--session-id", sessionId,
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertFalse(state.snapshot().contains { $0.contains("workspace.remote.pty_close") })
        XCTAssertTrue(result.stderr.contains("ssh-session-cleanup failed for 1 persisted SSH PTY session"), result.stderr)
        XCTAssertTrue(result.stderr.contains(sessionId), result.stderr)
        XCTAssertTrue(result.stderr.contains("persistent SSH PTY session is no longer running"), result.stderr)
    }

    func testSSHSessionCleanupAllWorkspacesSessionIDCountsDuplicateIDsPerWorkspace() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshcleandup")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let sessionId = "shared-session-id"
        let workspaceA = "22222222-2222-2222-2222-222222222222"
        let workspaceB = "33333333-3333-3333-3333-333333333333"

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
            case "workspace.remote.pty_sessions":
                XCTAssertEqual(params["all_workspaces"] as? Bool, true)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "sessions": [
                            [
                                "workspace_id": workspaceA,
                                "session_id": sessionId,
                            ],
                            [
                                "workspace_id": workspaceB,
                                "session_id": sessionId,
                            ],
                        ],
                    ]
                )
            case "workspace.remote.pty_close":
                XCTAssertEqual(params["session_id"] as? String, sessionId)
                XCTAssertTrue([workspaceA, workspaceB].contains(params["workspace_id"] as? String))
                return self.v2Response(id: id, ok: true, result: ["closed": true])
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-session-cleanup",
                "--all-workspaces",
                "--session-id", sessionId,
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("Closed 2 persisted SSH PTY sessions"), result.stdout)

        let closedWorkspaces = state.snapshot().compactMap { line -> String? in
            guard let payload = self.jsonObject(line),
                  payload["method"] as? String == "workspace.remote.pty_close",
                  let params = payload["params"] as? [String: Any],
                  params["session_id"] as? String == sessionId else {
                return nil
            }
            return params["workspace_id"] as? String
        }
        XCTAssertEqual(closedWorkspaces.count, 2)
        XCTAssertEqual(Set(closedWorkspaces), Set([workspaceA, workspaceB]))
    }

}
