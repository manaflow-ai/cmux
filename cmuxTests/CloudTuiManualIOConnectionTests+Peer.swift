import Darwin
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CloudTuiManualIOConnectionTests {
    static func outputLine(_ bytes: Data) -> Data {
        Data("{\"event\":\"output\",\"surface\":1,\"data\":\"\(bytes.base64EncodedString())\"}\n".utf8)
    }

    static func withConnection(
        queue: DispatchQueue = DispatchQueue(label: "test.cloud-io"),
        _ body: (CloudTuiManualIOConnection, Int32) async throws -> Void
    ) async throws {
        let path = "/tmp/cmux-io-\(UUID().uuidString.prefix(12)).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw socketError() }
        defer { Darwin.close(listener); unlink(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            pathBytes.withUnsafeBytes { target.copyBytes(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 1) == 0 else { throw socketError() }
        let connection = CloudTuiManualIOConnection(socketPath: path, queue: queue)
        defer { connection.close() }
        try await connection.start()
        let peer = accept(listener, nil, nil)
        guard peer >= 0 else { throw socketError() }
        defer { Darwin.close(peer) }
        var noSignal: Int32 = 1
        setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        // Deadlines fail broken fixtures instead of leaving a CI worker hung.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(peer, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        try await body(connection, peer)
    }

    static func write(_ descriptor: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw socketError() }
                offset += count
            }
        }
    }

    static func readLine(_ descriptor: Int32) throws -> Data {
        var result = Data()
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(descriptor, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw socketError() }
            if count == 0 { return result }
            result.append(byte)
            if byte == 0x0A { return result }
        }
    }

    /// Called only after the writer queue has processed the submitted burst.
    /// A nonblocking drain observes the causal boundary without a timing wait.
    static func readAvailable(_ descriptor: Int32) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = recv(descriptor, &buffer, buffer.count, MSG_DONTWAIT)
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return result }
            guard count > 0 else { throw socketError() }
            result.append(buffer, count: count)
        }
    }

    /// Blocking peer I/O stays off Swift's cooperative executor and the client's
    /// dispatch queue. Each test owns its descriptors until these jobs finish.
    static func blocking<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(with: Result { try operation() }) }
        }
    }

    static func socketError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
