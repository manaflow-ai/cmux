/// A transport kind that can provide one cmux-lite byte stream.
public enum TransportKind: String, Codable, Equatable, Hashable, Sendable {
    /// The new encrypted Iroh route.
    case iroh

    /// The existing Tailscale-compatible route.
    case tailscale

    /// A local-only route used by tests and development harnesses.
    case loopback
}

/// Opaque route metadata passed from route discovery to a connector.
public struct TransportRoute: Codable, Equatable, Hashable, Sendable {
    /// The route implementation that should receive this route.
    public let kind: TransportKind

    /// An implementation-specific nonempty route identifier.
    public let identifier: String

    /// Creates a route descriptor without embedding networking details in the policy layer.
    ///
    /// - Parameters:
    ///   - kind: The implementation family for the route.
    ///   - identifier: An opaque identifier interpreted by the connector.
    /// - Throws: ``Failure/emptyIdentifier`` when the identifier is empty.
    public init(kind: TransportKind, identifier: String) throws {
        guard !identifier.isEmpty else {
            throw Failure.emptyIdentifier
        }
        self.kind = kind
        self.identifier = identifier
    }

    /// Route construction failures.
    public enum Failure: Error, Equatable, Sendable {
        /// A route identifier was empty and could not be dialed.
        case emptyIdentifier
    }
}
