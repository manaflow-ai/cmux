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
