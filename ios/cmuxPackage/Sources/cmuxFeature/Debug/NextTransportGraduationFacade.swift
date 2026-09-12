#if DEBUG
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxMobileRPC
import CmuxMobileShell
import CmuxNextTransport
import CmuxNextTransportBridge
import Foundation
import OSLog
import Security

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
    nonisolated static let logger = Logger(subsystem: "dev.cmux.ios", category: "next-transport-graduation")

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
    static let bootstrapKeyPrefix = "dev.cmux.nextTransport.ios.bootstrap.v2."
    static let bootstrapKeychainService = "dev.cmux.nextTransport.ios.bootstrap.v2"

    struct Bootstrap: Codable {
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

    let defaults: UserDefaults
    let credentialPersistence = CredentialPersistenceQueue()
    private let denialPolicy = NextTransportDenialPolicy()
    let probeErrorClassifier = NextTransportProbeErrorClassifier()
    var brokerFactory: NextTransportDialClient.BrokerFactory?
    var clients: [String: NextTransportDialClient] = [:]
    /// Owned startup tasks keep a newly-created client asynchronous without
    /// letting a route request block on a network dial.
    var clientStartupTasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    /// The most recent healthy legacy RPC client per Mac (weak: the shell
    /// owns its lifetime), so dial-hint refreshes can re-mint the pair over
    /// a live channel between attempts.
    struct WeakPairClient {
        weak var client: MobileCoreRPCClient?
    }
    var pairClients: [String: WeakPairClient] = [:]
    var acceptors: [ObjectIdentifier: BridgeLaneAcceptor] = [:]
    var acceptorCleanupTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    var bootstrapsInFlight: Set<String> = []
    /// Macs with a decided capability verdict this app run. Inconclusive
    /// probes are deliberately removed so the next healthy connection retries.
    var probedThisRun: Set<String> = []
    /// Consecutive next-transport unavailability observations. A capability
    /// success is sticky while reachable, but a bounded run of timeouts lets
    /// the legacy channel recover and re-probe when a dev host is disabled.
    var nextTransportFailureCounts: [String: Int] = [:]
    private static let nextTransportFailureThreshold = 3
    /// Probe generations prevent a superseded shell connection from committing
    /// a late bootstrap or routing verdict.
    var probeGenerations: [String: UUID] = [:]

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
        Self.logger.notice(
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

    func setRouting(_ value: MacRouting, macID: String) {
        let previous = routing(macID: macID)
        if value == .unknown {
            defaults.removeObject(forKey: Self.routingKeyPrefix + macID)
        } else {
            defaults.set(value.rawValue, forKey: Self.routingKeyPrefix + macID)
        }
        Self.logger.notice(
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
            Self.logger.notice(
                """
                admittedConnection nil: \
                \(self.isEnabled ? "request carries no expected Mac device id" : "kill switch off", privacy: .public)
                """)
            return nil
        }
        let macRouting = routing(macID: macID)
        guard macRouting == .next else {
            Self.logger.notice(
                """
                admittedConnection nil mac=\(String(macID.prefix(8)), privacy: .public): \
                routing=\(macRouting.rawValue, privacy: .public) (not next)
                """)
            return nil
        }
        guard let client = ensureClient(macID: macID) else {
            Self.logger.notice(
                """
                admittedConnection nil mac=\(String(macID.prefix(8)), privacy: .public): \
                no dial client (no stored bootstrap)
                """)
            return nil
        }
        if case .closed(_, let denial) = client.dialState, let denial,
            denialPolicy.shouldInvalidateBootstrap(denial: denial)
        {
            Self.logger.notice(
                "credentials for \(macID, privacy: .public) denied; re-credentialing over legacy")
            invalidateBootstrap(macID: macID, cause: "admission denied (\(denial.rawValue))")
            return nil
        }
        guard let connection = await client.admittedConnection() else {
            await noteNextTransportFailure(macID: macID)
            Self.logger.notice(
                """
                admittedConnection nil mac=\(String(macID.prefix(8)), privacy: .public): \
                owner not ready (state=\(client.state, privacy: .public))
                """)
            return nil
        }
        guard await !connection.isClosed else {
            await noteNextTransportFailure(macID: macID)
            Self.logger.notice(
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
        Self.logger.notice(
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
        Self.logger.notice(
            """
            served \(kind, privacy: .public) mac=\(mac, privacy: .public) \
            via \(outcome, privacy: .public) (was \(previous ?? "unrecorded", privacy: .public))
            """)
    }

}
#endif
