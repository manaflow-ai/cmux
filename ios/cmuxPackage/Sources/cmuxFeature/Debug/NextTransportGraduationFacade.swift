#if DEBUG
import CMUXMobileCore
import CmuxIrohTransport
import CmuxMobileRPC
import CmuxMobileShell
import CmuxNextTransport
import CmuxNextTransportBridge
import Foundation
import OSLog
import Security

nonisolated private let graduationLog = Logger(
    subsystem: "dev.cmux.ios",
    category: "next-transport-graduation"
)

/// Thrown for requests to a next-transport Mac while its session is down:
/// the app fails and reconnects rather than silently degrading to legacy.
struct NextTransportUnavailableError: Error {}

/// Decides whether a dial client's reported session state means this Mac's
/// persisted bootstrap (ticket + grant) is no longer trustworthy. A real
/// admission denial means the credentials themselves are bad (the Mac
/// re-minted its signer, the grant expired or was revoked): the bootstrap
/// must be dropped so the legacy channel can re-credential. Extracted pure
/// so the regression suite can pin the decision table.
struct NextTransportDenialPolicy: Sendable {
    /// The denial codes that prove the CREDENTIALS are bad. The two
    /// protocol-shaped denials (`malformed-hello`, `protocol-mismatch`) are
    /// build or wire bugs, not credential staleness: re-minting the same
    /// grant would change nothing, so they never burn the bootstrap.
    let credentialDenials: Set<DenialCode>

    init(credentialDenials: Set<DenialCode> = [
        .invalidSignature, .expired, .revoked,
        .keyMismatch, .deviceIDMismatch, .appMismatch, .accountMismatch,
    ]) {
        self.credentialDenials = credentialDenials
    }

    /// Whether one typed denial proves a credential denial. Transport-level
    /// failures reach this as nil and never invalidate.
    func shouldInvalidateBootstrap(denial: DenialCode?) -> Bool {
        guard let denial else { return false }
        return credentialDenials.contains(denial)
    }

}

/// Interprets one `mobile.next_transport.pair` probe failure through the
/// RPC layer's TYPED error (`MobileShellConnectionError.rpcError`), never
/// `String(describing:)`: only a server-reported unknown-method code is a
/// capability verdict; everything else is transient.
struct NextTransportProbeErrorClassifier: Sendable {
    let methodNotFoundCodes: Set<String>

    init(methodNotFoundCodes: Set<String> = [
        "method_not_found", "unknown_method", "unsupported_method",
    ]) {
        self.methodNotFoundCodes = methodNotFoundCodes
    }

    func isMethodNotFound(_ error: any Error) -> Bool {
        guard case let MobileShellConnectionError.rpcError(code, message) = error else {
            return false
        }
        return isMethodNotFound(code: code, message: message)
    }

    func isMethodNotFound(code: String?, message: String) -> Bool {
        if let code = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            methodNotFoundCodes.contains(code)
        {
            return true
        }
        let message = message.lowercased()
        return message.contains("method not found") || message.contains("unknown method")
    }
}

/// Graduation lane routing, phone side. Routing is a sticky PER-MAC
/// decision made only by probe verdicts: a next-transport Mac carries all
/// traffic over the bridge and FAILS HARD while reconnecting; legacy
/// remains for Macs that answered method_not_found, for the credentialing
/// handshake, and for a Mac whose grant was DENIED (stale credentials drop
/// the bootstrap and the next healthy legacy connection re-pairs).
///
/// Bootstrap is slice 2: one `mobile.next_transport.pair` RPC over the
/// ALREADY authenticated legacy channel mints this phone's ticket + grant,
/// persisted per Mac. No pastes, no new backend.
@MainActor
final class NextTransportGraduationFacade {
    /// Stable short id correlating one live object across facade log lines.
    nonisolated static func objectID(_ object: AnyObject) -> String {
        String(UInt(bitPattern: ObjectIdentifier(object).hashValue) & 0xFFFF_FFFF, radix: 16)
    }

