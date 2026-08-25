#if DEBUG
import CMUXMobileCore
import CmuxIrohTransport
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
    private static let bootstrapKeyPrefix = "dev.cmux.nextTransport.ios.bootstrap."

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
        graduationLog.info("next transport not admitted for \(macID, privacy: .public); legacy path")
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

    /// Slice 2 bootstrap: mints this phone's next-transport credentials over
    /// one legacy transport-admitted connection, then persists them. Safe to
    /// call often; runs at most once per Mac at a time and never re-runs
    /// after success.
    func bootstrapIfNeeded(
        for request: CmxByteTransportRequest,
        makeLegacyTransport: @escaping @Sendable () async throws -> any CmxByteTransport
    ) {
        guard isEnabled, let macID = request.expectedPeerDeviceID else { return }
        guard storedBootstrap(macID: macID) == nil else { return }
        guard !bootstrapsInFlight.contains(macID), !probedThisRun.contains(macID) else { return }
        probedThisRun.insert(macID)
        bootstrapsInFlight.insert(macID)
        let identity = bootstrapIdentity()
        Task { [weak self] in
            defer { Task { @MainActor in self?.bootstrapsInFlight.remove(macID) } }
            do {
                let transport = try await makeLegacyTransport()
                try await transport.connect()
                defer { Task { await transport.close() } }
                let requestID = "next-pair-\(UUID().uuidString.prefix(8))"
                let payload: [String: Any] = [
                    "id": requestID,
                    "method": "mobile.next_transport.pair",
                    "params": [
                        "device_id": identity.deviceID,
                        "device_public_key": identity.publicKeyB64,
                        "app_identity": identity.appIdentity,
                    ],
                ]
                let body = try JSONSerialization.data(withJSONObject: payload)
                try await transport.send(try MobileSyncFrameCodec.encodeFrame(body))
                var buffer = Data()
                let deadline = ContinuousClock.now + .seconds(15)
                while ContinuousClock.now < deadline {
                    guard let chunk = try await transport.receive() else { break }
                    buffer.append(chunk)
                    for frame in try MobileSyncFrameCodec.decodeFrames(from: &buffer) {
                        guard
                            let object = try? JSONSerialization.jsonObject(with: frame)
                                as? [String: Any],
                            object["id"] as? String == requestID
                        else { continue }
                        guard object["ok"] as? Bool == true,
                            let result = object["result"] as? [String: Any],
                            let ticket = result["ticket"] as? String,
                            let grant = result["grant"] as? String
                        else {
                            let message =
                                ((object["error"] as? [String: Any])?["message"] as? String)
                                ?? "malformed response"
                            graduationLog.error(
                                "bootstrap \(macID, privacy: .public) refused: \(message, privacy: .public)")
                            return
                        }
                        await MainActor.run {
                            self?.storeBootstrap(macID: macID, ticket: ticket, grant: grant)
                        }
                        graduationLog.info(
                            "bootstrap \(macID, privacy: .public): ticket + grant stored")
                        return
                    }
                }
                graduationLog.error("bootstrap \(macID, privacy: .public): no response")
            } catch {
                graduationLog.error(
                    "bootstrap \(macID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
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
