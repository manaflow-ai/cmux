public import CMUXMobileCore
import CmuxAuthRuntime
import CmuxDotTransport
public import CmuxIrohTransport
import CmuxIrxTransport
import CmuxMobileShell
public import CmuxMobileRPC
public import Foundation
import OSLog

/// iOS composition root for the dot transport (the per-Mac Durable Object
/// relay in `CmuxDotTransport`). Default ON: when enabled, cmuxApp routes ALL
/// `.iroh` traffic here and neither the irx rebuild nor the legacy iroh
/// runtime is configured. The phone dials its paired Mac through the relay DO
/// on the presence worker origin, reusing every existing pairing artifact
/// (identity, pair grants, stored Macs/routes) with zero re-pairing.
public actor MobileDotRuntimeComposition {
    public static let enabledDefaultsKey = "cmux.dot.enabled"

    /// dot is the PRIMARY transport: on by default in every configuration.
    /// An explicit `false` in defaults (the remote revert switch writes it)
    /// falls back to the irx/legacy pick; the env var re-arms and persists.
    public nonisolated static var isEnabled: Bool {
        if ProcessInfo.processInfo.environment["CMUX_DOT_ENABLED"] == "1" {
            UserDefaults.standard.set(true, forKey: enabledDefaultsKey)
            return true
        }
        if UserDefaults.standard.object(forKey: enabledDefaultsKey) != nil {
            return UserDefaults.standard.bool(forKey: enabledDefaultsKey)
        }
        return true
    }

    public static let forceOnlyDefaultsKey = "cmux.dot.force-only"

    /// Soak/verification rigs set this so NO fallback transport kinds are
    /// registered and even a simulator provably rides the relay path
    /// (mirrors the irx force-relay knob's fallback suppression).
    public nonisolated static var forceTransportOnly: Bool {
        if ProcessInfo.processInfo.environment["CMUX_DOT_FORCE_ONLY"] == "1" {
            return true
        }
        return UserDefaults.standard.bool(forKey: forceOnlyDefaultsKey)
    }

    public enum CompositionError: Error, Sendable {
        case notSignedIn
        case unsupportedRoute
        case peerNotDiscovered
        case relayUnavailable
        case invalidGrant
        case eventsLaneUnavailable
        case sessionEnded(String)
        case simulatorStreamingUnsupported
    }

    /// One journal for every dot component on the phone; the JSONL file lives
    /// in the app container's Documents so the soak analyzer can pull it with
    /// `simctl get_app_container` (schema-compatible with the irx journal).
    nonisolated static let journal: DotJournal = {
        let logger = Logger(subsystem: "dev.cmux.ios", category: "dot-client")
        let mirror: @Sendable (String) -> Void = { line in
            logger.notice("\(line, privacy: .public)")
        }
        guard
            let documents = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask
            ).first
        else {
            return DotJournal(write: mirror)
        }
        return DotJournal.file(
            url: documents.appendingPathComponent("dot-journal.jsonl"),
            mirror: mirror
        )
    }()

    /// The broker-reuse plumbing journals through the irx JSONL schema; a
    /// sibling file keeps `dot-journal.jsonl` single-writer (two append
    /// queues on one file could interleave mid-line).
    nonisolated static let brokerJournal: IrxJournal = {
        let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first
        return IrxJournal(
            subsystem: "dev.cmux.ios",
            category: "dot-broker",
            journalFileURL: documents?.appendingPathComponent("dot-broker-journal.jsonl")
        )
    }()

    /// The stable factory cmuxApp registers for `.iroh` routes in dot mode.
    /// The kind name is legacy wire compat: stored routes and attach tickets
    /// carry the Mac's identity under `.iroh`, and dot resolves the grant and
    /// relay coordinates from that identity alone.
    public nonisolated var transportFactory: CmxConnectivityDeferredTransportFactory {
        CmxConnectivityDeferredTransportFactory(provider: self)
    }

    private let brokerBaseURL: URL?
    /// The relay lives on the SAME origin as the presence worker (the per-Mac
    /// `MacRelay` DO is hosted alongside `TeamPresence`), including the
    /// `CMUXPresenceBaseURL` Info.plist bake for per-dev isolated workers.
    private let relayBaseURL: URL?
    private let clientNamespace: String
    private let tag: String
    /// irx's state directory ON PURPOSE: the broker reuse below shares the
    /// binding/trust/grant disk caches the iroh stacks populated, so every
    /// pair grant already minted keeps working over dot with zero re-pairing.
    private let stateDirectory: URL

    private weak var auth: AuthCoordinator?
    /// Identity donor (identity adoption): the legacy composition owns the
    /// Keychain identity, app-instance scope, and durable device ID.
    private weak var legacyComposition: MobileIrohRuntimeComposition?
    private var broker: IrxBrokerService?
    private var identity: IrxIdentity?
    private var provisioningTask: Task<Void, Never>?
    private var provisionInFlight: Task<IrxBrokerService, any Error>?
    /// One reconnect owner per Mac peer (contract: the single dialer).
    private var enginesByPeer: [String: DotPeerEngine] = [:]
    /// Engine construction awaits grant/trust resolution, so single-flight it
    /// per peer (actor reentrancy would otherwise mint two reconnect owners).
    private var engineBuilds: [String: Task<DotPeerEngine, any Error>] = [:]
    /// The control stream is single-consumer: one claim per admitted session.
    private var claimedControlSessions: Set<String> = []
    /// The host-opened events lane is single-consumer per session too.
    private var claimedEventSessions: Set<String> = []

    @MainActor
    public init(
        apiBaseURL: String,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appNamespace injectedAppNamespace: MobileIOSAppNamespace? = nil,
        keychainAccessGroup: String? = nil,
        isDevelopmentAuthChannel: Bool
    ) {
        _ = keychainAccessGroup
        let appNamespace = injectedAppNamespace
            ?? MobileIOSAppNamespace(bundleIdentifier: bundleIdentifier)
        clientNamespace = appNamespace?.bundleIdentifier ?? "legacy"
        brokerBaseURL = MobileIrohRuntimeComposition.resolvedBrokerBaseURL(
            apiBaseURL: apiBaseURL,
            infoDictionary: infoDictionary,
            bundleIdentifier: bundleIdentifier
        )
        // Same resolution the presence subscriber uses (env override, then
        // defaults, then the baked Info.plist value, then the auth-channel
        // default), so the leg dials the worker whose Stack project can
        // verify its token.
        relayBaseURL = PresenceClient.resolvedServiceBaseURL(
            isDevelopmentAuthChannel: isDevelopmentAuthChannel
        ).flatMap { URL(string: $0) }
        let rawTag = MobileIOSBuildScope.current(
            infoDictionary: infoDictionary,
            bundleIdentifier: bundleIdentifier
        )?.value ?? "default"
        tag = String(rawTag.prefix(64)).lowercased().map { character in
            (character.isASCII && (character.isLetter || character.isNumber))
                || ["-", ".", ":", "_"].contains(character)
                ? String(character) : "-"
        }.joined()
        // Per-bundle, per-broker state (post-#11047), the SAME directory the
        // irx composition computes: the broker reuse below shares its
        // binding/trust/grant disk caches, so every pair grant already
        // minted keeps working over dot with zero re-pairing.
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        stateDirectory = IrxStateLocation.directory(
            base: appSupport,
            bundleIdentifier: bundleIdentifier,
            brokerHost: brokerBaseURL?.host()
        )
        IrxStateLocation.removeLegacySharedDirectory(base: appSupport)
    }

    // MARK: - Lifecycle

    public func configure(
        auth: AuthCoordinator,
        legacy: MobileIrohRuntimeComposition? = nil
    ) {
        self.auth = auth
        legacyComposition = legacy
        Self.journal.record(
            component: "client-runtime", event: "configured",
            attributes: [
                "tag": tag,
                "namespace": clientNamespace,
                "relay": relayBaseURL?.host() ?? "-",
                "broker": brokerBaseURL?.host() ?? "-",
            ]
        )
        // Proactive provisioning so the user-visible connect is warm:
        // identity adoption and the broker's cached binding/trust/grants all
        // resolve in the background at launch, never on the dial path.
        provisioningTask?.cancel()
        provisioningTask = Task { [weak self] in
            while !Task.isCancelled {
                if await self?.provisionIfPossible() == true {
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Foreground kick: engines redial now if their session died while iOS
    /// suspension paused the leg watchdogs (connect is idempotent when the
    /// session is already ready).
    public func didBecomeActive() async {
        for engine in enginesByPeer.values {
            await engine.connect()
        }
    }

    private func provisionIfPossible() async -> Bool {
        guard let auth else { return false }
        guard (try? await auth.authenticatedSessionSnapshot()) != nil else {
            return false
        }
        do {
            _ = try await provisionedBroker()
            Self.journal.record(component: "client-runtime", event: "provisioned")
            return true
        } catch {
            Self.journal.record(
                component: "client-runtime", event: "provisioning-retry",
                attributes: ["error": String(describing: error)]
            )
            return false
        }
    }

    /// Builds the control-plane broker, publishing it ONLY after every step
    /// succeeds (single-flight, all-or-nothing; a half-initialized broker
    /// would 403 every later call).
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
        // stack, so every stored route and pair grant stays valid across the
        // transport switch and this phone's identity hex still matches the
        // `initiator.endpointID` its grants pin.
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
        // Broker reuse is CONTROL PLANE only (registration, discovery, pair
        // grants, trust snapshot) against the shared disk caches; the data
        // plane is the relay DO, so no relay credentials, endpoint
        // supervisor, or credential autopilot exist here.
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
            journal: Self.brokerJournal
        )
        let cachedBinding = await broker.cachedBinding()
        let cachedTrust = await broker.cachedTrust()
        if cachedBinding == nil || cachedTrust == nil {
            // First run for this identity: serial, correctness over speed
            // (registration must precede grant minting and discovery).
            _ = try await broker.register(pairingEnabled: false, relayURLHint: nil)
            _ = try? await broker.discover()
        } else {
            // Warm start: publish immediately, refresh registration and the
            // trust/discovery snapshot in the background (irx's measured
            // launch-latency shape); nothing here sits on the dial path.
            Task {
                _ = try? await broker.register(pairingEnabled: false, relayURLHint: nil)
                _ = try? await broker.discover()
            }
        }
        self.identity = identity
        self.broker = broker
        return broker
    }

    // MARK: - Dialing

    private func peerTarget(for request: CmxByteTransportRequest) throws -> String {
        guard request.route.kind == .iroh,
            case let .peer(identity, _) = request.route.endpoint
        else {
            throw CompositionError.unsupportedRoute
        }
        // Path hints are iroh reachability material; dot is always
        // relay-carried, so the peer identity is the whole dial input.
        return identity.endpointID
    }

    private func engine(forPeer peerHex: String) async throws -> DotPeerEngine {
        if let existing = enginesByPeer[peerHex] { return existing }
        if let inFlight = engineBuilds[peerHex] {
            return try await inFlight.value
        }
        let task = Task<DotPeerEngine, any Error> {
            try await self.buildEngine(peerHex: peerHex)
        }
        engineBuilds[peerHex] = task
        defer { engineBuilds[peerHex] = nil }
        let engine = try await task.value
        enginesByPeer[peerHex] = engine
        return engine
    }

    private func buildEngine(peerHex: String) async throws -> DotPeerEngine {
        guard let relayBaseURL else { throw CompositionError.relayUnavailable }
        let broker = try await provisionedBroker()
        guard let identity, let auth else { throw CompositionError.notSignedIn }
        let (macDeviceID, admission) = try await admissionMaterial(
            peerHex: peerHex, broker: broker)
        Self.journal.record(
            component: "client-dial", event: "target-resolved",
            attributes: [
                "peer": String(peerHex.prefix(12)),
                "relay": relayBaseURL.host() ?? "-",
            ]
        )
        let leg = DotLegConfiguration(
            relayBaseURL: relayBaseURL,
            macDeviceID: macDeviceID,
            selfDeviceID: identity.deviceID,
            role: .phone,
            tokenProvider: { [weak auth] in
                // Fresh Stack access token on every (re)dial and for the
                // leg's in-band `auth.refresh`; same source the presence
                // subscriber reads (`AuthCoordinator.accessToken()`).
                guard let auth else {
                    throw CompositionError.notSignedIn
                }
                return try await auth.accessToken()
            },
            journal: Self.journal
        )
        return DotPeerEngine(
            configuration: .init(
                leg: leg,
                identity: DotAdoptedIdentitySigner(identity: identity),
                admission: admission
            )
        )
    }

    /// The dial input is the Mac's identity hex (what `.iroh` routes carry).
    /// Everything else comes from the CACHED pair grant minted for this
    /// phone: `acceptor.deviceID` names the per-Mac relay DO,
    /// `acceptor.endpointID` pins the E2E handshake peer, and the persisted
    /// trust snapshot supplies the grant-verification keys. Claims are
    /// decoded here for ROUTING only; cryptographic verification stays inside
    /// the dot handshake (the phone pins the acceptor key, the Mac verifies
    /// the grant JWS against the same pinned key set).
    private func admissionMaterial(
        peerHex: String,
        broker: IrxBrokerService
    ) async throws -> (macDeviceID: String, admission: DotAdmissionMaterial) {
        let grant = try await resolvedGrant(peerHex: peerHex, broker: broker)
        let claims: CmxIrohPairGrantClaims
        do {
            claims = try Self.decodedGrantClaims(grant.grantJWS)
        } catch {
            // An undecodable cached grant is a corpse: drop it so the NEXT
            // dial re-mints instead of re-presenting it.
            await broker.dropGrant(acceptorEndpointIDHex: peerHex)
            throw error
        }
        guard claims.acceptor.endpointID.endpointID == peerHex,
            let acceptorKey = Self.data(fromHex: peerHex),
            acceptorKey.count == 32
        else {
            await broker.dropGrant(acceptorEndpointIDHex: peerHex)
            throw CompositionError.invalidGrant
        }
        let keys = try await grantVerificationKeys(broker: broker)
        return (
            claims.acceptor.deviceID,
            DotAdmissionMaterial(
                grantJWS: grant.grantJWS,
                grantVerificationKeys: keys,
                expectedPeerPublicKey: acceptorKey
            )
        )
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

    private func grantVerificationKeys(
        broker: IrxBrokerService
    ) async throws -> [Data] {
        var trust = await broker.cachedTrust()
        if trust == nil {
            _ = try? await broker.discover()
            trust = await broker.cachedTrust()
        }
        guard let trust else { throw CompositionError.peerNotDiscovered }
        let keys = trust.verificationKeys.keys.compactMap { key -> Data? in
            // Raw 32-byte Ed25519 key = SPKI DER minus its fixed prefix.
            guard let der = Data(base64Encoded: key.spkiDerBase64),
                der.count > 32
            else { return nil }
            return Data(der.suffix(32))
        }
        guard !keys.isEmpty else { throw CompositionError.invalidGrant }
        return keys
    }

    private static func decodedGrantClaims(
        _ grantJWS: String
    ) throws -> CmxIrohPairGrantClaims {
        let segments = grantJWS.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
            let payload = base64URLDecoded(String(segments[1]))
        else {
            throw CompositionError.invalidGrant
        }
        do {
            return try JSONDecoder().decode(CmxIrohPairGrantClaims.self, from: payload)
        } catch {
            throw CompositionError.invalidGrant
        }
    }

    private static func base64URLDecoded(_ value: String) -> Data? {
        var standard = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        return Data(base64Encoded: standard)
    }

    private static func data(fromHex hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    // MARK: - Seam surface consumed by cmuxApp

    public func serverEventByteStream(
        for request: CmxByteTransportRequest
    ) async throws -> CmxIndependentEventByteStream {
        let peerHex = try peerTarget(for: request)
        let session = try await engine(forPeer: peerHex).readySession()
        guard !claimedEventSessions.contains(session.sessionID) else {
            throw CompositionError.unsupportedRoute
        }
        claimedEventSessions.insert(session.sessionID)
        let events = session.events
        let journal = Self.journal
        return AsyncThrowingStream { continuation in
            let pump = Task {
                for await event in events {
                    switch event {
                    case let .inboundStream(stream):
                        guard stream.descriptor.lane == DotLaneDescriptor.events.lane
                        else {
                            // v1 hosts open exactly one uni lane (events);
                            // an unknown lane is refused, not fatal.
                            journal.record(
                                component: "client-events", event: "unexpected-lane",
                                attributes: ["lane": stream.descriptor.lane]
                            )
                            await stream.close()
                            continue
                        }
                        journal.record(component: "client-events", event: "lane-accepted")
                        do {
                            // Chunk passthrough: the payload bytes are the
                            // dialect's own framed events, exactly what irx
                            // yields from its uni-lane reads.
                            while let chunk = try await stream.read() {
                                continuation.yield(chunk)
                            }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                        return
                    case let .ended(reason):
                        journal.record(
                            component: "client-events", event: "lane-missing",
                            attributes: ["reason": reason]
                        )
                        continuation.finish(
                            throwing: CompositionError.sessionEnded(reason))
                        return
                    }
                }
                journal.record(component: "client-events", event: "lane-missing")
                continuation.finish(throwing: CompositionError.eventsLaneUnavailable)
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
        let session = try await engine(forPeer: peerHex).readySession()
        let stream = try await session.openStream(
            .terminal(
                resource: "terminal:\(surfaceID.uuidString.lowercased())",
                cursor: cursor
            )
        )
        Self.journal.record(
            component: "client-terminal", event: "lane-opened",
            attributes: [
                "surface": surfaceID.uuidString.lowercased(),
                "cursor": cursor.map(String.init) ?? "-",
            ]
        )
        return MobileIrohTerminalLane(stream: Self.bidirectional(stream))
    }

    public func openArtifactLane(
        for request: CmxByteTransportRequest,
        resourceID: String,
        offset: UInt64
    ) async throws -> any MobileArtifactLaneConnection {
        let peerHex = try peerTarget(for: request)
        let session = try await engine(forPeer: peerHex).readySession()
        let stream = try await session.openStream(
            .artifact(resource: resourceID, offset: offset)
        )
        return DotArtifactLane(reader: DotBoundedStreamReader(stream: stream))
    }

    public func simulatorStreamLaneUnavailable() throws -> Never {
        // Simulator streaming is not served by dot v1; the viewer surfaces
        // its ordinary unavailable state.
        throw CompositionError.simulatorStreamingUnsupported
    }

    /// The deferred transport the RPC layer connects through. Each RPC client
    /// generation claims one admitted session's control stream; a replacement
    /// client forces a fresh dial (superseding the old session Mac-side).
    public func transport(
        for request: CmxByteTransportRequest
    ) async throws -> any CmxByteTransport {
        let peerHex = try peerTarget(for: request)
        return DotControlByteTransport { [weak self] in
            guard let self else {
                throw CompositionError.notSignedIn
            }
            return try await self.claimControlStream(peerHex: peerHex)
        }
    }

    private func claimControlStream(
        peerHex: String
    ) async throws -> any DotStream {
        let engine = try await engine(forPeer: peerHex)
        var session = try await engine.readySession()
        if claimedControlSessions.contains(session.sessionID) {
            // The live session's control stream already belongs to an earlier
            // transport: this caller is a replacement client, so replace the
            // session (one control owner per session, always).
            await session.close(reason: "control-transport-replacement")
            session = try await engine.readySession()
        }
        claimedControlSessions.insert(session.sessionID)
        // The phone INITIATES the control stream on first connect (lane
        // "control"; stream 0 = dialect control per the package contract).
        return try await session.openStream(.control)
    }
}

extension MobileDotRuntimeComposition {
    /// The legacy-seam view of a dot lane (IrxLegacyStreamAdapters lineage),
    /// so the proven terminal envelope handlers run over dot unchanged.
    fileprivate static func bidirectional(
        _ stream: any DotStream
    ) -> CmxIrohBidirectionalStream {
        CmxIrohBidirectionalStream(
            receiveStream: DotReceiveStreamAdapter(
                reader: DotBoundedStreamReader(stream: stream)
            ),
            sendStream: DotSendStreamAdapter(stream: stream)
        )
    }
}

extension MobileDotRuntimeComposition: CmxIrohDeferredTransportProviding {}

/// Adapts the adopted legacy identity (the same Ed25519 keypair the iroh
/// stacks authenticate with) to the dot handshake's signing seam, so the key
/// a grant pins as `initiator.endpointID` is the key the Mac verifies.
private struct DotAdoptedIdentitySigner: DotIdentitySigning {
    let identity: IrxIdentity

    var publicKey: Data { identity.publicKeyData }

    func sign(_ message: Data) async throws -> Data {
        try identity.sign(message)
    }
}

/// The control stream as a `CmxByteTransport` (IrxControlByteTransport
/// lineage): raw passthrough of the app's MobileSyncFrameCodec frames.
/// Releasing this transport closes the control STREAM only, never the
/// session — terminal, artifact, and event lanes ride the same session and
/// the peer engine stays the single owner of session lifetime.
private actor DotControlByteTransport: CmxByteTransport {
    typealias Establish = @Sendable () async throws -> any DotStream

    private let establish: Establish
    private var stream: (any DotStream)?
    private var connectInFlight: Task<any DotStream, any Error>?

    init(establish: @escaping Establish) {
        self.establish = establish
    }

    func connect() async throws {
        _ = try await establishedStream()
    }

    func receive() async throws -> Data? {
        try await establishedStream().read()
    }

    func send(_ data: Data) async throws {
        try await establishedStream().write(data)
    }

    func close() async {
        guard let stream else { return }
        self.stream = nil
        await stream.close()
    }

    private func establishedStream() async throws -> any DotStream {
        if let stream { return stream }
        if let connectInFlight {
            return try await connectInFlight.value
        }
        let task = Task<any DotStream, any Error> {
            try await self.establish()
        }
        connectInFlight = task
        defer { connectInFlight = nil }
        let established = try await task.value
        stream = established
        return established
    }
}

/// Rebounds `DotStream.read()` chunks to callers that read with an explicit
/// byte bound (the legacy receive-stream seam), carrying leftovers across
/// reads so no byte is dropped or duplicated.
private actor DotBoundedStreamReader {
    private let stream: any DotStream
    private var pending = Data()

    init(stream: any DotStream) {
        self.stream = stream
    }

    func read(maximumByteCount: Int) async throws -> Data? {
        guard maximumByteCount > 0 else { return Data() }
        while pending.isEmpty {
            guard let chunk = try await stream.read() else { return nil }
            pending = chunk
        }
        let take = min(maximumByteCount, pending.count)
        let out = Data(pending.prefix(take))
        pending.removeFirst(take)
        return out
    }

    func close() async {
        await stream.close()
    }
}

private struct DotReceiveStreamAdapter: CmxIrohReceiveStream {
    let reader: DotBoundedStreamReader

    func receive(maximumByteCount: Int) async throws -> Data? {
        try await reader.read(maximumByteCount: maximumByteCount)
    }

    func stop(errorCode: UInt64) async {
        await reader.close()
    }
}

private struct DotSendStreamAdapter: CmxIrohSendStream {
    let stream: any DotStream

    func send(_ data: Data) async throws {
        try await stream.write(data)
    }

    func finish() async throws {
        await stream.closeWrite()
    }

    func reset(errorCode: UInt64) async {
        await stream.close()
    }

    func setPriority(_ priority: Int32) async throws {
        // No per-stream priority over the relay mux.
    }
}

/// Artifact lane over dot: bounded reads down, no upstream bytes.
private struct DotArtifactLane: MobileArtifactLaneConnection {
    let reader: DotBoundedStreamReader

    func receive(maximumByteCount: Int) async throws -> Data? {
        try await reader.read(maximumByteCount: maximumByteCount)
    }

    func close() async {
        await reader.close()
    }
}
