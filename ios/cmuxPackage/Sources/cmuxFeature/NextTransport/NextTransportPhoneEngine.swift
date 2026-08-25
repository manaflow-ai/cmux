#if DEBUG
import CmuxNextTransport
import Foundation
import IrohLib
import Observation
import OSLog

nonisolated private let phoneEngineLog = Logger(
    subsystem: "dev.cmux.ios",
    category: "next-transport-engine"
)

/// The iOS connection layer, rebuilt from scratch on the cmux-lite engine
/// (graduation P4; manaflow-ai/cmuxterm-hq#317). One instance per paired
/// Mac, alive for the app session.
///
/// The four properties that made the lab connection stable are structural
/// here, not behavioral:
///
///  1. ONE dialer. The engine's ReconnectOwner is the only component that
///     ever dials, retries, or declares death. Every app surface observes.
///  2. Liveness from the substrate only. Nothing here infers death from a
///     quiet stream, a timer, or a failed request.
///  3. Credentials live inside the engine: self-minted at the refresh
///     point, applied zero-gap (insert-alone). Relay expiry is therefore
///     not a reconnect — the link is replaced before the old one dies.
///  4. No helpful machinery: no keepalives, no watchdogs, no reconcilers.
///     The app layer cannot close, redial, or health-check this
///     connection; the surfaces it receives are lifecycle-inert by type.
///
/// Reconnects that remain are exactly the necessary ones: real network
/// death (radio loss) and iOS suspension, both self-healed by the owner
/// with the lab's measured sub-second recovery, cut short further by the
/// foreground trigger.
@MainActor
@Observable
public final class NextTransportPhoneEngine {
    public enum EngineState: String, Sendable {
        case idle, connecting, ready, degraded, closed
    }

    public private(set) var state: EngineState = .idle
    /// Session-generation counter: the dogfood no-reconnects metric. One
    /// admission per app foreground-session is the bar; every increment
    /// beyond that is a reconnect that must justify itself in the log.
    public private(set) var admissionCount = 0
    public private(set) var lastEvent = ""

    private let identity: PeerIdentity
    private let hostKey: Data
    private let hostRelayURL: String?
    private let hostAddrs: [String]
    private let grant: PairingGrant
    private let broker: BrokerCredentialClient?

    private var endpoint: Endpoint?
    private var owner: ReconnectOwner?
    private var appliedRelayToken: String?
    private var pendingRelay: (url: String, token: String)?
    private var stateTask: Task<Void, Never>?

    /// Inputs come from the bootstrap exchange (ticket + grant fetched over
    /// the already-authenticated legacy channel) — no pastes, no manual
    /// steps. The engine identity is durable per install.
    public init(
        identity: PeerIdentity,
        hostKey: Data,
        hostRelayURL: String?,
        hostAddrs: [String],
        grant: PairingGrant,
        broker: BrokerCredentialClient?
    ) {
        self.identity = identity
        self.hostKey = hostKey
        self.hostRelayURL = hostRelayURL
        self.hostAddrs = hostAddrs
        self.grant = grant
        self.broker = broker
    }

    /// Starts the engine: builds the endpoint (self-minting relay
    /// credentials when a broker is configured), boots the single owner,
    /// and triggers the first dial. Idempotent.
    public func start() async {
        guard owner == nil else { return }
        do {
            var relays: [IrohSubstrate.RelayAccess] = []
            if let broker {
                let credentials = try await broker.mint(preferredUrl: hostRelayURL)
                relays = credentials.map {
                    IrohSubstrate.RelayAccess(url: $0.relayUrl, authToken: $0.token)
                }
                appliedRelayToken = credentials.first?.token
                note("self-minted \(credentials.count) relay credentials")
            }
            let endpoint = try await (relays.isEmpty
                ? IrohSubstrate.endpoint(identity: identity, minimalLoopback: false)
                : IrohSubstrate.endpoint(identity: identity, relays: relays))
            self.endpoint = endpoint
            bootOwner(endpoint: endpoint)
            await owner?.trigger(.automatic(trigger: "engine-start"))
        } catch {
            state = .closed
            note("engine start failed: \(error)")
        }
    }

