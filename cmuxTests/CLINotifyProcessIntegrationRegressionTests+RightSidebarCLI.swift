import XCTest
import Darwin
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Right sidebar CLI
extension CLINotifyProcessIntegrationRegressionTests {
    func testRightSidebarCLIForwardsV1SocketCommandsQuietly() throws {
        let cliPath = try bundledCLIPath()
        let cases: [(name: String, arguments: [String], expectedCommand: String, response: String, stdout: String)] = [
            ("toggle", ["right-sidebar", "toggle"], "right_sidebar toggle", "OK", ""),
            ("show", ["right-sidebar", "show"], "right_sidebar show", "OK", ""),
            ("hide", ["right-sidebar", "hide"], "right_sidebar hide", "OK", ""),
            ("focus", ["right-sidebar", "focus"], "right_sidebar focus", "OK", ""),
            ("set-find", ["right-sidebar", "set", "find"], "right_sidebar set find", "OK", ""),
            ("set-no-focus", ["right-sidebar", "set", "vault", "--no-focus"], "right_sidebar set vault --no-focus", "OK", ""),
            ("set-sessions", ["right-sidebar", "set", "sessions"], "right_sidebar set sessions", "OK", ""),
            ("files-alias", ["right-sidebar", "files"], "right_sidebar set files", "OK", ""),
            ("find-alias", ["right-sidebar", "find"], "right_sidebar set find", "OK", ""),
            ("vault-alias", ["right-sidebar", "vault"], "right_sidebar set vault", "OK", ""),
            ("sessions-alias", ["right-sidebar", "sessions"], "right_sidebar set sessions", "OK", ""),
            ("feed-alias", ["right-sidebar", "feed"], "right_sidebar set feed", "OK", ""),
            ("dock-alias", ["right-sidebar", "dock"], "right_sidebar set dock", "OK", ""),
            ("mode", ["right-sidebar", "mode"], "right_sidebar mode", #"{"visible":true,"mode":"find"}"#, #"{"visible":true,"mode":"find"}"# + "\n"),
        ]

        for item in cases {
            let socketPath = makeSocketPath("rs-\(item.name)")
            let listenerFD = try bindUnixSocket(at: socketPath)
            let state = MockSocketServerState()
            defer {
                Darwin.close(listenerFD)
                unlink(socketPath)
            }

            let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
                XCTAssertEqual(line, item.expectedCommand)
                return item.response
            }

            var environment = ProcessInfo.processInfo.environment
            environment["CMUX_SOCKET_PATH"] = socketPath
            environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

            let result = runProcess(
                executablePath: cliPath,
                arguments: item.arguments,
                environment: environment,
                timeout: 5
            )

            wait(for: [serverHandled], timeout: 5)
            XCTAssertFalse(result.timedOut, "\(item.name): \(result.stderr)")
            XCTAssertEqual(result.status, 0, "\(item.name): \(result.stderr)")
            XCTAssertEqual(result.stdout, item.stdout, item.name)
            XCTAssertTrue(result.stderr.isEmpty, "\(item.name): \(result.stderr)")
            XCTAssertEqual(state.commands, [item.expectedCommand], item.name)
        }
    }

    func testRightSidebarInvalidCommandValidatesBeforeTargetResolution() throws {
        let cliPath = try bundledCLIPath()
        let missingSocketPath = "/tmp/cmux-test-missing-\(UUID().uuidString).sock"
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = missingSocketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["right-sidebar", "unknown", "--workspace", "workspace:2"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertTrue(result.stdout.isEmpty, result.stdout)
        XCTAssertTrue(result.stderr.contains("Unknown right-sidebar command 'unknown'"), result.stderr)
        XCTAssertFalse(result.stderr.contains("Socket"), result.stderr)
    }

    func testRightSidebarInvalidSetModeValidatesBeforeTargetResolution() throws {
        let cliPath = try bundledCLIPath()
        let missingSocketPath = "/tmp/cmux-test-missing-\(UUID().uuidString).sock"
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = missingSocketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["right-sidebar", "set", "unknown", "--workspace", "workspace:2"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertTrue(result.stdout.isEmpty, result.stdout)
        XCTAssertTrue(result.stderr.contains("Unknown right-sidebar mode 'unknown'"), result.stderr)
        XCTAssertFalse(result.stderr.contains("Socket"), result.stderr)
    }

    func testRightSidebarCLIResolvesWindowAndWorkspaceHandlesBeforeForwarding() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("rs-target")
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
                switch method {
                case "window.list":
                    return self.v2Response(
                        id: id,
                        ok: true,
                        result: [
                            "windows": [
                                ["id": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", "index": 1],
                                ["id": windowId, "index": 3],
                            ]
                        ]
                    )
                case "workspace.list":
                    let params = payload["params"] as? [String: Any] ?? [:]
                    XCTAssertEqual(params["window_id"] as? String, windowId)
                    return self.v2Response(
                        id: id,
                        ok: true,
                        result: [
                            "workspaces": [
                                ["id": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", "index": 1],
                                ["id": workspaceId, "index": 2],
                            ]
                        ]
                    )
                default:
                    return self.v2Response(
                        id: id,
                        ok: false,
                        error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                    )
                }
            }

            XCTAssertEqual(line, "right_sidebar set find --tab=\(workspaceId) --window=\(windowId)")
            return "OK"
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["right-sidebar", "set", "find", "--window", "window:3", "--workspace", "workspace:2"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.isEmpty, result.stdout)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["window.list", "workspace.list"]
        )
        XCTAssertEqual(state.commands.last, "right_sidebar set find --tab=\(workspaceId) --window=\(windowId)")
    }

    func testRightSidebarCLIRejectsUnresolvedWorkspaceHandleBeforeForwarding() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("rs-miss")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return "ERROR: Unexpected command \(line)"
            }
            XCTAssertEqual(method, "workspace.list")
            return self.v2Response(
                id: id,
                ok: true,
                result: [
                    "workspaces": [
                        ["id": "11111111-1111-1111-1111-111111111111", "index": 1]
                    ]
                ]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["right-sidebar", "show", "--workspace", "workspace:99"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertTrue(result.stdout.isEmpty, result.stdout)
        XCTAssertTrue(result.stderr.contains("Workspace ref not found"), result.stderr)
        XCTAssertEqual(
            state.commands.compactMap { self.jsonObject($0)?["method"] as? String },
            ["workspace.list"]
        )
        XCTAssertFalse(
            state.commands.contains { $0.hasPrefix("right_sidebar ") },
            "Expected no right_sidebar command after target resolution failed, saw \(state.commands)"
        )
    }

}
