#if DEBUG
import CmuxAuthRuntime
import CmuxNextTransport
import Foundation
import IrohLib
import Observation
import OSLog

private let nextTransportLog = Logger(
    subsystem: "dev.cmux.ios",
    category: "next-transport-dial"
)

/// Graduation P4 slice 3: the iOS dev dial path for the parallel
/// next-transport host (manaflow-ai/cmux#10629). DEBUG-only; nothing here
/// touches the shipping CmuxIrohTransport paths.
///
/// Owns the full client stack the lab proved on this exact phone:
/// keychain-stable identity, a single ReconnectOwner (the only component
/// that ever dials), self-minted staging relay credentials applied
/// zero-gap, and ctl-lane credential pushes surfaced through the owner.
/// Input: the Mac's ticket + grant, exactly as the Mac's debug socket
/// verbs (next_transport_ticket / next_transport_grant) emit them.
@MainActor
@Observable
public final class NextTransportDialClient {
    public private(set) var state = "idle"
    public private(set) var sessionID: String?
    public private(set) var events: [String] = []
    public private(set) var echoVerdict: String?

    private let identity: PeerIdentity
    private var endpoint: Endpoint?
    private var owner: ReconnectOwner?
    private var appliedRelayToken: String?
    private var pendingRelay: (url: String, token: String)?

    private var hostKey: Data?
    private var hostAddrs: [String] = []
    private var hostRelayURL: String?
    private var grant: PairingGrant?
    private var broker: BrokerCredentialClient?
    /// Holds only a weak reference to the client, so the loop ends on its
    /// own at the tick after the client is released (no deinit needed; a
    /// MainActor deinit cannot touch isolated state under Swift 6).
    private var renewTask: Task<Void, Never>?

    /// The app-session credential source, installed once at composition boot
    /// (`MobileIrohRuntimeComposition.configure`). A home-screen launch has
    /// no dev env, so this is how a real phone mints relay credentials for
    /// its next-transport identity: the same signed-in Stack session and the
    /// same broker origin the legacy transport uses. Env credentials keep
    /// precedence for dev launches.
    private static var sessionBrokerFactory:
        (@MainActor (PeerIdentity) -> BrokerCredentialClient)?

    public init() {
        identity = Self.loadOrCreateIdentity()
        broker = Self.brokerClient(identity: identity)
        log("identity \(identity.deviceID.prefix(8))…, env broker \(broker == nil ? "absent" : "ready")")
    }

    /// Registers the signed-in session as a relay-credential source for
    /// every dial client. Mirrors the legacy transport's broker auth: the
    /// CURRENT session token pair per request, never a captured password.
    public static func installSessionBroker(
        brokerBaseURL: URL?, auth: AuthCoordinator
    ) {
        guard let brokerBaseURL else { return }
        let tokens: @Sendable () async throws
            -> BrokerCredentialClient.SessionTokens? = { [weak auth] in
                guard let auth else { return nil }
                do {
                    let session = try await auth.authenticatedSessionSnapshot()
                    return BrokerCredentialClient.SessionTokens(
                        accessToken: session.accessToken,
                        refreshToken: session.refreshToken)
                } catch AuthError.unauthorized {
                    // Definitively signed out: fail closed (LAN-only).
                    return nil
                }
                // Every other failure (token store owned by a session
                // transition, refresh in flight) rethrows: transient, the
                // next mint retries with a live pair.
            }
        sessionBrokerFactory = { identity in
            BrokerCredentialClient(
                sessionConfig: BrokerCredentialClient.SessionConfig(
                    baseUrl: brokerBaseURL.absoluteString,
                    deviceId: identity.deviceID,
                    appInstanceId: identity.deviceID,
                    tag: "next-transport-ios", platform: "ios"),
                tokens: tokens,
                identity: identity)
        }
    }

    public var devicePublicKeyB64: String { identity.publicKeyData.base64EncodedString() }
    public var deviceID: String { identity.deviceID }

