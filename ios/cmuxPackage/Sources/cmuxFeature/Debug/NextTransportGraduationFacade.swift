#if DEBUG
import CMUXMobileCore
import CmuxIrohTransport
import CmuxMobileRPC
import CmuxMobileShell
import CmuxNextTransport
import CmuxNextTransportBridge
import Foundation
import OSLog

private let graduationLog = Logger(
    subsystem: "dev.cmux.ios",
    category: "next-transport-graduation"
)

/// Stable short id correlating one live object across facade log lines.
func nextTransportObjectID(_ object: AnyObject) -> String {
    String(UInt(bitPattern: ObjectIdentifier(object).hashValue) & 0xFFFF_FFFF, radix: 16)
}

/// Elapsed whole milliseconds since `start`, for facade log lines.
func nextTransportElapsedMs(since start: ContinuousClock.Instant) -> Int64 {
    let elapsed = start.duration(to: ContinuousClock.now)
    return Int64(elapsed.components.seconds) * 1_000
        + Int64(elapsed.components.attoseconds / 1_000_000_000_000_000)
}

/// Thrown for requests to a next-transport Mac while its session is down:
/// the app fails and reconnects rather than silently degrading to legacy.
struct NextTransportUnavailableError: Error {}

/// Decides whether a dial client's reported session state means this Mac's
/// persisted bootstrap (ticket + grant) is no longer trustworthy. A real
/// admission denial means the credentials themselves are bad (the Mac
/// re-minted its signer, the grant expired or was revoked): the bootstrap
/// must be dropped so the legacy channel can re-credential. Extracted pure
/// so the regression suite can pin the decision table.
enum NextTransportDenialPolicy {
    /// The denial codes that prove the CREDENTIALS are bad. The two
    /// protocol-shaped denials (`malformed-hello`, `protocol-mismatch`) are
    /// build or wire bugs, not credential staleness: re-minting the same
    /// grant would change nothing, so they never burn the bootstrap.
    static let credentialDenials: Set<DenialCode> = [
        .invalidSignature, .expired, .revoked,
        .keyMismatch, .deviceIDMismatch, .appMismatch,
    ]

    /// Whether one typed denial proves a credential denial. Transport-level
    /// failures reach this as nil and never invalidate.
    static func shouldInvalidateBootstrap(denial: DenialCode?) -> Bool {
        guard let denial else { return false }
        return credentialDenials.contains(denial)
    }

    /// Raw-value convenience for the regression suite (the test target does
    /// not link CmuxNextTransport directly).
    static func shouldInvalidateBootstrap(denialRawValue: String?) -> Bool {
        shouldInvalidateBootstrap(
            denial: denialRawValue.flatMap(DenialCode.init(rawValue:)))
    }

    /// Display-string form, kept so the characterization suite pins the
    /// decision table against the exact strings the dial path publishes.
    static func shouldInvalidateBootstrap(stateDescription: String) -> Bool {
        guard stateDescription.hasPrefix("closed ("),
            stateDescription.hasSuffix(")")
        else { return false }
        return shouldInvalidateBootstrap(
            denialRawValue: String(
                stateDescription.dropFirst("closed (".count).dropLast()))
    }
}

/// Interprets one `mobile.next_transport.pair` probe failure through the
/// RPC layer's TYPED error (`MobileShellConnectionError.rpcError`), never
/// `String(describing:)`: only a server-reported unknown-method code is a
/// capability verdict; everything else is transient.
enum NextTransportProbeErrorClassifier {
    static func isMethodNotFound(_ error: any Error) -> Bool {
        guard case let MobileShellConnectionError.rpcError(code, message) = error else {
            return false
        }
        return isMethodNotFound(code: code, message: message)
    }

