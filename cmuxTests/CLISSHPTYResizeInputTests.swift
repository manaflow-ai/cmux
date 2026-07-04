import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct CLISSHPTYResizeInputTests {
    @Test
    func attachReportsPTYSizeChangeBeforeForwardingInput() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshptyinputresize")
        var listenerFD = try bindUnixSocket(at: socketPath)
        let bridge = try bindLoopbackTCP()
        let state = MockSocketServerState()
        let workspaceId = "22222222-2222-2222-2222-222222222222"
        let surfaceId = "33333333-3333-3333-3333-333333333333"
        let sessionId = "ssh-\(workspaceId)-\(surfaceId)"
        let token = "bridge-token"
        let resizeRequestReceived = DispatchSemaphore(value: 0)
        let inputForwarded = DispatchSemaphore(value: 0)
        let bridgeReady = DispatchSemaphore(value: 0)
        let closeBridge = DispatchSemaphore(value: 0)
        let bridgeCloseObserved = DispatchSemaphore(value: 0)
        let capturedResizeParams = CapturedResizeParams()
        let eventRecorder = EventRecorder()
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1

        defer {
            if masterFD >= 0 { Darwin.close(masterFD) }
            if slaveFD >= 0 { Darwin.close(slaveFD) }
            if listenerFD >= 0 { Darwin.close(listenerFD) }
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
                eventRecorder.append("resize")
                resizeRequestReceived.signal()
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
            inputForwarded: inputForwarded,
            closeBridge: closeBridge,
            bridgeCloseObserved: bridgeCloseObserved,
            eventRecorder: eventRecorder
        )

        let process = Process()
        let stderrPipe = Pipe()
        let stdinFD = dup(slaveFD)
        guard stdinFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let stdoutFD = dup(slaveFD)
        guard stdoutFD >= 0 else {
            Darwin.close(stdinFD)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let stdinHandle = FileHandle(fileDescriptor: stdinFD, closeOnDealloc: true)
        let stdoutHandle = FileHandle(fileDescriptor: stdoutFD, closeOnDealloc: true)
        Darwin.close(slaveFD)
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
        process.standardInput = stdinHandle
        process.standardOutput = stdoutHandle
        process.standardError = stderrPipe

        try process.run()
        stdinHandle.closeFile()
        stdoutHandle.closeFile()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }
        #expect(bridgeReady.wait(timeout: .now() + 5) == .success)

        try setPTYSize(masterFD: masterFD, cols: 120, rows: 40)
        writeAll(fd: masterFD, data: Data("stty size\n".utf8))
        #expect(
            resizeRequestReceived.wait(timeout: .now() + 5) == .success,
            "Expected ssh-pty-attach to report PTY size changes from an input edge"
        )
        #expect(
            inputForwarded.wait(timeout: .now() + 5) == .success,
            "Expected ssh-pty-attach to forward typed input after the bounded resize RPC"
        )

        closeBridge.signal()
        #expect(bridgeCloseObserved.wait(timeout: .now() + 5) == .success)

        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exited.signal()
        }
        let didExit = exited.wait(timeout: .now() + 5) == .success
        #expect(didExit, "Expected ssh-pty-attach to exit")
        guard didExit else {
            if process.isRunning {
                process.terminate()
            }
            socketHandled.stop()
            Darwin.close(listenerFD)
            listenerFD = -1
            return
        }
        socketHandled.stop()
        Darwin.close(listenerFD)
        listenerFD = -1
        #expect(socketHandled.handled.wait(timeout: .now() + 5) == .success)
        #expect(bridgeHandled.wait(timeout: .now() + 5) == .success)

        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, Comment(rawValue: stderr))
        let resizeParams = capturedResizeParams.snapshot()
        #expect(resizeParams?["attachment_token"] as? String == "attach-token")
        #expect(resizeParams?["cols"] as? Int == 120)
        #expect(resizeParams?["rows"] as? Int == 40)
        let events = eventRecorder.snapshot()
        let firstResizeIndex = events.firstIndex(of: "resize")
        let firstInputIndex = events.firstIndex(of: "input")
        #expect(firstResizeIndex != nil)
        #expect(firstInputIndex != nil)
        if let firstResizeIndex, let firstInputIndex {
            #expect(firstResizeIndex < firstInputIndex)
        }
    }

    // Regression for https://github.com/manaflow-ai/cmux/issues/6306. When a
    // `workspace.remote.pty_resize` delivery fails (e.g. it races a stale or
    // blocked remote-session control path and the bounded RPC times out), the
    // attach helper must not silently drop the size. It should retry the latest
    // size on its own — without waiting for another SIGWINCH or input edge — so
    // the remote PTY/TUI still converges and a manual workspace reconnect is not
    // required. Here the first resize the daemon receives (the attach-time
    // reconcile) fails; the helper must re-deliver the same size automatically.
    @Test
    func resizeRetriesAfterFailedDelivery() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("sshptyretry")
        var listenerFD = try bindUnixSocket(at: socketPath)
        let bridge = try bindLoopbackTCP()
        let state = MockSocketServerState()
        let workspaceId = "44444444-4444-4444-4444-444444444444"
        let surfaceId = "55555555-5555-5555-5555-555555555555"
        let sessionId = "ssh-\(workspaceId)-\(surfaceId)"
        let token = "bridge-token"
        let bridgeReady = DispatchSemaphore(value: 0)
        let firstResizeFailed = DispatchSemaphore(value: 0)
        let retriedResizeSucceeded = DispatchSemaphore(value: 0)
        let resizeAttempts = ResizeAttemptCounter()
        let capturedRetryParams = CapturedResizeParams()
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1

        defer {
            if masterFD >= 0 { Darwin.close(masterFD) }
            if slaveFD >= 0 { Darwin.close(slaveFD) }
            if listenerFD >= 0 { Darwin.close(listenerFD) }
            Darwin.close(bridge.fd)
            unlink(socketPath)
        }

        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        // Open the PTY at the target size so the attach-time reconcile (which
        // reads STDOUT's winsize after arming SIGWINCH) sends exactly this size
        // as its first — and only — resize, with no SIGWINCH or input edge
        // needed to drive it. Any subsequent send of this size can only come
        // from the helper's own retry.
        try setPTYSize(masterFD: masterFD, cols: 132, rows: 50)

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
                let attempt = resizeAttempts.record()
                if attempt == 1 {
                    // Simulate a delivery failure on the first attempt.
                    firstResizeFailed.signal()
                    return v2Response(
                        id: id,
                        ok: false,
                        error: [
                            "code": "remote_session_unavailable",
                            "message": "simulated stale remote-session control path",
                        ]
                    )
                }
                capturedRetryParams.store(params)
                retriedResizeSucceeded.signal()
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

        let bridgeHandled = startReadyBridge(bridge: bridge, bridgeReady: bridgeReady)

        let process = Process()
        let stderrPipe = Pipe()
        let stdinFD = dup(slaveFD)
        guard stdinFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let stdoutFD = dup(slaveFD)
        guard stdoutFD >= 0 else {
            Darwin.close(stdinFD)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let stdinHandle = FileHandle(fileDescriptor: stdinFD, closeOnDealloc: true)
        let stdoutHandle = FileHandle(fileDescriptor: stdoutFD, closeOnDealloc: true)
        Darwin.close(slaveFD)
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
        process.standardInput = stdinHandle
        process.standardOutput = stdoutHandle
        process.standardError = stderrPipe

        try process.run()
        stdinHandle.closeFile()
        stdoutHandle.closeFile()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        #expect(bridgeReady.wait(timeout: .now() + 5) == .success)
        #expect(
            firstResizeFailed.wait(timeout: .now() + 5) == .success,
            "Expected ssh-pty-attach to attempt the attach-time reconcile resize"
        )
        #expect(
            retriedResizeSucceeded.wait(timeout: .now() + 5) == .success,
            "Expected ssh-pty-attach to retry the resize after the first delivery failed, without a new SIGWINCH or input edge"
        )

        let retryParams = capturedRetryParams.snapshot()
        #expect(retryParams?["cols"] as? Int == 132)
        #expect(retryParams?["rows"] as? Int == 50)
        #expect(resizeAttempts.count() >= 2)

        if process.isRunning {
            process.terminate()
        }
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exited.signal()
        }
        _ = exited.wait(timeout: .now() + 5)
        socketHandled.stop()
        Darwin.close(listenerFD)
        listenerFD = -1
        _ = socketHandled.handled.wait(timeout: .now() + 5)
        _ = bridgeHandled.wait(timeout: .now() + 5)
    }

    private final class BundleToken {}

    // Lock-protected count of resize attempts seen by the mock socket thread.
    private final class ResizeAttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func record() -> Int {
            lock.lock()
            value += 1
            let result = value
            lock.unlock()
            return result
        }

        func count() -> Int {
            lock.lock()
            let result = value
            lock.unlock()
            return result
        }
    }

    // Lock-protected test capture shared by the mock socket thread and test thread.
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

    // Lock-protected test capture shared by the mock socket thread and test thread.
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

    // Lock-protected test capture shared by the bridge thread and mock socket thread.
    private final class EventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String] = []

        func append(_ event: String) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        func snapshot() -> [String] {
            lock.lock()
            let result = events
            lock.unlock()
            return result
        }
    }

    // Lock-protected stop flag for the multi-client mock socket accept loop.
    private final class MockSocketServer: @unchecked Sendable {
        let handled = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var stopped = false

        func stop() {
            lock.lock()
            stopped = true
            lock.unlock()
        }

        var isStopped: Bool {
            lock.lock()
            let result = stopped
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
        guard Darwin.listen(fd, 8) == 0 else {
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
    ) -> MockSocketServer {
        let server = MockSocketServer()
        let flags = fcntl(listenerFD, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(listenerFD, F_SETFL, flags | O_NONBLOCK)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let clientGroup = DispatchGroup()
            defer {
                clientGroup.wait()
                server.handled.signal()
            }

            while !server.isStopped {
                var clientAddr = sockaddr_un()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                    }
                }
                if clientFD >= 0 {
                    clientGroup.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        defer {
                            Darwin.close(clientFD)
                            clientGroup.leave()
                        }
                        handleMockSocketClient(clientFD: clientFD, state: state, handler: handler)
                    }
                    continue
                }

                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    usleep(10_000)
                    continue
                }
                return
            }
        }
        return server
    }

    private func handleMockSocketClient(
        clientFD: Int32,
        state: MockSocketServerState,
        handler: @escaping @Sendable (String) -> Data
    ) {
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

    // Minimal bridge: accept, read the handshake line, reply "ready", then hold
    // the connection open (draining any bytes) until the client closes it so the
    // attach helper's output read loop stays alive while the resize retry runs.
    private func startReadyBridge(
        bridge: LoopbackTCPListener,
        bridgeReady: DispatchSemaphore
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

            while true {
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count > 0 { continue }
                if count == 0 { return }
                if errno != EINTR { return }
            }
        }
        return handled
    }

    private func startBridgeServer(
        bridge: LoopbackTCPListener,
        bridgeReady: DispatchSemaphore,
        inputForwarded: DispatchSemaphore,
        closeBridge: DispatchSemaphore,
        bridgeCloseObserved: DispatchSemaphore,
        eventRecorder: EventRecorder
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
            while true {
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count > 0 {
                    eventRecorder.append("input")
                    inputForwarded.signal()
                    break
                }
                if count == 0 { return }
                if errno != EINTR { return }
            }
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
