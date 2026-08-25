#if DEBUG
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

    public init() {
        identity = Self.loadOrCreateIdentity()
        broker = Self.brokerClient(identity: identity)
        log("identity \(identity.deviceID.prefix(8))…, broker \(broker == nil ? "absent" : "ready")")
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
        do {
            if endpoint == nil {
                var relays: [IrohSubstrate.RelayAccess] = []
                if let broker {
                    let credentials = try await broker.mint(preferredUrl: hostRelayURL)
                    relays = credentials.map {
                        IrohSubstrate.RelayAccess(url: $0.relayUrl, authToken: $0.token)
                    }
                    appliedRelayToken = credentials.first?.token
                    log("self-minted \(credentials.count) relay credentials")
                }
                endpoint = try await (relays.isEmpty
                    ? IrohSubstrate.endpoint(identity: identity, minimalLoopback: false)
                    : IrohSubstrate.endpoint(identity: identity, relays: relays))
            }
        } catch {
            log("endpoint: \(error)")
            return
        }
        guard let endpoint else { return }
        let identity = identity
        let dial: @Sendable () async throws -> ConnectAttemptResult = { [weak self] in
            guard let self else { throw TransportError.pipeClosed }
            let (key, addrs, relayURL, grant) = await self.dialInputs()
            guard let key, let grant else { throw TransportError.pipeClosed }
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
                        await self.log("admitted as \(sessionID)")
                        return .admitted(conn, sessionID: sessionID)
                    case .denied(let code):
                        await self.log("denied: \(code.rawValue)")
                        return .denied(code)
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(15))
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
