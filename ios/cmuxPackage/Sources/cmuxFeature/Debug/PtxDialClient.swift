#if DEBUG
import CmuxAuthRuntime
import CmuxPeerTransport
import Foundation

/// Peer transport v2, phone side (Packages/Shared/CmuxPeerTransport).
/// DEBUG-only; nothing in this file touches the shipping CmuxIrohTransport
/// paths. The soak drives it through defaults keys and the shared event log,
/// so there is deliberately no UI.

/// The pieces of the v2 dial path shared by every admitted stack member.
struct PtxBootedStack: Sendable {
    let identity: PtxIdentity
    let endpoint: IrohEndpointBox
}

/// The one-per-app half of the v2 dial path: the persisted identity (one
/// Ed25519 key per install), the shared event log (one JSONL timeline), the
/// broker-backed credential service, and the SINGLE bound iroh endpoint.
/// Two endpoints bound from one secret key fight over the same relay-side
/// registration, so every per-Mac dial client shares this stack.
@MainActor
final class PtxDialEnvironment {
    static let shared = PtxDialEnvironment()

    static let appIdentity = "dev.cmux.ptx.ios"
    static let identityDefaultsKey = "dev.cmux.ptx.ios.identity"
    static let appInstanceDefaultsKey = "dev.cmux.ptx.ios.appInstance"
    static let credentialCacheDefaultsKey = "dev.cmux.ptx.ios.relayCredentials"

    /// One structured timeline for the whole phone-side v2 story: dials,
    /// admissions, credential churn, and bridge routing flips. The soak
    /// harness tails the JSONL file out of the app container.
    let log = PtxEventLog(
        subsystem: "dev.cmux.ios",
        category: "peer-transport",
        fileURL: FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first?.appendingPathComponent("ptx-events.jsonl")
    )

    private var brokerBaseURL: URL?
    private var tokenProvider:
        (@Sendable () async throws -> (access: String, refresh: String))?
    private var durableDeviceID: (@Sendable () async -> String?)?

    private var identityTask: Task<PtxIdentity?, Never>?
    private var stackTask: Task<PtxBootedStack?, Never>?
    private var credentialService: PtxCredentialService?
    private var endpointBox: IrohEndpointBox?
    private var preferredRelayURL: String?
    private var appliedRelayToken: String?

    /// Registers the app's signed-in session, resolved broker origin, and
    /// durable device id as this environment's inputs. Installed once at
    /// composition boot (`MobileIrohRuntimeComposition.configure`). The
    /// broker mints with the CURRENT session token pair per request, never a
    /// captured credential.
    func install(
        brokerBaseURL: URL?,
        durableDeviceID: @escaping @Sendable () async -> String?,
        auth: AuthCoordinator
    ) {
        self.brokerBaseURL = brokerBaseURL
        self.durableDeviceID = durableDeviceID
        tokenProvider = { [weak auth] in
            guard let auth else {
                throw PtxBrokerError.shape("auth coordinator released")
            }
            let session = try await auth.authenticatedSessionSnapshot()
            return (access: session.accessToken, refresh: session.refreshToken)
        }
    }

    /// The persisted v2 identity. The private key is minted once per install
    /// (defaults-persisted); the device id is the app's durable
    /// Keychain-persisted registry id, so grants bind to the same device
    /// identity the legacy transport registers. nil while the durable id is
    /// unresolvable (protected storage unavailable, environment not yet
    /// installed): callers skip and retry on the next healthy connect.
    func identity() async -> PtxIdentity? {
        if let identityTask { return await identityTask.value }
        guard let durableDeviceID else {
            log.emit(PtxEventKind.endpointFailed, reason: "environment-not-installed")
            return nil
        }
        let log = log
        let task = Task<PtxIdentity?, Never> {
            guard let deviceID = await durableDeviceID() else {
                log.emit(
                    PtxEventKind.endpointFailed,
                    reason: "durable-device-id-unavailable")
                return nil
            }
            return PtxIdentityStore.loadOrCreate(
                defaults: .standard,
                key: Self.identityDefaultsKey,
                deviceID: deviceID,
                appIdentity: Self.appIdentity
            )
        }
        identityTask = task
        let identity = await task.value
        if identity == nil { identityTask = nil }
        return identity
    }

    /// Boots (once, single-flight) the shared endpoint stack: credential
    /// fast path from the persisted cache, one fresh mint when the cache is
    /// empty, and a relayless boot when minting fails (the renew loop heals
    /// the relay in later, zero-gap). The endpoint binds with AT MOST ONE
    /// relay: handing the FFI the whole minted fleet makes bind() itself
    /// time out, while the single home relay (the ticket's, else the first
    /// credential) binds instantly.
    func bootedStack(preferredRelayURL: String?) async -> PtxBootedStack? {
        if let stackTask { return await stackTask.value }
        let task = Task<PtxBootedStack?, Never> { @MainActor [weak self] in
            guard let self else { return nil }
            return await self.bootStack(preferredRelayURL: preferredRelayURL)
        }
        stackTask = task
        let stack = await task.value
        if stack == nil { stackTask = nil }
        return stack
    }

