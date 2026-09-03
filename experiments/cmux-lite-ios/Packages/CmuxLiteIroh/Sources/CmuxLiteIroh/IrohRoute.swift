public import CmuxLiteTransport

/// The opaque route data an Iroh connector needs to dial one peer.
public struct IrohRoute: Codable, Equatable, Hashable, Sendable {
    /// The peer endpoint identifier supplied by discovery or pairing.
    public let endpointID: String

    /// An optional relay hint owned by the Iroh implementation.
    public let relayURL: String?

    /// Optional direct-address hints owned by the Iroh implementation.
    public let directAddresses: [String]

    /// Creates a route without normalizing or rewriting endpoint identity data.
    ///
    /// - Parameters:
    ///   - endpointID: A nonempty endpoint identifier.
    ///   - relayURL: An optional relay hint.
    ///   - directAddresses: Optional direct-address hints.
    /// - Throws: ``Failure/invalidEndpointID`` when the endpoint identifier is
    ///   empty or contains whitespace.
    public init(
        endpointID: String,
        relayURL: String? = nil,
        directAddresses: [String] = []
    ) throws {
        guard !endpointID.isEmpty,
              endpointID.allSatisfy({ !$0.isWhitespace })
        else {
            throw Failure.invalidEndpointID
        }
        self.endpointID = endpointID
        self.relayURL = relayURL
        self.directAddresses = directAddresses
    }

    /// Converts the route into the generic transport descriptor.
    ///
    /// The generic route carries only the stable endpoint identity. A
    /// ``IrohRouteResolver`` supplies current relay and direct-address hints
    /// immediately before dialing, so stale reachability data is not persisted
    /// in the generic selection layer.
    ///
    /// - Returns: A route addressed to this endpoint.
    public func transportRoute() throws -> TransportRoute {
        try TransportRoute(kind: .iroh, identifier: endpointID)
    }

    /// Route construction failures.
    public enum Failure: Error, Equatable, Sendable {
        /// The endpoint identifier was empty or contained whitespace.
        case invalidEndpointID
    }
}
