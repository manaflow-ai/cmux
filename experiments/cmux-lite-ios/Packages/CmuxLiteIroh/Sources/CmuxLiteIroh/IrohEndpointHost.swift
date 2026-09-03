internal import Foundation
public import CmuxLiteProtocol
public import CmuxLiteSession

/// Owns the serialized inbound accept loop for one bound Iroh endpoint.
///
/// The endpoint provider only accepts native connections. This host gives each
/// accepted byte stream one session owner, keeps those owners alive until they
/// finish, and closes them before the endpoint. A factory supplies application
/// handshake policy without exposing generated IrohLib handles.
public actor IrohEndpointHost {
    /// Host lifecycle and admission failures.
    public enum Failure: Error, Equatable, Sendable {
        /// ``start()`` was called more than once.
        case alreadyStarted

        /// The endpoint failed before it could accept another connection.
        case endpoint(IrohOpenFailure)

        /// The generated binding returned an unclassified failure.
        case unclassifiedEndpointFailure
    }

    /// Events emitted by the endpoint host in lifecycle order.
    public enum Event: Equatable, Sendable {
        /// The endpoint is bound and ready for publication.
        case listening(IrohRoute)

        /// A peer completed Iroh identity authentication and stream setup.
        case accepted(peer: IrohRoute)

        /// One admitted peer's protocol session ended.
        case sessionClosed(peerEndpointID: String)

        /// The listener ended because the endpoint failed.
        case failure(Failure)

        /// The host and every owned session are closed.
        case closed
    }

    /// Creates the server handshake configuration for one authenticated peer.
    ///
    /// Throwing rejects that peer and closes only its connection. The accept
    /// loop remains live for later candidates.
    public typealias SessionConfigurationFactory = @Sendable (
        _ peer: IrohRoute
    ) async throws -> SessionOwner.Configuration

    /// A single-consumer stream of listener and session lifecycle events.
    public nonisolated let events: AsyncStream<Event>

    private struct ActiveSession: Sendable {
        let peer: IrohRoute
        let owner: SessionOwner
    }

    private let endpoint: any IrohEndpointProvider
    private let codec: FrameCodec
    private let makeSessionConfiguration: SessionConfigurationFactory
    private let eventContinuation: AsyncStream<Event>.Continuation
    private var acceptLoopTask: Task<Void, Never>?
    private var sessions: [UUID: ActiveSession] = [:]
    private var observationTasks: [UUID: Task<Void, Never>] = [:]
    private var started = false
    private var closed = false

    /// Creates a host around an endpoint with caller-owned handshake policy.
    public init(
        endpoint: any IrohEndpointProvider,
        codec: FrameCodec,
        makeSessionConfiguration: @escaping SessionConfigurationFactory
    ) {
        self.endpoint = endpoint
        self.codec = codec
        self.makeSessionConfiguration = makeSessionConfiguration
        let (events, continuation) = AsyncStream<Event>.makeStream()
        self.events = events
        eventContinuation = continuation
    }

    deinit {
        acceptLoopTask?.cancel()
        for task in observationTasks.values {
            task.cancel()
        }
        eventContinuation.finish()
    }

    /// Binds the endpoint, publishes its initial route, and starts accepting.
    public func start() async throws {
        guard !started else {
            throw Failure.alreadyStarted
        }
        started = true

        do {
            let route = try await endpoint.localRoute()
            guard !closed else {
                throw IrohOpenFailure.closed
            }
            eventContinuation.yield(.listening(route))
            acceptLoopTask = Task { [weak self] in
                await self?.runAcceptLoop()
            }
        } catch {
            let failure = Self.map(error)
            await stopAfterFailure(failure)
            throw failure
        }
    }

    /// Returns the endpoint's current route without changing host lifecycle.
    public func localRoute() async throws -> IrohRoute {
        try await endpoint.localRoute()
    }

    /// Closes the listener and every active session, then finishes events.
    public func close() async {
        guard !closed else {
            return
        }
        closed = true
        acceptLoopTask?.cancel()
        acceptLoopTask = nil

        let activeSessions = Array(sessions.values)
        sessions.removeAll(keepingCapacity: false)
        let activeObservationTasks = Array(observationTasks.values)
        observationTasks.removeAll(keepingCapacity: false)
        for task in activeObservationTasks {
            task.cancel()
        }
        for session in activeSessions {
            await session.owner.close()
        }
        await endpoint.close()
        eventContinuation.yield(.closed)
        eventContinuation.finish()
    }

    /// Returns authenticated endpoint identities for currently owned sessions.
    public func activePeerEndpointIDs() -> [String] {
        sessions.values
            .map(\.peer.endpointID)
            .sorted()
    }

    private func runAcceptLoop() async {
        do {
            while !Task.isCancelled, !closed {
                guard let incoming = try await endpoint.accept() else {
                    await close()
                    return
                }
                await admit(incoming)
            }
        } catch is CancellationError {
            guard !closed else {
                return
            }
            await stopAfterFailure(.unclassifiedEndpointFailure)
            return
        } catch {
            guard !closed else {
                return
            }
            await stopAfterFailure(Self.map(error))
        }
    }

    private func admit(_ incoming: IrohIncomingConnection) async {
        let stream = IrohByteStream(connection: incoming.connection)
        let configuration: SessionOwner.Configuration
        do {
            configuration = try await makeSessionConfiguration(
                incoming.peerRoute
            )
        } catch {
            await stream.close()
            return
        }
        guard !closed else {
            await stream.close()
            return
        }

        // Register ownership before `start()`. A peer can complete and close
        // during that suspension; the later observer still drains buffered
        // events and removes the already-owned session deterministically.
        let sessionID = UUID()
        let owner = SessionOwner(
            configuration: configuration,
            stream: stream,
            codec: codec
        )
        sessions[sessionID] = ActiveSession(
            peer: incoming.peerRoute,
            owner: owner
        )
        do {
            try await owner.start()
        } catch {
            sessions.removeValue(forKey: sessionID)
            await owner.close()
            return
        }
        guard !closed else {
            sessions.removeValue(forKey: sessionID)
            await owner.close()
            return
        }

        let events = owner.events
        let observationTask = Task { [weak self] in
            for await event in events {
                guard case .closed = event else {
                    continue
                }
                await self?.sessionDidClose(id: sessionID)
                return
            }
            await self?.sessionDidClose(id: sessionID)
        }
        observationTasks[sessionID] = observationTask
        eventContinuation.yield(.accepted(peer: incoming.peerRoute))
    }

    private func sessionDidClose(id: UUID) {
        guard let session = sessions.removeValue(forKey: id) else {
            return
        }
        observationTasks.removeValue(forKey: id)
        eventContinuation.yield(
            .sessionClosed(peerEndpointID: session.peer.endpointID)
        )
    }

    private func stopAfterFailure(_ failure: Failure) async {
        guard !closed else {
            return
        }
        eventContinuation.yield(.failure(failure))
        await close()
    }

    private static func map(_ error: any Error) -> Failure {
        if let failure = error as? Failure {
            return failure
        }
        if let failure = error as? IrohOpenFailure {
            return .endpoint(failure)
        }
        return .unclassifiedEndpointFailure
    }
}
