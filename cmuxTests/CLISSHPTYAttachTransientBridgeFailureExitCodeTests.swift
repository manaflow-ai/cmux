import Darwin
import Foundation
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    func testSSHPTYAttachBridgeRPCTimeoutExitsRetryable() throws {
        try assertSSHPTYAttachBridgeRPCFailureExitCode(
            socketName: "sshptytimeout",
            error: [
                "code": "remote_pty_bridge_timeout",
                "message": "workspace.remote.pty_bridge timed out waiting for the remote daemon",
            ],
            expectedStatus: 255
        )
    }

    func testSSHPTYAttachBridgeRPCConnectionNotActiveExitsRetryable() throws {
        try assertSSHPTYAttachBridgeRPCFailureExitCode(
            socketName: "sshptynotactive",
            error: [
                "code": "remote_connection_inactive",
                "message": "remote connection is not active",
            ],
            expectedStatus: 255
        )
    }

    func testSSHPTYAttachUnknownFlagStaysFatal() throws {
        let cliPath = try bundledCLIPath()
        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-pty-attach",
                "--bogus-flag",
            ],
            environment: sshPTYAttachTestEnvironment(socketPath: makeSocketPath("sshptybogus")),
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
    }

    private func assertSSHPTYAttachBridgeRPCFailureExitCode(
        socketName: String,
        error: [String: Any],
        expectedStatus: Int32
    ) throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath(socketName)
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let surfaceId = "33333333-3333-3333-3333-333333333333"
        let sessionId = "ssh-\(workspaceId)-\(surfaceId)"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let socketHandled = startMockServer(
            listenerFD: listenerFD,
            state: state,
            fulfillWhen: { line in
                guard let payload = self.jsonObject(line) else { return false }
                return payload["method"] as? String == "workspace.remote.pty_bridge"
            }
        ) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "workspace.remote.pty_bridge":
                XCTAssertEqual(params["workspace_id"] as? String, workspaceId)
                XCTAssertEqual(params["session_id"] as? String, sessionId)
                XCTAssertEqual(params["attachment_id"] as? String, surfaceId)
                XCTAssertEqual(params["require_existing"] as? Bool, true)
                return self.v2Response(id: id, ok: false, error: error)
            case "workspace.remote.pty_detach":
                return self.v2Response(id: id, ok: true, result: ["detached": true])
            case "workspace.remote.pty_attach_end":
                return self.v2Response(id: id, ok: true, result: ["ended": true])
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-pty-attach",
                "--wait",
                "--require-existing",
                "--workspace", workspaceId,
                "--session-id", sessionId,
                "--attachment-id", surfaceId,
            ],
            environment: sshPTYAttachTestEnvironment(socketPath: socketPath),
            timeout: 5
        )

        wait(for: [socketHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, expectedStatus, result.stderr)

        let methods = state.snapshot().compactMap { self.jsonObject($0)?["method"] as? String }
        XCTAssertTrue(methods.contains("workspace.remote.pty_bridge"), "\(methods)")
        // Wrapper-retryable failures re-run the attach on this same surface;
        // sending pty_attach_end here would untrack it app-side and a
        // successful retry never re-tracks it.
        XCTAssertFalse(methods.contains("workspace.remote.pty_attach_end"), "\(methods)")
    }

    func testSSHPTYAttachSilentBridgeTimesOutRetryable() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshptysilent")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let bridge = try bindLoopbackTCP()
        let state = MockSocketServerState()
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let surfaceId = "33333333-3333-3333-3333-333333333333"
        let sessionId = "ssh-\(workspaceId)-\(surfaceId)"
        let token = "bridge-token"

        defer {
            Darwin.close(listenerFD)
            Darwin.close(bridge.fd)
            unlink(socketPath)
        }

        let socketHandled = startMockServer(
            listenerFD: listenerFD,
            state: state,
            fulfillWhen: { line in
                guard let payload = self.jsonObject(line) else { return false }
                return payload["method"] as? String == "workspace.remote.pty_bridge"
            }
        ) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            switch method {
            case "workspace.remote.pty_bridge":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "host": "127.0.0.1",
                        "port": bridge.port,
                        "token": token,
                        "session_id": sessionId,
                        "attachment_id": surfaceId,
                    ]
                )
            case "workspace.remote.pty_detach":
                return self.v2Response(id: id, ok: true, result: ["detached": true])
            case "workspace.remote.pty_attach_end":
                return self.v2Response(id: id, ok: true, result: ["ended": true])
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
        }
        let bridgeHandled = startSilentBridgeServer(listenerFD: bridge.fd)

        var environment = sshPTYAttachTestEnvironment(socketPath: socketPath)
        environment["CMUX_SSH_PTY_BRIDGE_READY_TIMEOUT_SECONDS"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-pty-attach",
                "--require-existing",
                "--workspace", workspaceId,
                "--session-id", sessionId,
                "--attachment-id", surfaceId,
            ],
            environment: environment,
            timeout: 10
        )

        wait(for: [socketHandled, bridgeHandled], timeout: 10)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 255, result.stderr)
        XCTAssertTrue(
            result.stderr.contains("timed out waiting for bridge status"),
            result.stderr
        )
        let methods = state.snapshot().compactMap { self.jsonObject($0)?["method"] as? String }
        XCTAssertTrue(methods.contains("workspace.remote.pty_bridge"), "\(methods)")
        // Wrapper-retryable failures re-run the attach on this same surface;
        // sending pty_attach_end here would untrack it app-side and a
        // successful retry never re-tracks it.
        XCTAssertFalse(methods.contains("workspace.remote.pty_attach_end"), "\(methods)")
    }

    /// Accepts one bridge connection, drains the client handshake, and never
    /// writes a status line, so the CLI's bounded ready wait must fire.
    private func startSilentBridgeServer(listenerFD: Int32) -> XCTestExpectation {
        let handled = expectation(description: "silent pty bridge server handled")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { handled.fulfill() }

            var clientAddr = sockaddr_in()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else { return }
            defer { Darwin.close(clientFD) }

            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count > 0 { continue }
                if count < 0 && errno == EINTR { continue }
                return
            }
        }
        return handled
    }

    private func sshPTYAttachTestEnvironment(socketPath: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        return environment
    }
}
