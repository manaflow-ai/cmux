public import Foundation

/// A native Iroh connection exposed through a small async-safe seam.
public protocol IrohConnection: Sendable {
    /// Sends one complete byte chunk to the peer.
    ///
    /// - Parameter bytes: Bytes accepted by the native connection.
    /// - Throws: A binding failure or cancellation.
    func send(_ bytes: Data) async throws

    /// Receives the next arbitrary byte chunk from the peer.
    ///
    /// - Returns: A nonempty chunk, or `nil` after peer EOF.
    /// - Throws: A binding failure or cancellation.
    func receive() async throws -> Data?

    /// Closes the native connection idempotently.
    func close() async
}

/// Supplies native Iroh connections for one route.
public protocol IrohConnectionProvider: Sendable {
    /// Opens a connection to the supplied endpoint.
    ///
    /// - Parameter route: The endpoint and optional path hints to dial.
    /// - Returns: A native connection that is not yet owned by a byte stream.
    /// - Throws: ``IrohOpenFailure`` or cancellation.
    func connect(to route: IrohRoute) async throws -> any IrohConnection
}

/// Classified failures emitted by a native Iroh binding.
public enum IrohOpenFailure: Error, Equatable, Sendable {
    /// The endpoint or its current network paths are unavailable.
    case unavailable

    /// The peer does not support this Iroh protocol version.
    case incompatiblePeer

    /// The supplied route metadata cannot be used.
    case invalidRoute

    /// The peer or admission layer denied this connection.
    case unauthorized

    /// The native endpoint was already closed.
    case closed
}
