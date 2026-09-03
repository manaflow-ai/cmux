/// Resolves an opaque transport endpoint identifier into the complete public
/// Iroh address hints needed for a dial.
public protocol IrohRouteResolver: Sendable {
    /// Resolves one endpoint identity without changing the requested identity.
    func resolve(endpointID: String) async throws -> IrohRoute
}

/// A process-local route catalog used by discovery and pairing code.
///
/// Endpoint identity remains the lookup key. Relay URLs and direct addresses
/// are reachability hints only and are never treated as authorization data.
public actor IrohRouteCatalog: IrohRouteResolver {
    /// Catalog mutation and lookup failures.
    public enum Failure: Error, Equatable, Sendable {
        /// No current route has been published for the requested identity.
        case unknownEndpoint(String)
    }

    private var routes: [String: IrohRoute] = [:]

    /// Creates an empty catalog.
    public init() {}

    /// Publishes or replaces the current public route for one endpoint.
    public func publish(_ route: IrohRoute) {
        routes[route.endpointID] = route
    }

    /// Removes a route and returns the value that was removed, if any.
    @discardableResult
    public func remove(endpointID: String) -> IrohRoute? {
        routes.removeValue(forKey: endpointID)
    }

    /// Returns a stable snapshot for diagnostics and tests.
    public func snapshot() -> [IrohRoute] {
        routes.values.sorted { $0.endpointID < $1.endpointID }
    }

    public func resolve(endpointID: String) async throws -> IrohRoute {
        guard let route = routes[endpointID] else {
            throw Failure.unknownEndpoint(endpointID)
        }
        return route
    }
}
