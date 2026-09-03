public import CmuxLiteProtocol

/// Opens one byte stream for a discovered route.
public protocol TransportConnector: Sendable {
    /// Opens the route and returns an unstarted byte stream.
    ///
    /// The caller owns the returned stream and must call ``ByteStream/connect()``
    /// before using it. A connector owns cleanup for resources created before
    /// it can return a stream.
    ///
    /// - Parameter route: Opaque route metadata selected by policy.
    /// - Returns: A stream ready for the session owner to connect.
    /// - Throws: ``TransportOpenFailure``. Unknown errors are treated as
    ///   non-retryable by ``TransportDialer`` so an adapter cannot accidentally
    ///   bypass an authorization or protocol decision.
    func open(route: TransportRoute) async throws -> any ByteStream
}
