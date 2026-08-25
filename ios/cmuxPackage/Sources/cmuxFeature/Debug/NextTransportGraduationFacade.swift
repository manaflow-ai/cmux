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

/// Graduation lane routing, phone side. When the route-traffic flag is on
/// and a Mac has been bootstrapped, the composition sends control, lanes,
/// and server events over the next transport; anything the facade cannot
/// serve falls back to the legacy path for that call.
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

    /// The admitted next-transport connection for this request's Mac, or nil
    /// when the facade should not (flag off) or cannot (no bootstrap, not
    /// admitted) serve it. Waits briefly for a dial in flight; a Mac that
    /// stays unreachable over the next transport degrades to legacy per call.
    func admittedConnection(
        for request: CmxByteTransportRequest
    ) async -> IrohPeerConnection? {
        guard isEnabled, let macID = request.expectedPeerDeviceID else { return nil }
        guard let bootstrap = storedBootstrap(macID: macID) else { return nil }
        let client: NextTransportDialClient
        if let existing = clients[macID] {
            client = existing
        } else {
            client = NextTransportDialClient()
            client.configure(ticketJSON: bootstrap.ticket, grantJSON: bootstrap.grant)
            clients[macID] = client
        }
        if let connection = await client.admittedConnection() {
            return connection
        }
        await client.connect()
        for _ in 0..<20 {
            if let connection = await client.admittedConnection() {
                return connection
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        graduationLog.notice("next transport not admitted for \(macID, privacy: .public); legacy path")
        return nil
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
        guard isEnabled, storedBootstrap(macID: macID) == nil,
            !bootstrapsInFlight.contains(macID), !probedThisRun.contains(macID)
        else { return }
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
            guard
                let object = try JSONSerialization.jsonObject(with: responseData)
                    as? [String: Any],
                let result = object["result"] as? [String: Any],
                let ticket = result["ticket"] as? String,
                let grant = result["grant"] as? String
            else {
                graduationLog.notice(
                    "bootstrap \(macID, privacy: .public): malformed pair response")
                return
            }
            storeBootstrap(macID: macID, ticket: ticket, grant: grant)
            graduationLog.notice("bootstrap \(macID, privacy: .public): ticket + grant stored")
        } catch {
            // method_not_found (old Mac) and unavailable (host off) land
            // here: this Mac stays legacy for the run.
            graduationLog.notice(
                "bootstrap \(macID, privacy: .public): unsupported or refused (\(String(describing: error), privacy: .public))")
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
