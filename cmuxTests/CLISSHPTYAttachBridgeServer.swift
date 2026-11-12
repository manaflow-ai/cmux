import Darwin
import Foundation

/// The bridge side of one attach, as seen by a test's bridge script.
struct CLISSHPTYAttachBridgeConnection {
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
final class CLISSHPTYAttachBridgeServer: @unchecked Sendable {
    let port: Int
    private let lifecycle: CLISSHPTYStopPipe

    init(script: @escaping @Sendable (CLISSHPTYAttachBridgeConnection) -> Void) throws {
        let listener = try Self.bindLoopbackTCP()
        var stopFDs: [Int32] = [-1, -1]
        guard pipe(&stopFDs) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(listener.fd)
            throw error
        }
        port = listener.port
        lifecycle = CLISSHPTYStopPipe(stopReadFD: stopFDs[0], stopWriteFD: stopFDs[1])
        let stopReadFD = stopFDs[0]
        let lifecycle = self.lifecycle
        let thread = Thread {
            defer {
                Darwin.close(listener.fd)
                lifecycle.finish()
            }
            guard let clientFD = CLISSHPTYAttachBridgeServer.accept(listenerFD: listener.fd, stopFD: stopReadFD) else { return }
            defer { Darwin.close(clientFD) }
            let connection = CLISSHPTYAttachBridgeConnection(fd: clientFD, stopFD: stopReadFD)
            let handshake = connection.receive(timeoutMilliseconds: 5_000) { $0.contains(0x0A) }
            guard handshake.contains(0x0A) else { return }
            script(connection)
        }
        thread.qualityOfService = QualityOfService.userInitiated
        thread.start()
    }

    /// Stops the server thread and reports whether it exited.
    func stop() -> Bool {
        lifecycle.requestStop()
        return lifecycle.waitForFinish()
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
            if clientFD >= 0 {
                // Cancellation tests deliberately close the CLI while the script
                // is writing; that failure must stop the script, not the test host.
                var enabled: Int32 = 1
                _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
                return clientFD
            }
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
