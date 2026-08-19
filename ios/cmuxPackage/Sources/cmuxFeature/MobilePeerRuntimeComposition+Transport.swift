import CMUXMobileCore
import CmuxMobileRPC
import CmuxPeerTransport
import CmuxPeerTransportCore
import Foundation

/// One live admitted client session for one exact Mac peer. Terminal lanes,
/// artifact lanes, and the server-event stream all ride the session that the
/// control transport admitted, mirroring the previous pooled-connection
/// contract.
final class MobilePeerSessionBox: Sendable {
    let session: PeerClientSession
    let endpointID: String
    let macDeviceID: String?

    init(session: PeerClientSession, endpointID: String, macDeviceID: String?) {
        self.session = session
        self.endpointID = endpointID
        self.macDeviceID = macDeviceID
    }
}

enum MobilePeerTransportError: Error, Equatable {
    /// The request's route is not an authenticated peer route.
    case unsupportedRoute
    /// The route kind is not `.iroh`.
    case unsupportedRouteKind(CmxAttachTransportKind)
    /// The request lacks the peer intent (`.transportAdmission` plus an
    /// expected peer device id) required to dial without substitution.
    case missingPeerIntent
    /// No broker path could authorize the dial (no grant online or offline).
    case pairGrantUnavailable
    /// The target Mac binding could not be resolved from discovery.
    case targetBindingUnavailable
}

// MARK: - Deferred transport factory

/// Stable route-factory facade installed before account activation completes.
///
/// The facade has no endpoint, dial, pooling, or session state. Every
/// connected transport resolves into the process-owned peer engine: await
/// endpoint activation, resolve the dial plan, dial, mint the pair grant,
/// admit the session.
public struct MobilePeerDeferredTransportFactory: CmxRouteAwareByteTransportFactory {
    public let supportedKinds: [CmxAttachTransportKind] = [.iroh]

    private weak var provider: MobilePeerRuntimeComposition?

    init(provider: MobilePeerRuntimeComposition) {
        self.provider = provider
    }

    public func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        try validatePeerRoute(route)
        throw MobilePeerTransportError.missingPeerIntent
    }

    public func makeTransport(
        for request: CmxByteTransportRequest
    ) throws -> any CmxByteTransport {
        try validatePeerRoute(request.route)
        guard request.authorizationMode == .transportAdmission,
              request.expectedPeerDeviceID?.isEmpty == false else {
            throw MobilePeerTransportError.missingPeerIntent
        }
        return MobilePeerDeferredByteTransport(request: request, provider: provider)
    }

    private func validatePeerRoute(_ route: CmxAttachRoute) throws {
        try route.validate()
        guard route.kind == .iroh else {
            throw MobilePeerTransportError.unsupportedRouteKind(route.kind)
        }
        guard case .peer = route.endpoint else {
            throw MobilePeerTransportError.unsupportedRoute
        }
    }
}

/// A disconnected byte transport bound to one exact peer route. `connect()`
/// resolves the live admitted session; receive/send delegate to that
/// session's control transport. Closing tears the whole peer session down
/// (control-stream close means connection close, as before).
final class MobilePeerDeferredByteTransport: CmxByteTransport, @unchecked Sendable {
    private let request: CmxByteTransportRequest
    private weak var provider: MobilePeerRuntimeComposition?
    private let lock = NSLock()
    private var box: MobilePeerSessionBox?

    init(request: CmxByteTransportRequest, provider: MobilePeerRuntimeComposition?) {
        self.request = request
        self.provider = provider
    }

    func connect() async throws {
        guard let provider else {
            throw MobilePeerRuntimePreparationError(
                diagnosticFailureKind: .endpointUnavailable,
                retryAfterSeconds: nil
            )
        }
        let box = try await provider.peerSession(for: request)
        setBox(box)
        try await box.session.controlTransport.connect()
    }

    private var connectedBox: MobilePeerSessionBox? {
        lock.lock()
        defer { lock.unlock() }
        return box
    }

    private func setBox(_ newValue: MobilePeerSessionBox?) {
        lock.lock()
        defer { lock.unlock() }
        box = newValue
    }

    func receive() async throws -> Data? {
        guard let connectedBox else { return nil }
        return try await connectedBox.session.controlTransport.receive()
    }

    func send(_ data: Data) async throws {
        guard let connectedBox else {
            throw MobilePeerRuntimePreparationError(
                diagnosticFailureKind: .endpointUnavailable,
                retryAfterSeconds: nil
            )
        }
        try await connectedBox.session.controlTransport.send(data)
    }