    /// Paste targets for the two socket-verb outputs.
    public func configure(ticketJSON: String, grantJSON: String) {
        guard let ticketData = ticketJSON.data(using: .utf8),
            let ticket = (try? JSONDecoder().decode(JSONValue.self, from: ticketData))?
                .objectValue,
            let key = ticket["key"]?.dataValue,
            let addrs = ticket["addrs"]?.arrayValue?.compactMap(\.stringValue)
        else {
            log("ticket: could not parse")
            return
        }
        hostKey = key
        hostAddrs = addrs
        hostRelayURL = ticket["relay"]?.stringValue
        guard let grantData = grantJSON.data(using: .utf8),
            let value = try? JSONDecoder().decode(JSONValue.self, from: grantData),
            let parsed = PairingGrant(payloadValue: value.objectValue?["grant"] ?? value)
        else {
            log("grant: could not parse")
            return
        }
        if parsed.devicePublicKey != identity.publicKeyData {
            log("grant: minted for a DIFFERENT device key")
        }
        grant = parsed
        log("configured: host \(key.base64EncodedString().prefix(12))…, relay \(hostRelayURL ?? "none")")
    }

    public func connect() async {
        guard hostKey != nil, grant != nil else {
            log("connect: configure ticket + grant first")
            return
        }
        if owner == nil { await bootOwner() }
        await owner?.trigger(.explicit(trigger: "dev-connect"))
    }

    public func disconnect() async {
        await owner?.stop(reason: .userRequested)
    }

    /// The live admitted connection, for the graduation facade to open
    /// bridged application lanes on. nil until the owner reports ready.
    public func admittedConnection() async -> IrohPeerConnection? {
        guard state == "ready" else { return nil }
        return await owner?.currentConnection as? IrohPeerConnection
    }

    /// The lab's proof traffic: 50 checksummed chunks over the echo lane.
    public func runEcho() async {
        guard let connection = await owner?.currentConnection, state == "ready" else {
            echoVerdict = "not connected"
            return
        }
        let echo = await connection.lane(TransportHost.echoLaneName)
        var validator = TrafficValidator()
        do {
            for seq in Int64(0)..<50 {
                try await echo.send(TerminalTraffic.chunk(seq: seq, size: 1_024, seed: 77))
                if let reply = await echo.receive() { validator.ingest(reply) }
            }
        } catch {
            echoVerdict = "echo failed: \(error)"
            return
        }
        echoVerdict = validator.isClean
            ? "CLEAN: \(validator.received)/50 ordered, checksums OK"
            : "DIRTY: \(validator.received) received"
        log("echo: \(echoVerdict ?? "")")
    }