    /// Elapsed whole milliseconds used by facade diagnostics.
    nonisolated static func elapsedMs(since start: ContinuousClock.Instant) -> Int64 {
        let elapsed = start.duration(to: ContinuousClock.now)
        return Int64(elapsed.components.seconds) * 1_000
            + Int64(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
    static let routeTrafficDefaultsKey = "dev.cmux.nextTransport.ios.routeAppTraffic"
    // v2: v1 tickets carried loopback-rewritten bound sockets that a real
    // phone can never dial; bumping the prefix invalidates them so every
    // Mac re-probes for a LAN-addressed ticket.
    private static let bootstrapKeyPrefix = "dev.cmux.nextTransport.ios.bootstrap.v2."
    private static let bootstrapKeychainService = "dev.cmux.nextTransport.ios.bootstrap.v2"

    private struct Bootstrap: Codable {
        var ticket: String
        var grant: String
    }

    /// Sticky per-Mac routing, decided ONLY by probe verdicts, never by
    /// dial outcomes (capability and reachability are different axes).
    enum MacRouting: String {
        /// Not yet probed, or credentials invalidated: legacy carries
        /// traffic and the next healthy connection re-probes.
        case unknown
        /// Probe succeeded: ALL traffic rides the next transport and fails
        /// hard while it reconnects — no silent legacy fallback.
        case next
        /// The Mac build answered method_not_found: legacy is correct.
        case legacy
    }

    private static let routingKeyPrefix = "dev.cmux.nextTransport.ios.routing.v1."

    private let defaults: UserDefaults
    private let denialPolicy = NextTransportDenialPolicy()
    private let probeErrorClassifier = NextTransportProbeErrorClassifier()
    private var brokerFactory: NextTransportDialClient.BrokerFactory?
    private var clients: [String: NextTransportDialClient] = [:]
    /// Owned startup tasks keep a newly-created client asynchronous without
    /// letting a route request block on a network dial.
    private var clientStartupTasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    /// The most recent healthy legacy RPC client per Mac (weak: the shell
    /// owns its lifetime), so dial-hint refreshes can re-mint the pair over
    /// a live channel between attempts.
    private struct WeakPairClient {
        weak var client: MobileCoreRPCClient?
    }
    private var pairClients: [String: WeakPairClient] = [:]
    private var acceptors: [ObjectIdentifier: BridgeLaneAcceptor] = [:]
    private var acceptorCleanupTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var bootstrapsInFlight: Set<String> = []
    /// Macs with a decided capability verdict this app run. Inconclusive
    /// probes are deliberately removed so the next healthy connection retries.
    private var probedThisRun: Set<String> = []
    /// Consecutive next-transport unavailability observations. A capability
    /// success is sticky while reachable, but a bounded run of timeouts lets
    /// the legacy channel recover and re-probe when a dev host is disabled.
    private var nextTransportFailureCounts: [String: Int] = [:]
    private static let nextTransportFailureThreshold = 3
    /// Probe generations prevent a superseded shell connection from committing
    /// a late bootstrap or routing verdict.
    private var probeGenerations: [String: UUID] = [:]

    init(
        defaults: UserDefaults = .standard,
        brokerFactory: NextTransportDialClient.BrokerFactory? = nil
    ) {
        self.defaults = defaults
        self.brokerFactory = brokerFactory
    }

    /// Installs the app-session broker source on this facade instance. The
    /// closure is owned by the composition root and read by each new dialer.
    func configureSessionBroker(brokerBaseURL: URL?, auth: AuthCoordinator) {
        guard let brokerBaseURL else {
            brokerFactory = nil
            return
        }
        let tokens: @Sendable () async throws
            -> BrokerCredentialClient.SessionTokens? = { [weak auth] in
                guard let auth else { return nil }
                do {
                    let session = try await auth.authenticatedSessionSnapshot()
                    return BrokerCredentialClient.SessionTokens(
                        accessToken: session.accessToken,
                        refreshToken: session.refreshToken)
                } catch AuthError.unauthorized {
                    return nil
                }
            }
        brokerFactory = { identity in
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

    /// Factory exposed to the debug screen so it uses the same injected
    /// session-backed broker as the graduation clients.
    var dialBrokerFactory: NextTransportDialClient.BrokerFactory? { brokerFactory }

    /// Default OFF: the next transport is a dev opt-in, enabled from the
    /// dev screen's toggle. With the defaults key unset (or false) every
    /// gate in this facade answers legacy; support is still negotiated per
    /// Mac once enabled (the pair probe is the capability check).
    var isEnabled: Bool {
        defaults.bool(forKey: Self.routeTrafficDefaultsKey)
    }

    func setEnabled(_ enabled: Bool) {
        graduationLog.notice(
            "facade setEnabled=\(enabled, privacy: .public) (was \(self.isEnabled, privacy: .public))")
        defaults.set(enabled, forKey: Self.routeTrafficDefaultsKey)
    }

    /// True when this Mac has a persisted ticket + grant.
    func hasBootstrap(macDeviceID: String) -> Bool {
        storedBootstrap(macID: macDeviceID) != nil
    }

    /// This Mac's sticky routing decision.
    func routing(macID: String) -> MacRouting {
        guard isEnabled else { return .legacy }
        guard let raw = defaults.string(forKey: Self.routingKeyPrefix + macID),
            let value = MacRouting(rawValue: raw)
        else { return .unknown }
        return value
    }

    private func setRouting(_ value: MacRouting, macID: String) {
        let previous = routing(macID: macID)
        if value == .unknown {
            defaults.removeObject(forKey: Self.routingKeyPrefix + macID)
        } else {
            defaults.set(value.rawValue, forKey: Self.routingKeyPrefix + macID)
        }
        graduationLog.notice(
            """
            routing \(macID, privacy: .public) -> \(value.rawValue, privacy: .public) \
            (was \(previous.rawValue, privacy: .public))
            """)
    }

    /// Lab-shaped access: a synchronous snapshot of the owner's state.
    /// Never blocks, never dials, never returns a closed connection. The
    /// ReconnectOwner inside the dial client is the ONLY reconnect
    /// authority; this method just reads its current truth.
    ///
    /// An admission denial means stale credentials (never a transient): the
    /// bootstrap is dropped and routing returns to unknown so the legacy
    /// control channel can re-credential — its one remaining data job.
    func admittedConnection(
        for request: CmxByteTransportRequest
    ) async -> IrohPeerConnection? {
        guard isEnabled, let macID = request.expectedPeerDeviceID else {
            graduationLog.notice(
                """
                admittedConnection nil: \
                \(self.isEnabled ? "request carries no expected Mac device id" : "kill switch off", privacy: .public)
                """)
            return nil
        }
        let macRouting = routing(macID: macID)
        guard macRouting == .next else {
            graduationLog.notice(
                """
                admittedConnection nil mac=\(String(macID.prefix(8)), privacy: .public): \
                routing=\(macRouting.rawValue, privacy: .public) (not next)
                """)
            return nil
        }
        guard let client = ensureClient(macID: macID) else {
            graduationLog.notice(
                """
                admittedConnection nil mac=\(String(macID.prefix(8)), privacy: .public): \
                no dial client (no stored bootstrap)
                """)
            return nil
        }
        if case .closed(_, let denial) = client.dialState, let denial,
            denialPolicy.shouldInvalidateBootstrap(denial: denial)
        {
            graduationLog.notice(
                "credentials for \(macID, privacy: .public) denied; re-credentialing over legacy")
            invalidateBootstrap(macID: macID, cause: "admission denied (\(denial.rawValue))")
            return nil
        }
        guard let connection = await client.admittedConnection() else {
            await noteNextTransportFailure(macID: macID)
            graduationLog.notice(
                """
                admittedConnection nil mac=\(String(macID.prefix(8)), privacy: .public): \
                owner not ready (state=\(client.state, privacy: .public))
                """)
            return nil
        }
        guard await !connection.isClosed else {
            await noteNextTransportFailure(macID: macID)
            graduationLog.notice(
                """
                admittedConnection nil mac=\(String(macID.prefix(8)), privacy: .public): \
                owner holds a closed corpse conn=\(Self.objectID(connection), privacy: .public)
                """)
            return nil
        }
        nextTransportFailureCounts.removeValue(forKey: macID)
        return connection
    }

    /// Demotes a previously capable Mac after a bounded run of transport
    /// failures. This is a reachability recovery, not a capability verdict:
    /// the bootstrap remains stored and the next healthy legacy connection
    /// issues the authoritative pair probe again.
    private func noteNextTransportFailure(macID: String) async {
        let count = nextTransportFailureCounts[macID, default: 0] + 1
        nextTransportFailureCounts[macID] = count
        guard count >= Self.nextTransportFailureThreshold else { return }
        nextTransportFailureCounts.removeValue(forKey: macID)
        guard routing(macID: macID) == .next else { return }
        setRouting(.unknown, macID: macID)
        probedThisRun.remove(macID)
        let staleClient = clients.removeValue(forKey: macID)
        clientStartupTasks[macID]?.task.cancel()
        clientStartupTasks.removeValue(forKey: macID)
        await staleClient?.disconnect()
        graduationLog.notice(
            "next-transport unavailable (\(Self.nextTransportFailureThreshold, privacy: .public)) times for mac=\(String(macID.prefix(8)), privacy: .public); routing -> unknown for legacy recovery")
    }

    /// True when this request's Mac is a next-transport Mac: traffic MUST
    /// ride the bridge and fail hard while it reconnects.
    func requiresBridge(for request: CmxByteTransportRequest) -> Bool {
        guard isEnabled, let macID = request.expectedPeerDeviceID else { return false }
        return routing(macID: macID) == .next
    }

    /// Which path served one composition request kind (bridged / legacy /
    /// fail-hard throw), logged ONCE per outcome change per (Mac, kind) so
    /// steady-state traffic doesn't repeat itself but every flip is on record.
    private var lastServedPathOutcome: [String: String] = [:]

    func noteServedPath(kind: String, macID: String?, outcome: String) {
        let mac = macID.map { String($0.prefix(8)) } ?? "-"
        let key = "\(mac)|\(kind)"
        let previous = lastServedPathOutcome[key]
        guard previous != outcome else { return }
        lastServedPathOutcome[key] = outcome
        graduationLog.notice(
            """
            served \(kind, privacy: .public) mac=\(mac, privacy: .public) \
            via \(outcome, privacy: .public) (was \(previous ?? "unrecorded", privacy: .public))
            """)
    }

    /// Boots (once) the per-Mac dial client from stored credentials. The
    /// owner autonomously maintains the session from then on.
    @discardableResult
    private func ensureClient(macID: String) -> NextTransportDialClient? {
        if let existing = clients[macID] { return existing }
        guard let bootstrap = storedBootstrap(macID: macID) else {
            graduationLog.notice(
                """
                ensureClient mac=\(String(macID.prefix(8)), privacy: .public): \
                no stored bootstrap; routing falls back to unknown
                """)
            setRouting(.unknown, macID: macID)
            return nil
        }
        let client = NextTransportDialClient(brokerFactory: brokerFactory, defaults: defaults)
        var ticketJSON = bootstrap.ticket
        // Soak rig: with direct addresses stripped, every byte MUST cross
        // the relay — a simulator on the Mac's own machine cannot cheat the
        // non-local test over LAN/loopback.
        if defaults.bool(forKey: "dev.cmux.nextTransport.ios.soak.relayOnly"),
            var object = (try? JSONSerialization.jsonObject(with: Data(ticketJSON.utf8)))
                as? [String: Any]
        {
            object["addrs"] = [String]()
            if let data = try? JSONSerialization.data(withJSONObject: object),
                let stripped = String(data: data, encoding: .utf8)
            {
                ticketJSON = stripped
                graduationLog.notice(
                    "soak relayOnly: direct addrs stripped for mac=\(String(macID.prefix(8)), privacy: .public)")
            }
        }
        do {
            try client.configure(ticketJSON: ticketJSON, grantJSON: bootstrap.grant)
        } catch {
            // A persisted pair this identity can never present (key or
            // device mismatch after a reinstall, or a corrupt record) is as
            // dead as a denial: drop it and let legacy re-credential.
            invalidateBootstrap(
                macID: macID,
                cause: "stored bootstrap rejected (\(NextTransportDialClient.shortErrorCode(error)))")
            return nil
        }
        // Between dial attempts the owner never reuses a stale address
        // list: a live legacy channel re-mints the pair, else the persisted
        // bootstrap is re-read.
        client.hintRefresher = { [weak self] in
            await self?.refreshedBootstrap(macID: macID)
        }
        clients[macID] = client
        graduationLog.notice(
            """
            ensureClient mac=\(String(macID.prefix(8)), privacy: .public): dial client BOOTED \
            from stored bootstrap; owner connect triggered \
            (clients=\(self.clients.count, privacy: .public))
            """)
        if clientStartupTasks[macID] == nil {
            let startupID = UUID()
            let startup = Task { [weak self, weak client] in
                await client?.connect()
                await self?.clientStartupFinished(macID: macID, id: startupID)
            }
            clientStartupTasks[macID] = (id: startupID, task: startup)
        }
        return client
    }

    /// Clears a completed owned client-start task without touching a newer one.
    private func clientStartupFinished(macID: String, id: UUID) {
        guard clientStartupTasks[macID]?.id == id else { return }
        clientStartupTasks.removeValue(forKey: macID)
    }

    private func invalidateBootstrap(macID: String, cause: String) {
        graduationLog.notice(
            """
            bootstrap INVALIDATED mac=\(String(macID.prefix(8)), privacy: .public) \
            cause=\(cause, privacy: .public); dial client discarded, routing -> unknown, \
            legacy will re-credential
            """)
        Self.BootstrapKeychain.delete(
            macID: macID, defaults: defaults, keyPrefix: Self.bootstrapKeyPrefix)
        let client = clients.removeValue(forKey: macID)
        clientStartupTasks[macID]?.task.cancel()
        if let client {
            let disconnectID = UUID()
            let disconnectTask = Task { [weak self] in
                await client.disconnect()
                await self?.clientStartupFinished(macID: macID, id: disconnectID)
            }
            clientStartupTasks[macID] = (id: disconnectID, task: disconnectTask)
        } else {
            clientStartupTasks.removeValue(forKey: macID)
        }
        probedThisRun.remove(macID)
        setRouting(.unknown, macID: macID)
    }

    /// One raw-stream acceptor per connection (single onRawStream owner),
    /// for host-opened server-event streams.
    func acceptor(for connection: IrohPeerConnection) async -> BridgeLaneAcceptor {
        let key = ObjectIdentifier(connection)
        if let existing = acceptors[key] { return existing }
        let fresh = await BridgeLaneAcceptor.attached(to: connection, acceptsServerEvents: true)
        acceptors[key] = fresh
        let cleanup = Task { [weak self] in
            _ = await connection.termination()
            guard !Task.isCancelled else { return }
            await self?.removeAcceptor(key: key, expected: fresh)
        }
        acceptorCleanupTasks[key] = cleanup
        graduationLog.notice(
            """
            server-event acceptor created conn=\(Self.objectID(connection), privacy: .public) \
            (acceptors=\(self.acceptors.count, privacy: .public))
            """)
        return fresh
    }

    /// Evicts a terminated connection's acceptor and releases its stream
    /// queues; identity matching prevents an old cleanup task from removing a
    /// newer reconnect's acceptor.
    private func removeAcceptor(
        key: ObjectIdentifier, expected: BridgeLaneAcceptor
    ) async {
        guard acceptors[key] === expected else { return }
        acceptors.removeValue(forKey: key)
        acceptorCleanupTasks.removeValue(forKey: key)
        await expected.finish()
    }

    /// Slice 2 bootstrap: one pair RPC on the live client mints and persists
    /// this phone's next-transport credentials. Once per Mac per run; a Mac
    /// that answers method_not_found (old build) stays legacy silently.
    func probeBootstrap(
        client: MobileCoreRPCClient, macID: String, generation: UUID
    ) async {
        // Every healthy legacy connection refreshes the pair-RPC handle so
        // dial-hint refreshes can re-mint over a LIVE channel.
        pairClients[macID] = WeakPairClient(client: client)
        guard isEnabled, routing(macID: macID) != .legacy,
            !bootstrapsInFlight.contains(macID), !probedThisRun.contains(macID)
        else {
            let reason: String
            if !isEnabled {
                reason = "kill switch off"
            } else if routing(macID: macID) == .legacy {
                reason = "routing already legacy (sticky verdict)"
            } else if bootstrapsInFlight.contains(macID) {
                reason = "bootstrap already in flight"
            } else {
                reason = "already probed this run"
            }
            graduationLog.notice(
                """
                probe skip mac=\(String(macID.prefix(8)), privacy: .public): \
                \(reason, privacy: .public)
                """)
            return
        }
        // Claim the generation only after the skip guards. A concurrent
        // callback that finds an in-flight probe must not overwrite (and then
        // remove) the active probe's fence.
        probeGenerations[macID] = generation
        defer {
            if probeGenerations[macID] == generation {
                probeGenerations.removeValue(forKey: macID)
            }
        }
        bootstrapsInFlight.insert(macID)
        defer { bootstrapsInFlight.remove(macID) }
        let probeStart = ContinuousClock.now
        let identity = await bootstrapIdentity()
        graduationLog.notice(
            """
            probe begin mac=\(String(macID.prefix(8)), privacy: .public) \
            device=\(String(identity.deviceID.prefix(8)), privacy: .public) \
            app=\(identity.appIdentity, privacy: .public)
            """)
        do {
            let minted = try await mintBootstrap(client: client, identity: identity)
            guard !Task.isCancelled, probeGenerations[macID] == generation else { return }
            guard await storeBootstrap(
                macID: macID, ticket: minted.ticket, grant: minted.grant,
                generation: generation
            ) else {
                // A capability verdict is useful only when the credential
                // pair survived protected persistence. Keep routing unknown
                // so the legacy channel can retry instead of wedging on a
                // `.next` value with no bootstrap behind it.
                return
            }
            guard !Task.isCancelled, probeGenerations[macID] == generation else { return }
            probedThisRun.insert(macID)
            setRouting(.next, macID: macID)
            nextTransportFailureCounts.removeValue(forKey: macID)
            _ = ensureClient(macID: macID)
            graduationLog.notice(
                """
                bootstrap \(macID, privacy: .public): ticket + grant stored \
                elapsedMs=\(Self.elapsedMs(since: probeStart), privacy: .public)
                """)
        } catch {
            guard !Task.isCancelled, probeGenerations[macID] == generation else { return }
            // Probe verdicts are the ONLY capability signal. A typed
            // unknown-method rejection = the Mac build has no next
            // transport: legacy is CORRECT, sticky. Anything else (host
            // off, transient, malformed response) leaves the Mac unknown so
            // a later healthy connection re-probes. The raw error goes to
            // os.log only; nothing user-visible interpolates it.
            if probeErrorClassifier.isMethodNotFound(error) {
                probedThisRun.insert(macID)
                Self.BootstrapKeychain.delete(
                    macID: macID, defaults: defaults, keyPrefix: Self.bootstrapKeyPrefix)
                clientStartupTasks[macID]?.task.cancel()
                clientStartupTasks.removeValue(forKey: macID)
                let staleClient = clients.removeValue(forKey: macID)
                await staleClient?.disconnect()
                setRouting(.legacy, macID: macID)
                graduationLog.notice(
                    """
                    bootstrap \(macID, privacy: .public): Mac build has no next transport; \
                    legacy sticky \
                    elapsedMs=\(Self.elapsedMs(since: probeStart), privacy: .public)
                    """)
            } else {
                // A transient or malformed response is not a capability
                // verdict. Remove any in-run marker so the next healthy
                // connection can issue a fresh authoritative probe.
                probedThisRun.remove(macID)
                if routing(macID: macID) == .next {
                    setRouting(.unknown, macID: macID)
                }
                graduationLog.notice(
                    """
                    bootstrap \(macID, privacy: .public): probe inconclusive \
                    (\(String(describing: error), privacy: .public)); will retry \
                    elapsedMs=\(Self.elapsedMs(since: probeStart), privacy: .public)
                    """)
            }
        }
    }

    /// The pair RPC returned something that is not a ticket + grant pair.
    private struct MalformedPairResponse: Error {}

    /// One `mobile.next_transport.pair` RPC over a live legacy client:
    /// mints this phone's ticket + grant for that Mac.
    #if compiler(>=6.2)
    @concurrent
    #endif
    private nonisolated func mintBootstrap(
        client: MobileCoreRPCClient,
        identity: PeerIdentity
    ) async throws -> (ticket: String, grant: String) {
        let proof = try identity.sign(
            PairingGrant.requestProofTranscript(
                deviceID: identity.deviceID,
                devicePublicKey: identity.publicKeyData,
                appIdentity: identity.appIdentity
            )
        )
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.next_transport.pair",
            params: [
                "device_id": identity.deviceID,
                "device_public_key": identity.publicKeyData.base64EncodedString(),
                "app_identity": identity.appIdentity,
                "device_proof": proof.base64EncodedString(),
            ])
        let responseData = try await client.sendRequest(request)
        // sendRequest returns the UNWRAPPED result payload (see
        // MobileIrohReleaseGateResponseValidator), not the RPC envelope.
        guard
            let object = try JSONSerialization.jsonObject(with: responseData)
                as? [String: Any],
            let ticket = object["ticket"] as? String,
            let grant = object["grant"] as? String
        else {
            throw MalformedPairResponse()
        }
        return (ticket, grant)
    }

    /// Dial-hint refresh between reconnect attempts: re-mint the pair over
    /// the live legacy channel when one is reachable (and persist it), else
    /// fall back to the persisted bootstrap so the owner at least dials
    /// known coordinates. `fresh` tells the dial client which it got.
    private func refreshedBootstrap(
        macID: String
    ) async -> (ticketJSON: String, grantJSON: String, fresh: Bool)? {
        if let rpcClient = pairClients[macID]?.client {
            do {
                let minted = try await mintBootstrap(
                    client: rpcClient, identity: await bootstrapIdentity())
                await persistBootstrap(macID: macID, ticket: minted.ticket, grant: minted.grant)
                graduationLog.notice(
                    "hint refresh mac=\(String(macID.prefix(8)), privacy: .public): re-minted over legacy")
                return (minted.ticket, minted.grant, true)
            } catch {
                graduationLog.notice(
                    """
                    hint refresh mac=\(String(macID.prefix(8)), privacy: .public) \
                    re-mint failed (\(String(describing: error), privacy: .public)); \
                    falling back to persisted bootstrap
                    """)
            }
        }
        guard let stored = storedBootstrap(macID: macID) else { return nil }
        return (stored.ticket, stored.grant, false)
    }

    /// The same persisted identity the dial client uses, so a grant minted
    /// through bootstrap works in both the facade and the dev screen.
    private func bootstrapIdentity() async -> PeerIdentity {
        await NextTransportDialClient.currentIdentityOffMain(defaults: defaults)
    }

    /// Probe-path store: persists the pair AND drops any stale client so
    /// the next request boots a fresh one from it.
    private func storeBootstrap(
        macID: String, ticket: String, grant: String, generation: UUID
    ) async -> Bool {
        guard !Task.isCancelled, probeGenerations[macID] == generation else { return false }
        guard await persistBootstrap(macID: macID, ticket: ticket, grant: grant) else {
            probedThisRun.remove(macID)
            if routing(macID: macID) == .next { setRouting(.unknown, macID: macID) }
            return false
        }
        guard !Task.isCancelled, probeGenerations[macID] == generation else { return false }
        clientStartupTasks[macID]?.task.cancel()
        clientStartupTasks.removeValue(forKey: macID)
        let previous = clients.removeValue(forKey: macID)
        await previous?.disconnect()
        return true
    }

    /// Persist-only write (also the hint-refresh path, where the LIVE dial
    /// client is mid-attempt and must not be dropped).
    private func persistBootstrap(macID: String, ticket: String, grant: String) async -> Bool {
        let bootstrap = Bootstrap(ticket: ticket, grant: grant)
        guard let data = try? JSONEncoder().encode(bootstrap) else {
            graduationLog.error(
                """
                persistBootstrap FAILED mac=\(String(macID.prefix(8)), privacy: .public): \
                bootstrap did not encode
                """)
            return false
        }
        guard Self.BootstrapKeychain.write(
            data, macID: macID, defaults: defaults, keyPrefix: Self.bootstrapKeyPrefix)
        else { return false }
        graduationLog.notice(
            """
            bootstrap persisted mac=\(String(macID.prefix(8)), privacy: .public) \
            ticketBytes=\(ticket.utf8.count, privacy: .public) \
            grantBytes=\(grant.utf8.count, privacy: .public)
            """)
        return true
    }

    private func storedBootstrap(macID: String) -> Bootstrap? {
        guard let data = Self.BootstrapKeychain.read(
            macID: macID, defaults: defaults, keyPrefix: Self.bootstrapKeyPrefix)
        else { return nil }
        return try? JSONDecoder().decode(Bootstrap.self, from: data)
    }

    /// Device-only Keychain persistence for ticket/grant pairs. The defaults
    /// key is retained solely as a one-time migration source for older debug
    /// builds; new writes never place pairing material in preferences.
    private enum BootstrapKeychain {
        private static let accountPrefix = "mac-"

        static func read(
            macID: String, defaults: UserDefaults, keyPrefix: String
        ) -> Data? {
            let account = accountPrefix + macID
            var query = baseQuery(account: account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                let data = result as? Data {
                return data
            }
            guard let legacy = defaults.data(forKey: keyPrefix + macID) else { return nil }
            // Migrate atomically from the old preferences slot when possible.
            let migrated = writeKeychain(legacy, account: account)
            // Never leave ticket/grant material in the preferences plist when
            // the protected write is unavailable; callers can re-pair.
            defaults.removeObject(forKey: keyPrefix + macID)
            return migrated ? legacy : nil
        }

        static func write(
            _ data: Data, macID: String, defaults: UserDefaults, keyPrefix: String
        ) -> Bool {
            let account = accountPrefix + macID
            if writeKeychain(data, account: account) {
                defaults.removeObject(forKey: keyPrefix + macID)
                return true
            } else {
                graduationLog.error(
                    "bootstrap Keychain write failed mac=\(String(macID.prefix(8)), privacy: .public); not writing defaults")
                defaults.removeObject(forKey: keyPrefix + macID)
                return false
            }
        }

        static func delete(
            macID: String, defaults: UserDefaults, keyPrefix: String
        ) {
            SecItemDelete(baseQuery(account: accountPrefix + macID) as CFDictionary)
            defaults.removeObject(forKey: keyPrefix + macID)
        }

        private static func writeKeychain(_ data: Data, account: String) -> Bool {
            let query = baseQuery(account: account)
            let update = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary)
            if update == errSecSuccess { return true }
            guard update == errSecItemNotFound else { return false }
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }

        private static func baseQuery(account: String) -> [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: bootstrapKeychainService,
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: false,
                kSecUseDataProtectionKeychain as String: true,
            ]
        }
    }
}
#endif