    /// Foreground wake: the one place a proactive credential check plus a
    /// single owner trigger is warranted (iOS may have killed the sockets
    /// during suspension; the lab measured this self-heal sub-second).
    public func appForegrounded() async {
        await rotateRelayCredentialIfStale(reason: "foreground")
        await owner?.trigger(.automatic(trigger: "foreground"))
    }

    /// The current admitted connection, for lane surfaces. Never exposed
    /// with lifecycle controls.
    func currentConnection() async -> (any PeerConnection)? {
        await owner?.currentConnection
    }

    /// Awaits a ready session (bounded by the caller's own cancellation).
    /// The RPC virtual transport calls this in connect(); it never dials —
    /// the owner is always the dialer. Signal-driven: the owner's state
    /// stream yields the current state immediately on subscription, so this
    /// is a pure await, never a poll.
    func waitReady() async {
        guard let owner else { return }
        for await sessionState in await owner.states() {
            if case .ready = sessionState { return }
            if Task.isCancelled { return }
        }
    }

    private func bootOwner(endpoint: Endpoint) {
        let identity = identity
        let grant = grant
        let hostKey = hostKey
        let hostAddrs = hostAddrs
        let hostRelayURL = hostRelayURL
        let dial: @Sendable () async throws -> ConnectAttemptResult = { [weak self] in
            await self?.rotateRelayCredentialIfStale(reason: "pre-dial")
            let addr = EndpointAddr(
                id: try EndpointId.fromBytes(bytes: hostKey),
                relayUrl: hostRelayURL,
                addresses: hostAddrs)
            return try await withThrowingTaskGroup(of: ConnectAttemptResult.self) { group in
                group.addTask {
                    let connection = try await IrohSubstrate.dial(endpoint: endpoint, to: addr)
                    switch try await TransportClient.connect(
                        connection: connection, identity: identity, grant: grant)
                    {
                    case .admitted(let sessionID):
                        return .admitted(connection, sessionID: sessionID)
                    case .denied(let code):
                        return .denied(code)
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(15))
                    throw TransportError.dialTimeout
                }
                guard let first = try await group.next() else {
                    throw TransportError.dialTimeout
                }
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
        stateTask = Task { [weak self] in
            await owner.endpointReady(true)
            for await sessionState in await owner.states() {
                await MainActor.run {
                    guard let self else { return }
                    switch sessionState {
                    case .idle: self.state = .idle
                    case .connecting: self.state = .connecting
                    case .ready:
                        self.state = .ready
                        self.admissionCount += 1
                        self.note("admitted (session #\(self.admissionCount))")
                    case .degraded: self.state = .degraded
                    case .closed(let reason):
                        self.state = .closed
                        self.note("closed (\(reason.code))")
                    }
                }
            }
        }
    }

    private func storePushedCredential(url: String, token: String) {
        guard IrohSubstrate.tokenEndpointId(token) == identity.publicKeyData else {
            note("pushed credential bound to a different device; ignored")
            return
        }
        pendingRelay = (url, token)
        note("relay credential staged")
    }

    private func rotateRelayCredentialIfStale(reason: String) async {
        // Self-mint takes priority when the applied token nears expiry;
        // pushed credentials cover hosts that mint on our behalf.
        if let broker, let applied = appliedRelayToken,
            let expiry = IrohSubstrate.tokenExpiry(applied),
            expiry.timeIntervalSinceNow < 90
        {
            if let fresh = try? await broker.mint(preferredUrl: hostRelayURL).first {
                pendingRelay = (fresh.relayUrl, fresh.token)
                note("self-minted fresh credential (\(reason))")
            }
        }
        guard let pending = pendingRelay, pending.token != appliedRelayToken,
            let endpoint
        else { return }
        do {
            try await endpoint.insertRelay(
                config: RelayConfig(url: pending.url, authToken: pending.token))
            appliedRelayToken = pending.token
            note("relay credential rotated in, zero-gap (\(reason))")
        } catch {
            note("credential rotation failed: \(error)")
        }
    }

    private func note(_ message: String) {
        phoneEngineLog.info("\(message, privacy: .public)")
        lastEvent = message
    }
}
#endif
