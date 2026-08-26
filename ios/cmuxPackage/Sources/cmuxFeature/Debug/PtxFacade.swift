#if DEBUG
import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShell
import CmuxPeerTransport
import CmuxPeerTransportBridge
import Foundation

/// Thrown for requests to a peer-transport-v2 Mac while its session is down:
/// traffic fails hard and the owner reconnects, instead of silently
/// degrading to the legacy transport.
struct PtxUnavailableError: Error {}

/// Peer transport v2 lane routing, phone side. Routing is a STICKY per-Mac
/// decision made only by probe verdicts, never by dial outcomes (capability
/// and reachability are different axes): a v2 Mac carries all traffic over
/// the bridge and fails hard while reconnecting; legacy remains only for
/// Macs that answered method_not_found and for the credentialing handshake.
///
/// Bootstrap: one `mobile.peer_transport.pair` RPC over the ALREADY
/// authenticated legacy channel mints this phone's ticket + grant, persisted
/// per Mac. No pastes, no new backend.
@MainActor
final class PtxFacade {
    static let shared = PtxFacade()

    static let enabledDefaultsKey = "dev.cmux.ptx.enabled"
    private static let routingKeyPrefix = "dev.cmux.ptx.routing.v1."
    private static let bootstrapKeyPrefix = "dev.cmux.ptx.bootstrap.v1."

    struct Bootstrap: Codable {
        var ticket: String
        var grant: String
    }

    /// Sticky per-Mac routing, decided ONLY by probe verdicts.
    enum MacRouting: String {
        /// Not yet probed, or credentials invalidated: legacy carries
        /// traffic and the next healthy connection re-probes.
        case unknown
        /// Probe succeeded: ALL traffic rides the v2 transport and fails
        /// hard while it reconnects — no silent legacy fallback.
        case ptx
        /// The Mac build answered method_not_found: legacy is correct.
        case legacy
    }

    private var clients: [String: PtxDialClient] = [:]
    /// One raw-stream acceptor per admitted connection, keyed by connection
    /// identity: the acceptor is the connection's single raw-stream owner,
    /// and attaching two would split streams between them.
    private var acceptorTasks: [ObjectIdentifier: Task<PtxBridgeAcceptor, Never>] = [:]
    private var bootstrapsInFlight: Set<String> = []
    /// Macs probed this app run: the pair RPC runs once per Mac per run.
    private var probedThisRun: Set<String> = []
    private var lastServedPathOutcome: [String: String] = [:]

    private var log: PtxEventLog { PtxDialEnvironment.shared.log }