    private func bootStack(preferredRelayURL: String?) async -> PtxBootedStack? {
        guard let identity = await identity() else { return nil }
        guard let tokenProvider else {
            log.emit(PtxEventKind.endpointFailed, reason: "environment-not-installed")
            return nil
        }
        let broker = PtxBrokerClient(
            baseURL: brokerBaseURL?.absoluteString ?? "https://cmux-staging.vercel.app",
            auth: .tokens(tokenProvider),
            identity: identity,
            appInstanceID: appInstanceID(),
            tag: "ptx",
            platform: "ios"
        )
        let service = PtxCredentialService(
            broker: broker,
            defaults: .standard,
            cacheKey: Self.credentialCacheDefaultsKey,
            log: log
        )
        credentialService = service
        var credentials = await service.validCachedCredentials()
        if credentials.isEmpty {
            // No valid cache: one synchronous mint attempt. Failure is not
            // fatal — the endpoint boots relayless (still LAN/direct
            // dialable) and the renew loop inserts the relay once a later
            // mint succeeds.
            credentials = (try? await service.freshCredentials()) ?? []
        }
        let primary = PtxCredentialService.preferring(
            credentials, url: preferredRelayURL
        ).first
        let relays = primary.map {
            [PtxEndpoint.RelayAccess(url: $0.relayURL, authToken: $0.token)]
        } ?? []
        let box: IrohEndpointBox
        do {
            box = IrohEndpointBox(
                endpoint: try await PtxEndpoint.bind(identity: identity, relays: relays))
        } catch {
            log.emit(
                PtxEventKind.endpointFailed, reason: "bind-failed",
                detail: ["error": String(describing: error)])
            return nil
        }
        endpointBox = box
        self.preferredRelayURL = preferredRelayURL ?? primary?.relayURL
        appliedRelayToken = primary?.token
        await service.startRenewLoop(
            endpoint: box, preferredRelayURL: self.preferredRelayURL)
        log.emit(
            PtxEventKind.endpointReady,
            detail: [
                "relay": primary?.relayURL ?? "none",
                "minted": String(credentials.count),
            ])
        return PtxBootedStack(identity: identity, endpoint: box)
    }

    /// Foreground wake: revalidate relay credentials NOW instead of waiting
    /// for the renew tick — the app may have slept past token expiry. Mints
    /// only when the cache is stale and rotates zero-gap only when the
    /// primary token actually changed.
    func refreshCredentialsOnForeground() {
        guard let credentialService, let endpointBox else { return }
        let log = log
        let preferred = preferredRelayURL
        Task { @MainActor [weak self] in
            let minted: [PtxRelayCredential]
            do {
                minted = try await credentialService.currentCredentials()
            } catch {
                // Mint failures are already logged by the service; the renew
                // loop keeps retrying on its own cadence.
                return
            }
            guard
                let primary = PtxCredentialService.preferring(
                    minted, url: preferred
                ).first
            else { return }
            guard primary.token != self?.appliedRelayToken else { return }
            let rotated = await PtxEndpoint.rotateRelay(
                endpoint: endpointBox.endpoint,
                url: primary.relayURL,
                token: primary.token,
                log: log
            )
            if rotated { self?.appliedRelayToken = primary.token }
        }
    }

    private func appInstanceID() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: Self.appInstanceDefaultsKey) {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: Self.appInstanceDefaultsKey)
        return fresh
    }
}

/// One Mac's v2 dial client: the stored ticket + grant, ONE PtxReconnectOwner
/// (the sole dial/redial authority for that Mac), denial and repeated-failure
/// classification back into the facade, and host credential pushes verified
/// and rotated into the shared endpoint.
@MainActor
final class PtxDialClient {
    // Read inside the Sendable connect closure, off the main actor.
    nonisolated static let relayOnlyDefaultsKey = "dev.cmux.ptx.relayOnly"

    let macID: String
    private let ticket: PtxTicket
    private let grant: PtxGrant
    private let environment: PtxDialEnvironment
    private var owner: PtxReconnectOwner?
    private var bootTask: Task<Void, Never>?
    private var consecutiveDialFailures = 0
    private var invalidated = false
    /// Facade callback: stale credentials (admission denial) or a dead
    /// capability (3 consecutive dial failures) drop the stored bootstrap
    /// and reset routing so legacy re-credentials on the next probe.
    var onInvalidated: (@MainActor (String) -> Void)?

