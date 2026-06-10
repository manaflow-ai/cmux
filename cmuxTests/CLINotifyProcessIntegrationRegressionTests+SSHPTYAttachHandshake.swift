import XCTest
import Darwin
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - SSH PTY attach handshake
extension CLINotifyProcessIntegrationRegressionTests {
    func testSSHPTYAttachWaitUsesCurrentTerminalSizeForBridgeHandshake() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshptysize")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let bridge = try bindLoopbackTCP()
        let state = MockSocketServerState()
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let surfaceId = "33333333-3333-3333-3333-333333333333"
        let sessionId = "ssh-\(workspaceId)-\(surfaceId)"
        let token = "bridge-token"
        let bridgeRequestReceived = DispatchSemaphore(value: 0)
        let allowBridgeResponse = DispatchSemaphore(value: 0)
        let handshakeReceived = DispatchSemaphore(value: 0)
        let handshakeLock = NSLock()
        var handshakePayload: [String: Any]?
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1

        defer {
            if masterFD >= 0 { Darwin.close(masterFD) }
            if slaveFD >= 0 { Darwin.close(slaveFD) }
            Darwin.close(listenerFD)
            Darwin.close(bridge.fd)
            unlink(socketPath)
        }

        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else {
            throw NSError(domain: "cmux.tests", code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "openpty failed: \(String(cString: strerror(errno)))",
            ])
        }

        func setPTYSize(cols: Int, rows: Int) throws {
            var size = winsize(
                ws_row: UInt16(rows),
                ws_col: UInt16(cols),
                ws_xpixel: 0,
                ws_ypixel: 0
            )
            guard ioctl(masterFD, TIOCSWINSZ, &size) == 0 else {
                throw NSError(domain: "cmux.tests", code: Int(errno), userInfo: [
                    NSLocalizedDescriptionKey: "TIOCSWINSZ failed: \(String(cString: strerror(errno)))",
                ])
            }
        }

        try setPTYSize(cols: 40, rows: 12)

        let socketHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            switch method {
            case "workspace.remote.pty_bridge":
                bridgeRequestReceived.signal()
                _ = allowBridgeResponse.wait(timeout: .now() + 5)
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

        let bridgeHandled = expectation(description: "bridge handshake captured")
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
            if let lineEnd = pending.firstIndex(of: 0x0A) {
                let line = pending.prefix(upTo: lineEnd)
                let payload = try? JSONSerialization.jsonObject(with: Data(line), options: []) as? [String: Any]
                handshakeLock.lock()
                handshakePayload = payload
                handshakeLock.unlock()
                handshakeReceived.signal()
            }

            let ready = #"{"type":"ready","attachment_token":"attach-token"}"# + "\n"
            _ = ready.withCString { ptr in
                Darwin.write(clientFD, ptr, strlen(ptr))
            }
        }

        let process = Process()
        let stderrPipe = Pipe()
        let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        slaveFD = -1
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = [
            "ssh-pty-attach",
            "--wait",
            "--workspace", workspaceId,
            "--session-id", sessionId,
            "--attachment-id", surfaceId,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = slaveHandle
        process.standardError = stderrPipe

        try process.run()
        slaveHandle.closeFile()
        XCTAssertEqual(bridgeRequestReceived.wait(timeout: .now() + 5), .success)
        try setPTYSize(cols: 132, rows: 43)
        allowBridgeResponse.signal()
        XCTAssertEqual(handshakeReceived.wait(timeout: .now() + 5), .success)

        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exited.signal()
        }
        XCTAssertEqual(exited.wait(timeout: .now() + 5), .success)
        wait(for: [socketHandled, bridgeHandled], timeout: 5)

        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, stderr)
        handshakeLock.lock()
        let capturedHandshake = handshakePayload
        handshakeLock.unlock()
        XCTAssertEqual(capturedHandshake?["token"] as? String, token)
        XCTAssertEqual(capturedHandshake?["cols"] as? Int, 132)
        XCTAssertEqual(capturedHandshake?["rows"] as? Int, 43)
    }

    func testSSHPTYAttachSerializesResizeBeforeEOFLocalCleanup() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshptyresize")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let bridge = try bindLoopbackTCP()
        let state = MockSocketServerState()
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let surfaceId = "33333333-3333-3333-3333-333333333333"
        let sessionId = "ssh-\(workspaceId)-\(surfaceId)"
        let token = "bridge-token"
        let resizeRequestReceived = DispatchSemaphore(value: 0)
        let allowResizeResponse = DispatchSemaphore(value: 0)
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
                guard let params = payload["params"] as? [String: Any],
                      params["attachment_token"] as? String == "attach-token" else {
                    return self.v2Response(
                        id: id,
                        ok: false,
                        error: ["code": "missing_token", "message": "Missing attachment token"]
                    )
                }
                resizeRequestReceived.signal()
                _ = allowResizeResponse.wait(timeout: .now() + 5)
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["errors": [["error": "resize response marker"]]]
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

        var sawResize = false
        for _ in 0..<10 {
            Darwin.kill(process.processIdentifier, SIGWINCH)
            if resizeRequestReceived.wait(timeout: .now() + 0.2) == .success {
                sawResize = true
                break
            }
        }
        XCTAssertTrue(sawResize, "Expected ssh-pty-attach to issue a resize RPC after SIGWINCH")

        closeBridge.signal()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        allowResizeResponse.signal()

        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exited.signal()
        }
        XCTAssertEqual(exited.wait(timeout: .now() + 5), .success)

        wait(for: [socketHandled, bridgeHandled], timeout: 5)
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, stderr)
        XCTAssertEqual(stdout, "")
        XCTAssertEqual(stderr, "")
        let methods = state.snapshot().compactMap { self.jsonObject($0)?["method"] as? String }
        XCTAssertEqual(methods, [
            "workspace.remote.pty_bridge",
            "workspace.remote.pty_resize",
            "workspace.remote.pty_sessions",
            "workspace.remote.pty_attach_end",
        ])
    }

    func testSSHSessionAttachCreatesSurfaceWithPersistedPTYSessionID() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshattach")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let surfaceId = "33333333-3333-3333-3333-333333333333"
        let sessionId = "ssh-existing-session"

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
            XCTAssertEqual(method, "surface.create")
            let params = payload["params"] as? [String: Any] ?? [:]
            XCTAssertEqual(params["workspace_id"] as? String, workspaceId)
            XCTAssertEqual(params["remote_pty_session_id"] as? String, sessionId)
            XCTAssertEqual(params["focus"] as? Bool, true)
            let initialCommand = params["initial_command"] as? String ?? ""
            XCTAssertTrue(initialCommand.hasPrefix("/bin/sh -c "), initialCommand)
            XCTAssertTrue(initialCommand.contains("ssh-pty-attach"), initialCommand)
            XCTAssertTrue(initialCommand.contains("--require-existing"), initialCommand)
            XCTAssertTrue(initialCommand.contains(sessionId), initialCommand)
            XCTAssertTrue(initialCommand.contains("CMUX_WORKSPACE_ID"), initialCommand)
            XCTAssertTrue(initialCommand.contains("CMUX_SURFACE_ID"), initialCommand)
            XCTAssertTrue(initialCommand.contains("254|255"), initialCommand)
            return self.v2Response(
                id: id,
                ok: true,
                result: [
                    "workspace_id": workspaceId,
                    "workspace_ref": "workspace:1",
                    "pane_id": "44444444-4444-4444-4444-444444444444",
                    "pane_ref": "pane:1",
                    "surface_id": surfaceId,
                    "surface_ref": "surface:1",
                    "type": "terminal",
                ]
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh-session-attach",
                "--workspace", workspaceId,
                "--session-id", sessionId,
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        XCTAssertEqual(state.snapshot().count, 1)
    }

    func testSSHPTYAttachRequireExistingPassesBridgeFlag() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshreq")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let bridge = try bindLoopbackTCP()
        let state = MockSocketServerState()
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let surfaceId = "33333333-3333-3333-3333-333333333333"
        let sessionId = "ssh-existing-session"
        let token = "bridge-token"

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
            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "workspace.remote.pty_bridge":
                XCTAssertEqual(params["workspace_id"] as? String, workspaceId)
                XCTAssertEqual(params["session_id"] as? String, sessionId)
                XCTAssertEqual(params["attachment_id"] as? String, surfaceId)
                XCTAssertEqual(params["require_existing"] as? Bool, true)
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
        let bridgeHandled = startBridgeErrorServer(listenerFD: bridge.fd, message: "missing session")

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
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertTrue(result.stderr.contains("ssh-pty-attach: missing session"), result.stderr)
        let methods = state.snapshot().compactMap { self.jsonObject($0)?["method"] as? String }
        XCTAssertEqual(methods, [
            "workspace.remote.pty_bridge",
            "workspace.remote.pty_attach_end",
        ])
    }

    func testSSHPTYAttachRequireExistingSessionNotFoundFailsWithoutWaitRetry() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshreqmissing")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let surfaceId = "33333333-3333-3333-3333-333333333333"
        let sessionId = "ssh-missing-session"

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
            switch method {
            case "workspace.remote.pty_bridge":
                XCTAssertEqual(params["workspace_id"] as? String, workspaceId)
                XCTAssertEqual(params["session_id"] as? String, sessionId)
                XCTAssertEqual(params["attachment_id"] as? String, surfaceId)
                XCTAssertEqual(params["require_existing"] as? Bool, true)
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: [
                        "code": "pty_session_not_found",
                        "message": "persistent PTY session \"\(sessionId)\" is not running",
                    ]
                )
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
            timeout: 3
        )

        wait(for: [socketHandled], timeout: 3)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertTrue(result.stderr.contains("persistent SSH PTY session is no longer running"), result.stderr)
        let methods = state.snapshot().compactMap { self.jsonObject($0)?["method"] as? String }
        XCTAssertEqual(methods, [
            "workspace.remote.pty_bridge",
            "workspace.remote.pty_attach_end",
        ])
    }

}
