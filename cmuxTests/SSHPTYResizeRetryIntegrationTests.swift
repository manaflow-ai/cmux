import XCTest
import Darwin

// Regression coverage for #6306, kept in its own file so the large
// CLINotifyProcessIntegrationRegressionTests.swift stays within the Swift
// file-length budget. It extends the same test class to reuse the existing
// mock-socket / bundled-CLI harness helpers.
extension CLINotifyProcessIntegrationRegressionTests {
    // Regression for #6306: a failed workspace.remote.pty_resize must be retried
    // (with the latest size) instead of silently dropped, otherwise the remote
    // PTY/TUI can stay stuck at a stale geometry until a manual workspace
    // reconnect. Here every resize RPC fails; a single user SIGWINCH must still
    // produce a *second* resize attempt with no further signals. Before the fix
    // (best-effort `try?`), the failed send was dropped and the second attempt
    // never arrived.
    func testSSHPTYAttachRetriesResizeAfterDeliveryFailure() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshptyretry")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let bridge = try bindLoopbackTCP()
        let state = MockSocketServerState()
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let surfaceId = "33333333-3333-3333-3333-333333333333"
        let sessionId = "ssh-\(workspaceId)-\(surfaceId)"
        let token = "bridge-token"
        let resizeReceived = DispatchSemaphore(value: 0)
        let bridgeReady = DispatchSemaphore(value: 0)
        let closeBridge = DispatchSemaphore(value: 0)

        defer {
            Darwin.close(listenerFD)
            Darwin.close(bridge.fd)
            unlink(socketPath)
        }

        let socketHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
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
            case "workspace.remote.pty_resize":
                // Always fail delivery to simulate a stale/blocked remote
                // control path so the CLI must retry the latest size.
                resizeReceived.signal()
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "remote_unavailable", "message": "remote connection is not active"]
                )
            case "workspace.remote.pty_sessions":
                return self.v2Response(id: id, ok: true, result: ["sessions": []])
            case "workspace.remote.pty_attach_end":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceId,
                        "surface_id": surfaceId,
                        "session_id": sessionId,
                        "cleared_remote_pty_session": true,
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

        let bridgeHandled = expectation(description: "controlled bridge handled")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { bridgeHandled.fulfill() }
            var clientAddr = sockaddr_in()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(bridge.fd, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else { return }
            defer { Darwin.close(clientFD) }

            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while !pending.contains(0x0A) {
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if count == 0 { return }
                pending.append(buffer, count: count)
            }

            let ready = #"{"type":"ready","attachment_token":"attach-token"}"# + "\n"
            _ = ready.withCString { ptr in
                Darwin.write(clientFD, ptr, strlen(ptr))
            }
            bridgeReady.signal()
            _ = closeBridge.wait(timeout: .now() + 5)
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = [
            "ssh-pty-attach",
            "--workspace", workspaceId,
            "--session-id", sessionId,
            "--attachment-id", surfaceId,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }
        XCTAssertEqual(bridgeReady.wait(timeout: .now() + 5), .success)

        // Deliver SIGWINCH until the first resize RPC lands (the signal source
        // may not be installed the instant the bridge reports ready), then stop.
        var sawFirstResize = false
        for _ in 0..<20 {
            Darwin.kill(process.processIdentifier, SIGWINCH)
            if resizeReceived.wait(timeout: .now() + 0.2) == .success {
                sawFirstResize = true
                break
            }
        }
        XCTAssertTrue(sawFirstResize, "Expected ssh-pty-attach to issue an initial resize RPC after SIGWINCH")

        // No further SIGWINCH is sent. A second resize attempt can only arrive
        // from the coalesce/retry coordinator re-sending the latest size after
        // the first delivery failed. The pre-fix best-effort send would never
        // retry, so this would time out.
        XCTAssertEqual(
            resizeReceived.wait(timeout: .now() + 3),
            .success,
            "Expected ssh-pty-attach to retry the resize after a delivery failure"
        )

        closeBridge.signal()
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exited.signal()
        }
        _ = exited.wait(timeout: .now() + 5)
        if process.isRunning {
            process.terminate()
        }

        wait(for: [socketHandled, bridgeHandled], timeout: 5)
        let resizeCount = state.snapshot()
            .compactMap { self.jsonObject($0)?["method"] as? String }
            .filter { $0 == "workspace.remote.pty_resize" }
            .count
        XCTAssertGreaterThanOrEqual(
            resizeCount,
            2,
            "Expected at least one retry resize RPC, saw \(resizeCount)"
        )
    }
}