    init?(
        macID: String, bootstrap: PtxFacade.Bootstrap,
        environment: PtxDialEnvironment
    ) {
        guard let ticket = try? PtxTicket(encoded: bootstrap.ticket),
            let grantData = Data(base64Encoded: bootstrap.grant),
            let grant = try? JSONDecoder().decode(PtxGrant.self, from: grantData)
        else { return nil }
        self.macID = macID
        self.ticket = ticket
        self.grant = grant
        self.environment = environment
    }

    /// Boots the owner (once) and triggers the bootstrap dial. Safe to call
    /// repeatedly; a failed environment boot clears itself so the next call
    /// retries instead of wedging on a nil owner.
    func start() {
        guard bootTask == nil, !invalidated else { return }
        bootTask = Task { @MainActor [weak self] in
            await self?.boot()
        }
    }

    /// The live admitted connection, or nil: never dials, never blocks on a
    /// dial, never returns a closed corpse. Routing layers fail hard on nil
    /// while routing == .ptx.
    func liveConnection() async -> PtxConnection? {
        guard let owner else { return nil }
        guard let session = await owner.liveSession() else { return nil }
        guard await !session.connection.isClosed else { return nil }
        return session.connection
    }

    func shutdown(reason: String) async {
        invalidated = true
        bootTask?.cancel()
        await owner?.stop(reason: reason)
    }

    private func boot() async {
        guard owner == nil, !invalidated else { return }
        guard
            let stack = await environment.bootedStack(
                preferredRelayURL: ticket.relayURL)
        else {
            bootTask = nil
            return
        }
        let log = environment.log
        let identity = stack.identity
        let box = stack.endpoint
        let ticket = ticket
        let grant = grant
        let connect: @Sendable () async throws -> PtxDialOutcome = { [weak self] in
            let plan = PtxClient.DialPlan(
                ticket: ticket,
                relayOnly: UserDefaults.standard.bool(
                    forKey: PtxDialClient.relayOnlyDefaultsKey)
            )
            do {
                let outcome = try await PtxClient.connect(
                    endpoint: box.endpoint, plan: plan, identity: identity,
                    grant: grant, log: log)
                if case .denied(let code) = outcome {
                    await self?.noteDenied(code: code)
                } else {
                    await self?.noteDialSucceeded()
                }
                return outcome
            } catch {
                await self?.noteDialFailed()
                throw error
            }
        }
        let onControlFrame: @Sendable (PtxFrame) async -> Void = { frame in
            guard frame.type == PtxFrameType.relayCredential else { return }
            guard let token = frame.payload["token"]?.stringValue,
                let url = (frame.payload["url"] ?? frame.payload["relay_url"])?
                    .stringValue
            else {
                log.emit(
                    PtxEventKind.credentialError, reason: "push-malformed",
                    detail: ["type": frame.type])
                return
            }
            // The relay refuses a wrong-key token with NO client-visible
            // error, so verify the binding BEFORE applying it.
            guard PtxEndpoint.tokenEndpointID(token) == identity.publicKeyData
            else {
                log.emit(
                    PtxEventKind.credentialError, reason: "push-wrong-key",
                    detail: ["url": url])
                return
            }
            log.emit(PtxEventKind.credentialReceived, detail: ["url": url])
            _ = await PtxEndpoint.rotateRelay(
                endpoint: box.endpoint, url: url, token: token, log: log)
        }
        let onStateChange: @Sendable (PtxOwnerState) async -> Void = { [weak self] state in
            // A post-admission denial (revocation mid-session) parks the
            // owner; classify it exactly like a dial-time denial.
            if case .parked(let reason) = state, reason.hasPrefix("denied-") {
                await self?.noteDenied(code: reason)
            }
        }
        let owner = PtxReconnectOwner(
            log: log,
            connect: connect,
            onControlFrame: onControlFrame,
            onStateChange: onStateChange
        )
        self.owner = owner
        guard !invalidated else {
            await owner.stop(reason: PtxCloseReason.userRequested.rawValue)
            return
        }
        await owner.trigger(.automatic("bootstrap"))
    }

    private func noteDialSucceeded() {
        consecutiveDialFailures = 0
    }

    private func noteDialFailed() {
        consecutiveDialFailures += 1
        guard consecutiveDialFailures >= 3 else { return }
        invalidate(cause: "dial-failed-x\(consecutiveDialFailures)")
    }

    private func noteDenied(code: String) {
        consecutiveDialFailures = 0
        invalidate(cause: code)
    }

    private func invalidate(cause: String) {
        guard !invalidated else { return }
        invalidated = true
        onInvalidated?(cause)
    }
}
#endif