    static func isMethodNotFound(code: String?, message: String) -> Bool {
        if let code = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            ["method_not_found", "unknown_method", "unsupported_method"].contains(code)
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
    static let shared = NextTransportGraduationFacade()

    static let routeTrafficDefaultsKey = "dev.cmux.nextTransport.ios.routeAppTraffic"
    // v2: v1 tickets carried loopback-rewritten bound sockets that a real
    // phone can never dial; bumping the prefix invalidates them so every
    // Mac re-probes for a LAN-addressed ticket.
    private static let bootstrapKeyPrefix = "dev.cmux.nextTransport.ios.bootstrap.v2."

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

    private var clients: [String: NextTransportDialClient] = [:]
    /// The most recent healthy legacy RPC client per Mac (weak: the shell
    /// owns its lifetime), so dial-hint refreshes can re-mint the pair over
    /// a live channel between attempts.
    private struct WeakPairClient {
        weak var client: MobileCoreRPCClient?
    }
    private var pairClients: [String: WeakPairClient] = [:]
    private var acceptors: [ObjectIdentifier: BridgeLaneAcceptor] = [:]
    private var bootstrapsInFlight: Set<String> = []
    /// Macs probed this app run whose probe failed (no support, host off):
    /// stay legacy without re-probing until the next launch.
    private var probedThisRun: Set<String> = []

    /// Default OFF: the next transport is a dev opt-in, enabled from the
    /// dev screen's toggle. With the defaults key unset (or false) every
    /// gate in this facade answers legacy; support is still negotiated per
    /// Mac once enabled (the pair probe is the capability check).
    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.routeTrafficDefaultsKey)
    }

    func setEnabled(_ enabled: Bool) {
        graduationLog.notice(
            "facade setEnabled=\(enabled, privacy: .public) (was \(self.isEnabled, privacy: .public))")
        UserDefaults.standard.set(enabled, forKey: Self.routeTrafficDefaultsKey)
    }

    /// True when this Mac has a persisted ticket + grant.
    func hasBootstrap(macDeviceID: String) -> Bool {
        storedBootstrap(macID: macDeviceID) != nil
    }

    /// This Mac's sticky routing decision.
    func routing(macID: String) -> MacRouting {
        guard isEnabled else { return .legacy }
        guard let raw = UserDefaults.standard.string(forKey: Self.routingKeyPrefix + macID),
            let value = MacRouting(rawValue: raw)
        else { return .unknown }
        return value
    }

    private func setRouting(_ value: MacRouting, macID: String) {
        let previous = routing(macID: macID)
        if value == .unknown {
            UserDefaults.standard.removeObject(forKey: Self.routingKeyPrefix + macID)
        } else {
            UserDefaults.standard.set(value.rawValue, forKey: Self.routingKeyPrefix + macID)
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
            NextTransportDenialPolicy.shouldInvalidateBootstrap(denial: denial)
        {
            graduationLog.notice(
                "credentials for \(macID, privacy: .public) denied; re-credentialing over legacy")
            invalidateBootstrap(macID: macID, cause: "admission denied (\(denial.rawValue))")
            return nil
        }
        guard let connection = await client.admittedConnection() else {
            graduationLog.notice(
                """
                admittedConnection nil mac=\(String(macID.prefix(8)), privacy: .public): \
                owner not ready (state=\(client.state, privacy: .public))
                """)
            return nil
        }
        guard await !connection.isClosed else {
            graduationLog.notice(
                """
                admittedConnection nil mac=\(String(macID.prefix(8)), privacy: .public): \
                owner holds a closed corpse conn=\(nextTransportObjectID(connection), privacy: .public)
                """)
            return nil
        }
        return connection
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
        let client = NextTransportDialClient()
        var ticketJSON = bootstrap.ticket
        // Soak rig: with direct addresses stripped, every byte MUST cross
        // the relay — a simulator on the Mac's own machine cannot cheat the
        // non-local test over LAN/loopback.
        if UserDefaults.standard.bool(forKey: "dev.cmux.nextTransport.ios.soak.relayOnly"),
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
                cause: "stored bootstrap rejected (\(nextTransportShortErrorCode(error)))")
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
        Task { await client.connect() }
        return client
    }

    private func invalidateBootstrap(macID: String, cause: String) {
        graduationLog.notice(
            """
            bootstrap INVALIDATED mac=\(String(macID.prefix(8)), privacy: .public) \
            cause=\(cause, privacy: .public); dial client discarded, routing -> unknown, \
            legacy will re-credential
            """)
        UserDefaults.standard.removeObject(forKey: Self.bootstrapKeyPrefix + macID)
        let client = clients.removeValue(forKey: macID)
        Task { await client?.disconnect() }
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
        graduationLog.notice(
            """
            server-event acceptor created conn=\(nextTransportObjectID(connection), privacy: .public) \
            (acceptors=\(self.acceptors.count, privacy: .public))
            """)
        return fresh
    }

    /// Installs the shell's post-connect probe hook exactly once. The probe
    /// rides the composite's LIVE authenticated RPC client (the release-gate
    /// pattern), so it never contends for the pooled control lane the app's
    /// own requests own.
    @MainActor
    static func installProbeHook() {
        guard MobileShellComposite.nextTransportBootstrapProbe == nil else { return }
        MobileShellComposite.nextTransportBootstrapProbe = { client, macDeviceID in
            await NextTransportGraduationFacade.shared.probeBootstrap(
                client: client, macID: macDeviceID)
        }
    }

    /// Slice 2 bootstrap: one pair RPC on the live client mints and persists
    /// this phone's next-transport credentials. Once per Mac per run; a Mac
    /// that answers method_not_found (old build) stays legacy silently.
    private func probeBootstrap(client: MobileCoreRPCClient, macID: String) async {
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
        if storedBootstrap(macID: macID) != nil {
            // Stored credentials ARE a capability verdict (upgrade path):
            // adopt them; if the Mac re-minted its signer since, the denial
            // cycle drops them and re-probes automatically.
            graduationLog.notice(
                """
                probe mac=\(String(macID.prefix(8)), privacy: .public): stored bootstrap \
                adopted as capability verdict (upgrade path); routing -> next
                """)
            setRouting(.next, macID: macID)
            ensureClient(macID: macID)
            return
        }
        probedThisRun.insert(macID)
        bootstrapsInFlight.insert(macID)
        defer { bootstrapsInFlight.remove(macID) }
        let probeStart = ContinuousClock.now
        let identity = bootstrapIdentity()
        graduationLog.notice(
            """
            probe begin mac=\(String(macID.prefix(8)), privacy: .public) \
            device=\(String(identity.deviceID.prefix(8)), privacy: .public) \
            app=\(identity.appIdentity, privacy: .public)
            """)
        do {
            let minted = try await mintBootstrap(client: client, identity: identity)
            storeBootstrap(macID: macID, ticket: minted.ticket, grant: minted.grant)
            setRouting(.next, macID: macID)
            ensureClient(macID: macID)
            graduationLog.notice(
                """
                bootstrap \(macID, privacy: .public): ticket + grant stored \
                elapsedMs=\(nextTransportElapsedMs(since: probeStart), privacy: .public)
                """)
        } catch {
            // Probe verdicts are the ONLY capability signal. A typed
            // unknown-method rejection = the Mac build has no next
            // transport: legacy is CORRECT, sticky. Anything else (host
            // off, transient, malformed response) leaves the Mac unknown so
            // a later healthy connection re-probes. The raw error goes to
            // os.log only; nothing user-visible interpolates it.
            if NextTransportProbeErrorClassifier.isMethodNotFound(error) {
                setRouting(.legacy, macID: macID)
                graduationLog.notice(
                    """
                    bootstrap \(macID, privacy: .public): Mac build has no next transport; \
                    legacy sticky \
                    elapsedMs=\(nextTransportElapsedMs(since: probeStart), privacy: .public)
                    """)
            } else {
                graduationLog.notice(
                    """
                    bootstrap \(macID, privacy: .public): probe inconclusive \
                    (\(String(describing: error), privacy: .public)); will retry \
                    elapsedMs=\(nextTransportElapsedMs(since: probeStart), privacy: .public)
                    """)
            }
        }
    }

    /// The pair RPC returned something that is not a ticket + grant pair.
    private struct MalformedPairResponse: Error {}

    /// One `mobile.next_transport.pair` RPC over a live legacy client:
    /// mints this phone's ticket + grant for that Mac.
    private func mintBootstrap(
        client: MobileCoreRPCClient,
        identity: (deviceID: String, publicKeyB64: String, appIdentity: String)
    ) async throws -> (ticket: String, grant: String) {
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.next_transport.pair",
            params: [
                "device_id": identity.deviceID,
                "device_public_key": identity.publicKeyB64,
                "app_identity": identity.appIdentity,
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
                    client: rpcClient, identity: bootstrapIdentity())
                persistBootstrap(macID: macID, ticket: minted.ticket, grant: minted.grant)
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
    private func bootstrapIdentity() -> (
        deviceID: String, publicKeyB64: String, appIdentity: String
    ) {
        let probe = NextTransportDialClient()
        return (probe.deviceID, probe.devicePublicKeyB64, "dev.cmux.next.ios")
    }

    /// Probe-path store: persists the pair AND drops any stale client so
    /// the next request boots a fresh one from it.
    private func storeBootstrap(macID: String, ticket: String, grant: String) {
        persistBootstrap(macID: macID, ticket: ticket, grant: grant)
        clients[macID] = nil
    }

    /// Persist-only write (also the hint-refresh path, where the LIVE dial
    /// client is mid-attempt and must not be dropped).
    private func persistBootstrap(macID: String, ticket: String, grant: String) {
        let bootstrap = Bootstrap(ticket: ticket, grant: grant)
        guard let data = try? JSONEncoder().encode(bootstrap) else {
            graduationLog.error(
                """
                persistBootstrap FAILED mac=\(String(macID.prefix(8)), privacy: .public): \
                bootstrap did not encode
                """)
            return
        }
        UserDefaults.standard.set(data, forKey: Self.bootstrapKeyPrefix + macID)
        graduationLog.notice(
            """
            bootstrap persisted mac=\(String(macID.prefix(8)), privacy: .public) \
            ticketBytes=\(ticket.utf8.count, privacy: .public) \
            grantBytes=\(grant.utf8.count, privacy: .public)
            """)
    }

    private func storedBootstrap(macID: String) -> Bootstrap? {
        guard let data = UserDefaults.standard.data(forKey: Self.bootstrapKeyPrefix + macID)
        else { return nil }
        return try? JSONDecoder().decode(Bootstrap.self, from: data)
    }
}
#endif