    func close() async {
        let box = connectedBox
        setBox(nil)
        guard let box else { return }
        await provider?.closePeerSession(box, reason: "client transport closed")
    }
}

// MARK: - Session establishment and lanes

extension MobilePeerRuntimeComposition {
    /// Resolves a disconnected transport from the active account runtime.
    public func transport(
        for request: CmxByteTransportRequest
    ) async throws -> any CmxByteTransport {
        _ = try await requireReadyRuntime()
        return try transportFactory.makeTransport(for: request)
    }

    /// Opens a production terminal byte lane for one exact Mac surface.
    ///
    /// The caller persists `cursor` as it applies raw PTY bytes, then supplies
    /// that cursor when reopening after a stream failure so the Mac can replay
    /// from its bounded byte history without duplicating output.
    ///
    /// `priority` is retained for source compatibility; per-stream priority is
    /// not exposed by the peer transport's QUIC binding.
    public func openTerminalLane(
        for request: CmxByteTransportRequest,
        surfaceID: UUID,
        cursor: UInt64? = nil,
        priority: Int32 = 0
    ) async throws -> MobileIrohTerminalLane {
        _ = priority
        let box = try await peerSession(for: request)
        let stream = try await box.session.openTerminalLane(
            resourceID: "terminal:\(surfaceID.uuidString.lowercased())",
            cursor: cursor
        )
        return MobileIrohTerminalLane(stream: stream)
    }

    /// Opens a low-priority raw artifact lane for an opaque Mac-issued capability.
    public func openArtifactLane(
        for request: CmxByteTransportRequest,
        resourceID: String,
        offset: UInt64,
        priority: Int32 = -10
    ) async throws -> any MobileArtifactLaneConnection {
        _ = priority
        let box = try await peerSession(for: request)
        let stream = try await box.session.openArtifactLane(
            resourceID: resourceID,
            offset: offset
        )
        do {
            try await stream.finish()
            return MobileIrohArtifactLane(stream: stream)
        } catch {
            await stream.reset()
            throw error
        }
    }

