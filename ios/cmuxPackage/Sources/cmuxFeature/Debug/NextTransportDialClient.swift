#if DEBUG
import CmuxAuthRuntime
import CmuxNextTransport
import Foundation
import IrohLib
import Observation
import OSLog
import Security

private let nextTransportLog = Logger(
    subsystem: "dev.cmux.ios",
    category: "next-transport-dial"
)

/// Typed session state for the dial surface. `state` (the display string)
/// is derived from this; the facade's fallback decisions consume the typed
/// value, never the string.
public enum NextTransportDialState: Equatable, Sendable {
    case idle
    case connecting
    case ready
    case degraded
    /// Session ended. `denial` is non-nil exactly when the close code was a
    /// real admission denial (`DenialCode`), nil for transport-level ends
    /// (timeouts, network loss, local closes).
    case closed(code: String, denial: DenialCode?)

    /// Short display string for the dev screen and log lines.
    public var displayDescription: String {
        switch self {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .ready: return "ready"
        case .degraded: return "degraded"
        case .closed(let code, _): return "closed (\(code))"
        }
    }
}

/// Typed rejection from `configure(ticketJSON:grantJSON:)`. The call is
/// atomic: when any of these is thrown, NO state was committed — the
/// previous ticket/grant (if any) remain in effect.
public enum NextTransportConfigureError: Error, Equatable {
    case malformedTicket
    case malformedGrant
    /// Grant minted for a different device key than this phone's identity.
    case grantKeyMismatch
    /// Grant minted for a different durable device ID.
    case grantDeviceIDMismatch
    /// Grant minted for a different app identity.
    case grantAppMismatch
}

/// Short stable code for one error, safe for `events`/UI surfaces. The full
/// error text goes to os.log only (raw descriptions can carry URLs, peer
/// addresses, or token fragments).
func nextTransportShortErrorCode(_ error: any Error) -> String {
    switch error {
    case is CancellationError:
        return "cancelled"
    case let transport as TransportError:
        switch transport {
        case .pipeClosed: return "pipe-closed"
        case .connectionClosedBeforeReply: return "closed-before-reply"
        case .unexpectedFrame: return "unexpected-frame"
        case .dialTimeout: return "dial-timeout"
        }
    case let broker as BrokerCredentialClient.BrokerError:
        switch broker {
        case .http(let step, let status, _, _): return "broker-http-\(step)-\(status)"
        case .malformedURL: return "broker-url"
        case .shape: return "broker-shape"
        case .notSignedIn: return "not-signed-in"
        }
    case let configure as NextTransportConfigureError:
        switch configure {
        case .malformedTicket: return "malformed-ticket"
        case .malformedGrant: return "malformed-grant"
        case .grantKeyMismatch: return "grant-key-mismatch"
        case .grantDeviceIDMismatch: return "grant-device-id-mismatch"
        case .grantAppMismatch: return "grant-app-mismatch"
        }
    case let url as URLError:
        return "url-\(url.code.rawValue)"
    default:
        return String(describing: type(of: error))
    }
}

/// Graduation P4 slice 3: the iOS dev dial path for the parallel
/// next-transport host (manaflow-ai/cmux#10629). DEBUG-only; nothing here
/// touches the shipping CmuxIrohTransport paths.
///
/// Owns the full client stack the lab proved on this exact phone:
/// Keychain-stable identity, a single ReconnectOwner (the only component
/// that ever dials), self-minted staging relay credentials applied
/// zero-gap, and ctl-lane credential pushes applied to the live endpoint
/// the moment they arrive. Input: the Mac's ticket + grant, exactly as the
/// Mac's debug socket verbs (next_transport_ticket / next_transport_grant)
/// emit them, or the facade's bootstrap pair RPC.
@MainActor
@Observable
public final class NextTransportDialClient {
    /// Typed session state; `state` is its display string.
    public private(set) var dialState: NextTransportDialState = .idle
    /// Display string derived from `dialState`, for the dev screen.
    public var state: String { dialState.displayDescription }
    /// The most recent real admission denial, if any. The facade reads this
    /// to decide whether the persisted bootstrap is still trustworthy.
    public private(set) var lastDenial: DenialCode?
    public private(set) var sessionID: String?
    public private(set) var events: [String] = []
    public private(set) var echoVerdict: String?

