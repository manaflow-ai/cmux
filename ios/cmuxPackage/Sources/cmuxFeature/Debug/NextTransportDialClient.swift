#if DEBUG
import CmuxAuthRuntime
import CmuxNextTransport
import Foundation
import IrohLib
import Observation
import OSLog
import Security

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
    nonisolated static let logger = Logger(subsystem: "dev.cmux.ios", category: "next-transport-dial")

    /// Factory for an app-session-backed broker. The composition root injects
    /// this per client; no process-wide mutable broker state is consulted.
    public typealias BrokerFactory = @MainActor (PeerIdentity) -> BrokerCredentialClient

    /// Elapsed whole milliseconds used by dial diagnostics.
    nonisolated static func elapsedMs(since start: ContinuousClock.Instant) -> Int64 {
        let elapsed = start.duration(to: ContinuousClock.now)
        return Int64(elapsed.components.seconds) * 1_000
            + Int64(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    /// Short stable code for one error, safe for events/UI surfaces. Raw
    /// descriptions remain confined to the OS log.
    nonisolated static func shortErrorCode(_ error: any Error) -> String {
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
    /// Typed session state; `state` is its display string.
    public internal(set) var dialState: NextTransportDialState = .idle
    /// Display string derived from `dialState`, for the dev screen.
    public var state: String { dialState.displayDescription }
    /// The most recent real admission denial, if any. The facade reads this
    /// to decide whether the persisted bootstrap is still trustworthy.
    public internal(set) var lastDenial: DenialCode?
    public internal(set) var sessionID: String?
    public internal(set) var events: [String] = []
    public internal(set) var echoVerdict: String?

    /// Fresh dial hints (ticket + grant JSON) fetched between attempts, so a
    /// reconnect never reuses a stale address list when a better one is
    /// available. `fresh` is true when the pair was re-minted over a live
    /// legacy channel, false when it was re-read from persistence.
    public typealias HintRefresh =
        @Sendable () async -> (ticketJSON: String, grantJSON: String, fresh: Bool)?
    /// Installed by the graduation facade; nil for the paste-driven dev
    /// screen flow (which keeps its configured ticket).
    @ObservationIgnored public var hintRefresher: HintRefresh?

    let identity: PeerIdentity
    var endpoint: Endpoint?
    var owner: ReconnectOwner?
    var appliedRelayToken: String?
    var pendingRelay: (url: String, token: String)?
    let credentialPersistence = CredentialPersistenceQueue()

    var hostKey: Data?
    var hostAddrs: [String] = []
    var hostRelayURL: String?
    var grant: PairingGrant?
    var broker: BrokerCredentialClient?
    /// Credentials from the most recent successful mint; their `expiresAt`
    /// claims drive the renewal schedule.
    var mintedCredentials: [BrokerCredentialClient.Credential] = []
    /// Capped retry delay after a failed renewal. Expiry-derived scheduling is
    /// used only while the broker is healthy; failures must not collapse to a
    /// permanent minimum-delay request storm.
    var renewalRetryDelaySeconds: Int64?
    /// Dial attempts since the last explicit configure, so reconnects (not
    /// first dials) refresh hints and prefer the relay path.
    var dialAttemptIndex = 0
    /// A relay-only attempt that failed steers the next attempt back to the
    /// full address list.
    var relayOnlyAttemptFailed = false
    /// The admission result that the owner is about to publish as `.ready`.
    /// It is kept separate from `sessionID` so a transient `.connecting` state
    /// cannot erase the identifier before the UI observes readiness.
    var pendingAdmittedSessionID: String?
    /// Holds only a weak reference to the client, so the loop ends on its
    /// own at the tick after the client is released (no deinit needed; a
    /// MainActor deinit cannot touch isolated state under Swift 6).
    var renewTask: Task<Void, Never>?
    /// Observation of the owner state is retained so disconnect can cancel it
    /// before a facade drops this client.
    var stateObservationTask: Task<Void, Never>?
    /// At most one endpoint/owner boot may be in flight. The generation fence
    /// makes a boot that resumes after `disconnect()` inert and closes any
    /// endpoint it managed to create before noticing cancellation.
    private var bootTask: Task<Void, Never>?
    var lifecycleGeneration: UInt64 = 0
    let brokerFactory: BrokerFactory?
    let defaults: UserDefaults
    let keychainService: String
    let pushedRelayKeychainService: String
    let sleep: @Sendable (Duration) async throws -> Void

    struct RenewalRetryPolicy: Sendable {
        let minimumDelaySeconds: Int64 = 10
        let maximumDelaySeconds: Int64 = 300

        func nextDelay(after previous: Int64?) -> Int64 {
            guard let previous else { return minimumDelaySeconds }
            return min(previous * 2, maximumDelaySeconds)
        }
    }

    let renewalRetryPolicy = RenewalRetryPolicy()

    public init(
        brokerFactory: BrokerFactory? = nil,
        defaults: UserDefaults = .standard,
        keychainService: String = "dev.cmux.nextTransport.ios.identity.v1",
        sleep: @escaping @Sendable (Duration) async throws -> Void = { delay in
            try await ContinuousClock().sleep(for: delay)
        }
    ) {
        self.brokerFactory = brokerFactory
        self.defaults = defaults
        self.keychainService = keychainService
        pushedRelayKeychainService = keychainService + ".relay"
        self.sleep = sleep
        identity = Self.loadOrCreateIdentity(
            defaults: defaults, keychainService: keychainService)
        broker = Self.brokerClient(identity: identity)
        // A credential pushed on a previous run seeds the relay map as soon
        // as the endpoint boots.
        pendingRelay = Self.persistedPushedCredential(
            defaults: defaults, keychainService: pushedRelayKeychainService)
        log("identity \(identity.deviceID.prefix(8))…, env broker \(broker == nil ? "absent" : "ready")")
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

    public func connect() async {
        guard isConfigured else {
            log("connect: configure ticket + grant first")
            return
        }
        let generation = lifecycleGeneration
        if owner == nil {
            if bootTask == nil {
                bootTask = Task { [weak self] in
                    await self?.bootOwner(generation: generation)
                }
            }
            await bootTask?.value
            if generation == lifecycleGeneration {
                bootTask = nil
            }
            guard generation == lifecycleGeneration else { return }
        }
        guard generation == lifecycleGeneration, let owner else { return }
        await owner.trigger(.explicit(trigger: "dev-connect"))
    }

    public func disconnect() async {
        lifecycleGeneration &+= 1
        bootTask?.cancel()
        bootTask = nil
        stateObservationTask?.cancel()
        stateObservationTask = nil
        renewTask?.cancel()
        renewTask = nil
        await owner?.stop(reason: .userRequested)
        owner = nil
        if let endpoint {
            try? await endpoint.close()
            self.endpoint = nil
        }
        dialState = .idle
        sessionID = nil
        pendingAdmittedSessionID = nil
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
        let result = await Self.performEcho(connection: connection)
        if let errorCode = result.errorCode {
            echoVerdict = "echo failed (\(errorCode))"
            log("echo failed (\(errorCode))")
            return
        }
        echoVerdict = result.isClean
            ? "CLEAN: \(result.received)/50 ordered, checksums OK"
            : "DIRTY: \(result.received) received"
        log("echo: \(echoVerdict ?? "")")
    }

    /// Runs the synthetic echo workload away from the UI actor. The returned
    /// value is immutable, so only the caller publishes it to observable state.
    private struct EchoResult: Sendable {
        let received: Int
        let isClean: Bool
        let errorCode: String?
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    private nonisolated static func performEcho(
        connection: any PeerConnection
    ) async -> EchoResult {
        let echo = await connection.lane(TransportHost.echoLaneName)
        var validator = TrafficValidator()
        do {
            for seq in Int64(0)..<50 {
                try await echo.send(TerminalTraffic().chunk(seq: seq, size: 1_024, seed: 77))
                if let reply = await echo.receive() { validator.ingest(reply) }
            }
            return EchoResult(
                received: validator.received, isClean: validator.isClean, errorCode: nil)
        } catch {
            return EchoResult(
                received: validator.received, isClean: false,
                errorCode: Self.shortErrorCode(error))
        }
    }

    /// Event-log writer. `events` (and everything the dev screen shows)
    /// carries only short stable codes; the raw error text goes to os.log.
    func log(_ message: String, error: (any Error)? = nil) {
        if let error {
            Self.logger.error(
                "\(message, privacy: .public): \(String(describing: error), privacy: .public)")
            events.append("\(message) [\(Self.shortErrorCode(error))]")
        } else {
            Self.logger.notice("\(message, privacy: .public)")
            events.append(message)
        }
        if events.count > 200 { events.removeFirst(events.count - 200) }
    }
}
#endif
