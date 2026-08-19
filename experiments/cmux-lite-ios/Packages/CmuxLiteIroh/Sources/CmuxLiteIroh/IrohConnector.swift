public import CmuxLiteProtocol
public import CmuxLiteTransport

/// Opens Iroh routes and returns ``IrohByteStream`` adapters.
public struct IrohConnector: TransportConnector, Sendable {
    private let provider: any IrohConnectionProvider

    /// Creates a connector around a native binding provider.
    ///
    /// - Parameter provider: The object that owns the native Iroh endpoint.
    public init(provider: any IrohConnectionProvider) {
        self.provider = provider
    }

    /// Opens one Iroh route and classifies binding failures for fallback policy.
    ///
    /// - Parameter route: A generic route whose kind must be ``TransportKind/iroh``.
    /// - Returns: An unstarted ``IrohByteStream``.
    /// - Throws: ``TransportOpenFailure`` for classified route failures, or an
    ///   unclassified error that the dialer will treat as non-retryable.
    public func open(route: TransportRoute) async throws -> any ByteStream {
        guard route.kind == .iroh else {
            throw TransportOpenFailure.invalidRoute
        }

        let irohRoute: IrohRoute
        do {
            irohRoute = try IrohRoute(endpointID: route.identifier)
        } catch {
            throw TransportOpenFailure.invalidRoute
        }

        do {
            let connection = try await provider.connect(to: irohRoute)
            return IrohByteStream(connection: connection)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as IrohOpenFailure {
            throw Self.map(failure)
        }
    }

    private static func map(_ failure: IrohOpenFailure) -> TransportOpenFailure {
        switch failure {
        case .unavailable, .closed:
            return .unavailable
        case .incompatiblePeer:
            return .incompatiblePeer
        case .invalidRoute:
            return .invalidRoute
        case .unauthorized:
            return .unauthorized
        }
    }
}