    private func bootOwner() async {
        if endpoint == nil {
            // Env broker (dev launches) keeps precedence; a home-screen
            // launch falls back to the app's signed-in session.
            if broker == nil, let factory = Self.sessionBrokerFactory {
                broker = factory(identity)
                log("session-backed broker ready")
            }
            // Credentials BEFORE the endpoint exists, so the relay is in the
            // initial relay map. Relay is additive: a mint failure (offline
            // API, signed out) still boots a direct-only endpoint that can
            // dial the ticket's LAN addresses, and the renew loop upgrades
            // it in place once minting succeeds.
            var relays: [IrohSubstrate.RelayAccess] = []
            if let broker {
                let mintStart = ContinuousClock.now
                do {
                    let credentials = try await broker.mint(preferredUrl: hostRelayURL)
                    relays = credentials.map {
                        IrohSubstrate.RelayAccess(url: $0.relayUrl, authToken: $0.token)
                    }
                    appliedRelayToken = credentials.first?.token
                    let expiry = credentials.first.flatMap {
                        IrohSubstrate.tokenExpiry($0.token)
                    }
                    log(
                        """
                        self-minted \(credentials.count) relay credentials in \
                        \(nextTransportElapsedMs(since: mintStart))ms \
                        (first \(credentials.first?.relayUrl ?? "none"), \
                        tokenExp \(expiry.map(String.init) ?? "unparsed"))
                        """)
                } catch {
                    log(
                        """
                        relay mint failed after \(nextTransportElapsedMs(since: mintStart))ms; \
                        continuing LAN-only: \(error)
                        """)
                }
            }
            do {
                endpoint = try await (relays.isEmpty
                    ? IrohSubstrate.endpoint(identity: identity, minimalLoopback: false)
                    : IrohSubstrate.endpoint(identity: identity, relays: relays))
            } catch {
                log("endpoint: \(error)")
                return
            }
            startCredentialRenewal()
        }
        guard let endpoint else { return }
        let identity = identity
        let dial: @Sendable () async throws -> ConnectAttemptResult = { [weak self] in
            guard let self else { throw TransportError.pipeClosed }
            let dialStart = ContinuousClock.now
            let (key, addrs, relayURL, grant) = await self.dialInputs()
            guard let key, let grant else {
                await self.log("dial aborted: ticket/grant no longer configured")
                throw TransportError.pipeClosed
            }
            await self.rotateRelayCredentialIfStale()
            let addr = EndpointAddr(
                id: try EndpointId.fromBytes(bytes: key), relayUrl: relayURL, addresses: addrs)
            await self.log("dialing via \(addrs.joined(separator: ", ")) relay \(relayURL ?? "none")")
            return try await withThrowingTaskGroup(of: ConnectAttemptResult.self) { group in
                group.addTask {
                    let conn = try await IrohSubstrate.dial(endpoint: endpoint, to: addr)
                    switch try await TransportClient.connect(
                        connection: conn, identity: identity, grant: grant)
                    {
                    case .admitted(let sessionID):
                        await self.log(
                            "admitted as \(sessionID) in \(nextTransportElapsedMs(since: dialStart))ms")
                        return .admitted(conn, sessionID: sessionID)
                    case .denied(let code):
                        await self.log(
                            "denied: \(code.rawValue) after \(nextTransportElapsedMs(since: dialStart))ms")
                        return .denied(code)
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(15))
                    await self.log(
                        "dial TIMEOUT after \(nextTransportElapsedMs(since: dialStart))ms")
                    throw TransportError.dialTimeout
                }
                guard let first = try await group.next() else { throw TransportError.dialTimeout }
                group.cancelAll()
                return first
            }
        }
        let owner = ReconnectOwner(connectOnce: dial) { [weak self] frame in
            guard frame.type == FrameTypes.relayCredential,
                let url = frame.payload["url"]?.stringValue,
                let token = frame.payload["token"]?.stringValue
            else { return }
            await self?.storePushedCredential(url: url, token: token)
        }
        self.owner = owner
        await owner.endpointReady(true)
        Task { [weak self] in
            for await state in await owner.states() {
                await MainActor.run {
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.state = "ready"
                        self.sessionID = nil
                    case .connecting: self.state = "connecting"
                    case .idle: self.state = "idle"
                    case .degraded: self.state = "degraded"
                    case .closed(let reason): self.state = "closed (\(reason.code))"
                    }
                    self.log("state: \(self.state)")
                }
            }
        }
        log("reconnect owner up")
    }

    private func dialInputs() -> (Data?, [String], String?, PairingGrant?) {
        (hostKey, hostAddrs, hostRelayURL, grant)
    }

    private func storePushedCredential(url: String, token: String) async {
        guard IrohSubstrate.tokenEndpointId(token) == identity.publicKeyData else {
            log("pushed credential bound to a DIFFERENT device; ignoring")
            return
        }
        pendingRelay = (url, token)
        log("relay credential received; applies on next dial")
    }

    private func rotateRelayCredentialIfStale() async {
        guard let pending = pendingRelay, pending.token != appliedRelayToken,
            let endpoint
        else { return }
        do {
            try await endpoint.insertRelay(
                config: RelayConfig(url: pending.url, authToken: pending.token))
            appliedRelayToken = pending.token
            log("relay credential rotated in, zero-gap")
        } catch {
            log("credential rotation failed: \(error)")
        }
    }

    /// Self-minted rotation on the token's own cadence (refreshAfter = 60s
    /// before the 300s expiry), mirroring the host runtime's renew loop:
    /// insert-alone handoff (never removeRelay first), so live sessions ride
    /// the fresh credential zero-gap. Also heals a LAN-only boot: once the
    /// web API is reachable and the session signed in, the first successful
    /// mint inserts the relay into the running endpoint.
    private func startCredentialRenewal() {
        guard renewTask == nil, broker != nil else { return }
        renewTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(240))
                guard let self, !Task.isCancelled else { return }
                await self.renewSelfMintedCredentials()
            }
        }
    }

    private func renewSelfMintedCredentials() async {
        guard let broker, let endpoint else { return }
        let renewStart = ContinuousClock.now
        do {
            let fresh = try await broker.mint(preferredUrl: hostRelayURL)
            for credential in fresh {
                try await endpoint.insertRelay(
                    config: RelayConfig(url: credential.relayUrl, authToken: credential.token))
            }
            appliedRelayToken = fresh.first?.token ?? appliedRelayToken
            let expiry = fresh.first.flatMap { IrohSubstrate.tokenExpiry($0.token) }
            log(
                """
                self-minted relay credentials rotated zero-gap (\(fresh.count) relays, \
                tokenExp \(expiry.map(String.init) ?? "unparsed"), \
                \(nextTransportElapsedMs(since: renewStart))ms)
                """)
        } catch {
            log(
                """
                credential renewal failed after \
                \(nextTransportElapsedMs(since: renewStart))ms: \(error)
                """)
        }
    }

    private func log(_ message: String) {
        nextTransportLog.notice("\(message, privacy: .public)")
        events.append(message)
        if events.count > 200 { events.removeFirst(events.count - 200) }
    }

    private static func loadOrCreateIdentity() -> PeerIdentity {
        let defaults = UserDefaults.standard
        let keyKey = "dev.cmux.nextTransport.ios.identity.key"
        let idKey = "dev.cmux.nextTransport.ios.identity.deviceID"
        if let keyB64 = defaults.string(forKey: keyKey),
            let key = Data(base64Encoded: keyB64),
            let deviceID = defaults.string(forKey: idKey)
        {
            return PeerIdentity(
                appIdentity: "dev.cmux.next.ios", deviceID: deviceID, privateKeyData: key)
        }
        let fresh = PeerIdentity.generate(
            appIdentity: "dev.cmux.next.ios", deviceID: UUID().uuidString.lowercased())
        defaults.set(fresh.privateKeyData.base64EncodedString(), forKey: keyKey)
        defaults.set(fresh.deviceID, forKey: idKey)
        return fresh
    }

    /// Staging broker credentials from the dev launch env (mobile-dev-launch
    /// exports the dogfood pair into the app's environment on dev installs).
    private static func brokerClient(identity: PeerIdentity) -> BrokerCredentialClient? {
        let env = ProcessInfo.processInfo.environment
        guard
            let email = env["CMUX_DOGFOOD_STACK_EMAIL"],
            let password = env["CMUX_DOGFOOD_STACK_PASSWORD"]
        else { return nil }
        return BrokerCredentialClient(
            config: BrokerCredentialClient.Config(
                baseUrl: "https://cmux-staging.vercel.app",
                stackBase: "https://api.stack-auth.com",
                stackProjectId: "454ecd03-1db2-4050-845e-4ce5b0cd9895",
                stackPck: "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g",
                email: email, password: password,
                deviceId: identity.deviceID, appInstanceId: identity.deviceID,
                tag: "next-transport-ios", platform: "ios"),
            identity: identity)
    }
}
#endif
