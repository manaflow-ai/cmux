import Foundation

/// Abstracts the full-duplex message transport used by ``CmuxProtocolClient``.
public protocol CmuxTransport: Sendable {
    /// Opens the transport.
    func connect() async throws

    /// Sends one complete UTF-8 JSON protocol message.
    /// - Parameter data: The encoded JSON object.
    func send(_ data: Data) async throws

    /// Receives one complete UTF-8 JSON protocol message.
    /// - Returns: The encoded JSON object.
    func receive() async throws -> Data

    /// Wakes a peer whose asynchronous outbound queue is drained between inbound frames.
    func wakePeer() async throws

    /// Closes the transport and releases its resources.
    func close() async
}

public extension CmuxTransport {
    /// Leaves transports without a protocol-level wake mechanism unchanged.
    func wakePeer() async throws {}
}
