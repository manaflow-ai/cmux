import Darwin
import Foundation
import Testing

/// Exercises the real CLI/bridge boundary where a persistent attach declares
/// that historical PTY output is still being replayed.
@Suite(.serialized)
struct CLISSHPTYAttachReplayBoundaryTests {
    @Test
    func inputTypedDuringReplayIsDiscardedBeforeForwarding() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundleToken.self)
        let socketPath = makeSocketPath()
        var controlListener = try bindUnixSocket(at: socketPath)
        let bridgeListener = try bindLoopbackTCP()
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let ready = DispatchSemaphore(value: 0)
        let dangerousWritten = DispatchSemaphore(value: 0)
        let preReplayChecked = DispatchSemaphore(value: 0)
        let allowReplay = DispatchSemaphore(value: 0)
        let forwardedCaptured = DispatchSemaphore(value: 0)
        let capturedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-pty-replay-input-\(UUID().uuidString)")
        try Data().write(to: capturedURL)
        let workspaceID = "22222222-2222-2222-2222-222222222222"
        let surfaceID = "33333333-3333-3333-3333-333333333333"
        let lifecycleID = "44444444-4444-4444-4444-444444444444"
        let sessionID = "ssh-\(workspaceID)-\(surfaceID)"

        let bridgeServer = try BridgeServer(
            listener: bridgeListener,
            replay: "remote-prompt$ ",
            capturedURL: capturedURL,
            ready: ready,
            dangerousWritten: dangerousWritten,
            preReplayChecked: preReplayChecked,
            allowReplay: allowReplay,
            forwardedCaptured: forwardedCaptured
        )
        let responder = ControlSocketResponder(
            bridgePort: bridgeListener.port,
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
            dangerousWritten.signal()
            allowReplay.signal()
            bridgeServer.stop()
            CLIMockAcceptLoopRegistry.shared.stop(listenerFD: controlListener)
            if controlListener >= 0 { Darwin.close(controlListener) }
            Darwin.close(bridgeListener.fd)
            if masterFD >= 0 { Darwin.close(masterFD) }
            if slaveFD >= 0 { Darwin.close(slaveFD) }
            try? FileManager.default.removeItem(at: capturedURL)
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
        process.arguments = [
            "ssh-pty-attach",
            "--require-existing",
            "--workspace", workspaceID,
            "--session-id", sessionID,
            "--lifecycle-id", lifecycleID,
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

        // The bridge has acknowledged the attach, but has not released its
        // declared historical replay prefix yet.
        #expect(ready.wait(timeout: .now() + 5) == .success)
        #expect(waitForTerminalPhase(fd: slaveFD, disconnected: true))
        writeAll(fd: masterFD, string: "dangerous-command\n")
        dangerousWritten.signal()
        #expect(preReplayChecked.wait(timeout: .now() + 5) == .success)

        let preReplayInput = try String(contentsOf: capturedURL, encoding: .utf8)
        #expect(preReplayInput.isEmpty, Comment(rawValue: preReplayInput))

        allowReplay.signal()
        #expect(waitForTerminalPhase(fd: slaveFD, disconnected: false))
        writeAll(fd: masterFD, string: "safe-command\n")
        #expect(forwardedCaptured.wait(timeout: .now() + 5) == .success)

        if process.isRunning {
            _ = processExited.wait(timeout: .now() + 5)
        }
        if process.isRunning {
            process.terminate()
            _ = processExited.wait(timeout: .now() + 5)
        }
        let captured = try String(contentsOf: capturedURL, encoding: .utf8)
        #expect(captured == "safe-command\n", Comment(rawValue: captured))
        #expect(process.terminationStatus == 0, Comment(rawValue: String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""))
    }

    private final class BundleToken {}

    private struct LoopbackTCPListener: Sendable {
        let fd: Int32
        let port: Int
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

    private final class BridgeServer {
        private let stopReadFD: Int32
        private let stopWriteFD: Int32
        private let finished = DispatchSemaphore(value: 0)

        init(
            listener: LoopbackTCPListener,
            replay: String,
            capturedURL: URL,
            ready: DispatchSemaphore,
            dangerousWritten: DispatchSemaphore,
            preReplayChecked: DispatchSemaphore,
            allowReplay: DispatchSemaphore,
            forwardedCaptured: DispatchSemaphore
        ) throws {
            var stopFDs = [-1, -1]
            guard pipe(&stopFDs) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            stopReadFD = stopFDs[0]
            stopWriteFD = stopFDs[1]
            let finished = self.finished
            let stopReadFD = stopFDs[0]
            let thread = Thread {
                defer { finished.signal() }
                var pollFDs = [
                    pollfd(fd: listener.fd, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: stopReadFD, events: Int16(POLLIN), revents: 0),
                ]
                guard Darwin.poll(&pollFDs, 2, -1) > 0,
                      pollFDs[1].revents & Int16(POLLIN) == 0 else { return }
                var address = sockaddr_in()
                var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientFD = withUnsafeMutablePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        Darwin.accept(listener.fd, sockaddrPointer, &addressLength)
                    }
                }
                guard clientFD >= 0 else { return }
                defer { Darwin.close(clientFD) }
                Self.serve(
                    clientFD: clientFD,
                    replay: replay,
                    capturedURL: capturedURL,
                    ready: ready,
                    dangerousWritten: dangerousWritten,
                    preReplayChecked: preReplayChecked,
                    allowReplay: allowReplay,
                    forwardedCaptured: forwardedCaptured
                )
            }
            thread.qualityOfService = .userInitiated
            thread.start()
        }

        func stop() {
            var byte: UInt8 = 1
            _ = Darwin.write(stopWriteFD, &byte, 1)
            _ = finished.wait(timeout: .now() + 5)
            Darwin.close(stopReadFD)
            Darwin.close(stopWriteFD)
        }

        private static func serve(
            clientFD: Int32,
            replay: String,
            capturedURL: URL,
            ready: DispatchSemaphore,
            dangerousWritten: DispatchSemaphore,
            preReplayChecked: DispatchSemaphore,
            allowReplay: DispatchSemaphore,
            forwardedCaptured: DispatchSemaphore
        ) {
            defer { forwardedCaptured.signal() }
            guard readThroughNewline(fd: clientFD) else { return }
            let readyPayload = "{\"type\":\"ready\",\"attachment_token\":\"attach-token\",\"replay_bytes\":\(replay.utf8.count)}\n"
            guard cliMockWriteAll(readyPayload, to: clientFD) else { return }
            ready.signal()
            guard dangerousWritten.wait(timeout: .now() + 5) == .success else { return }
            let preReplay = readAvailable(fd: clientFD, timeoutMilliseconds: 400)
            try? preReplay.write(to: capturedURL)
            preReplayChecked.signal()
            guard allowReplay.wait(timeout: .now() + 5) == .success else { return }
            guard cliMockWriteAll(replay, to: clientFD) else { return }
            let postReplay = readUntilNewline(fd: clientFD, timeoutMilliseconds: 5_000)
            try? (preReplay + postReplay).write(to: capturedURL)
        }

        private static func readThroughNewline(fd: Int32) -> Bool {
            var byte: UInt8 = 0
            while true {
                let count = Darwin.read(fd, &byte, 1)
                if count > 0 { if byte == 0x0A { return true }; continue }
                if count < 0, errno == EINTR { continue }
                return false
            }
        }

        private static func readAvailable(fd: Int32, timeoutMilliseconds: Int32) -> Data {
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let timeout = result.isEmpty ? timeoutMilliseconds : 0
                guard Darwin.poll(&pollFD, 1, timeout) > 0 else { return result }
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 { result.append(buffer, count: count); continue }
                if count < 0, errno == EINTR { continue }
                return result
            }
        }

        private static func readUntilNewline(fd: Int32, timeoutMilliseconds: Int32) -> Data {
            var result = Data()
            let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMilliseconds) * 1_000_000
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { return result }
                let remaining = deadline - now
                var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let timeout = Int32(min(UInt64(Int32.max), (remaining + 999_999) / 1_000_000))
                guard Darwin.poll(&pollFD, 1, timeout) > 0 else { return result }
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 {
                    result.append(buffer, count: count)
                    if result.contains(0x0A) { return result }
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return result
                }
            }
            return result
        }
    }

    private func waitForTerminalPhase(fd: Int32, disconnected: Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            var state = termios()
            if tcgetattr(fd, &state) == 0 {
                let isDisconnected = (state.c_lflag & tcflag_t(ISIG)) != 0 &&
                    (state.c_lflag & tcflag_t(ICANON)) == 0 &&
                    (state.c_lflag & tcflag_t(ECHO)) == 0
                if isDisconnected == disconnected { return true }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    private func writeAll(fd: Int32, string: String) {
        _ = cliMockWriteAll(string, to: fd)
    }

    private func makeSocketPath() -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-ssh-replay-\(UUID().uuidString).sock")
            .path
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

    private func bindLoopbackTCP() throws -> LoopbackTCPListener {
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
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &length)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return LoopbackTCPListener(fd: fd, port: Int(UInt16(bigEndian: bound.sin_port)))
    }
}
