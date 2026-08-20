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

/// Owns one bound native endpoint's public identity and lifecycle.
public protocol IrohEndpointLifecycle: Sendable {
    /// Returns this endpoint's current public route after binding if needed.
    func localRoute() async throws -> IrohRoute

    /// Closes the endpoint and releases all native resources.
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

/// One accepted native connection and the peer identity authenticated by Iroh.
///
/// The peer route contains public endpoint metadata only. It never contains
/// the local endpoint's private identity key.
public struct IrohIncomingConnection: Sendable {
    /// The authenticated peer identity and any route hints known at accept time.
    public let peerRoute: IrohRoute

    /// The accepted bidirectional byte connection.
    public let connection: any IrohConnection

    /// Creates an accepted connection value.
    public init(
        peerRoute: IrohRoute,
        connection: any IrohConnection
    ) {
        self.peerRoute = peerRoute
        self.connection = connection
    }
}

/// Supplies both outgoing and incoming connections for one bound endpoint.
public protocol IrohEndpointProvider:
    IrohConnectionProvider,
    IrohEndpointLifecycle
{
    /// Waits for the next compatible incoming connection.
    ///
    /// `nil` means the endpoint was closed. A listener may reject unrelated or
    /// malformed candidates internally and continue waiting for the next one.
    func accept() async throws -> IrohIncomingConnection?
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

    /// Another caller currently owns the endpoint's pending accept operation.
    ///
    /// A single accepted connection must never be handed to two consumers, so
    /// callers create one serialized accept loop rather than racing `accept()`
    /// from multiple tasks.
    case acceptAlreadyPending
}