    /// Starts the one server-event byte stream on the admitted session.
    ///
    /// The Mac delivers events on host-opened unidirectional lanes; each lane's
    /// bytes are surfaced in order, and a host-side lane reopen continues the
    /// same byte stream. The stream finishes when the session closes.
    public func serverEventByteStream(
        for request: CmxByteTransportRequest
    ) async throws -> CmxIndependentEventByteStream {
        let box = try await peerSession(for: request)
        let session = box.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for await lane in session.serverEventLanes() {
                        if !lane.initialBytes.isEmpty {
                            continuation.yield(lane.initialBytes)
                        }
                        while let data = try await lane.stream.read() {
                            guard !Task.isCancelled else {
                                continuation.finish()
                                return
                            }
                            continuation.yield(data)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Returns the live admitted session for the request's peer, establishing
    /// one if needed. Establishment is single-flight per peer endpoint so a
    /// reconnect burst dials once.
    func peerSession(
        for request: CmxByteTransportRequest
    ) async throws -> MobilePeerSessionBox {
        guard case let .peer(identity, pathHints) = request.route.endpoint else {
            throw MobilePeerTransportError.unsupportedRoute
        }
        let key = identity.endpointID
        if let live = sessionsByEndpointID[key] {
            return live
        }
        if let inFlight = sessionTasksByEndpointID[key] {
            return try await inFlight.value
        }
        let task = Task { [weak self] () throws -> MobilePeerSessionBox in
            guard let self else {
                throw MobilePeerRuntimePreparationError(
                    diagnosticFailureKind: .endpointUnavailable,
                    retryAfterSeconds: nil
                )
            }
            return try await self.establishPeerSession(
                identity: identity,
                routePathHints: pathHints,
                expectedPeerDeviceID: request.expectedPeerDeviceID
            )
        }
        sessionTasksByEndpointID[key] = task
        defer { sessionTasksByEndpointID[key] = nil }
        do {
            let box = try await task.value
            sessionsByEndpointID[key] = box
            watchPeerSession(box)
            return box
        } catch {
            throw error
        }
    }

    private func establishPeerSession(
        identity: CmxIrohPeerIdentity,
        routePathHints: [CmxIrohPathHint],
        expectedPeerDeviceID: String?
    ) async throws -> MobilePeerSessionBox {
        let activation = try await requireReadyRuntime()
        diagnosticLog?.record(DiagnosticEvent(
            .transportDialStarted,
            a: DiagnosticTransportKind.iroh.rawValue
        ))
        let wallClock = now()

        // Dial plan: the route's identity is authoritative; discovery merges
        // fresher reachability hints and supplies the target binding for the
        // pair grant. Failures classify back into the provider so only
        // unreachable-class outcomes force a refetch.
        var plan: PeerDialPlan?
        var targetBinding: PeerBrokerBinding?
        let planDeviceID = (expectedPeerDeviceID).map(cmxCanonicalDeviceID(_:))
        if let planDeviceID, let discoveryProvider {
            plan = try? await discoveryProvider.dialPlan(
                macDeviceID: planDeviceID,
                tag: nil
            )
            if plan?.binding.endpointID != identity {
                // The broker row moved to a different endpoint identity; the
                // route's pinned identity stays authoritative for this dial.
                plan = nil
            }
            targetBinding = plan?.binding
        }
        var freshSnapshot: PeerBrokerDiscoverySnapshot?
        if targetBinding == nil {
            freshSnapshot = try? await freshDiscoverySnapshot(activation: activation)
            targetBinding = freshSnapshot?.bindings.first {
                $0.platform == .mac && $0.endpointID == identity
            }
        }

        var relayHints = routePathHints
            .filter { $0.kind == .relayURL && $0.isUsable(at: wallClock) }
            .map(\.value)
        var directHints = routePathHints
            .filter { $0.kind == .directAddress && $0.isUsable(at: wallClock) }
            .map(\.value)
        if let plan {
            relayHints.append(contentsOf: plan.relayHints.filter { !relayHints.contains($0) })
            directHints.append(contentsOf: plan.directHints.filter { !directHints.contains($0) })
        }
        switch transportVerificationMode {
        case .relayOnly:
            directHints = []
        case .directOnly:
            relayHints = []
        case .automatic:
            break
        }

        let connection: PeerQuicConnection
        do {
            connection = try await dialer.dial(
                endpointID: identity.endpointID,
                relayHints: relayHints,
                directHints: directHints,
                generation: activation.generation,
                timeout: .seconds(20)
            )
        } catch let failure as PeerDialFailure {
            if let planDeviceID {
                await discoveryProvider?.noteDialFailure(
                    macDeviceID: planDeviceID,
                    classification: failure.classification,
                    planWasEmpty: relayHints.isEmpty && directHints.isEmpty
                )
            }
            recordDialFailure(failure)
            throw failure
        }

        do {
            let credential = try await pairGrantCredential(
                activation: activation,
                targetBinding: targetBinding,
                targetIdentity: identity,
                freshSnapshot: freshSnapshot
            )
            let session = try await PeerClientSessionFactory().establish(
                connection: connection,
                credential: credential
            )
            if let planDeviceID {
                await discoveryProvider?.noteDialSuccess(macDeviceID: planDeviceID)
            }
            diagnosticLog?.record(DiagnosticEvent(
                .transportDialConnected,
                a: DiagnosticTransportKind.iroh.rawValue
            ))
            return MobilePeerSessionBox(
                session: session,
                endpointID: identity.endpointID,
                macDeviceID: planDeviceID
                    ?? targetBinding.map { cmxCanonicalDeviceID($0.deviceID) }
            )
        } catch {
            connection.close(reason: "admission failed")
            if let failure = error as? PeerDialFailure, let planDeviceID {
                await discoveryProvider?.noteDialFailure(
                    macDeviceID: planDeviceID,
                    classification: failure.classification,
                    planWasEmpty: false
                )
            }
            recordDialFailure(error)
            throw error
        }
    }

    /// Mints the seven-day pair grant online, honoring the offline grant cache
    /// when the broker is unreachable.
    private func pairGrantCredential(
        activation: MobilePeerActivationState,
        targetBinding: PeerBrokerBinding?,
        targetIdentity: CmxIrohPeerIdentity,
        freshSnapshot: PeerBrokerDiscoverySnapshot?
    ) async throws -> String {
        guard let accountBroker else {
            throw MobilePeerTransportError.pairGrantUnavailable
        }
        guard let targetBinding else {
            // Broker discovery could not name the acceptor binding; the only
            // remaining authority is the offline cache.
            if let cached = try? await cachedGrant(
                activation: activation,
                targetDeviceID: nil,
                targetIdentity: targetIdentity,
                brokerFailure: .connectivity
            ) {
                return cached
            }
            throw MobilePeerTransportError.targetBindingUnavailable
        }
        do {
            let grant = try await accountBroker.issuePairGrant(
                initiatorBindingID: activation.binding.bindingID,
                acceptorBindingID: targetBinding.bindingID
            )
            if let freshSnapshot {
                await saveOfflineGrant(
                    activation: activation,
                    targetBinding: targetBinding,
                    discovery: freshSnapshot,
                    grant: grant
                )
            }
            return grant.grant
        } catch let error as PeerBrokerError {
            if case let .serverRateLimited(retryAfter) = error {
                await cooldownLedger.noteRetryAfter(
                    retryAfter,
                    key: .init(accountID: activation.accountID)
                )
            }
            guard error.allowsOfflineGrantFallback else {
                throw MobilePeerEndpointActivator.dialFailure(
                    for: error,
                    stage: "pair grant"
                )
            }
            if let cached = try? await cachedGrant(
                activation: activation,
                targetDeviceID: cmxCanonicalDeviceID(targetBinding.deviceID),
                targetIdentity: targetIdentity,
                brokerFailure: error
            ) {
                return cached
            }
            throw MobilePeerEndpointActivator.dialFailure(
                for: error,
                stage: "pair grant"
            )
        }
    }

    private func cachedGrant(
        activation: MobilePeerActivationState,
        targetDeviceID: String?,
        targetIdentity: CmxIrohPeerIdentity,
        brokerFailure: PeerBrokerError
    ) async throws -> String? {
        guard let expectation = try? offlineGrantExpectation(activation: activation)
        else { return nil }
        guard let targetDeviceID else { return nil }
        let authority = try await offlineGrants.load(
            afterBrokerFailure: brokerFailure,
            targetDeviceID: targetDeviceID,
            targetEndpointID: targetIdentity,
            expectation: expectation,
            confirmedLocalBinding: activation.binding,
            now: now()
        )
        return authority?.pairGrant.grant
    }

    private func saveOfflineGrant(
        activation: MobilePeerActivationState,
        targetBinding: PeerBrokerBinding,
        discovery: PeerBrokerDiscoverySnapshot,
        grant: PeerPairGrantResponse
    ) async {
        guard let expectation = try? offlineGrantExpectation(activation: activation)
        else { return }
        try? await offlineGrants.save(
            localBinding: activation.binding,
            targetBinding: targetBinding,
            discovery: discovery,
            pairGrant: grant,
            for: expectation,
            now: now()
        )
    }

    private func offlineGrantExpectation(
        activation: MobilePeerActivationState
    ) throws -> PeerOfflineGrantExpectation {
        try PeerOfflineGrantExpectation(
            accountID: activation.accountID,
            localBindingExpectation: PeerLocalBindingExpectation(
                deviceID: activation.binding.deviceID,
                appInstanceID: activation.binding.appInstanceID,
                clientNamespace: activation.binding.clientNamespace,
                tag: activation.binding.tag,
                platform: .ios,
                endpointID: activation.binding.endpointID,
                identityGeneration: activation.binding.identityGeneration,
                pairingEnabled: activation.binding.pairingEnabled,
                capabilities: activation.binding.capabilities
            ),
            managedRelayURLs: Set(activation.relayURLs)
        )
    }

    private func recordDialFailure(_ error: any Error) {
        diagnosticLog?.record(DiagnosticEvent(
            .transportDialFailed,
            a: DiagnosticTransportKind.iroh.rawValue,
            b: DiagnosticFailureKind.classify(error).rawValue
        ))
    }

    private func watchPeerSession(_ box: MobilePeerSessionBox) {
        Task { @MainActor [weak self] in
            _ = await box.session.awaitClose()
            guard let self else { return }
            if self.sessionsByEndpointID[box.endpointID] === box {
                self.sessionsByEndpointID[box.endpointID] = nil
            }
        }
    }

    func closePeerSession(_ box: MobilePeerSessionBox, reason: String) async {
        if sessionsByEndpointID[box.endpointID] === box {
            sessionsByEndpointID[box.endpointID] = nil
        }
        await box.session.close(reason: reason)
    }

    func closeAllSessions(reason: String) async {
        let tasks = sessionTasksByEndpointID.values
        sessionTasksByEndpointID.removeAll()
        for task in tasks {
            task.cancel()
        }
        let boxes = sessionsByEndpointID.values
        sessionsByEndpointID.removeAll()
        for box in boxes {
            await box.session.close(reason: reason)
        }
    }
}
