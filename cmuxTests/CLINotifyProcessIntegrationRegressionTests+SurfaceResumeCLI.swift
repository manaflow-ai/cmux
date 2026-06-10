import XCTest
import Darwin
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - surface-resume CLI
extension CLINotifyProcessIntegrationRegressionTests {
    func testSurfaceResumeClearCLIForwardsCheckpointAndSourceGuards() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("resume-clear-guards")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            XCTAssertEqual(method, "surface.resume.clear")
            return self.v2Response(id: id, ok: true, result: ["cleared": false])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "surface", "resume", "clear",
                "--workspace", workspaceId,
                "--surface", surfaceId,
                "--checkpoint", "old-session",
                "--checkpoint-id", "new-session",
                "--source", "agent-hook",
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")

        let clearRequests = state.commands.compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.clear" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        let request = try XCTUnwrap(clearRequests.first)
        XCTAssertEqual(request["workspace_id"] as? String, workspaceId)
        XCTAssertEqual(request["surface_id"] as? String, surfaceId)
        XCTAssertEqual(request["checkpoint_id"] as? String, "new-session")
        XCTAssertEqual(request["source"] as? String, "agent-hook")
    }

    func testSurfaceResumeSetCLIPreservesQuotedShellCommand() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("resume-set-shell")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            XCTAssertEqual(method, "surface.resume.set")
            return self.v2Response(id: id, ok: true, result: ["resume_binding": [:]])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "surface", "resume", "set",
                "--workspace", workspaceId,
                "--surface", surfaceId,
                "--kind", "tmux",
                "--shell", "tmux attach -t work",
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")

        let setRequests = state.commands.compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.set" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        XCTAssertEqual(setRequests.count, 1)
        let request = try XCTUnwrap(setRequests.first)
        XCTAssertEqual(request["workspace_id"] as? String, workspaceId)
        XCTAssertEqual(request["surface_id"] as? String, surfaceId)
        XCTAssertEqual(request["kind"] as? String, "tmux")
        XCTAssertEqual(request["command"] as? String, "tmux attach -t work")
    }

    func testSurfaceResumeSetCLIStopsParsingOptionsAfterTerminator() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("resume-set-terminator")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            XCTAssertEqual(method, "surface.resume.set")
            return self.v2Response(id: id, ok: true, result: ["resume_binding": [:]])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "surface", "resume", "set",
                "--workspace", workspaceId,
                "--surface", surfaceId,
                "--",
                "myapp",
                "--name", "foo",
                "--kind", "bar",
                "--cwd", "/tmp/ignored",
                "--surface", "not-a-target",
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")

        let setRequests = state.commands.compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.set" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        let request = try XCTUnwrap(setRequests.first)
        XCTAssertEqual(request["workspace_id"] as? String, workspaceId)
        XCTAssertEqual(request["surface_id"] as? String, surfaceId)
        XCTAssertNil(request["name"])
        XCTAssertNil(request["kind"])
        XCTAssertEqual(
            request["command"] as? String,
            "'myapp' '--name' 'foo' '--kind' 'bar' '--cwd' '/tmp/ignored' '--surface' 'not-a-target'"
        )
    }

    func testSurfaceResumeSetCLIDoesNotScopeExplicitSurfaceToEnvWorkspace() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("resume-set-surface")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let staleWorkspaceId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let movedSurfaceId = "22222222-2222-2222-2222-222222222222"
        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            XCTAssertEqual(method, "surface.resume.set")
            return self.v2Response(id: id, ok: true, result: ["resume_binding": [:]])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_WORKSPACE_ID"] = staleWorkspaceId
        environment["CMUX_SURFACE_ID"] = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "surface", "resume", "set",
                "--surface", movedSurfaceId,
                "--shell", "tmux attach -t moved",
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let setRequests = state.commands.compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.set" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        let request = try XCTUnwrap(setRequests.first)
        XCTAssertNil(request["workspace_id"])
        XCTAssertEqual(request["surface_id"] as? String, movedSurfaceId)
    }

    func testSurfaceResumeSetCLIRejectsTrailingShellTokens() throws {
        let cliPath = try bundledCLIPath()
        let missingSocketPath = "/tmp/cmux-test-missing-\(UUID().uuidString).sock"

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = missingSocketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "surface", "resume", "set",
                "--workspace", "11111111-1111-1111-1111-111111111111",
                "--surface", "22222222-2222-2222-2222-222222222222",
                "--shell", "tmux",
                "attach",
                "-t",
                "work",
            ],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.contains("surface resume set: unexpected argument 'attach' after --shell"))
        XCTAssertFalse(result.stderr.contains("Socket"), result.stderr)
    }

    func testSurfaceResumeSetCLIRejectsPreTerminatorCommandTokens() throws {
        let cliPath = try bundledCLIPath()
        let missingSocketPath = "/tmp/cmux-test-missing-\(UUID().uuidString).sock"
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = missingSocketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "surface", "resume", "set",
                "--workspace", "11111111-1111-1111-1111-111111111111",
                "--surface", "22222222-2222-2222-2222-222222222222",
                "myapp",
                "--",
                "--flag",
            ],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertTrue(result.stderr.contains("surface resume set: unexpected argument 'myapp' before --"))
        XCTAssertFalse(result.stderr.contains("Socket"), result.stderr)
    }

    func testSurfaceResumeSetCLIRejectsDanglingValueOptionsBeforeSocketRequest() throws {
        let cliPath = try bundledCLIPath()
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let missingSocketPath = "/tmp/cmux-test-missing-\(UUID().uuidString).sock"
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = missingSocketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let cases: [(arguments: [String], expected: String)] = [
            (
                [
                    "surface", "resume", "set",
                    "--workspace", workspaceId,
                    "--surface",
                ],
                "surface resume set: --surface requires a value"
            ),
            (
                [
                    "surface", "resume", "set",
                    "--workspace", workspaceId,
                    "--surface", surfaceId,
                    "--shell",
                ],
                "surface resume set: --shell requires a value"
            ),
            (
                [
                    "surface", "resume", "set",
                    "--workspace", workspaceId,
                    "--surface", surfaceId,
                    "--shell", "--",
                ],
                "surface resume set: --shell requires a value"
            ),
        ]

        for item in cases {
            let result = runProcess(
                executablePath: cliPath,
                arguments: item.arguments,
                environment: environment,
                timeout: 5
            )

            XCTAssertFalse(result.timedOut, result.stderr)
            XCTAssertEqual(result.status, 1, result.stderr)
            XCTAssertTrue(result.stdout.isEmpty, result.stdout)
            XCTAssertTrue(result.stderr.contains(item.expected), result.stderr)
            XCTAssertFalse(result.stderr.contains("Socket"), result.stderr)
        }
    }

    func testSurfaceResumeClearCLIRejectsMalformedGuardsBeforeClearing() throws {
        let cliPath = try bundledCLIPath()
        let missingSocketPath = "/tmp/cmux-test-missing-\(UUID().uuidString).sock"

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = missingSocketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "surface", "resume", "clear",
                "--workspace", "11111111-1111-1111-1111-111111111111",
                "--surface", "22222222-2222-2222-2222-222222222222",
                "--checkpoint",
            ],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.contains("surface resume clear: --checkpoint requires a value"))
        XCTAssertFalse(result.stderr.contains("Socket"), result.stderr)
    }

    func testSurfaceResumeClearCLINormalizesWindowIndex() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("resume-clear-window")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let windowId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let surfaceId = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let surfaceRef = "surface:7"
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
                    result: ["windows": [["id": windowId, "ref": "window:1", "index": 0]]]
                )
            case "window.focus":
                return self.v2Response(id: id, ok: true, result: ["window_id": windowId])
            case "surface.list":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["window_id"] as? String, windowId)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["surfaces": [["id": surfaceId, "ref": surfaceRef, "index": 0]]]
                )
            case "surface.resume.clear":
                return self.v2Response(id: id, ok: true, result: ["cleared": true])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--window", "0", "surface", "resume", "clear", "--surface", "0"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")

        let clearRequests = state.commands.compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.clear" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        XCTAssertFalse(
            state.commands.contains { command in
                jsonObject(command)?["method"] as? String == "window.focus"
            },
            "surface resume metadata commands should route by window_id without focusing the window"
        )
        let request = try XCTUnwrap(clearRequests.first)
        XCTAssertEqual(request["window_id"] as? String, windowId)
        XCTAssertNotEqual(request["window_id"] as? String, "0")
        XCTAssertEqual(request["surface_id"] as? String, surfaceId)
    }

    func testSurfaceResumeClearCLIParsesLocalWindowOption() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("resume-clear-local-window")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let windowId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let surfaceId = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
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
                    result: ["windows": [["id": windowId, "ref": "window:1", "index": 0]]]
                )
            case "surface.list":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["window_id"] as? String, windowId)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["surfaces": [["id": surfaceId, "ref": "surface:7", "index": 0]]]
                )
            case "surface.resume.clear":
                return self.v2Response(id: id, ok: true, result: ["cleared": true])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["surface", "resume", "clear", "--window", "0", "--surface", "0"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK\n")
        XCTAssertFalse(
            state.commands.contains { command in
                jsonObject(command)?["method"] as? String == "window.focus"
            },
            "local --window should route surface resume metadata without focusing the window"
        )

        let clearRequests = state.commands.compactMap { command -> [String: Any]? in
            guard let payload = jsonObject(command),
                  payload["method"] as? String == "surface.resume.clear" else {
                return nil
            }
            return payload["params"] as? [String: Any]
        }
        let request = try XCTUnwrap(clearRequests.first)
        XCTAssertEqual(request["window_id"] as? String, windowId)
        XCTAssertEqual(request["surface_id"] as? String, surfaceId)
    }

}
