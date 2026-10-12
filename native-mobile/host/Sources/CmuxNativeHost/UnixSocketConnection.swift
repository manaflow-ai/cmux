import Foundation
import Synchronization

/// A blocking Unix-domain stream socket with an async face: reads run on a
/// dedicated thread, writes on a serial queue.
public final class UnixSocketConnection: Sendable {
    public struct Failure: Error, CustomStringConvertible, Sendable {
        public var description: String
    }

    private let fd: Int32
    private let writeQueue = DispatchQueue(label: "cmux.native.unix.write")
    private let state = Mutex<(closed: Bool, readerDone: Bool)>((false, false))
    public let chunks: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    private init(fd: Int32) {
        self.fd = fd
        (chunks, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
    }

    public static func connect(path: String) throws -> UnixSocketConnection {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(description: "socket: \(String(cString: strerror(errno)))") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else {
            Darwin.close(fd)
            throw Failure(description: "socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw Failure(description: "connect \(path): \(message)")
        }
        let connection = UnixSocketConnection(fd: fd)
        connection.startReader()
        return connection
    }

    private func startReader() {
        let thread = Thread { [self] in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n > 0 {
                    continuation.yield(Data(buffer[0..<n]))
                } else if n < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            continuation.finish()
            let shouldClose = state.withLock { s -> Bool in
                s.readerDone = true
                return s.closed
            }
            if shouldClose { closeDescriptor() } else { shutdownAndMarkClosed() }
        }
        thread.name = "cmux-native-host.unix-read"
        thread.start()
    }

    /// Writes all bytes (blocking off the caller's thread).
    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            writeQueue.async { [self] in
                if state.withLock({ $0.closed }) { return c.resume(throwing: Failure(description: "socket closed")) }
                var offset = 0
                let ok = data.withUnsafeBytes { raw -> Bool in
                    while offset < raw.count {
                        let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                        if n > 0 { offset += n } else if n < 0, errno == EINTR { continue } else { return false }
                    }
                    return true
                }
                ok ? c.resume() : c.resume(throwing: Failure(description: "write: \(String(cString: strerror(errno)))"))
            }
        }
    }

    public func close() {
        shutdownAndMarkClosed()
    }

    private func shutdownAndMarkClosed() {
        let (first, readerDone) = state.withLock { s -> (Bool, Bool) in
            defer { s.closed = true }
            return (!s.closed, s.readerDone)
        }
        guard first else { return }
        // Unblocks the reader thread; it closes the descriptor on exit.
        shutdown(fd, SHUT_RDWR)
        if readerDone { closeDescriptor() }
    }

    /// Closes on the write queue so no in-flight write sees a reused descriptor.
    private func closeDescriptor() {
        writeQueue.async { [fd] in _ = Darwin.close(fd) }
    }
}
