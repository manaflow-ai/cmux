public import CMUXMobileCore
import CmuxAuthRuntime
public import CmuxIrohTransport
import CmuxIrxTransport
public import CmuxMobileRPC
public import Foundation

/// iOS composition root for the irx transport (the from-scratch iroh rebuild
/// in `CmuxIrxTransport`). DEBUG-only, default-off: when `cmux.irx.enabled`
/// (or `CMUX_IRX_ENABLED=1`) is set, cmuxApp routes ALL `.iroh` traffic here
/// and the legacy `MobileIrohRuntimeComposition` is never configured, so the
/// two stacks cannot fight over the broker binding slot.
public actor MobileIrxRuntimeComposition {
    public static let enabledDefaultsKey = "cmux.irx.enabled"
    public static let forceRelayDefaultsKey = "cmux.irx.force-relay"

    /// irx is the PRIMARY transport: on by default in every configuration.
    /// An explicit `false` in defaults (the remote revert switch writes it)
    /// falls back to the legacy stack; the env var re-arms and persists.
    public nonisolated static var isEnabled: Bool {
        if ProcessInfo.processInfo.environment["CMUX_IRX_ENABLED"] == "1" {
            UserDefaults.standard.set(true, forKey: enabledDefaultsKey)
            return true
        }
        if UserDefaults.standard.object(forKey: enabledDefaultsKey) != nil {
            return UserDefaults.standard.bool(forKey: enabledDefaultsKey)
        }
        return true
    }

    public nonisolated static var forceRelayOnly: Bool {
        if ProcessInfo.processInfo.environment["CMUX_IRX_FORCE_RELAY"] == "1" {
            UserDefaults.standard.set(true, forKey: forceRelayDefaultsKey)
            return true
        }
        return UserDefaults.standard.bool(forKey: forceRelayDefaultsKey)
    }

    public enum CompositionError: Error, Sendable {
        case notSignedIn
        case unsupportedRoute
        case peerNotDiscovered
        case simulatorStreamingUnsupported
    }

    /// One journal for every irx component on the phone; the JSONL file lives
    /// in the app container's Documents so the soak analyzer can pull it with
    /// `simctl get_app_container`.
    nonisolated static let journal: IrxJournal = {
        let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first
        return IrxJournal(
            subsystem: "dev.cmux.ios",
            category: "irx-client",
            journalFileURL: documents?.appendingPathComponent("irx-journal.jsonl")
        )
    }()

    /// The stable factory cmuxApp registers for `.iroh` routes in irx mode.
    public nonisolated var transportFactory: CmxConnectivityDeferredTransportFactory {
        CmxConnectivityDeferredTransportFactory(provider: self)
    }

    private let brokerBaseURL: URL?
    private let clientNamespace: String
    private let tag: String
    private let stateDirectory: URL

    private weak var auth: AuthCoordinator?
    /// Identity donor (identity adoption): the legacy composition owns the
    /// Keychain identity, app-instance scope, and durable device ID.
    private weak var legacyComposition: MobileIrohRuntimeComposition?
    private var broker: IrxBrokerService?
    private var endpointSupervisor: IrxEndpointSupervisor?
    private var autopilot: IrxRelayCredentialAutopilot?
    private var identity: IrxIdentity?
    /// The always-on fact channel to the per-account control-plane DO.
    /// Never on the dial path; delivers pushed passes and hint updates.
    private var controlPlane: IrxControlPlaneClient?
    private var controlPlaneBaseURL: URL?
    private var provisioningTask: Task<Void, Never>?
    private var provisionInFlight: Task<IrxBrokerService, any Error>?
    /// One reconnect owner per Mac endpoint (contract: the single dialer).
    private var enginesByPeer: [String: IrxPeerEngine] = [:]
    /// Route material per peer, refreshed on every transport request.
    private var routesByPeer: [String: (relayURL: String?, directAddresses: [String])] = [:]
    /// The control lane is single-consumer: one claim per admitted session.
    private var claimedControlSessions: Set<String> = []
    /// The events uni-lane accept is single-consumer per session too.
    private var claimedEventSessions: Set<String> = []

    @MainActor
    public init(
        apiBaseURL: String,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appNamespace injectedAppNamespace: MobileIOSAppNamespace? = nil,
        keychainAccessGroup: String? = nil,
        defaults: UserDefaults = .standard
    ) {
        _ = keychainAccessGroup
        _ = defaults
        let appNamespace = injectedAppNamespace
            ?? MobileIOSAppNamespace(bundleIdentifier: bundleIdentifier)
        clientNamespace = appNamespace?.bundleIdentifier ?? "legacy"
        brokerBaseURL = MobileIrohRuntimeComposition.resolvedBrokerBaseURL(
            apiBaseURL: apiBaseURL,
            infoDictionary: infoDictionary,
            bundleIdentifier: bundleIdentifier
        )
        let rawTag = MobileIOSBuildScope.current(
            infoDictionary: infoDictionary,
            bundleIdentifier: bundleIdentifier
        )?.value ?? "default"
        tag = String(rawTag.prefix(64)).lowercased().map { character in
            (character.isASCII && (character.isLetter || character.isNumber))
                || ["-", ".", ":", "_"].contains(character)
                ? String(character) : "-"
        }.joined()
        stateDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("cmux-irx", isDirectory: true)
    }

    /// irx mints its own durable device UUID (persisted beside the identity),
    /// giving the irx binding its own broker slot: it can never reincarnate
    /// the legacy runtime's binding out from under another build.
    private func irxDeviceID() -> String {
        let url = stateDirectory.appendingPathComponent("device-id")
        if let existing = try? String(contentsOf: url, encoding: .utf8),
            !existing.isEmpty
        {
            return existing.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let minted = UUID().uuidString.lowercased()
        try? FileManager.default.createDirectory(
            at: stateDirectory, withIntermediateDirectories: true)
        try? minted.write(to: url, atomically: true, encoding: .utf8)
        return minted
    }

    // MARK: - Lifecycle

    public func configure(
        auth: AuthCoordinator,
        legacy: MobileIrohRuntimeComposition? = nil,
        controlPlaneBaseURL: URL? = nil
    ) {
        self.auth = auth
        legacyComposition = legacy
        self.controlPlaneBaseURL = controlPlaneBaseURL
        Self.journal.record(
            "client-runtime", "configured",
            [
                "tag": tag,
                "namespace": clientNamespace,
                "force_relay": String(Self.forceRelayOnly),
                "broker": brokerBaseURL?.host() ?? "-",
            ]
        )
        // Proactive provisioning so the user-visible connect is warm:
        // identity, binding, discovery, relay credentials all resolve in the
        // background at launch, never on the dial path.
        provisioningTask?.cancel()
        provisioningTask = Task { [weak self] in
            // Capped exponential backoff: a persistent broker-side failure
            // must degrade to a gentle poll, never a 2s hammer (each failed
            // attempt can hit registration, and registration writes bump the
            // account route revision fleet-wide).
            var delay: Duration = .seconds(2)
            while !Task.isCancelled {
                if await self?.provisionIfPossible() == true {
                    return
                }
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(30))
            }
        }
    }

    /// Foreground kick: re-check credential freshness immediately (iOS
    /// suspension pauses the autopilot's sleep) and reconnect the control
    /// socket, which resyncs facts from the persisted revision.
    public func didBecomeActive() async {
        await autopilot?.kick()
        await controlPlane?.kick()
        for engine in enginesByPeer.values {
            await engine.warmUp(trigger: "foreground")
        }
    }

    // MARK: - Control-plane fact ingestion

    private func startControlPlane(identity: IrxIdentity) {
        guard controlPlane == nil, let controlPlaneBaseURL, let auth else { return }
        let client = IrxControlPlaneClient(
            configuration: .init(
                socketURL: controlPlaneBaseURL
                    .appendingPathComponent("v1/control/socket"),
                endpointIDHex: identity.endpointIDHex,
                // Phase A: passes stay on the HTTPS autopilot (now hardened
                // with stale-connection retry). The broker's mint endpoint
                // requires an endpoint-signed proof for non-legacy
                // namespaces, which the DO cannot mint bearer-only; flip
                // this when proof pass-through ships.
                wantPasses: false,
                cacheDirectory: stateDirectory
            ),
            tokenPair: { [weak auth] in
                guard let auth else { return nil }
                let session = try await auth.authenticatedSessionSnapshot()
                return (session.accessToken, session.refreshToken)
            },
            handlers: .init(
                onRelayPasses: { [weak self] credentials in
                    await self?.ingestPushedPasses(credentials)
                },
                onHintUpdate: { [weak self] endpointIDHex, relayURL in
                    await self?.ingestHintUpdate(
                        endpointIDHex: endpointIDHex, relayURL: relayURL)
                },
                onDirectory: { _ in },
                onSnapshotComplete: { _ in }
            ),
            journal: Self.journal
        )
        controlPlane = client
        Task { await client.start() }
    }

    /// Pushed passes flow through the broker's mint rules (fleet allowlist,
    /// identity binding, monotonic freshness), then rotate make-before-break
    /// and reset the autopilot timer so push and fallback never double-mint.
    private func ingestPushedPasses(_ credentials: [IrxRelayCredential]) async {
        guard let broker, let endpointSupervisor, let autopilot else { return }
        guard let accepted = await broker.acceptPushedRelayCredentials(credentials)
        else { return }
        await endpointSupervisor.rotateCredentials(accepted)
        await autopilot.kick()
    }

    /// The event-driven relay race: a pushed hint that disagrees with the
    /// route an in-flight dial used cancels that dial and redials at the
    /// true relay. An admitted session is never touched, and an agreeing
    /// hint (the overwhelmingly common case) is a no-op.
    private func ingestHintUpdate(endpointIDHex: String, relayURL: String) async {
        let existing = routesByPeer[endpointIDHex]
        guard existing?.relayURL != relayURL else { return }
        routesByPeer[endpointIDHex] = (relayURL, existing?.directAddresses ?? [])
        Self.journal.record(
            "client-runtime", "hint-adopted",
            [
                "peer": String(endpointIDHex.prefix(12)),
                "relay": relayURL,
                "was": existing?.relayURL ?? "-",
            ]
        )
        if let engine = enginesByPeer[endpointIDHex] {
            await engine.relayHintChanged(trigger: "ctl-hint-update")
        }
    }

    private func provisionIfPossible() async -> Bool {
        guard let auth else { return false }
        guard let session = try? await auth.authenticatedSessionSnapshot() else {
            return false
        }
        _ = session
        do {
            _ = try await provisionedBroker()
            Self.journal.record("client-runtime", "provisioned")
            return true
        } catch {
            Self.journal.record(
                "client-runtime", "provisioning-retry",
                ["error": String(describing: error)]
            )
            return false
        }
    }

    /// Builds and warms the full broker/endpoint stack, publishing it ONLY
    /// after every step succeeds. A transient failure (e.g. the auth session
    /// not yet coherent during launch sign-in) must never leave a
    /// half-initialized broker behind: an unregistered client 403s every
    /// later call, which is exactly the poisoned state this single-flight
    /// all-or-nothing shape forbids.
    private func provisionedBroker() async throws -> IrxBrokerService {
        if let broker { return broker }
        if let provisionInFlight {
            return try await provisionInFlight.value
        }
        let task = Task<IrxBrokerService, any Error> {
            try await self.provisionOnce()
        }
        provisionInFlight = task
        defer { provisionInFlight = nil }
        return try await task.value
    }

    private func provisionOnce() async throws -> IrxBrokerService {
        guard let auth, let brokerBaseURL else {
            throw CompositionError.notSignedIn
        }
        let session = try await auth.authenticatedSessionSnapshot()
        // IDENTITY ADOPTION: same identity/device/app-instance as the legacy
        // stack, so the binding refreshes in place and stored routes + pair
        // grants stay valid across the transport switch.
        guard let legacyComposition,
            let adopted = try await legacyComposition.irxAdoptedIdentity(
                accountID: session.accountID, tag: tag)
        else {
            throw CompositionError.notSignedIn
        }
        let identity = IrxIdentity(
            privateKeyData: adopted.material.secretKey.bytes,
            deviceID: adopted.deviceID,
            appInstanceID: adopted.appInstanceID
        )
        let broker = try IrxBrokerService(
            configuration: .init(
                baseURL: brokerBaseURL,
                clientNamespace: clientNamespace,
                tag: tag,
                platform: .ios,
                displayName: nil,
                cacheDirectory: stateDirectory,
                identityGeneration: adopted.material.generation
            ),
            identity: identity,
            accessTokenPair: { [weak auth] in
                guard let auth else { return nil }
                let session = try await auth.authenticatedSessionSnapshot()
                return (session.accessToken, session.refreshToken)
            },
            journal: Self.journal
        )
        let supervisor = IrxEndpointSupervisor(
            configuration: .init(
                identity: identity,
                pathMode: Self.forceRelayOnly ? .relayOnly : .automatic,
                preferredBindAddress: nil,
                // The Mac opens no bidi streams toward the phone; the events
                // lane is unidirectional and credited post-admission.
                initialRemoteBiStreams: 0,
                initialRemoteUniStreams: 0
            ),
            journal: Self.journal
        )
        let pilot = IrxRelayCredentialAutopilot(
            broker: broker, endpoint: supervisor, journal: Self.journal)
        // Launch-latency shape (measured on device: registration 636ms +
        // discovery 445ms + lazy bind-to-online 1186ms serialized into a
        // 3.3s first connect): when the binding and trust snapshot are
        // already on disk, publish immediately and refresh registration +
        // discovery in the BACKGROUND; and warm the endpoint's relay link
        // during provisioning so the first dial never pays for it.
        let cachedBinding = await broker.cachedBinding()
        let cachedTrust = await broker.cachedTrust()
        let cachedCredentials = await broker.cachedRelayCredentials()
        if cachedBinding == nil || cachedTrust == nil {
            // First run for this identity: the full serial path, correctness
            // over speed (registration must precede mint/discovery).
            _ = try await broker.register(pairingEnabled: false, relayURLHint: nil)
            _ = try await pilot.usableCredentials()
            _ = try? await broker.discover()
        } else if cachedCredentials.isEmpty {
            // Cached identity but stale relay passes: the mint below MUST
            // follow a registration on THIS client instance. register() arms
            // the client's per-request binding proof, and the broker's mint
            // policy rejects proofless non-legacy mints; a mint racing a
            // background register 403s (`binding_request_proof_required`)
            // and wedges provisioning in a retry loop.
            _ = try await broker.register(pairingEnabled: false, relayURLHint: nil)
            Task { _ = try? await broker.discover() }
        } else {
            // Fresh passes on disk: nothing needs the broker before dialing,
            // so registration + discovery refresh entirely in the background
            // (the true zero-RTT launch).
            Task {
                _ = try? await broker.register(pairingEnabled: false, relayURLHint: nil)
                _ = try? await broker.discover()
            }
        }
        let credentials = try await pilot.usableCredentials()
        // Fire-and-forget relay-link warm-up: bind + come online now, in
        // parallel with whatever the UI is doing.
        Task { _ = try? await supervisor.readyEndpoint(credentials: credentials) }
        await pilot.start()
        self.identity = identity
        self.broker = broker
        endpointSupervisor = supervisor
        autopilot = pilot
        startControlPlane(identity: identity)
        return broker
    }

    // MARK: - Dialing

    private func peerTarget(for request: CmxByteTransportRequest) throws -> String {
        guard request.route.kind == .iroh,
            case let .peer(identity, pathHints) = request.route.endpoint
        else {
            throw CompositionError.unsupportedRoute
        }
        let now = Date()
        let relayURL = pathHints.first {
            $0.kind == .relayURL && $0.isUsable(at: now)
        }?.value
        let directAddresses = Self.forceRelayOnly
            ? []
            : pathHints.filter { $0.kind == .directAddress && $0.isUsable(at: now) }
                .map(\.value)
        // Attach tickets strip path hints, so a nil hint here is normal;
        // never clobber a relay already resolved from discovery with nil.
        let existing = routesByPeer[identity.endpointID]
        routesByPeer[identity.endpointID] = (
            relayURL ?? existing?.relayURL,
            directAddresses.isEmpty ? (existing?.directAddresses ?? []) : directAddresses
        )
        return identity.endpointID
    }

    /// The target's home relay from the account registry: the Mac registers
    /// the relay its endpoint actually homes on, and dialing any OTHER relay
    /// is a black hole (the relay only forwards to peers connected to it).
    private func relayHintFromDiscovery(
        peerHex: String,
        broker: IrxBrokerService
    ) async -> String? {
        guard let discovery = try? await broker.discover() else { return nil }
        let now = Date()
        let hint = discovery.bindings
            .first { $0.endpointID.endpointID == peerHex }?
            .pathHints
            .first { $0.kind == .relayURL && $0.isUsable(at: now) }?
            .value
        if let hint {
            routesByPeer[peerHex] = (hint, routesByPeer[peerHex]?.directAddresses ?? [])
        }
        return hint
    }

    private func engine(forPeer peerHex: String) -> IrxPeerEngine {
        if let existing = enginesByPeer[peerHex] { return existing }
        let engine = IrxPeerEngine(
            journal: Self.journal,
            label: String(peerHex.prefix(12))
        ) { [weak self] in
            guard let self else { throw CompositionError.notSignedIn }
            return try await self.dialOnce(peerHex: peerHex)
        }
        enginesByPeer[peerHex] = engine
        return engine
    }

    /// One dial: cached grant + cached credentials + ready endpoint, then
    /// connect + one-round-trip admission. Broker calls happen only on cache
    /// misses (first pairing with this Mac, or a stale grant).
    private func dialOnce(peerHex: String) async throws -> IrxClientSession {
        let broker = try await provisionedBroker()
        guard let supervisor = endpointSupervisor, let autopilot else {
            throw CompositionError.notSignedIn
        }
        let grant = try await resolvedGrant(peerHex: peerHex, broker: broker)
        let credentials = try await autopilot.usableCredentials()
        var relayURL = routesByPeer[peerHex]?.relayURL
        if relayURL == nil {
            relayURL = await relayHintFromDiscovery(peerHex: peerHex, broker: broker)
        }
        Self.journal.record(
            "client-dial", "target-resolved",
            [
                "peer": String(peerHex.prefix(12)),
                "relay": relayURL ?? "-",
                "direct": String(routesByPeer[peerHex]?.directAddresses.count ?? 0),
            ]
        )
        if relayURL == nil {
            // Stale/missing hint (e.g. the Mac's registered hint lapsed):
            // fall back to our own relay rather than refusing outright; the
            // fleet is small enough that co-homing is common, and a wrong
            // guess fails in one dial timeout instead of stranding the peer.
            relayURL = credentials.first?.relayURL
            Self.journal.record(
                "client-dial", "relay-fallback",
                ["peer": String(peerHex.prefix(12)), "relay": relayURL ?? "-"]
            )
        }
        let address = try supervisor.dialAddress(
            peerEndpointIDHex: peerHex,
            relayURL: relayURL,
            directAddresses: routesByPeer[peerHex]?.directAddresses ?? []
        )
        let connection = try await supervisor.dial(
            address: address, credentials: credentials)
        do {
            let (admit, control) = try await IrxAdmission.performClient(
                connection: connection,
                grantJWS: grant.grantJWS,
                journal: Self.journal
            )
            // Credit the server-opened events lane now that admission holds.
            await connection.raiseRemoteStreamCredit(bi: 0, uni: 4)
            return IrxClientSession(
                connection: connection,
                admit: admit,
                control: control,
                establishedAt: Date()
            )
        } catch let denial as IrxAdmissionDenied {
            // A revoked/expired/mismatched grant can be stale cache: drop it
            // so the NEXT dial re-mints instead of re-presenting the corpse.
            if denial.code == .invalidGrant || denial.code == .grantExpired
                || denial.code == .revoked
            {
                await broker.dropGrant(acceptorEndpointIDHex: peerHex)
            }
            throw denial
        }
    }

    private func resolvedGrant(
        peerHex: String,
        broker: IrxBrokerService
    ) async throws -> IrxGrantSnapshot {
        if let cached = await broker.cachedGrant(acceptorEndpointIDHex: peerHex) {
            return cached
        }
        // First contact with this Mac: find its binding, mint a grant.
        let discovery = try await broker.discover()
        guard
            let acceptorBinding = discovery.bindings.first(where: {
                $0.endpointID.endpointID == peerHex && $0.platform == .mac
            })
        else {
            throw CompositionError.peerNotDiscovered
        }
        return try await broker.issuePairGrant(
            acceptorBindingID: acceptorBinding.bindingID,
            acceptorEndpointIDHex: peerHex
        )
    }

    // MARK: - Seam surface consumed by cmuxApp

    public func serverEventByteStream(
        for request: CmxByteTransportRequest
    ) async throws -> CmxIndependentEventByteStream {
        let peerHex = try peerTarget(for: request)
        let session = try await engine(forPeer: peerHex)
            .ensureSession(trigger: "server-events")
        guard !claimedEventSessions.contains(session.admit.session) else {
            throw CompositionError.unsupportedRoute
        }
        claimedEventSessions.insert(session.admit.session)
        let connection = session.connection
        let journal = Self.journal
        return AsyncThrowingStream { continuation in
            let pump = Task {
                guard
                    let (descriptor, reader) = try await connection.acceptUniLane(),
                    descriptor.lane == .events
                else {
                    journal.record("client-events", "lane-missing")
                    continuation.finish(
                        throwing: IrxConnectionError.closed(nil))
                    return
                }
                journal.record("client-events", "lane-accepted")
                do {
                    while let chunk = try await reader.readRaw() {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                pump.cancel()
            }
        }
    }

    public func openTerminalLane(
        for request: CmxByteTransportRequest,
        surfaceID: UUID,
        cursor: UInt64? = nil
    ) async throws -> MobileIrohTerminalLane {
        let peerHex = try peerTarget(for: request)
        let session = try await engine(forPeer: peerHex)
            .ensureSession(trigger: "terminal-lane")
        let lane = try await session.connection.openLane(
            IrxLaneDescriptor(
                lane: .terminal,
                resource: "terminal:\(surfaceID.uuidString.lowercased())",
                cursor: cursor
            )
        )
        Self.journal.record(
            "client-terminal", "lane-opened",
            [
                "surface": surfaceID.uuidString.lowercased(),
                "cursor": cursor.map(String.init) ?? "-",
            ]
        )
        return MobileIrohTerminalLane(stream: lane.bidirectional())
    }

    public func openArtifactLane(
        for request: CmxByteTransportRequest,
        resourceID: String,
        offset: UInt64
    ) async throws -> any MobileArtifactLaneConnection {
        let peerHex = try peerTarget(for: request)
        let session = try await engine(forPeer: peerHex)
            .ensureSession(trigger: "artifact-lane")
        let lane = try await session.connection.openLane(
            IrxLaneDescriptor(lane: .artifact, resource: resourceID, offset: offset)
        )
        return IrxArtifactLane(lane: lane)
    }

    public func simulatorStreamLaneUnavailable() throws -> Never {
        // Simulator streaming is not served by irx v1; the viewer surfaces
        // its ordinary unavailable state.
        throw CompositionError.simulatorStreamingUnsupported
    }

    /// The deferred transport the RPC layer connects through. Each RPC client
    /// generation claims one admitted session's control lane; a replacement
    /// client forces a fresh dial (superseding the old session Mac-side).
    public func transport(
        for request: CmxByteTransportRequest
    ) async throws -> any CmxByteTransport {
        let peerHex = try peerTarget(for: request)
        return IrxControlByteTransport(closeCode: .explicitRedial) { [weak self] in
            guard let self else {
                throw CompositionError.notSignedIn
            }
            return try await self.claimControlLane(peerHex: peerHex)
        }
    }

    private func claimControlLane(
        peerHex: String
    ) async throws -> (IrxConnection, IrxLaneStream) {
        let engine = engine(forPeer: peerHex)
        var session = try await engine.ensureSession(trigger: "control-transport")
        if claimedControlSessions.contains(session.admit.session) {
            // The live session's control lane already belongs to an earlier
            // transport: this caller is a replacement client, so replace the
            // session (one control owner per session, always).
            session = try await engine.ensureSession(
                explicit: true, trigger: "control-transport-replacement")
        }
        claimedControlSessions.insert(session.admit.session)
        return (session.connection, session.control)
    }
}

/// Artifact lane over irx: bounded reads down, no upstream bytes.
struct IrxArtifactLane: MobileArtifactLaneConnection {
    let lane: IrxLaneStream

    func receive(maximumByteCount: Int) async throws -> Data? {
        try await lane.reader.readRaw(maximumByteCount: maximumByteCount)
    }

    func close() async {
        await lane.close()
    }
}

extension MobileIrxRuntimeComposition: CmxIrohDeferredTransportProviding {}
