import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct CLISSHPTYResizePollingTests {
    @Test
    func attachPollsPTYSizeChangesWithoutSIGWINCH() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshptypollresize")
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
        let bridgeCloseObserved = DispatchSemaphore(value: 0)
        let capturedResizeParams = CapturedResizeParams()
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
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        try setPTYSize(masterFD: masterFD, cols: 80, rows: 24)

        let socketHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return malformedRequestResponse(raw: line)
            }
            switch method {
            case "workspace.remote.pty_bridge":
                return v2Response(
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
                let params = payload["params"] as? [String: Any] ?? [:]
                capturedResizeParams.store(params)
                resizeRequestReceived.signal()
                _ = allowResizeResponse.wait(timeout: .now() + 5)
                return v2Response(id: id, ok: true, result: [:])
            case "workspace.remote.pty_sessions":
                return v2Response(id: id, ok: true, result: ["sessions": []])
            case "workspace.remote.pty_attach_end":
                return v2Response(
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
                return v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected_method", "message": "Unexpected method \(method)"]
                )
            }
        }

        let bridgeHandled = startBridgeServer(
            bridge: bridge,
            bridgeReady: bridgeReady,
            closeBridge: closeBridge,
            bridgeCloseObserved: bridgeCloseObserved
        )

        let process = Process()
        let stderrPipe = Pipe()
        let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        slaveFD = -1
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
        process.standardOutput = slaveHandle
        process.standardError = stderrPipe

        try process.run()
        slaveHandle.closeFile()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }
        #expect(bridgeReady.wait(timeout: .now() + 5) == .success)

        try setPTYSize(masterFD: masterFD, cols: 120, rows: 40)
        #expect(
            resizeRequestReceived.wait(timeout: .now() + 3) == .success,
            "Expected ssh-pty-attach to notice PTY size changes even when no SIGWINCH is delivered"
        )

        closeBridge.signal()
        #expect(bridgeCloseObserved.wait(timeout: .now() + 5) == .success)
        allowResizeResponse.signal()

        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exited.signal()
        }
        #expect(exited.wait(timeout: .now() + 5) == .success)
        #expect(socketHandled.wait(timeout: .now() + 5) == .success)
        #expect(bridgeHandled.wait(timeout: .now() + 5) == .success)

        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, Comment(rawValue: stderr))
        let resizeParams = capturedResizeParams.snapshot()
        #expect(resizeParams?["attachment_token"] as? String == "attach-token")
        #expect(resizeParams?["cols"] as? Int == 120)
        #expect(resizeParams?["rows"] as? Int == 40)
    }

    private final class BundleToken {}

    private final class MockSocketServerState: @unchecked Sendable {
        private let lock = NSLock()
        private var commands: [String] = []

        func append(_ command: String) {
            lock.lock()
            commands.append(command)
            lock.unlock()
        }

        func snapshot() -> [String] {
            lock.lock()
            let value = commands
            lock.unlock()
            return value
        }
    }

    private final class CapturedResizeParams: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String: Any]?

        func store(_ params: [String: Any]) {
            lock.lock()
            value = params
            lock.unlock()
        }

        func snapshot() -> [String: Any]? {
            lock.lock()
            let result = value
            lock.unlock()
            return result
        }
    }

    private struct LoopbackTCPListener {
        let fd: Int32
        let port: Int
    }

    private func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: BundleToken.self)
    }

    private func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-\(name.prefix(6))-\(shortID).sock")
            .path
    }

    private func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = Array(path.utf8)
        guard utf8.count < maxPathLength else {
            Darwin.close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { buffer in
                for index in 0..<utf8.count {
                    buffer[index] = CChar(bitPattern: utf8[index])
                }
                buffer[utf8.count] = 0
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return fd
    }

    private func bindLoopbackTCP() throws -> LoopbackTCPListener {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(0)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.getsockname(fd, sockaddrPtr, &boundLen)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        return LoopbackTCPListener(fd: fd, port: Int(UInt16(bigEndian: boundAddr.sin_port)))
    }

    private func startMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        handler: @escaping @Sendable (String) -> Data
    ) -> DispatchSemaphore {
        let handled = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { handled.signal() }
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else { return }
            defer { Darwin.close(clientFD) }

            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                while let newlineIndex = pending.firstIndex(of: 0x0A) {
                    let lineData = pending[..<newlineIndex]
                    pending.removeSubrange(pending.startIndex...newlineIndex)
                    let line = String(data: Data(lineData), encoding: .utf8) ?? ""
                    state.append(line)
                    writeAll(fd: clientFD, data: handler(line))
                }

                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count > 0 {
                    pending.append(buffer, count: count)
                } else if count == 0 {
                    return
                } else if errno != EINTR {
                    return
                }
            }
        }
        return handled
    }

    private func startBridgeServer(
        bridge: LoopbackTCPListener,
        bridgeReady: DispatchSemaphore,
        closeBridge: DispatchSemaphore,
        bridgeCloseObserved: DispatchSemaphore
    ) -> DispatchSemaphore {
        let handled = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { handled.signal() }
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
            ready.withCString { ptr in
                _ = Darwin.write(clientFD, ptr, strlen(ptr))
            }
            bridgeReady.signal()
            _ = closeBridge.wait(timeout: .now() + 5)
            bridgeCloseObserved.signal()
        }
        return handled
    }

    private func setPTYSize(masterFD: Int32, cols: Int, rows: Int) throws {
        var size = winsize(
            ws_row: UInt16(rows),
            ws_col: UInt16(cols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        guard ioctl(masterFD, TIOCSWINSZ, &size) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }

    private func malformedRequestResponse(raw: String) -> Data {
        v2Response(
            id: "malformed",
            ok: false,
            error: ["code": "malformed", "message": "Malformed request: \(raw)"]
        )
    }

    private func v2Response(
        id: Any,
        ok: Bool,
        result: [String: Any] = [:],
        error: [String: Any]? = nil
    ) -> Data {
        var payload: [String: Any] = ["id": id, "ok": ok]
        if ok {
            payload["result"] = result
        } else {
            payload["error"] = error ?? ["code": "error", "message": "error"]
        }
        var data = try! JSONSerialization.data(withJSONObject: payload, options: [])
        data.append(0x0A)
        return data
    }

    private func writeAll(fd: Int32, data: Data) {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var remaining = rawBuffer.count
            var cursor = base
            while remaining > 0 {
                let written = Darwin.write(fd, cursor, remaining)
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
}
