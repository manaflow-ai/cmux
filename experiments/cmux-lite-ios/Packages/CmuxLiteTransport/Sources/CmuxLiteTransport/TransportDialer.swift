public import CmuxLiteProtocol

/// Performs one serialized, observable route-selection attempt.
public actor TransportDialer {
    /// Classifies a failed route attempt for observability and fallback policy.
    public enum FailureReason: Equatable, Sendable {
        /// The route is temporarily unavailable.
        case unavailable

        /// The peer cannot speak this transport.
        case incompatiblePeer

        /// The route metadata is invalid.
        case invalidRoute

        /// The peer denied admission.
        case unauthorized

        /// The connector threw an error without a transport classification.
        case unclassified
    }

    /// Events emitted in route-attempt order.
    public enum Event: Equatable, Sendable {
        /// A connector is about to be asked to open this route.
        case attempting(TransportRoute)

        /// A connector failed or was not registered for this route.
        case failed(TransportRoute, reason: FailureReason)

        /// A connector returned a stream for this route.
        case connected(TransportRoute)

        /// Every policy-approved route failed.
        case exhausted
    }

    /// Dialer command failures.
    public enum Failure: Error, Equatable, Sendable {
        /// The policy produced no routes to attempt.
        case noRoutes

        /// A live connection already belongs to this dialer.
        case alreadyConnected

        /// Every ordered route failed or had no connector.
        case allRoutesFailed([TransportRoute])

        /// A connector returned a non-retryable failure, so fallback stopped.
        case nonRetryable(TransportRoute, reason: FailureReason)
    }

    /// A single-consumer stream of route-attempt events.
    public nonisolated let events: AsyncStream<Event>

    private struct OpenedTransport: Sendable {
        let route: TransportRoute
        let stream: any ByteStream
    }

    private let routes: [TransportRoute]
    private let connectors: [TransportKind: any TransportConnector]
    private let eventContinuation: AsyncStream<Event>.Continuation
    private var inFlight: Task<OpenedTransport, any Error>?
    private var connectedRoute: TransportRoute?

    /// Creates a dialer with an immutable route list and connector registry.
    ///
    /// - Parameters:
    ///   - routes: Discovered routes, in any order.
    ///   - policy: The policy that determines attempt order and restrictions.
    ///   - connectors: One connector per route kind.
    /// - Throws: ``Failure/noRoutes`` when policy removes every route.
    public init(
        routes: [TransportRoute],
        policy: TransportSelectionPolicy,
        connectors: [TransportKind: any TransportConnector]
    ) throws {
        let orderedRoutes = policy.orderedRoutes(from: routes)
        guard !orderedRoutes.isEmpty else {
            throw Failure.noRoutes
        }

        self.routes = orderedRoutes
        self.connectors = connectors
        let (events, continuation) = AsyncStream<Event>.makeStream()
        self.events = events
        self.eventContinuation = continuation
    }

    deinit {
        inFlight?.cancel()
        eventContinuation.finish()
    }

    /// Opens the first route that succeeds, joining an attempt already in flight.
    ///
    /// Concurrent callers share the same attempt. A later call after a
    /// successful connection fails with ``Failure/alreadyConnected`` so one
    /// dialer cannot create two live sessions accidentally.
    ///
    /// - Returns: An unstarted byte stream for the selected route.
    /// - Throws: ``Failure/alreadyConnected``, ``Failure/allRoutesFailed(_:)``,
    ///   ``Failure/nonRetryable(_:reason:)``, or cancellation.
    public func connect() async throws -> any ByteStream {
        guard connectedRoute == nil else {
            throw Failure.alreadyConnected
        }

        if let inFlight {
            return try await inFlight.value.stream
        }

        let routes = routes
        let connectors = connectors
        let continuation = eventContinuation
        let task = Task<OpenedTransport, any Error> {
            for route in routes {
                try Task.checkCancellation()
                continuation.yield(.attempting(route))

                guard let connector = connectors[route.kind] else {
                    continuation.yield(.failed(route, reason: .unclassified))
                    continue
                }

                do {
                    let stream = try await connector.open(route: route)
                    continuation.yield(.connected(route))
                    return OpenedTransport(route: route, stream: stream)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let failure as TransportOpenFailure {
                    let reason = Self.reason(for: failure)
                    continuation.yield(.failed(route, reason: reason))
                    if failure == .unauthorized {
                        throw Failure.nonRetryable(route, reason: reason)
                    }
                } catch {
                    continuation.yield(.failed(route, reason: .unclassified))
                    throw Failure.nonRetryable(route, reason: .unclassified)
                }
            }

            continuation.yield(.exhausted)
            throw Failure.allRoutesFailed(routes)
        }
        inFlight = task

        do {
            let opened = try await task.value
            inFlight = nil
            connectedRoute = opened.route
            return opened.stream
        } catch {
            inFlight = nil
            throw error
        }
    }

    /// Returns the route selected by a successful call, if any.
    public func currentRoute() -> TransportRoute? {
        connectedRoute
    }

    private static func reason(for failure: TransportOpenFailure) -> FailureReason {
        switch failure {
        case .unavailable:
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
