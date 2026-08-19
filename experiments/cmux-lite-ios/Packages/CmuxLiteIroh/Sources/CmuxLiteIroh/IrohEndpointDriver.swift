public import Foundation

/// The small native-endpoint seam consumed by ``IrohLibConnectionProvider``.
///
/// Keeping this protocol above the generated IrohLib classes lets unit tests
/// exercise endpoint reuse, close ordering, and route handling without a live
/// relay or a platform network.
public protocol IrohEndpointDriver: Sendable {
    /// Opens one bidirectional byte connection to a route.
    func connect(
        to route: IrohRoute,
        alpn: Data
    ) async throws -> any IrohConnection

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
