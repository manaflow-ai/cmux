import Foundation
import Network

/// A byte stream to an RFB server. `NetworkRFBTransport` is TCP; an app can
/// supply another carrier (a tunnel, a test pipe).
public protocol RFBTransport: AnyObject, Sendable {
    /// Connects; returns when bytes can flow.
    func open() async throws
    /// The next bytes from the server, at least one. Throws
    /// `RFBError.connectionClosed` at the end of the stream.
    func receive() async throws -> [UInt8]
    /// Queues bytes in call order.
    func send(_ bytes: [UInt8]) async throws
    /// Closes the stream; pending reads throw.
    func close()
}

/// TCP through Network.framework, Nagle off (input events go out at once).
public final class NetworkRFBTransport: RFBTransport {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "cmux.vnc.transport", qos: .userInitiated)

    public init(host: String, port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 15
        let parameters = NWParameters(tls: nil, tcp: tcp)
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 5900, using: parameters)
    }

    public func open() async throws {
        let connection = self.connection
        let once = ResumeOnce()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if once.claim() { continuation.resume() }
                    case let .waiting(error), let .failed(error):
                        if once.claim() {
                            connection.cancel()
                            continuation.resume(throwing: RFBError.transport(error.localizedDescription))
                        }
                    case .cancelled:
                        if once.claim() { continuation.resume(throwing: RFBError.connectionClosed) }
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    public func receive() async throws -> [UInt8] {
        let connection = self.connection
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: [UInt8](data))
                } else if let error {
                    continuation.resume(throwing: RFBError.transport(error.localizedDescription))
                } else if isComplete {
                    continuation.resume(throwing: RFBError.connectionClosed)
                } else {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    public func send(_ bytes: [UInt8]) async throws {
        guard !bytes.isEmpty else { return }
        let connection = self.connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: RFBError.transport(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func close() {
        connection.cancel()
    }
}

/// A continuation guard for handlers that fire more than once.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
