import Darwin
import Foundation
import Testing

/// Exercises the real CLI/bridge boundary where a persistent attach declares
/// that historical PTY output is still being replayed.
@Suite(.serialized)
struct CLISSHPTYAttachReplayBoundaryTests {
    @Test
    func inputTypedDuringReplayIsDiscardedBeforeForwarding() throws {
        // The CLI writes bridge output to the terminal only after every setup
        // step that precedes replay, so the mode seen once the replay head is
        // on screen is the mode the attach holds until the replay completes.
        let replayHead = "remote-"
        let replayTail = "prompt$ "
        let releaseReplayTail = DispatchSemaphore(value: 0)
        let forwardedCaptured = DispatchSemaphore(value: 0)
        let finishBridge = DispatchSemaphore(value: 0)
        let forwarded = ForwardedInput()

        try withSSHPTYAttach(requireExisting: true) { bridge in
            guard bridge.sendReady(replayBytes: (replayHead + replayTail).utf8.count),
                  bridge.send(replayHead),
                  bridge.wait(for: releaseReplayTail),
                  bridge.send(replayTail) else { return }
            // The CLI forwards input in order, so a leaked line typed during
            // replay would arrive here ahead of the safe one.
            forwarded.append(bridge.receive(timeoutMilliseconds: 5_000) { $0.contains(0x0A) })
            forwardedCaptured.signal()
            _ = bridge.wait(for: finishBridge)
        } body: { attach in
            try #require(attach.output.waitForOutput(containing: replayHead))
            // Mid-replay, signal keys stay live and typed bytes stay local.
            #expect(isDisconnectedMode(fd: attach.slaveFD))
            try #require(attach.write("dangerous-command\n"))

            releaseReplayTail.signal()
            try #require(waitUntil { isRawForwardingMode(fd: attach.slaveFD) })
            try #require(attach.write("safe-command\n"))
            try #require(forwardedCaptured.wait(timeout: .now() + 10) == .success)
            #expect(forwarded.text == "safe-command\n", Comment(rawValue: forwarded.text))

            finishBridge.signal()
            try #require(attach.waitForExit())
            #expect(attach.process.terminationStatus == 0, Comment(rawValue: attach.stderrText))
            #expect(TerminalFlags(fd: attach.slaveFD) == attach.initialFlags)
        }
    }

    @Test
    func freshAttachForwardsKeystrokesBeforeNewline() throws {
        // A fresh attach declares no replay, so its first bridge output is
        // live. The CLI writes it only after setting up terminal input, so
        // the marker on screen means the attach has settled on its mode.
        let liveMarker = "live-prompt$ "
        let keystrokeWritten = DispatchSemaphore(value: 0)
        let keystrokeChecked = DispatchSemaphore(value: 0)
        let finishBridge = DispatchSemaphore(value: 0)
        let forwarded = ForwardedInput()

        try withSSHPTYAttach(requireExisting: false) { bridge in
            guard bridge.sendReady(replayBytes: 0),
                  bridge.send(liveMarker),
                  bridge.wait(for: keystrokeWritten) else { return }
            forwarded.append(bridge.receive(timeoutMilliseconds: 5_000) { $0.contains(UInt8(ascii: "k")) })
            keystrokeChecked.signal()
            _ = bridge.wait(for: finishBridge)
        } body: { attach in
            try #require(attach.output.waitForOutput(containing: liveMarker))
            #expect(isRawForwardingMode(fd: attach.slaveFD))

            // Raw forwarding hands each keystroke to the bridge immediately.
            // Canonical mode would echo it locally and hold it until a newline.
            try #require(attach.write("k"))
            keystrokeWritten.signal()
            try #require(keystrokeChecked.wait(timeout: .now() + 10) == .success)
            #expect(forwarded.text == "k", Comment(rawValue: forwarded.text))
            #expect(isRawForwardingMode(fd: attach.slaveFD))

            finishBridge.signal()
            try #require(attach.waitForExit())
            #expect(attach.process.terminationStatus == 0, Comment(rawValue: attach.stderrText))
            #expect(TerminalFlags(fd: attach.slaveFD) == attach.initialFlags)
        }
    }

    private final class BundleToken {}

