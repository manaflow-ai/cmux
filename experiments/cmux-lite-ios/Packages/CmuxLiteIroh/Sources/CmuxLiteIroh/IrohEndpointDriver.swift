public import Foundation

/// The small native-endpoint seam consumed by ``IrohLibConnectionProvider``.
///
/// Keeping this protocol above the generated IrohLib classes lets unit tests
/// exercise endpoint reuse, close ordering, and route handling without a live
/// relay or a platform network.
public protocol IrohEndpointDriver: Sendable {
    /// Returns the endpoint's current public identity and address hints.
    func localRoute() async throws -> IrohRoute

    /// Opens one bidirectional byte connection to a route.
    func connect(
        to route: IrohRoute,
        alpn: Data
    ) async throws -> any IrohConnection

    /// Accepts the next incoming connection advertising the requested ALPN.
    ///
    /// Implementations may consume and reject unrelated candidates before
    /// returning. `nil` means the endpoint has been closed.
    func accept(alpn: Data) async throws -> IrohIncomingConnection?

    /// Closes the endpoint and releases native resources.
    func close() async
}

/// Creates one native endpoint generation from immutable configuration.
public protocol IrohEndpointFactory: Sendable {
    /// Binds an endpoint or throws a classified native failure.
    func bind(
        configuration: IrohLibConfiguration
    ) async throws -> any IrohEndpointDriver
}