    /// Default ON in DEBUG: support is negotiated per Mac (the pair probe is
    /// the capability check — unsupported Macs simply stay legacy), so the
    /// defaults bool is a kill switch, not an opt-in.
    var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
    }

    /// This Mac's sticky routing decision.
    func routing(macID: String) -> MacRouting {
        guard isEnabled else { return .legacy }
        guard
            let raw = UserDefaults.standard.string(
                forKey: Self.routingKeyPrefix + Self.macKey(macID)),
            let value = MacRouting(rawValue: raw)
        else { return .unknown }
        return value
    }

    private func setRouting(_ value: MacRouting, macID: String, cause: String) {
        let previous = routing(macID: macID)
        let key = Self.routingKeyPrefix + Self.macKey(macID)
        if value == .unknown {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(value.rawValue, forKey: key)
        }
        log.emit(
            PtxEventKind.bridgeEvent, reason: cause,
            detail: [
                "mac": Self.macPrefix(macID),
                "routing": value.rawValue,
                "was": previous.rawValue,
            ])
    }

    /// The live admitted v2 connection for this request's Mac, or nil.
    /// A synchronous read of the owner's current truth: never dials, never
    /// ptx serves the PRIMARY session: the foreground control connection and
    /// the feature lanes sharing it. Background/secondary and probe requests
    /// stay legacy: a physical Mac runs several tagged app instances sharing
    /// one device id, the request's device id is the facade's only routing
    /// key, and the secondary status sweep probes EVERY stored instance —
    /// hijacking those onto the (single-instance) ptx session made the
    /// instance-tag authority reject it in a permanent retry storm.
    /// Instance-precise routing needs a route-level fingerprint; until then,
    /// purposes that are cross-instance by design keep their legacy path.
    private func purposeRidesPtx(_ request: CmxByteTransportRequest) -> Bool {
        switch request.sessionPurpose {
        case .foregroundControl, .featureLane:
            return true
        case .backgroundControl, .probe:
            return false
        }
    }

    /// blocks on a dial, never returns a closed connection.
    func admittedConnection(
        for request: CmxByteTransportRequest
    ) async -> PtxConnection? {
        guard isEnabled, let macID = request.expectedPeerDeviceID else { return nil }
        guard purposeRidesPtx(request) else { return nil }
        guard routing(macID: macID) == .ptx else { return nil }
        guard let client = ensureClient(macID: macID) else { return nil }
        return await client.liveConnection()
    }

    /// True when this request's Mac is a v2 Mac: traffic MUST ride the
    /// bridge and fail hard while the owner reconnects.
    func requiresBridge(for request: CmxByteTransportRequest) -> Bool {
        guard isEnabled, let macID = request.expectedPeerDeviceID else { return false }
        guard purposeRidesPtx(request) else { return false }
        return routing(macID: macID) == .ptx
    }

    /// Which path served one composition request kind, logged through the
    /// shared event log ONCE per outcome change per (Mac, kind): steady
    /// state stays quiet, every flip is on record.
    func noteServedPath(kind: String, macID: String?, outcome: String) {
        let mac = macID.map(Self.macPrefix) ?? "-"
        let key = "\(mac)|\(kind)"
        let previous = lastServedPathOutcome[key]
        guard previous != outcome else { return }
        lastServedPathOutcome[key] = outcome
        log.emit(
            PtxEventKind.bridgeEvent, reason: kind,
            detail: [
                "path": outcome,
                "mac": mac,
                "was": previous ?? "unrecorded",
            ])
    }

    /// The connection's single acceptor for host-opened server-event
    /// streams, created at most once per connection (single-flight so a
    /// concurrent first use cannot attach two raw-stream owners).
    func acceptor(for connection: PtxConnection) async -> PtxBridgeAcceptor {
        let key = ObjectIdentifier(connection)
        if let existing = acceptorTasks[key] { return await existing.value }
        let task = Task {
            await PtxBridgeAcceptor.attached(to: connection, acceptsServerEvents: true)
        }
        acceptorTasks[key] = task
        return await task.value
    }

    /// Installs the shell's post-connect probe hook exactly once. The probe
    /// rides the composite's LIVE authenticated RPC client, never a pooled
    /// control lane, so it cannot contend with the app's own requests.
    static func installProbeHook() {
        guard MobileShellComposite.peerTransportBootstrapProbe == nil else { return }
        MobileShellComposite.peerTransportBootstrapProbe = { client, macDeviceID in
            await PtxFacade.shared.probeBootstrap(client: client, macID: macDeviceID)
        }
    }

    /// One `mobile.peer_transport.pair` RPC per Mac per app run over the
    /// live legacy channel mints and persists this phone's v2 ticket +
    /// grant. Probe verdicts are the ONLY routing signal: method_not_found
    /// means the Mac build has no v2 host, so legacy is CORRECT and sticky;
    /// anything else (host busy, transient) leaves the Mac unknown so a
    /// later run re-probes.
    func probeBootstrap(client: MobileCoreRPCClient, macID: String) async {
        let key = Self.macKey(macID)
        guard isEnabled,
            routing(macID: macID) != .legacy,
            !bootstrapsInFlight.contains(key),
            !probedThisRun.contains(key)
        else { return }
        if storedBootstrap(macID: macID) != nil {
            // Stored credentials ARE a capability verdict (upgrade path):
            // adopt them; if the Mac re-minted its signer since, the denial
            // cycle drops them and re-probes automatically.
            probedThisRun.insert(key)
            setRouting(.ptx, macID: macID, cause: "bootstrap-adopted")
            ensureClient(macID: macID)
            return
        }
        bootstrapsInFlight.insert(key)
        defer { bootstrapsInFlight.remove(key) }
        guard let identity = await PtxDialEnvironment.shared.identity() else {
            // No durable device id yet: not a probe verdict; retry on the
            // next healthy connect.
            return
        }
        probedThisRun.insert(key)
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "mobile.peer_transport.pair",
                params: [
                    "device_id": identity.deviceID,
                    "device_public_key": identity.publicKeyData.base64EncodedString(),
                    "app_identity": identity.appIdentity,
                ])
            // sendRequest returns the UNWRAPPED result payload, no envelope.
            let response = try await client.sendRequest(request)
            guard
                let object = try JSONSerialization.jsonObject(with: response)
                    as? [String: Any],
                let ticket = object["ticket"] as? String,
                let grant = object["grant"] as? String
            else {
                log.emit(
                    PtxEventKind.bridgeEvent, reason: "pair-malformed",
                    detail: ["mac": Self.macPrefix(macID)])
                return
            }
            log.emit(
                PtxEventKind.bridgeEvent, reason: "pair-minted",
                detail: [
                    "mac": Self.macPrefix(macID),
                    "schema": String(describing: object["schema_version"] ?? "-"),
                ])
            storeBootstrap(macID: macID, ticket: ticket, grant: grant)
            setRouting(.ptx, macID: macID, cause: "pair-succeeded")
            ensureClient(macID: macID)
        } catch {
            if case MobileShellConnectionError.rpcError(let code, _) = error,
                code == "method_not_found"
            {
                setRouting(.legacy, macID: macID, cause: "pair-method-not-found")
                return
            }
            log.emit(
                PtxEventKind.bridgeEvent, reason: "pair-inconclusive",
                detail: [
                    "mac": Self.macPrefix(macID),
                    "error": String(describing: error),
                ])
        }
    }

    /// Boots (once) the per-Mac dial client from the stored bootstrap; its
    /// reconnect owner autonomously maintains the session from then on.
    @discardableResult
    private func ensureClient(macID: String) -> PtxDialClient? {
        let key = Self.macKey(macID)
        if let existing = clients[key] {
            existing.start()
            return existing
        }
        guard let bootstrap = storedBootstrap(macID: macID) else {
            setRouting(.unknown, macID: macID, cause: "bootstrap-missing")
            return nil
        }
        guard
            let client = PtxDialClient(
                macID: key, bootstrap: bootstrap,
                environment: PtxDialEnvironment.shared)
        else {
            invalidateBootstrap(macID: macID, cause: "bootstrap-unparseable")
            return nil
        }
        client.onInvalidated = { [weak self] cause in
            self?.invalidateBootstrap(macID: macID, cause: cause)
        }
        clients[key] = client
        client.start()
        return client
    }

    /// Admission denial or repeated dial failure: the stored credentials are
    /// dropped, routing resets to unknown, and the legacy channel
    /// re-credentials on the next probe.
    func invalidateBootstrap(macID: String, cause: String) {
        let key = Self.macKey(macID)
        UserDefaults.standard.removeObject(forKey: Self.bootstrapKeyPrefix + key)
        let client = clients.removeValue(forKey: key)
        Task { await client?.shutdown(reason: PtxCloseReason.userRequested.rawValue) }
        probedThisRun.remove(key)
        setRouting(.unknown, macID: macID, cause: "invalidated:\(cause)")
    }

    private func storeBootstrap(macID: String, ticket: String, grant: String) {
        guard
            let data = try? JSONEncoder().encode(Bootstrap(ticket: ticket, grant: grant))
        else { return }
        UserDefaults.standard.set(
            data, forKey: Self.bootstrapKeyPrefix + Self.macKey(macID))
        // A stale client (older ticket) must not outlive its bootstrap.
        if let stale = clients.removeValue(forKey: Self.macKey(macID)) {
            Task { await stale.shutdown(reason: PtxCloseReason.superseded.rawValue) }
        }
    }

    private func storedBootstrap(macID: String) -> Bootstrap? {
        guard
            let data = UserDefaults.standard.data(
                forKey: Self.bootstrapKeyPrefix + Self.macKey(macID))
        else { return nil }
        return try? JSONDecoder().decode(Bootstrap.self, from: data)
    }

    /// One normalized defaults/dictionary key per Mac: device ids arrive
    /// from both the attach ticket (probe) and the transport request
    /// (routing), so both sides normalize identically.
    private static func macKey(_ macID: String) -> String {
        macID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func macPrefix(_ macID: String) -> String {
        String(macKey(macID).prefix(8))
    }
}
#endif
