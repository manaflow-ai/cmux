import Darwin
import Foundation
import XCTest

/// Lock-protected because the mock socket server invokes handlers from
/// explicitly @Sendable closures.
private final class BridgeRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

extension CLINotifyProcessIntegrationRegressionTests {
    func testSSHPTYAttachSessionLostRespawnsWithoutRequireExisting() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshptyrespawn")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let firstBridge = try bindLoopbackTCP()
        let secondBridge = try bindLoopbackTCP()
        let state = MockSocketServerState()
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let surfaceId = "33333333-3333-3333-3333-333333333333"
        let sessionId = "ssh-\(workspaceId)-\(surfaceId)"

        defer {
            Darwin.close(listenerFD)
            Darwin.close(firstBridge.fd)
            Darwin.close(secondBridge.fd)
            unlink(socketPath)
        }

        let bridgeCounter = BridgeRequestCounter()
        let socketHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "workspace.remote.pty_bridge":
                let bridgeCount = bridgeCounter.next()
                XCTAssertEqual(params["workspace_id"] as? String, workspaceId)
                XCTAssertEqual(params["session_id"] as? String, sessionId)
                XCTAssertEqual(params["attachment_id"] as? String, surfaceId)
                let bridge = bridgeCount == 1 ? firstBridge : secondBridge
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "host": "127.0.0.1",
                        "port": bridge.port,
                        "token": "bridge-token-\(bridgeCount)",
                        "session_id": sessionId,
                        "lifecycle_id": params["lifecycle_id"] as? String ?? "",
                        "attachment_id": surfaceId,
                    ]
                )
            case "workspace.remote.pty_resize":
                return self.v2Response(id: id, ok: true, result: ["resized": true])
            case "workspace.remote.pty_sessions":
                return self.v2Response(id: id, ok: true, result: ["sessions": []])
            case "workspace.remote.pty_attach_end":
                XCTAssertEqual(params["workspace_id"] as? String, workspaceId)
                XCTAssertEqual(params["surface_id"] as? String, surfaceId)
                XCTAssertEqual(params["session_id"] as? String, sessionId)
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
        let firstBridgeHandled = startBridgeErrorServer(
            listenerFD: firstBridge.fd,
            message: "persistent SSH PTY session is no longer running",
            code: "pty_session_not_found"
        )
        let secondBridgeHandled = startBridgeReadyThenCloseServer(listenerFD: secondBridge.fd)

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

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
            environment: environment,
            timeout: 5
        )

        wait(for: [socketHandled, firstBridgeHandled, secondBridgeHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.isEmpty, result.stdout)
        XCTAssertTrue(
            result.stderr.contains("[cmux] remote session was lost; starting a new shell."),
            result.stderr
        )

        let requests = state.snapshot().compactMap { self.jsonObject($0) }
        let bridgeRequireExisting = requests.compactMap { request -> Bool? in
            guard request["method"] as? String == "workspace.remote.pty_bridge" else { return nil }
            return (request["params"] as? [String: Any])?["require_existing"] as? Bool
        }
        XCTAssertEqual(bridgeRequireExisting, [true, false])
        let lifecycleIDs = requests.compactMap { request -> String? in
            guard ["workspace.remote.pty_bridge", "workspace.remote.pty_sessions"]
                .contains(request["method"] as? String) else { return nil }
            return (request["params"] as? [String: Any])?["lifecycle_id"] as? String
        }
        XCTAssertFalse(lifecycleIDs.isEmpty)
        XCTAssertEqual(Set(lifecycleIDs).count, 1, "logical generation changed across respawn: \(lifecycleIDs)")

        // The session-lost respawn must keep the app-side surface tracking
        // intact between the failed require-existing attach and the fresh
        // attach: a pty_attach_end fired in that window untracks the surface
        // and marks it ended while the replacement shell is about to run. The
        // only legitimate attach_end is the final one, after the respawned
        // bridge closed and pty_sessions confirmed the remote PTY exited.
        let methods = requests.compactMap { $0["method"] as? String }
        XCTAssertEqual(
            methods.filter { $0 == "workspace.remote.pty_attach_end" }.count,
            1,
            "expected only the final post-exit pty_attach_end: \(methods)"
        )
        let bridgeIndices = methods.indices.filter { methods[$0] == "workspace.remote.pty_bridge" }
        XCTAssertEqual(bridgeIndices.count, 2, "expected two pty_bridge requests: \(methods)")
        if bridgeIndices.count == 2 {
            XCTAssertFalse(
                methods[..<bridgeIndices[1]].contains("workspace.remote.pty_attach_end"),
                "pty_attach_end must not fire before the respawn bridge request: \(methods)"
            )
        }
    }

    func testSSHPTYAttachIntentionalCleanupEndsWithoutRetrying() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshptycleanup")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let bridge = try bindLoopbackTCP()
        let state = MockSocketServerState()
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let surfaceId = "33333333-3333-3333-3333-333333333333"
        let sessionId = "ssh-\(workspaceId)-\(surfaceId)"

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
                return self.v2Response(id: id, ok: true, result: [
                    "host": "127.0.0.1",
                    "port": bridge.port,
                    "token": "bridge-token",
                    "session_id": sessionId,
                    "lifecycle_id": surfaceId,
                    "attachment_id": surfaceId,
                ])
            case "workspace.remote.pty_resize":
                return self.v2Response(id: id, ok: true, result: ["resized": true])
            case "workspace.remote.pty_sessions":
                return self.v2Response(id: id, ok: true, result: [
                    "requested_session_lifecycle": "intentional_cleanup_requested",
                    "sessions": [["session_id": sessionId]],
                    "errors": [["error": "remote connection is not active"]],
                ])
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
        let bridgeHandled = startBridgeReadyThenCloseServer(listenerFD: bridge.fd)

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
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
            environment: environment,
            timeout: 5
        )

        wait(for: [socketHandled, bridgeHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let methods = state.snapshot().compactMap { self.jsonObject($0)?["method"] as? String }
        XCTAssertEqual(methods.filter { $0 == "workspace.remote.pty_bridge" }.count, 1, "\(methods)")
        XCTAssertEqual(methods.filter { $0 == "workspace.remote.pty_attach_end" }.count, 1, "\(methods)")
    }

    func testSSHPTYAttachClosedGenerationBeforeReadyEndsWithoutWrapperRetry() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshptyclosedstart")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let surfaceId = "33333333-3333-3333-3333-333333333333"
        let sessionId = "ssh-\(workspaceId)-\(surfaceId)"
        let lifecycleId = "44444444-4444-4444-4444-444444444444"
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let socketHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            if method != "workspace.remote.pty_attach_end" {
                XCTAssertEqual(params["lifecycle_id"] as? String, lifecycleId)
            }
            switch method {
            case "workspace.remote.pty_bridge":
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "pty_lifecycle_closed", "message": "remote PTY operation failed"]
                )
            case "workspace.remote.pty_sessions":
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "remote_pty_error", "message": "reconciliation unavailable"]
                )
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

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SSH_PTY_ATTACH_WRAPPER_CAN_RETRY"] = "1"
        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-pty-attach", "--wait", "--require-existing",
                "--workspace", workspaceId, "--session-id", sessionId,
                "--lifecycle-id", lifecycleId, "--attachment-id", surfaceId,
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [socketHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let methods = state.snapshot().compactMap { self.jsonObject($0)?["method"] as? String }
        XCTAssertEqual(methods.filter { $0 == "workspace.remote.pty_bridge" }.count, 1, "\(methods)")
        XCTAssertEqual(methods.filter { $0 == "workspace.remote.pty_attach_end" }.count, 1, "\(methods)")
    }

    func testSSHPTYAttachTransientPreReadyFailureKeepsLifecycleForRetry() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshptypreretry")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let firstBridge = try bindLoopbackTCP()
        let secondBridge = try bindLoopbackTCP()
        let state = MockSocketServerState()
        let bridgeCounter = BridgeRequestCounter()
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let surfaceId = "33333333-3333-3333-3333-333333333333"
        let lifecycleId = "44444444-4444-4444-4444-444444444444"
        let sessionId = "ssh-\(workspaceId)-\(surfaceId)"
        defer {
            Darwin.close(listenerFD)
            Darwin.close(firstBridge.fd)
            Darwin.close(secondBridge.fd)
            unlink(socketPath)
        }

        let socketHandled = startMockServer(
            listenerFD: listenerFD,
            state: state,
            connectionCount: 2
        ) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            if method != "workspace.remote.pty_attach_end" {
                XCTAssertEqual(params["lifecycle_id"] as? String, lifecycleId)
            }
            switch method {
            case "workspace.remote.pty_bridge":
                let count = bridgeCounter.next()
                let bridge = count == 1 ? firstBridge : secondBridge
                return self.v2Response(id: id, ok: true, result: [
                    "host": "127.0.0.1", "port": bridge.port,
                    "token": "bridge-token-\(count)", "session_id": sessionId,
                    "lifecycle_id": lifecycleId, "attachment_id": surfaceId,
                ])
            case "workspace.remote.pty_resize":
                return self.v2Response(id: id, ok: true, result: ["resized": true])
            case "workspace.remote.pty_sessions":
                return self.v2Response(id: id, ok: true, result: ["sessions": []])
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
        let firstBridgeHandled = startBridgeErrorServer(
            listenerFD: firstBridge.fd,
            message: "connection reset",
            code: "remote_pty_error"
        )
        let secondBridgeHandled = startBridgeReadyThenCloseServer(listenerFD: secondBridge.fd)
        let arguments = [
            "ssh-pty-attach", "--wait", "--workspace", workspaceId,
            "--session-id", sessionId, "--lifecycle-id", lifecycleId,
            "--attachment-id", surfaceId,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SSH_PTY_ATTACH_WRAPPER_CAN_RETRY"] = "1"

        let first = runProcess(
            executablePath: cliPath,
            arguments: arguments,
            environment: environment,
            timeout: 5
        )
        XCTAssertFalse(first.timedOut, first.stderr)
        XCTAssertEqual(first.status, SSHPTYAttachExitCode.retryableTransient.rawValue, first.stderr)

        environment["CMUX_SSH_PTY_ATTACH_WRAPPER_CAN_RETRY"] = "0"
        let second = runProcess(
            executablePath: cliPath,
            arguments: arguments,
            environment: environment,
            timeout: 5
        )

        wait(for: [socketHandled, firstBridgeHandled, secondBridgeHandled], timeout: 5)
        XCTAssertFalse(second.timedOut, second.stderr)
        XCTAssertEqual(second.status, 0, second.stderr)
        let requests = state.snapshot().compactMap { self.jsonObject($0) }
        let reconciliationFlags = requests.compactMap { request -> Bool? in
            guard request["method"] as? String == "workspace.remote.pty_sessions" else { return nil }
            return (request["params"] as? [String: Any])?["acknowledge_lifecycle_if_session_absent"] as? Bool
        }
        XCTAssertEqual(reconciliationFlags, [false, true])
        let methods = requests.compactMap { $0["method"] as? String }
        XCTAssertEqual(methods.filter { $0 == "workspace.remote.pty_bridge" }.count, 2, "\(methods)")
        XCTAssertEqual(methods.filter { $0 == "workspace.remote.pty_attach_end" }.count, 1, "\(methods)")
    }

    private func startBridgeErrorServer(listenerFD: Int32, message: String, code: String) -> XCTestExpectation {
        let handled = expectation(description: "pty bridge coded error server handled")
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

            let payload: [String: Any] = ["type": "error", "message": message, "code": code]
            guard var data = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
            data.append(0x0A)
            data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                var remaining = rawBuffer.count
                var cursor = base
                while remaining > 0 {
                    let written = Darwin.write(clientFD, cursor, remaining)
                    if written > 0 {
                        remaining -= written
                        cursor = cursor.advanced(by: written)
                    } else if written < 0 && errno == EINTR {
                        continue
                    } else {
                        return
                    }
                }
            }
        }
        return handled
    }
}