    /// Fresh dial hints (ticket + grant JSON) fetched between attempts, so a
    /// reconnect never reuses a stale address list when a better one is
    /// available. `fresh` is true when the pair was re-minted over a live
    /// legacy channel, false when it was re-read from persistence.
    public typealias HintRefresh =
        @Sendable () async -> (ticketJSON: String, grantJSON: String, fresh: Bool)?
    /// Installed by the graduation facade; nil for the paste-driven dev
    /// screen flow (which keeps its configured ticket).
    @ObservationIgnored public var hintRefresher: HintRefresh?

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
    /// Credentials from the most recent successful mint; their `expiresAt`
    /// claims drive the renewal schedule.
    private var mintedCredentials: [BrokerCredentialClient.Credential] = []
    /// Dial attempts since the last explicit configure, so reconnects (not
    /// first dials) refresh hints and prefer the relay path.
    private var dialAttemptIndex = 0
    /// A relay-only attempt that failed steers the next attempt back to the
    /// full address list.
    private var relayOnlyAttemptFailed = false
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
        // A credential pushed on a previous run seeds the relay map as soon
        // as the endpoint boots.
        pendingRelay = Self.persistedPushedCredential()
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
            var environment = NextTransportEnvironment.staging
            environment.brokerBaseURL = brokerBaseURL
            return BrokerCredentialClient(
                environment: environment,
                identity: identity,
                auth: .session(tokens: tokens),
                tag: "next-transport-ios",
                platform: "ios")
        }
    }

    public var devicePublicKeyB64: String { identity.publicKeyData.base64EncodedString() }
    public var deviceID: String { identity.deviceID }

    /// True when a ticket + grant pair has been committed.
    public var isConfigured: Bool { hostKey != nil && grant != nil }
    /// The committed host key, for tests asserting configure atomicity.
    public var configuredHostKeyB64: String? { hostKey?.base64EncodedString() }

    /// Paste targets for the two socket-verb outputs. Atomic: the ticket AND
    /// the grant are fully parsed and validated against this phone's
    /// identity before anything is committed; on a typed rejection the
    /// previously committed pair (if any) stays in effect.
    public func configure(ticketJSON: String, grantJSON: String) throws {
        let parsed: ParsedConfiguration
        do {
            parsed = try Self.parseConfiguration(
                ticketJSON: ticketJSON, grantJSON: grantJSON, identity: identity)
        } catch let error as NextTransportConfigureError {
            log("configure rejected", error: error)
            throw error
        }
        commit(parsed)
        log(
            "configured: host \(parsed.hostKey.base64EncodedString().prefix(12))…, relay \(parsed.relayURL ?? "none")")
    }

    /// One fully parsed and validated ticket + grant pair.
    private struct ParsedConfiguration {
        var hostKey: Data
        var addrs: [String]
        var relayURL: String?
        var grant: PairingGrant
    }

    private static func parseConfiguration(
        ticketJSON: String, grantJSON: String, identity: PeerIdentity
    ) throws -> ParsedConfiguration {
        guard let ticketData = ticketJSON.data(using: .utf8),
            let ticket = (try? JSONDecoder().decode(JSONValue.self, from: ticketData))?
                .objectValue,
            let key = ticket["key"]?.dataValue,
            let addrs = ticket["addrs"]?.arrayValue?.compactMap(\.stringValue)
        else {
            throw NextTransportConfigureError.malformedTicket
        }
        guard let grantData = grantJSON.data(using: .utf8),
            let value = try? JSONDecoder().decode(JSONValue.self, from: grantData),
            let parsed = PairingGrant(payloadValue: value.objectValue?["grant"] ?? value)
        else {
            throw NextTransportConfigureError.malformedGrant
        }
        guard parsed.devicePublicKey == identity.publicKeyData else {
            throw NextTransportConfigureError.grantKeyMismatch
        }
        guard parsed.deviceID == identity.deviceID else {
            throw NextTransportConfigureError.grantDeviceIDMismatch
        }
        guard parsed.appIdentity == identity.appIdentity else {
            throw NextTransportConfigureError.grantAppMismatch
        }
        return ParsedConfiguration(
            hostKey: key, addrs: addrs,
            relayURL: ticket["relay"]?.stringValue, grant: parsed)
    }

    private func commit(_ parsed: ParsedConfiguration) {
        hostKey = parsed.hostKey
        hostAddrs = parsed.addrs
        hostRelayURL = parsed.relayURL
        grant = parsed.grant
        dialAttemptIndex = 0
        relayOnlyAttemptFailed = false
    }

    public func connect() async {
        guard isConfigured else {
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
        guard case .ready = dialState else { return nil }
        return await owner?.currentConnection as? IrohPeerConnection
    }

    /// The lab's proof traffic: 50 checksummed chunks over the echo lane.
    public func runEcho() async {
        guard case .ready = dialState, let connection = await owner?.currentConnection
        else {
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
            echoVerdict = "echo failed (\(nextTransportShortErrorCode(error)))"
            log("echo failed", error: error)
            return
        }
        echoVerdict = validator.isClean
            ? "CLEAN: \(validator.received)/50 ordered, checksums OK"
            : "DIRTY: \(validator.received) received"
        log("echo: \(echoVerdict ?? "")")
    }

    /// Every dial attempt must complete or fail within this bound; UDP
    /// blackholes produce silence, and the deadline turns silence into a
    /// retryable failure on the owner's normal backoff path.
    static let dialAttemptTimeout: Duration = .seconds(6)

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
                    mintedCredentials = credentials
                    relays = credentials.map {
                        IrohSubstrate.RelayAccess(url: $0.relayUrl, authToken: $0.token)
                    }
                    appliedRelayToken = credentials.first?.token
                    let expiry = credentials.first?.expiresAt
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
                        continuing LAN-only
                        """, error: error)
                }
            }
            do {
                endpoint = try await (relays.isEmpty
                    ? IrohSubstrate.endpoint(identity: identity, minimalLoopback: false)
                    : IrohSubstrate.endpoint(identity: identity, relays: relays))
            } catch {
                log("endpoint boot failed", error: error)
                return
            }
            startCredentialRenewal()
            // A credential pushed on a previous run (or before the endpoint
            // existed) applies now, not on some future dial.
            await applyPendingRelayCredential()
        }
        guard let endpoint else { return }
        let identity = identity
        let dial: @Sendable () async throws -> ConnectAttemptResult = { [weak self] in
            guard let self else { throw TransportError.pipeClosed }
            let dialStart = ContinuousClock.now
            let relayOnly = await self.beginAttempt()
            let (key, addrs, relayURL, grant) = await self.dialInputs()
            guard let key, let grant else {
                await self.log("dial aborted: ticket/grant no longer configured")
                throw TransportError.pipeClosed
            }
            // Relay-first on reconnects: the relay path is reachable before
            // hole punching completes, so a reconnect prefers it and lets
            // iroh upgrade to a direct path afterwards.
            let dialAddrs = relayOnly ? [] : addrs
            let addr = EndpointAddr(
                id: try EndpointId.fromBytes(bytes: key), relayUrl: relayURL,
                addresses: dialAddrs)
            await self.log(
                relayOnly
                    ? "dialing relay-first via \(relayURL ?? "none")"
                    : "dialing via \(dialAddrs.joined(separator: ", ")) relay \(relayURL ?? "none")")
            do {
                let result = try await withThrowingTaskGroup(
                    of: ConnectAttemptResult.self
                ) { group in
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
                        // Structured timeout race: the losing dial leg is
                        // cancelled below and unwinds through the owner's
                        // normal failure path.
                        try await Task.sleep(for: Self.dialAttemptTimeout)
                        await self.log(
                            "dial TIMEOUT after \(nextTransportElapsedMs(since: dialStart))ms")
                        throw TransportError.dialTimeout
                    }
                    guard let first = try await group.next() else {
                        throw TransportError.dialTimeout
                    }
                    group.cancelAll()
                    return first
                }
                await self.noteAttemptEnded(failed: false, relayOnly: relayOnly)
                return result
            } catch {
                await self.noteAttemptEnded(failed: true, relayOnly: relayOnly)
                throw error
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
                        self.dialState = .ready
                        self.sessionID = nil
                    case .connecting: self.dialState = .connecting
                    case .idle: self.dialState = .idle
                    case .degraded: self.dialState = .degraded
                    case .closed(let reason):
                        let denial = DenialCode(rawValue: reason.code)
                        self.dialState = .closed(code: reason.code, denial: denial)
                        if let denial { self.lastDenial = denial }
                    }
                    self.log("state: \(self.state)")
                }
            }
        }
        log("reconnect owner up")
    }

    /// Starts one dial attempt: refreshes hints between attempts (never on
    /// the first after configure) and reports whether this attempt should
    /// prefer the relay path. Returns true for a relay-only attempt.
    private func beginAttempt() async -> Bool {
        let attempt = dialAttemptIndex
        dialAttemptIndex += 1
        if attempt > 0 { await refreshHints() }
        return attempt > 0 && hostRelayURL != nil && appliedRelayToken != nil
            && !relayOnlyAttemptFailed
    }

    /// Between attempts, never reuse a stale address list: the facade's
    /// refresher re-mints the pair over the legacy channel when it is
    /// reachable, or re-reads the persisted bootstrap otherwise.
    private func refreshHints() async {
        guard let refresher = hintRefresher else { return }
        guard let hints = await refresher() else {
            log("hint refresh unavailable; reusing stored addrs (may be stale)")
            return
        }
        do {
            let parsed = try Self.parseConfiguration(
                ticketJSON: hints.ticketJSON, grantJSON: hints.grantJSON,
                identity: identity)
            let attempt = dialAttemptIndex
            commit(parsed)
            dialAttemptIndex = attempt  // still a reconnect, not a first dial
            log(
                hints.fresh
                    ? "dial hints re-minted over legacy"
                    : "dial hints re-read from persisted bootstrap (may be stale)")
        } catch {
            log("hint refresh produced an invalid pair; keeping previous", error: error)
        }
    }

    private func noteAttemptEnded(failed: Bool, relayOnly: Bool) {
        if relayOnly {
            // A failed relay-only attempt steers the next one back to the
            // full address list; a success re-arms the preference.
            relayOnlyAttemptFailed = failed
        } else if !failed {
            relayOnlyAttemptFailed = false
        }
    }

    private func dialInputs() -> (Data?, [String], String?, PairingGrant?) {
        (hostKey, hostAddrs, hostRelayURL, grant)
    }

    private static let pushedRelayDefaultsKey =
        "dev.cmux.nextTransport.ios.pushedRelayCredential"

    /// A ctl-lane `opt.relay-credential` push applies IMMEDIATELY to the
    /// live endpoint (make-before-break) and persists, so neither a quiet
    /// session nor a relaunch waits for the next dial to use it.
    private func storePushedCredential(url: String, token: String) async {
        guard IrohSubstrate.tokenEndpointId(token) == identity.publicKeyData else {
            log("pushed credential bound to a DIFFERENT device; ignoring")
            return
        }
        pendingRelay = (url, token)
        UserDefaults.standard.set(
            ["url": url, "token": token], forKey: Self.pushedRelayDefaultsKey)
        await applyPendingRelayCredential()
    }

    private func applyPendingRelayCredential() async {
        guard let pending = pendingRelay, pending.token != appliedRelayToken,
            let endpoint
        else { return }
        do {
            // Insert-alone handoff (never removeRelay first), so live
            // sessions ride the fresh credential zero-gap.
            try await endpoint.insertRelay(
                config: RelayConfig(url: pending.url, authToken: pending.token))
            appliedRelayToken = pending.token
            log("relay credential rotated in, zero-gap")
        } catch {
            log("credential rotation failed", error: error)
        }
    }

    private static func persistedPushedCredential() -> (url: String, token: String)? {
        guard
            let stored = UserDefaults.standard.dictionary(
                forKey: pushedRelayDefaultsKey),
            let url = stored["url"] as? String,
            let token = stored["token"] as? String,
            let expiry = IrohSubstrate.tokenExpiry(token),
            expiry > Int64(Date().timeIntervalSince1970)
        else { return nil }
        return (url, token)
    }

    /// Self-minted rotation driven by the credentials' OWN expiries through
    /// `RelayCredentialSchedule` (earliest `expiresAt` minus lead, plus a
    /// small random jitter so a fleet of clients never re-mints in
    /// lockstep), mirroring the host runtime's renew loop: insert-alone
    /// handoff (never removeRelay first), so live sessions ride the fresh
    /// credential zero-gap. Also heals a LAN-only boot: once the web API is
    /// reachable and the session signed in, the first successful mint
    /// inserts the relay into the running endpoint.
    private func startCredentialRenewal() {
        guard renewTask == nil, broker != nil else { return }
        renewTask = Task { [weak self] in
            while !Task.isCancelled {
                // Weak read for the schedule and NO strong self across the
                // sleep, so the loop ends on its own at the tick after the
                // client is released.
                guard let delay = await self?.nextRenewalDelay() else { return }
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return  // cancelled
                }
                guard let self, !Task.isCancelled else { return }
                await self.renewSelfMintedCredentials()
            }
        }
    }

    /// Seconds until the next renewal should fire, from the installed
    /// credentials' expiries (fallback cadence when none carry one).
    private func nextRenewalDelay() -> Int64 {
        let now = Int64(Date().timeIntervalSince1970)
        let jitter = Int64.random(in: 0...30)
        guard
            let target = RelayCredentialSchedule.nextRefresh(
                credentials: mintedCredentials, now: now, jitterSeconds: jitter)
        else {
            // Nothing minted yet (LAN-only boot): retry on the fallback
            // cadence so the first reachable mint heals the relay map.
            return RelayCredentialSchedule.fallbackIntervalSeconds - jitter
        }
        return max(target - now, RelayCredentialSchedule.minimumDelaySeconds)
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
            mintedCredentials = fresh
            appliedRelayToken = fresh.first?.token ?? appliedRelayToken
            let expiry = fresh.first?.expiresAt
            log(
                """
                self-minted relay credentials rotated zero-gap (\(fresh.count) relays, \
                tokenExp \(expiry.map(String.init) ?? "unparsed"), \
                \(nextTransportElapsedMs(since: renewStart))ms)
                """)
        } catch {
            log(
                "credential renewal failed after \(nextTransportElapsedMs(since: renewStart))ms",
                error: error)
        }
    }

    /// Event-log writer. `events` (and everything the dev screen shows)
    /// carries only short stable codes; the raw error text goes to os.log.
    private func log(_ message: String, error: (any Error)? = nil) {
        if let error {
            nextTransportLog.error(
                "\(message, privacy: .public): \(String(describing: error), privacy: .public)")
            events.append("\(message) [\(nextTransportShortErrorCode(error))]")
        } else {
            nextTransportLog.notice("\(message, privacy: .public)")
            events.append(message)
        }
        if events.count > 200 { events.removeFirst(events.count - 200) }
    }

    /// Identity private-key storage: the device-only Keychain (query shape
    /// matches `CmxIrohKeychainIdentityStore`), with a one-time migration
    /// from the UserDefaults slot early dev builds used. Secret material
    /// never returns to defaults; if the Keychain refuses the write the
    /// identity stays ephemeral for this launch.
    private enum IdentityKeychain {
        static let service = "dev.cmux.nextTransport.ios.identity.v1"
        static let account = "identity-private-key"

        static func read() -> Data? {
            var query = baseQuery()
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let data = result as? Data else {
                if status != errSecItemNotFound {
                    nextTransportLog.error(
                        "identity keychain read failed status=\(status, privacy: .public)")
                }
                return nil
            }
            return data
        }

        static func write(_ data: Data) -> Bool {
            let query = baseQuery()
            let update = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary)
            if update == errSecSuccess { return true }
            guard update == errSecItemNotFound else {
                nextTransportLog.error(
                    "identity keychain update failed status=\(update, privacy: .public)")
                return false
            }
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let add = SecItemAdd(insert as CFDictionary, nil)
            guard add == errSecSuccess else {
                nextTransportLog.error(
                    "identity keychain add failed status=\(add, privacy: .public)")
                return false
            }
            return true
        }

        private static func baseQuery() -> [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: false,
                kSecUseDataProtectionKeychain as String: true,
            ]
        }
    }

    private static func loadOrCreateIdentity() -> PeerIdentity {
        let defaults = UserDefaults.standard
        let legacyKeyKey = "dev.cmux.nextTransport.ios.identity.key"
        let idKey = "dev.cmux.nextTransport.ios.identity.deviceID"
        let deviceID: String
        if let stored = defaults.string(forKey: idKey) {
            deviceID = stored
        } else {
            deviceID = UUID().uuidString.lowercased()
            defaults.set(deviceID, forKey: idKey)
        }
        if let key = IdentityKeychain.read() {
            return PeerIdentity(
                appIdentity: "dev.cmux.next.ios", deviceID: deviceID, privateKeyData: key)
        }
        // One-time migration: early dev builds kept the private key in
        // UserDefaults. Move it into the Keychain and clear the old slot
        // only once the Keychain write stuck.
        if let keyB64 = defaults.string(forKey: legacyKeyKey),
            let key = Data(base64Encoded: keyB64)
        {
            if IdentityKeychain.write(key) {
                defaults.removeObject(forKey: legacyKeyKey)
                nextTransportLog.notice("identity key migrated defaults -> keychain")
            }
            return PeerIdentity(
                appIdentity: "dev.cmux.next.ios", deviceID: deviceID, privateKeyData: key)
        }
        let fresh = PeerIdentity.generate(
            appIdentity: "dev.cmux.next.ios", deviceID: deviceID)
        if !IdentityKeychain.write(fresh.privateKeyData) {
            nextTransportLog.error(
                "identity keychain write failed; identity is ephemeral this launch")
        }
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
            environment: .staging,
            identity: identity,
            auth: .password(email: email, password: password),
            tag: "next-transport-ios",
            platform: "ios")
    }
}
#endif