    /// Runs one `ssh-pty-attach` on a pty against a mock control socket and a
    /// scripted bridge, then hands the running CLI to `body`.
    ///
    /// Each resource is released by its own `defer`, so on every exit path the
    /// CLI is reaped first, then the control socket, bridge, and output drain
    /// it may still be using are stopped, and the pty closes last.
    private func withSSHPTYAttach(
        requireExisting: Bool,
        bridgeScript: @escaping @Sendable (BridgeConnection) -> Void,
        body: (AttachedCLI) throws -> Void
    ) throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundleToken.self)
        let workspaceID = UUID().uuidString.lowercased()
        let surfaceID = UUID().uuidString.lowercased()
        let sessionID = "ssh-\(workspaceID)-\(surfaceID)"

        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer {
            Darwin.close(masterFD)
            Darwin.close(slaveFD)
        }
        let initialFlags = try #require(TerminalFlags(fd: slaveFD))

        let output = try PTYOutputDrain(masterFD: masterFD)
        defer { #expect(output.stop(), "pty output reader did not stop") }

        let bridge = try BridgeServer(script: bridgeScript)
        defer { #expect(bridge.stop(), "bridge server did not stop") }

        let socketPath = makeSocketPath()
        let controlListener = try bindUnixSocket(at: socketPath)
        let responder = ControlSocketResponder(
            bridgePort: bridge.port,
            sessionID: sessionID,
            surfaceID: surfaceID
        )
        CLIMockAcceptLoopRegistry.shared.start(
            listenerFD: controlListener,
            onConnection: { clientFD in
                defer { Darwin.close(clientFD) }
                cliMockServeLineFramedConnection(clientFD: clientFD) { line in
                    responder.response(for: line)
                }
            },
            onListenerClosed: {}
        )
        defer {
            CLIMockAcceptLoopRegistry.shared.stop(listenerFD: controlListener)
            Darwin.close(controlListener)
            unlink(socketPath)
        }

        let stdinFD = dup(slaveFD)
        let stdoutFD = dup(slaveFD)
        guard stdinFD >= 0, stdoutFD >= 0 else {
            if stdinFD >= 0 { Darwin.close(stdinFD) }
            if stdoutFD >= 0 { Darwin.close(stdoutFD) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let process = Process()
        let stderrPipe = Pipe()
        let processExited = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = ["ssh-pty-attach"]
            + (requireExisting ? ["--require-existing"] : [])
            + [
                "--workspace", workspaceID,
                "--session-id", sessionID,
                "--lifecycle-id", UUID().uuidString.lowercased(),
                "--attachment-id", surfaceID,
            ]
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        process.environment = environment
        process.standardInput = FileHandle(fileDescriptor: stdinFD, closeOnDealloc: true)
        process.standardOutput = FileHandle(fileDescriptor: stdoutFD, closeOnDealloc: true)
        process.standardError = stderrPipe
        process.terminationHandler = { _ in processExited.signal() }
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                if processExited.wait(timeout: .now() + 2) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    #expect(processExited.wait(timeout: .now() + 5) == .success, "ssh-pty-attach did not exit")
                }
            }
        }

        try body(AttachedCLI(
            masterFD: masterFD,
            slaveFD: slaveFD,
            initialFlags: initialFlags,
            output: output,
            process: process,
            exited: processExited,
            stderr: stderrPipe
        ))
    }

    /// The running CLI and the test's side of its terminal.
    private struct AttachedCLI {
        let masterFD: Int32
        let slaveFD: Int32
        let initialFlags: TerminalFlags
        let output: PTYOutputDrain
        let process: Process
        let exited: DispatchSemaphore
        let stderr: Pipe

        /// Types into the CLI's terminal.
        func write(_ string: String) -> Bool {
            cliMockWriteAll(string, to: masterFD)
        }

        func waitForExit() -> Bool {
            exited.wait(timeout: .now() + 5) == .success
        }

        var stderrText: String {
            String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
    }

    /// The termios mode flags, compared to confirm the CLI restored the
    /// caller's terminal.
    private struct TerminalFlags: Equatable {
        let input: tcflag_t
        let output: tcflag_t
        let control: tcflag_t
        let local: tcflag_t

        init?(fd: Int32) {
            var state = termios()
            guard tcgetattr(fd, &state) == 0 else { return nil }
            input = state.c_iflag
            output = state.c_oflag
            control = state.c_cflag
            local = state.c_lflag
        }
    }

    /// Bytes the mock bridge received from the CLI, shared with the test thread.
    private final class ForwardedInput: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Reads the CLI's terminal output the way a live terminal does, and keeps
    /// it for tests to wait on. With no reader, a TCSAFLUSH mode change waits
    /// forever for the pty output queue to drain.
    ///
    /// The reader thread owns a duplicate of the master and the read end of its
    /// stop pipe and closes both itself, so a reader that outlives `stop()`
    /// never touches a descriptor number the test has released.
    private final class PTYOutputDrain: @unchecked Sendable {
        private let stopWriteFD: Int32
        private let finished = DispatchSemaphore(value: 0)
        private let condition = NSCondition()
        private var received = Data()

        init(masterFD: Int32) throws {
            let readerFD = dup(masterFD)
            guard readerFD >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var stopFDs: [Int32] = [-1, -1]
            guard pipe(&stopFDs) == 0 else {
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                Darwin.close(readerFD)
                throw error
            }
            stopWriteFD = stopFDs[1]
            let stopReadFD = stopFDs[0]
            let thread = Thread { self.read(from: readerFD, stopFD: stopReadFD) }
            thread.qualityOfService = QualityOfService.userInitiated
            thread.start()
        }

        /// Waits until the terminal has received `text`.
        func waitForOutput(containing text: String) -> Bool {
            let needle = Data(text.utf8)
            let deadline = Date().addingTimeInterval(5)
            condition.lock()
            defer { condition.unlock() }
            while received.range(of: needle) == nil {
                guard condition.wait(until: deadline) else {
                    return received.range(of: needle) != nil
                }
            }
            return true
        }

        /// Stops the reader and reports whether it exited.
        func stop() -> Bool {
            var byte: UInt8 = 1
            _ = Darwin.write(stopWriteFD, &byte, 1)
            let exited = finished.wait(timeout: .now() + 5) == .success
            Darwin.close(stopWriteFD)
            return exited
        }

        private func read(from readerFD: Int32, stopFD: Int32) {
            defer {
                Darwin.close(readerFD)
                Darwin.close(stopFD)
                finished.signal()
            }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                var pollFDs = [
                    pollfd(fd: readerFD, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: stopFD, events: Int16(POLLIN), revents: 0),
                ]
                let ready = Darwin.poll(&pollFDs, 2, -1)
                if ready < 0, errno == EINTR { continue }
                guard ready > 0, pollFDs[1].revents == 0 else { return }
                let count = Darwin.read(readerFD, &buffer, buffer.count)
                if count > 0 {
                    condition.lock()
                    received.append(buffer, count: count)
                    condition.broadcast()
                    condition.unlock()
                    continue
                }
                if count < 0, errno == EINTR || errno == EAGAIN { continue }
                return
            }
        }
    }

    private struct ControlSocketResponder: Sendable {
        let bridgePort: Int
        let sessionID: String
        let surfaceID: String

        func response(for line: String) -> String {
            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return "{}"
            }
            switch method {
            case "workspace.remote.pty_bridge":
                return v2Response(id: id, result: [
                    "host": "127.0.0.1",
                    "port": bridgePort,
                    "token": "bridge-token",
                    "session_id": sessionID,
                    "attachment_id": surfaceID,
                ])
            case "workspace.remote.pty_resize":
                return v2Response(id: id, result: [:])
            case "workspace.remote.pty_sessions":
                return v2Response(id: id, result: ["sessions": []])
            case "workspace.remote.pty_attach_end", "workspace.remote.pty_detach":
                return v2Response(id: id, result: [:])
            default:
                return v2Response(id: id, ok: false, error: [
                    "code": "unexpected_method",
                    "message": "unexpected method \(method)",
                ])
            }
        }

        private func v2Response(
            id: String,
            ok: Bool = true,
            result: [String: Any]? = nil,
            error: [String: Any]? = nil
        ) -> String {
            var value: [String: Any] = ["id": id, "ok": ok]
            if let result { value["result"] = result }
            if let error { value["error"] = error }
            let data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// The bridge side of one attach, as seen by a test's bridge script.
    private struct BridgeConnection {
        let fd: Int32
        let stopFD: Int32

        func sendReady(replayBytes: Int) -> Bool {
            send("{\"type\":\"ready\",\"attachment_token\":\"attach-token\",\"replay_bytes\":\(replayBytes)}\n")
        }

        func send(_ string: String) -> Bool {
            cliMockWriteAll(string, to: fd)
        }

        /// Waits for a signal from the test. Returns false once the server
        /// stops, so a failed test never leaves the script waiting.
        func wait(for signal: DispatchSemaphore) -> Bool {
            let deadline = DispatchTime.now() + 30
            while DispatchTime.now() < deadline, !stopRequested {
                if signal.wait(timeout: .now() + .milliseconds(50)) == .success { return true }
            }
            return false
        }

        /// Collects bytes from the CLI until `isComplete` accepts them, the
        /// timeout passes, the CLI closes the connection, or the server stops.
        func receive(timeoutMilliseconds: Int, until isComplete: (Data) -> Bool) -> Data {
            var result = Data()
            let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMilliseconds) * 1_000_000
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !isComplete(result) {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { break }
                var pollFDs = [
                    pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: stopFD, events: Int16(POLLIN), revents: 0),
                ]
                let ready = Darwin.poll(&pollFDs, 2, Int32(clamping: (deadline - now + 999_999) / 1_000_000))
                if ready < 0, errno == EINTR { continue }
                guard ready > 0, pollFDs[1].revents == 0 else { break }
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 {
                    result.append(buffer, count: count)
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            return result
        }

        private var stopRequested: Bool {
            var pollFD = pollfd(fd: stopFD, events: Int16(POLLIN), revents: 0)
            return Darwin.poll(&pollFD, 1, 0) > 0
        }
    }

    /// A one-connection mock of the remote PTY bridge. After reading the CLI's
    /// handshake line it runs `script`, then closes the connection.
    ///
    /// The server thread owns its listener, the connection, and the read end
    /// of its stop pipe and closes them itself. `stop()` wakes any wait in the
    /// script.
    private final class BridgeServer: @unchecked Sendable {
        let port: Int
        private let stopWriteFD: Int32
        private let finished = DispatchSemaphore(value: 0)

        init(script: @escaping @Sendable (BridgeConnection) -> Void) throws {
            let listener = try Self.bindLoopbackTCP()
            var stopFDs: [Int32] = [-1, -1]
            guard pipe(&stopFDs) == 0 else {
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                Darwin.close(listener.fd)
                throw error
            }
            port = listener.port
            stopWriteFD = stopFDs[1]
            let stopReadFD = stopFDs[0]
            let finished = self.finished
            let thread = Thread {
                defer {
                    Darwin.close(listener.fd)
                    Darwin.close(stopReadFD)
                    finished.signal()
                }
                guard let clientFD = BridgeServer.accept(listenerFD: listener.fd, stopFD: stopReadFD) else { return }
                defer { Darwin.close(clientFD) }
                let connection = BridgeConnection(fd: clientFD, stopFD: stopReadFD)
                let handshake = connection.receive(timeoutMilliseconds: 5_000) { $0.contains(0x0A) }
                guard handshake.contains(0x0A) else { return }
                script(connection)
            }
            thread.qualityOfService = QualityOfService.userInitiated
            thread.start()
        }

        /// Stops the server thread and reports whether it exited.
        func stop() -> Bool {
            var byte: UInt8 = 1
            _ = Darwin.write(stopWriteFD, &byte, 1)
            let exited = finished.wait(timeout: .now() + 5) == .success
            Darwin.close(stopWriteFD)
            return exited
        }

        private static func accept(listenerFD: Int32, stopFD: Int32) -> Int32? {
            while true {
                var pollFDs = [
                    pollfd(fd: listenerFD, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: stopFD, events: Int16(POLLIN), revents: 0),
                ]
                let ready = Darwin.poll(&pollFDs, 2, -1)
                if ready < 0, errno == EINTR { continue }
                guard ready > 0, pollFDs[1].revents == 0 else { return nil }
                let clientFD = Darwin.accept(listenerFD, nil, nil)
                if clientFD >= 0 { return clientFD }
                if errno == EINTR || errno == ECONNABORTED { continue }
                return nil
            }
        }

        private static func bindLoopbackTCP() throws -> (fd: Int32, port: Int) {
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0, Darwin.listen(fd, 1) == 0 else {
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                Darwin.close(fd)
                throw error
            }
            var bound = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getsockname(fd, $0, &length)
                }
            }
            guard nameResult == 0 else {
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                Darwin.close(fd)
                throw error
            }
            return (fd, Int(UInt16(bigEndian: bound.sin_port)))
        }
    }

    /// Raw forwarding: no line editing, no local echo, and signal keys reach
    /// the remote shell as bytes.
    private func isRawForwardingMode(fd: Int32) -> Bool {
        guard let local = TerminalFlags(fd: fd)?.local else { return false }
        return local & (tcflag_t(ICANON) | tcflag_t(ECHO) | tcflag_t(ISIG)) == 0
    }

    /// Disconnected: raw input, but signal keys still stop the attach.
    private func isDisconnectedMode(fd: Int32) -> Bool {
        guard let local = TerminalFlags(fd: fd)?.local else { return false }
        return local & tcflag_t(ISIG) != 0 && local & (tcflag_t(ICANON) | tcflag_t(ECHO)) == 0
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = DispatchTime.now() + 5
        while DispatchTime.now() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    private func makeSocketPath() -> String {
        // A UUID under the per-user temporary directory overflows sun_path (104 bytes).
        "/tmp/cli-replay-\(UUID().uuidString).sock"
    }

    private func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { buffer in
                for (index, byte) in bytes.enumerated() { buffer[index] = CChar(bitPattern: byte) }
                buffer[bytes.count] = 0
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, Darwin.listen(fd, 8) == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return fd
    }
}
