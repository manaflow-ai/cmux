import Darwin
import Foundation
import Testing

extension CLISSHPTYAttachReplayBoundaryTests {
    final class BundleToken {}

    /// Runs one `ssh-pty-attach` on a pty against a mock control socket and a
    /// scripted bridge, then hands the running CLI to `body`.
    ///
    /// Each resource is released by its own `defer`, so on every exit path the
    /// CLI is reaped first, then the control socket, bridge, and output drain
    /// it may still be using are stopped, and the pty closes last.
    func withSSHPTYAttach(
        requireExisting: Bool,
        daemonVersion: String? = BundledCLITestSupport.appVersion,
        beforeBridgeResponse: (@Sendable () -> Void)? = nil,
        outputIsBroken: Bool = false,
        outputIsBackpressured: Bool = false,
        bridgeError: Bool = false,
        onRequest: (@Sendable (String, [String: Any]) -> Void)? = nil,
        bridgeScript: @escaping @Sendable (CLISSHPTYAttachBridgeConnection) -> Void,
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
        var custom = termios()
        try #require(tcgetattr(slaveFD, &custom) == 0)
        custom.c_iflag |= tcflag_t(IXOFF)
        withUnsafeMutableBytes(of: &custom.c_cc) { $0[Int(VEOF)] = 0x06 }
        try #require(tcsetattr(slaveFD, TCSANOW, &custom) == 0)
        let initialFlags = try #require(TerminalFlags(fd: slaveFD))

        let output = try PTYOutputDrain(masterFD: masterFD)
        defer { #expect(output.stop(), "pty output reader did not stop") }

        let bridge = try CLISSHPTYAttachBridgeServer(script: bridgeScript)
        defer {
            #expect(bridge.stop(), "bridge server did not stop")
            #expect(bridge.stop(), "repeated bridge stop was not idempotent")
        }

        let socketPath = makeSocketPath()
        let controlListener = try bindUnixSocket(at: socketPath)
        let responder = ControlSocketResponder(
            bridgePort: bridge.port,
            sessionID: sessionID,
            surfaceID: surfaceID,
            daemonVersion: daemonVersion,
            beforeBridgeResponse: beforeBridgeResponse,
            bridgeError: bridgeError,
            onRequest: onRequest
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
        let blockedOutput = outputIsBackpressured ? Pipe() : nil
        defer { withExtendedLifetime(blockedOutput) {} }
        if let blockedOutput { process.standardOutput = blockedOutput.fileHandleForWriting }
        if outputIsBroken {
            let brokenOutput = Pipe()
            try brokenOutput.fileHandleForReading.close()
            process.standardOutput = brokenOutput.fileHandleForWriting
        }
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
            stderr: stderrPipe,
            blockedOutput: blockedOutput
        ))
    }

    /// The running CLI and the test's side of its terminal.
    struct AttachedCLI {
        let masterFD: Int32
        let slaveFD: Int32
        let initialFlags: TerminalFlags
        let output: PTYOutputDrain
        let process: Process
        let exited: DispatchSemaphore
        let stderr: Pipe
        let blockedOutput: Pipe?

        var hasBufferedOutput: Bool {
            guard let blockedOutput else { return false }
            var ready = pollfd(fd: blockedOutput.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            return Darwin.poll(&ready, 1, 0) > 0 && ready.revents & Int16(POLLIN) != 0
        }

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
    struct TerminalFlags: Equatable {
        let input: tcflag_t
        let output: tcflag_t
        let control: tcflag_t
        let local: tcflag_t
        let controlCharacters: [UInt8]
        let inputSpeed: speed_t
        let outputSpeed: speed_t

        init?(fd: Int32) {
            var state = termios()
            guard tcgetattr(fd, &state) == 0 else { return nil }
            input = state.c_iflag
            output = state.c_oflag
            control = state.c_cflag
            local = state.c_lflag
            controlCharacters = withUnsafeBytes(of: state.c_cc) { Array($0) }
            inputSpeed = cfgetispeed(&state)
            outputSpeed = cfgetospeed(&state)
        }
    }

    /// Bytes the mock bridge received from the CLI, shared with the test thread.
    final class ForwardedInput: @unchecked Sendable {
        let lock = NSLock()
        var data = Data()

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
    final class PTYOutputDrain: @unchecked Sendable {
        let lifecycle: CLISSHPTYStopPipe
        let condition = NSCondition()
        var received = Data()

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
            lifecycle = CLISSHPTYStopPipe(stopReadFD: stopFDs[0], stopWriteFD: stopFDs[1])
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

        var text: String {
            condition.lock()
            defer { condition.unlock() }
            return String(decoding: received, as: UTF8.self)
        }

        /// Stops the reader and reports whether it exited.
        func stop() -> Bool {
            lifecycle.requestStop()
            return lifecycle.waitForFinish()
        }

        func read(from readerFD: Int32, stopFD: Int32) {
            defer {
                Darwin.close(readerFD)
                lifecycle.finish()
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

    struct ControlSocketResponder: Sendable {
        let bridgePort: Int
        let sessionID: String
        let surfaceID: String
        let daemonVersion: String?
        let beforeBridgeResponse: (@Sendable () -> Void)?
        let bridgeError: Bool
        let onRequest: (@Sendable (String, [String: Any]) -> Void)?

        func response(for line: String) -> String {
            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return "{}"
            }
            onRequest?(method, payload["params"] as? [String: Any] ?? [:])
            switch method {
            case "workspace.remote.pty_bridge":
                beforeBridgeResponse?()
                if bridgeError { return v2Response(id: id, ok: false, error: ["code": "not_ready", "message": "disconnected"]) }
                return v2Response(id: id, result: [
                    "host": "127.0.0.1", "daemon_version": daemonVersion ?? NSNull(),
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

        func v2Response(
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

    /// Raw forwarding: no line editing, no local echo, and signal keys reach
    /// the remote shell as bytes.
    func isRawForwardingMode(fd: Int32) -> Bool {
        guard let local = TerminalFlags(fd: fd)?.local else { return false }
        return local & (tcflag_t(ICANON) | tcflag_t(ECHO) | tcflag_t(ISIG)) == 0
    }

    /// Disconnected: raw input, but signal keys still stop the attach.
    func isDisconnectedMode(fd: Int32) -> Bool {
        guard let local = TerminalFlags(fd: fd)?.local else { return false }
        return local & tcflag_t(ISIG) != 0 && local & (tcflag_t(ICANON) | tcflag_t(ECHO)) == 0
    }

    func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = DispatchTime.now() + 5
        while DispatchTime.now() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    func makeSocketPath() -> String {
        // A UUID under the per-user temporary directory overflows sun_path (104 bytes).
        "/tmp/cli-replay-\(UUID().uuidString).sock"
    }

    func bindUnixSocket(at path: String) throws -> Int32 {
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
