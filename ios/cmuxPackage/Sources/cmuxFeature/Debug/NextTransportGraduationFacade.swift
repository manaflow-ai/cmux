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

/// Thrown for requests to a next-transport Mac while its session is down:
/// the app fails and reconnects rather than silently degrading to legacy.
struct NextTransportUnavailableError: Error {}

/// Graduation lane routing, phone side. Routing is a sticky PER-MAC
/// decision made only by probe verdicts: a next-transport Mac carries all
/// traffic over the bridge and FAILS HARD while reconnecting; legacy
/// remains only for Macs that answered method_not_found and for the
/// credentialing handshake.
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
    private var acceptors: [ObjectIdentifier: BridgeLaneAcceptor] = [:]
    private var bootstrapsInFlight: Set<String> = []
    /// Macs probed this app run whose probe failed (no support, host off):
    /// stay legacy without re-probing until the next launch.
    private var probedThisRun: Set<String> = []

    /// Default ON in dev builds: support is negotiated per Mac (the pair
    /// probe is the capability check — unsupported Macs simply stay legacy),
    /// so the toggle is a kill switch, not an opt-in.
    var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: Self.routeTrafficDefaultsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: Self.routeTrafficDefaultsKey)
    }

    func setEnabled(_ enabled: Bool) {
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
        if value == .unknown {
            UserDefaults.standard.removeObject(forKey: Self.routingKeyPrefix + macID)
        } else {
            UserDefaults.standard.set(value.rawValue, forKey: Self.routingKeyPrefix + macID)
        }
        graduationLog.notice(
            "routing \(macID, privacy: .public) -> \(value.rawValue, privacy: .public)")
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
        guard isEnabled, let macID = request.expectedPeerDeviceID else { return nil }
        guard routing(macID: macID) == .next else { return nil }
        guard let client = ensureClient(macID: macID) else { return nil }
        if client.state.contains("denied") {
            graduationLog.notice(
                "credentials for \(macID, privacy: .public) denied; re-credentialing over legacy")
            invalidateBootstrap(macID: macID)
            return nil
        }
        guard let connection = await client.admittedConnection() else { return nil }
        guard await !connection.isClosed else { return nil }
        return connection
    }

    /// True when this request's Mac is a next-transport Mac: traffic MUST
    /// ride the bridge and fail hard while it reconnects.
    func requiresBridge(for request: CmxByteTransportRequest) -> Bool {
        guard isEnabled, let macID = request.expectedPeerDeviceID else { return false }
        return routing(macID: macID) == .next
    }

    /// Boots (once) the per-Mac dial client from stored credentials. The
    /// owner autonomously maintains the session from then on.
    @discardableResult
    private func ensureClient(macID: String) -> NextTransportDialClient? {
        if let existing = clients[macID] { return existing }
        guard let bootstrap = storedBootstrap(macID: macID) else {
            setRouting(.unknown, macID: macID)
            return nil
        }
        let client = NextTransportDialClient()
        client.configure(ticketJSON: bootstrap.ticket, grantJSON: bootstrap.grant)
        clients[macID] = client
        Task { await client.connect() }
        return client
    }

    private func invalidateBootstrap(macID: String) {
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
        guard isEnabled, routing(macID: macID) != .legacy,
            !bootstrapsInFlight.contains(macID), !probedThisRun.contains(macID)
        else { return }
        if storedBootstrap(macID: macID) != nil {
            // Stored credentials ARE a capability verdict (upgrade path):
            // adopt them; if the Mac re-minted its signer since, the denial
            // cycle drops them and re-probes automatically.
            setRouting(.next, macID: macID)
            ensureClient(macID: macID)
            return
        }
        probedThisRun.insert(macID)
        bootstrapsInFlight.insert(macID)
        defer { bootstrapsInFlight.remove(macID) }
        let identity = bootstrapIdentity()
        do {
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
                graduationLog.notice(
                    "bootstrap \(macID, privacy: .public): malformed pair response")
                return
            }
            storeBootstrap(macID: macID, ticket: ticket, grant: grant)
            setRouting(.next, macID: macID)
            ensureClient(macID: macID)
            graduationLog.notice("bootstrap \(macID, privacy: .public): ticket + grant stored")
        } catch {
            // Probe verdicts are the ONLY capability signal. method_not_found
            // = the Mac build has no next transport: legacy is CORRECT,
            // sticky. Anything else (host off, transient) leaves the Mac
            // unknown so a later healthy connection re-probes.
            let description = String(describing: error)
            if description.contains("method_not_found") {
                setRouting(.legacy, macID: macID)
                graduationLog.notice(
                    "bootstrap \(macID, privacy: .public): Mac build has no next transport; legacy sticky")
            } else {
                graduationLog.notice(
                    "bootstrap \(macID, privacy: .public): probe inconclusive (\(description, privacy: .public)); will retry")
            }
        }
    }

    /// The same persisted identity the dial client uses, so a grant minted
    /// through bootstrap works in both the facade and the dev screen.
    private func bootstrapIdentity() -> (
        deviceID: String, publicKeyB64: String, appIdentity: String
    ) {
        let probe = NextTransportDialClient()
        return (probe.deviceID, probe.devicePublicKeyB64, "dev.cmux.next.ios")
    }

    private func storeBootstrap(macID: String, ticket: String, grant: String) {
        let bootstrap = Bootstrap(ticket: ticket, grant: grant)
        guard let data = try? JSONEncoder().encode(bootstrap) else { return }
        UserDefaults.standard.set(data, forKey: Self.bootstrapKeyPrefix + macID)
        clients[macID] = nil
    }

    private func storedBootstrap(macID: String) -> Bootstrap? {
        guard let data = UserDefaults.standard.data(forKey: Self.bootstrapKeyPrefix + macID)
        else { return nil }
        return try? JSONDecoder().decode(Bootstrap.self, from: data)
    }
}
#endif
