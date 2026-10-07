import Foundation
@preconcurrency import Network

struct TimeoutError: Error {}

func within<T: Sendable>(_ limit: Duration = .seconds(5), _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// Lets exactly one caller through.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

/// An HTTP/1.1 server on 127.0.0.1 that records each request head and
/// answers `200 ok:<request line>` with `Connection: close`.
final class HTTPTestServer: @unchecked Sendable {
    let listener: NWListener
    let port: UInt16
    private let lock = NSLock()
    private var heads: [String] = []

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    var receivedHeads: [String] {
        lock.lock()
        defer { lock.unlock() }
        return heads
    }

    static func start() async throws -> HTTPTestServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "c14.http")
        let box = ServerBox()
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            box.server?.serve(connection, buffer: Data())
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error): if once.take() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        let server = HTTPTestServer(listener: listener, port: port)
        box.server = server
        return server
    }

    private func serve(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, _ in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                lock.lock()
                heads.append(head)
                lock.unlock()
                let line = head.components(separatedBy: "\r\n").first ?? ""
                let body = Data("ok:\(line)".utf8)
                let response = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
                connection.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            } else if isComplete {
                connection.cancel()
            } else {
                serve(connection, buffer: buffer)
            }
        }
    }

    func stop() {
        listener.cancel()
    }
}

final class ServerBox: @unchecked Sendable {
    var server: HTTPTestServer?
}

/// Sends raw bytes to 127.0.0.1:port and reads until the server closes.
func rawExchange(port: UInt16, _ request: String) async throws -> String {
    let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    connection.start(queue: DispatchQueue(label: "c14.client"))
    defer { connection.cancel() }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        })
    }
    var received = Data()
    while true {
        let (chunk, done): (Data?, Bool) = try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error, data == nil { continuation.resume(throwing: error) } else { continuation.resume(returning: (data, isComplete)) }
            }
        }
        if let chunk { received.append(chunk) }
        if done { break }
    }
    return String(decoding: received, as: UTF8.self)
}

/// A port nothing listens on (bound, then released).
func closedPort() -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) } }
    _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
    return UInt16(bigEndian: address.sin_port)
}
