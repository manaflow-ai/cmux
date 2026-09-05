public import CMUXMobileCore
import CmuxAuthRuntime
public import CmuxIrohTransport
import CmuxIrxTransport
public import CmuxMobileRPC
import CmuxMobileShellModel
import CmuxMobileTransport
public import Foundation

/// A control lane is single-consumer per admitted session, while separate Mac
/// sessions must remain independently claimable. The owner token lets a
/// closing RPC client release only the claims it created.
struct MobileIrxControlLaneClaims {
    private var ownerBySession: [String: UUID] = [:]

    mutating func claim(sessionID: String, ownerID: UUID) -> Bool {
        if let existingOwner = ownerBySession[sessionID], existingOwner != ownerID {
            return false
        }
        ownerBySession[sessionID] = ownerID
        return true
    }

    mutating func release(ownerID: UUID) {
        ownerBySession = ownerBySession.filter { $0.value != ownerID }
    }

    mutating func removeAll() {
        ownerBySession.removeAll()
    }
}

/// iOS composition root for the irx transport (the from-scratch iroh rebuild
/// in `CmuxIrxTransport`). DEBUG-only, default-off: when `cmux.irx.enabled`
/// (or `CMUX_IRX_ENABLED=1`) is set, cmuxApp routes ALL `.iroh` traffic here
/// and the legacy `MobileIrohRuntimeComposition` is never configured, so the
/// two stacks cannot fight over the broker binding slot.
public actor MobileIrxRuntimeComposition {
    public static let enabledDefaultsKey = "cmux.irx.enabled"
    public static let forceRelayDefaultsKey = "cmux.irx.force-relay"

    /// irx is the PRIMARY transport: on by default in every configuration.
    /// An explicit `false` in defaults (the remote revert switch writes it)
    /// falls back to the legacy stack; the env var re-arms and persists.
    public nonisolated static var isEnabled: Bool {
        if ProcessInfo.processInfo.environment["CMUX_IRX_ENABLED"] == "1" {
            UserDefaults.standard.set(true, forKey: enabledDefaultsKey)
            return true
        }
        if UserDefaults.standard.object(forKey: enabledDefaultsKey) != nil {
            return UserDefaults.standard.bool(forKey: enabledDefaultsKey)
        }
        return true
    }

    public nonisolated static var forceRelayOnly: Bool {
        if ProcessInfo.processInfo.environment["CMUX_IRX_FORCE_RELAY"] == "1" {
            UserDefaults.standard.set(true, forKey: forceRelayDefaultsKey)
            return true
        }
        return UserDefaults.standard.bool(forKey: forceRelayDefaultsKey)
    }

    public enum CompositionError: Error, Sendable {
        case notSignedIn
        case unsupportedRoute
        case peerNotDiscovered
        case directDialUnavailable
        case networkPathChanged
    }

    /// Dial-gate refusals from the device-list lease. Deliberately NOT
    /// ``IrxAdmissionDenied``: the peer engine treats these as ordinary
    /// transient failures (backoff + redial), because a stale lease or a
    /// directory that has not yet caught up heals as soon as the control
    /// plane re-stamps. A revoked entry, by contrast, throws
    /// `IrxAdmissionDenied(.revoked)` and parks the engine.
    public enum DeviceListDialRefusal: Error, Sendable {
        case staleLease
        case unknownEndpoint
    }

    /// One journal for every irx component on the phone; the JSONL file lives
    /// in the app container's Documents so the soak analyzer can pull it with
    /// `simctl get_app_container`.
    nonisolated static let journal: IrxJournal = {
        let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first
        return IrxJournal(
            subsystem: "dev.cmux.ios",
            category: "irx-client",
            journalFileURL: documents?.appendingPathComponent("irx-journal.jsonl")
        )
    }()

    /// The stable factory cmuxApp registers for `.iroh` routes in irx mode.
    public nonisolated var transportFactory: CmxConnectivityDeferredTransportFactory {
        CmxConnectivityDeferredTransportFactory(provider: self)
    }

    private let brokerBaseURL: URL?
    private let clientNamespace: String
    public nonisolated let tag: String
    private let stateDirectory: URL
    /// The app's signed Keychain access group; scopes the Release device-list
    /// and broker-cache Keychain items.
    private let keychainAccessGroup: String?
    /// Shared with the legacy path provider so IRX can authorize and expire
    /// authenticated Bonjour LAN profiles on the same network generations.
    private let networkPathState: MobileIrohNetworkPathState
    private let lanPeerDiscovery: CmxIrohLANPeerDiscovery
    /// Device-local, account-scoped user overrides from the Private Addresses
    /// editor. IRX reads the same persisted store as the retired runtime, so
    /// switching transport implementations never loses the user's routes.
    private let customPrivatePaths: CmxIrohCustomPrivatePathStore
    private let reachability: (any ReachabilityProviding)?

    private weak var auth: AuthCoordinator?
    /// Identity donor (identity adoption): the legacy composition owns the
    /// Keychain identity, app-instance scope, and durable device ID.
    private weak var legacyComposition: MobileIrohRuntimeComposition?
    private var broker: IrxBrokerService?
    private var endpointSupervisor: IrxEndpointSupervisor?
    private var autopilot: IrxRelayCredentialAutopilot?
    private var identity: IrxIdentity?
    /// The always-on fact channel to the per-account control-plane DO.
    /// Never on the dial path; delivers pushed passes, hint updates, and the
    /// device-list directory (the dial-gate authority).
    private var controlPlane: IrxControlPlaneClient?
    private var controlPlaneBaseURL: URL?
    /// The current device-list lease: consulted by the dial gate. nil until
    /// a directory has EVER been received or restored (the bootstrap
    /// exception: a fresh install may dial before its first directory).
    private let deviceListBox = IrxDeviceListCurrent()
    /// Durable lease storage (Keychain in Release, dev file store in DEBUG).
    private var deviceListStore: IrxDeviceListStore?
    private var provisioningTask: Task<Void, Never>?
    private var provisionInFlight: Task<IrxBrokerService, any Error>?
    /// Auth observation stays alive for the lifetime of the composition. A
    /// successful first provision must not terminate it, otherwise an
    /// implicit token clear or account switch leaves the endpoint running.
    private var authObservationTask: Task<Void, Never>?
    private var activeAccountID: String?
    private var lifecycleEpoch: UInt64 = 0
    /// One reconnect owner per Mac endpoint (contract: the single dialer).
    private var enginesByPeer: [String: IrxPeerEngine] = [:]
    /// Route material per peer, refreshed on every transport request.
    private var routesByPeer: [String: (relayURL: String?, directAddresses: [String])] = [:]
    /// The latest path intent for each peer. Direct is an exclusive,
    /// fail-closed allowlist; automatic permits broker and LAN discovery.
    private var dialIntentByPeer: [String: IrxDialIntent] = [:]
    /// The intent used by the currently admitted session. A request that
    /// changes intent explicitly replaces the session before reusing it.
    private var activeDialIntentByPeer: [String: IrxDialIntent] = [:]
    /// The LAN resolver authenticates an mDNS result against the device ID as
    /// well as the endpoint key. Attach routes carry that intent separately
    /// from the cryptographic peer identity.
    private var expectedDeviceIDByPeer: [String: String] = [:]
    /// The control lane is single-consumer: one live transport owner per
    /// admitted session. A second RPC client must not force a QUIC replacement
    /// just to obtain the same lane, because foreground recovery and secondary
    /// aggregation can overlap briefly.
    private var controlLaneClaims = MobileIrxControlLaneClaims()
    /// The events uni-lane accept is single-consumer per session too.
    private var claimedEventSessions: Set<String> = []
    /// Change-only stream consumed by the MainActor settings adapter.
    private var settingsContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    @MainActor
    public init(
        apiBaseURL: String,
        reachability: (any ReachabilityProviding)? = nil,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appNamespace injectedAppNamespace: MobileIOSAppNamespace? = nil,
        keychainAccessGroup: String? = nil,
        defaults: UserDefaults = .standard
    ) {
        let networkPathState = MobileIrohNetworkPathState()
        let lanPeerDiscovery = CmxIrohLANPeerDiscovery(
            networkPath: { await networkPathState.snapshot() },
            authorizeProfile: { profile, generation, interfaceIndex in
                await networkPathState.authorizeLANProfile(
                    profile,
                    generation: generation,
                    interfaceIndex: interfaceIndex
                )
            },
            revokeProfile: { profile, generation in
                await networkPathState.revokeLANProfile(
                    profile,
                    generation: generation
                )
            }
        )
        self.keychainAccessGroup = keychainAccessGroup
        self.networkPathState = networkPathState
        self.lanPeerDiscovery = lanPeerDiscovery
        self.customPrivatePaths = CmxIrohCustomPrivatePathStore(
            store: CmxIrohUserDefaultsInstallStateStore(defaults: defaults)
        )
        self.reachability = reachability
        let appNamespace = injectedAppNamespace
            ?? MobileIOSAppNamespace(bundleIdentifier: bundleIdentifier)
        clientNamespace = appNamespace?.bundleIdentifier ?? "legacy"
        brokerBaseURL = MobileIrohRuntimeComposition.resolvedBrokerBaseURL(
            apiBaseURL: apiBaseURL,
            infoDictionary: infoDictionary,
            bundleIdentifier: bundleIdentifier
        )
        let rawTag = MobileIOSBuildScope.current(
            infoDictionary: infoDictionary,
            bundleIdentifier: bundleIdentifier
        )?.value ?? "default"
        tag = String(rawTag.prefix(64)).lowercased().map { character in
            (character.isASCII && (character.isLetter || character.isNumber))
                || ["-", ".", ":", "_"].contains(character)
                ? String(character) : "-"
        }.joined()
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        stateDirectory = IrxStateLocation.directory(
            base: appSupport,
            bundleIdentifier: bundleIdentifier,
            brokerHost: brokerBaseURL?.host()
        )
        IrxStateLocation.removeLegacySharedDirectory(base: appSupport)
    }

    // MARK: - Lifecycle

    public func configure(
        auth: AuthCoordinator,
        legacy: MobileIrohRuntimeComposition? = nil,
        controlPlaneBaseURL: URL? = nil
    ) async {
        self.auth = auth
        legacyComposition = legacy
        self.controlPlaneBaseURL = controlPlaneBaseURL
        lifecycleEpoch &+= 1
        let configurationEpoch = lifecycleEpoch
        if let reachability {
            guard isLifecycleEpochCurrent(configurationEpoch),
                  !Task.isCancelled else { return }
            await networkPathState.start(
                reachability: reachability,
                onPathChange: { [weak self] in
                    await self?.invalidateCachedDirectRoutesForNetworkChange()
                    await self?.lanPeerDiscovery.pathDidChange()
                }
            )
        }
        Self.journal.record(
            "client-runtime", "configured",
            [
                "tag": tag,
                "namespace": clientNamespace,
                "force_relay": String(Self.forceRelayOnly),
                "broker": brokerBaseURL?.host() ?? "-",
            ]
        )
        authObservationTask?.cancel()
        provisioningTask?.cancel()
        provisioningTask = nil
        // Proactive provisioning is event-driven on auth. The observation task
        // never exits after a successful provision, so implicit sign-out and
        // account switches receive the same teardown as explicit sign-out.
        authObservationTask = Task { [weak self, weak auth] in
            guard let auth else { return }
            await auth.awaitBootstrapped()
            guard !Task.isCancelled else { return }
            Self.journal.record("client-runtime", "auth-gate-bootstrapped")
            for await identity in await auth.authenticatedSessionIdentities() {
                guard !Task.isCancelled else { return }
                await self?.applyAuthIdentity(identity)
            }
        }
    }

    private func applyAuthIdentity(
        _ sessionIdentity: AuthenticatedSessionIdentity?
    ) async {
        guard let sessionIdentity else {
            await handleSignOut()
            return
        }
        guard activeAccountID != sessionIdentity.accountID || broker == nil else {
            // A same-account refresh does not replace a healthy runtime. If a
            // prior task was cancelled before publication, restart it.
            if provisioningTask == nil {
                startProvisioning(for: sessionIdentity)
            }
            return
        }
        if activeAccountID != nil || broker != nil {
            await handleSignOut()
        }
        activeAccountID = sessionIdentity.accountID
        startProvisioning(for: sessionIdentity)
    }

    private func isCurrent(_ epoch: UInt64) -> Bool {
        epoch == lifecycleEpoch && activeAccountID != nil
    }

    private func isLifecycleEpochCurrent(_ epoch: UInt64) -> Bool {
        epoch == lifecycleEpoch
    }

    private func requireCurrent(_ epoch: UInt64) throws {
        guard isCurrent(epoch) else { throw CancellationError() }
    }

    private func requireLifecycle(_ epoch: UInt64) throws {
        guard epoch == lifecycleEpoch else { throw CancellationError() }
    }

    private func startProvisioning(for sessionIdentity: AuthenticatedSessionIdentity) {
        provisioningTask?.cancel()
        let epoch = lifecycleEpoch
        provisioningTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.provisionSignedInWithRetry(
                sessionIdentity: sessionIdentity,
                epoch: epoch
            )
        }
    }

    /// Provisions with capped backoff. Returns true on success; returns
    /// false immediately when not signed in (the caller's auth signal owns
    /// the next attempt, so no pre-auth retries ever run).
    private func provisionSignedInWithRetry(
        sessionIdentity: AuthenticatedSessionIdentity,
        epoch: UInt64
    ) async -> Bool {
        guard let auth else { return false }
        Self.journal.record("client-runtime", "auth-gate-snapshot-check")
        guard await auth.isAuthenticatedSessionIdentityCurrent(sessionIdentity) else {
            Self.journal.record("client-runtime", "auth-gate-not-signed-in")
            return false
        }
        Self.journal.record("client-runtime", "auth-gate-signed-in")
        var delay: Duration = .seconds(1)
        while !Task.isCancelled {
            guard lifecycleEpoch == epoch,
                  await auth.isAuthenticatedSessionIdentityCurrent(sessionIdentity)
            else { return false }
            if await provisionIfPossible(
                sessionIdentity: sessionIdentity,
                epoch: epoch
            ) { return true }
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(30))
        }
        return false
    }

    /// Foreground kick: re-check credential freshness immediately (iOS
    /// suspension pauses the autopilot's sleep) and reconnect the control
    /// socket, which resyncs facts from the persisted revision.
    public func didBecomeActive() async {
        await autopilot?.kick()
        await controlPlane?.kick()
        await lanPeerDiscovery.permissionMayHaveChanged()
        for engine in enginesByPeer.values {
            await engine.foregroundKick()
        }
    }

    // MARK: - Control-plane fact ingestion

    private func startControlPlane(identity: IrxIdentity) {
        guard controlPlane == nil, let controlPlaneBaseURL, let auth else { return }
        let epoch = lifecycleEpoch
        let client = IrxControlPlaneClient(
            configuration: .init(
                socketURL: controlPlaneBaseURL
                    .appendingPathComponent("v1/control/socket"),
                endpointIDHex: identity.endpointIDHex,
                // Phase A: passes stay on the HTTPS autopilot (now hardened
                // with stale-connection retry). The broker's mint endpoint
                // requires an endpoint-signed proof for non-legacy
                // namespaces, which the DO cannot mint bearer-only; flip
                // this when proof pass-through ships.
                wantPasses: false,
                cacheDirectory: stateDirectory,
                clientInfo: IrxCtlClientInfo(
                    deviceID: identity.deviceID,
                    platform: "ios",
                    appVersion: IrxCtlClientInfo.appVersionString(
                        infoDictionary: Bundle.main.infoDictionary),
                    releaseTrack: Self.clientReleaseTrack(),
                    capabilities: ["cmux.irx.v2", "list-auth"]
                ),
                clientNamespace: clientNamespace
            ),
            tokenPair: { [weak auth] in
                guard let auth else { return nil }
                let session = try await auth.authenticatedSessionSnapshot()
                return (session.accessToken, session.refreshToken)
            },
            handlers: .init(
                onRelayPasses: { [weak self] credentials in
                    guard let self, await self.isCurrent(epoch) else { return false }
                    return await self.ingestPushedPasses(credentials)
                },
                onHintUpdate: { [weak self] endpointIDHex, relayURL in
                    guard let self, await self.isCurrent(epoch) else { return false }
                    return await self.ingestHintUpdate(
                        endpointIDHex: endpointIDHex, relayURL: relayURL)
                },
                onDirectory: { _ in true },
                onSnapshotComplete: { _ in },
                onDirectoryFact: { [weak self] fact in
                    guard let self, await self.isCurrent(epoch) else { return false }
                    return await self.applyDeviceListFact(fact)
                },
                onFreshness: { [weak self] rev, issuedAt in
                    guard let self, await self.isCurrent(epoch) else { return }
                    await self.applyDeviceListFreshness(rev: rev, issuedAt: issuedAt)
                }
            ),
            journal: Self.journal
        )
        controlPlane = client
        Task { await client.start() }
    }

    // MARK: - Device list (dial-gate authority)

    /// The phone's iteration of the device-list apply: persist, swap the
    /// dial-gate box, project into the UI state, acknowledge the revision.
    /// (Enforcement on LIVE sessions is the Mac's job; the phone's gate
    /// bites at the next dial.)
    private func applyDeviceListFact(_ fact: IrxCtlDirectoryFact) async -> Bool {
        if let current = deviceListBox.current, fact.rev <= current.rev {
            Self.journal.record(
                "client-runtime", "device-list-stale-rev",
                ["rev": String(fact.rev), "have": String(current.rev)]
            )
            return true
        }
        let snapshot = IrxDeviceListSnapshot(
            fact: fact,
            receivedAtWall: Date(),
            receivedAtMonotonic: .now
        )
        if let deviceListStore {
            guard await deviceListStore.persist(snapshot) else { return false }
        }
        deviceListBox.replace(snapshot)
        Self.journal.record(
            "client-runtime", "device-list-applied",
            ["rev": String(fact.rev), "entries": String(snapshot.entries.count)]
        )
        await projectDeviceListForUI(snapshot)
        return true
    }

    private func applyDeviceListFreshness(rev: Int, issuedAt: Date) async {
        guard
            let updated = deviceListBox.restamp(
                rev: rev,
                issuedAt: issuedAt,
                receivedAtWall: Date(),
                receivedAtMonotonic: .now
            )
        else { return }
        if let deviceListStore {
            await deviceListStore.persist(updated)
        }
        Self.journal.record(
            "client-runtime", "device-list-restamped", ["rev": String(rev)]
        )
    }

    /// Mirrors the lease into the @Observable UI state (Computers rows read
    /// it to badge seeded Macs).
    private func projectDeviceListForUI(_ snapshot: IrxDeviceListSnapshot) async {
        let fresh = snapshot.isFresh(now: .now)
        var byEndpoint: [String: MobileMacListAuthState.Entry] = [:]
        var byDevice: [String: MobileMacListAuthState.Entry] = [:]
        for (endpointIDHex, entry) in snapshot.entries {
            let projected = MobileMacListAuthState.Entry(
                status: entry.status,
                revoked: entry.revoked,
                isFresh: fresh,
                appVersion: entry.appVersion,
                minimumSupportedVersion: snapshot.minimumSupportedMacVersion
            )
            byEndpoint[endpointIDHex] = projected
            if let deviceID = entry.deviceID {
                byDevice[deviceID] = projected
            }
        }
        await MainActor.run {
            MobileMacListAuthState.shared.replace(
                entriesByEndpointID: byEndpoint,
                entriesByDeviceID: byDevice,
                minimumSupportedMacVersion: snapshot.minimumSupportedMacVersion
            )
        }
        publishSettingsUpdate()
    }

    /// UI/programmatic lookup: the peer's list-auth stance right now.
    public func deviceListEntry(
        endpointIDHex: String
    ) -> (status: String, revoked: Bool, fresh: Bool)? {
        guard let snapshot = deviceListBox.current,
            let entry = snapshot.entries[endpointIDHex]
        else { return nil }
        return (entry.status, entry.revoked, snapshot.isFresh(now: .now))
    }

    /// Sign-out: drop the lease everywhere (memory, durable store, UI), so
    /// the next account starts from its own directory.
    public func handleSignOut() async {
        lifecycleEpoch &+= 1
        await networkPathState.stop()
        activeAccountID = nil
        provisioningTask?.cancel()
        provisioningTask = nil
        provisionInFlight?.cancel()
        provisionInFlight = nil

        // Stop every live authority before erasing its persisted state. The
        // broker and endpoint both carry endpoint identity in memory, while
        // their epoch fences prevent late network completions from restoring
        // a cache entry after this method returns.
        let controlPlane = self.controlPlane
        self.controlPlane = nil
        await controlPlane?.stop()
        let autopilot = self.autopilot
        self.autopilot = nil
        await autopilot?.stop()
        let supervisor = self.endpointSupervisor
        self.endpointSupervisor = nil
        await supervisor?.deactivate()
        let engines = Array(enginesByPeer.values)
        enginesByPeer.removeAll()
        for engine in engines {
            await engine.stop(code: .userRequested)
        }
        await lanPeerDiscovery.stop()
        // irx adopts the legacy identity repository, so the donor must run its
        // sign-out preparation even when legacy transport is dormant. This is
        // what removes the Ed25519 endpoint key and queues any binding revoke
        // for an implicit token clear or account switch.
        if let legacyComposition {
            let preparation = await legacyComposition.beginSignOutPreparation()
            _ = await preparation.value
        }
        let broker = self.broker
        self.broker = nil
        await broker?.deactivate()
        identity = nil
        routesByPeer.removeAll()
        dialIntentByPeer.removeAll()
        activeDialIntentByPeer.removeAll()
        expectedDeviceIDByPeer.removeAll()
        controlLaneClaims.removeAll()
        claimedEventSessions.removeAll()

        deviceListBox.clear()
        if let deviceListStore {
            await deviceListStore.clear()
        }
        deviceListStore = nil
        await MainActor.run {
            MobileMacListAuthState.shared.clear()
        }
        publishSettingsUpdate()
        Self.journal.record("client-runtime", "device-list-signed-out")
    }

    /// The lease's durable backend, matching the identity/credential stores'
    /// DEBUG/#else split exactly.
    private nonisolated static func deviceListSecureStore(
        stateDirectory: URL,
        keychainAccessGroup: String?
    ) -> any CmxIrohSecureCredentialStoring {
        #if DEBUG
        CmxIrohDevelopmentFileCredentialStore(
            directory: stateDirectory.appendingPathComponent(
                "device-list", isDirectory: true)
        )
        #else
        CmxIrohKeychainCredentialStore(
            service: "com.cmuxterm.irx.device-list.v1",
            accessGroup: keychainAccessGroup
        )
        #endif
    }

    /// The phone build's control-plane release track. Conservative: DEBUG is
    /// "dev"; a bundle id carrying a ".beta" segment is "beta"; everything
    /// else reports "appstore" (TestFlight and App Store share a bundle id,
    /// so the wire cannot distinguish them here).
    private nonisolated static func clientReleaseTrack(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> String {
        #if DEBUG
        return "dev"
        #else
        return (bundleIdentifier ?? "").contains(".beta") ? "beta" : "appstore"
        #endif
    }

    /// Pushed passes flow through the broker's mint rules (fleet allowlist,
    /// identity binding, monotonic freshness), then rotate make-before-break
    /// and reset the autopilot timer so push and fallback never double-mint.
    private func ingestPushedPasses(_ credentials: [IrxRelayCredential]) async -> Bool {
        guard let broker, let endpointSupervisor, let autopilot else { return false }
        guard let accepted = await broker.acceptPushedRelayCredentials(credentials)
        else { return false }
        await endpointSupervisor.rotateCredentials(accepted)
        await autopilot.kick()
        return true
    }

    /// The event-driven relay race: a pushed hint that disagrees with the
    /// route an in-flight dial used cancels that dial and redials at the
    /// true relay. An admitted session is never touched, and an agreeing
    /// hint (the overwhelmingly common case) is a no-op.
    private func ingestHintUpdate(endpointIDHex: String, relayURL: String) async -> Bool {
        let existing = routesByPeer[endpointIDHex]
        guard existing?.relayURL != relayURL else { return true }
        routesByPeer[endpointIDHex] = (relayURL, existing?.directAddresses ?? [])
        Self.journal.record(
            "client-runtime", "hint-adopted",
            [
                "peer": String(endpointIDHex.prefix(12)),
                "relay": relayURL,
                "was": existing?.relayURL ?? "-",
            ]
        )
        if let engine = enginesByPeer[endpointIDHex] {
            await engine.relayHintChanged(trigger: "ctl-hint-update")
        }
        return true
    }

    private func provisionIfPossible(
        sessionIdentity: AuthenticatedSessionIdentity,
        epoch: UInt64
    ) async -> Bool {
        guard let auth else { return false }
        guard lifecycleEpoch == epoch,
              await auth.isAuthenticatedSessionIdentityCurrent(sessionIdentity),
              let session = try? await auth.authenticatedSessionSnapshot(),
              session.accountID == sessionIdentity.accountID else {
            return false
        }
        _ = session
        do {
            _ = try await provisionedBroker(epoch: epoch)
            Self.journal.record("client-runtime", "provisioned")
            return true
        } catch {
            Self.journal.record(
                "client-runtime", "provisioning-retry",
                ["error": String(describing: error)]
            )
            return false
        }
    }

    /// Builds and warms the full broker/endpoint stack, publishing it ONLY
    /// after every step succeeds. A transient failure (e.g. the auth session
    /// not yet coherent during launch sign-in) must never leave a
    /// half-initialized broker behind: an unregistered client 403s every
    /// later call, which is exactly the poisoned state this single-flight
    /// all-or-nothing shape forbids.
    private func provisionedBroker(epoch: UInt64? = nil) async throws -> IrxBrokerService {
        if let epoch {
            try requireCurrent(epoch)
        }
        if let broker { return broker }
        if let provisionInFlight {
            return try await provisionInFlight.value
        }
        let operationEpoch = epoch ?? lifecycleEpoch
        let task = Task<IrxBrokerService, any Error> {
            try await self.provisionOnce(epoch: operationEpoch)
        }
        provisionInFlight = task
        defer { provisionInFlight = nil }
        return try await task.value
    }

    private func provisionOnce(epoch: UInt64) async throws -> IrxBrokerService {
        try requireLifecycle(epoch)
        guard let auth, let brokerBaseURL else {
            throw CompositionError.notSignedIn
        }
        let session = try await auth.authenticatedSessionSnapshot()
        try requireLifecycle(epoch)
        guard activeAccountID == nil || activeAccountID == session.accountID else {
            throw CancellationError()
        }
        // IDENTITY ADOPTION: same identity/device/app-instance as the legacy
        // stack, so the binding refreshes in place and stored routes + pair
        // grants stay valid across the transport switch.
        guard let legacyComposition,
            let adopted = try await legacyComposition.irxAdoptedIdentity(
                accountID: session.accountID, tag: tag)
        else {
            throw CompositionError.notSignedIn
        }
        try requireLifecycle(epoch)
        let identity = IrxIdentity(
            privateKeyData: adopted.material.secretKey.bytes,
            deviceID: adopted.deviceID,
            appInstanceID: adopted.appInstanceID
        )
        let broker = try IrxBrokerService(
            configuration: .init(
                baseURL: brokerBaseURL,
                clientNamespace: clientNamespace,
                tag: tag,
                platform: .ios,
                displayName: nil,
                cacheDirectory: stateDirectory,
                identityGeneration: adopted.material.generation,
                // Release: broker caches live in the Keychain, scoped per
                // account + backend; DEBUG stays on the JSON files.
                accountID: session.accountID,
                keychainAccessGroup: keychainAccessGroup
            ),
            identity: identity,
            accessTokenPair: { [weak auth] in
                guard let auth else { return nil }
                let session = try await auth.authenticatedSessionSnapshot()
                return (session.accessToken, session.refreshToken)
            },
            journal: Self.journal
        )
        let supervisor = IrxEndpointSupervisor(
            configuration: .init(
                identity: identity,
                pathMode: Self.forceRelayOnly ? .relayOnly : .automatic,
                preferredBindAddress: nil,
                // The Mac opens no bidi streams toward the phone; the events
                // lane is unidirectional and credited post-admission.
                initialRemoteBiStreams: 0,
                initialRemoteUniStreams: 0
            ),
            journal: Self.journal
        )
        let pilot = IrxRelayCredentialAutopilot(
            broker: broker, endpoint: supervisor, journal: Self.journal)
        // Launch-latency shape (measured on device: registration 636ms +
        // discovery 445ms + lazy bind-to-online 1186ms serialized into a
        // 3.3s first connect): when the binding and trust snapshot are
        // already on disk, publish immediately and refresh registration +
        // discovery in the BACKGROUND; and warm the endpoint's relay link
        // during provisioning so the first dial never pays for it.
        let cachedBinding = await broker.cachedBinding()
        let cachedTrust = await broker.cachedTrust()
        let cachedCredentials = await broker.cachedRelayCredentials()
        try requireLifecycle(epoch)
        if cachedBinding == nil || cachedTrust == nil {
            // First run for this identity: the full serial path, correctness
            // over speed (registration must precede mint/discovery).
            _ = try await broker.register(pairingEnabled: false, relayURLHint: nil)
            _ = try await pilot.usableCredentials()
            _ = try? await broker.discover()
        } else if cachedCredentials.isEmpty {
            // Cached identity but stale relay passes: the mint below MUST
            // follow a registration on THIS client instance. register() arms
            // the client's per-request binding proof, and the broker's mint
            // policy rejects proofless non-legacy mints; a mint racing a
            // background register 403s (`binding_request_proof_required`)
            // and wedges provisioning in a retry loop.
            _ = try await broker.register(pairingEnabled: false, relayURLHint: nil)
            Task { _ = try? await broker.discover() }
        } else {
            // Fresh passes on disk: nothing needs the broker before dialing,
            // so registration + discovery refresh entirely in the background
            // (the true zero-RTT launch).
            Task {
                _ = try? await broker.register(pairingEnabled: false, relayURLHint: nil)
                _ = try? await broker.discover()
            }
        }
        let credentials = try await pilot.usableCredentials()
        try requireLifecycle(epoch)
        // Fire-and-forget relay-link warm-up: bind + come online now, in
        // parallel with whatever the UI is doing.
        Task { _ = try? await supervisor.readyEndpoint(credentials: credentials) }
        await pilot.start()
        guard isCurrent(epoch) else {
            await pilot.stop()
            await supervisor.deactivate()
            await broker.deactivate()
            throw CancellationError()
        }
        self.identity = identity
        self.broker = broker
        endpointSupervisor = supervisor
        autopilot = pilot
        // DEVICE LIST: restore the persisted lease before any dial so the
        // gate (and the UI projection) work offline; the control-plane
        // socket then refreshes it with live directory facts.
        let listStore = IrxDeviceListStore(
            secureStore: Self.deviceListSecureStore(
                stateDirectory: stateDirectory,
                keychainAccessGroup: keychainAccessGroup
            ),
            accountID: session.accountID,
            backendHost: brokerBaseURL.host() ?? "unknown-broker",
            journal: Self.journal
        )
        deviceListStore = listStore
        if let persisted = await listStore.loadPersisted() {
            deviceListBox.replace(persisted)
            await projectDeviceListForUI(persisted)
        }
        startControlPlane(identity: identity)
        return broker
    }

    // MARK: - First-pair picker surface

    /// Fresh authenticated broker discovery for the first-pair picker.
    /// Returns nil instead of throwing so the picker degrades to an empty
    /// candidate list, mirroring the legacy discovery contract.
    public func freshLiveDiscovery() async -> CmxIrohDiscoveryResponse? {
        guard let broker = try? await provisionedBroker() else {
            Self.journal.record(
                "client-runtime", "picker-discovery", ["bindings": "unprovisioned"])
            return nil
        }
        let discovery = try? await broker.discover(maximumAge: 5)
        Self.journal.record(
            "client-runtime", "picker-discovery",
            ["bindings": discovery.map { String($0.bindings.count) } ?? "unavailable"]
        )
        return discovery
    }

    /// Drops the reusable discovery snapshot after a presence route push.
    public func invalidateDiscoverySnapshot() async {
        await broker?.invalidateDiscoverySnapshot()
    }

    /// Revokes one account-owned binding (forget-computer server leg).
    public func revokeBinding(_ bindingID: String) async throws {
        let broker = try await provisionedBroker()
        try await broker.revoke(bindingID: bindingID)
    }

    /// The live authenticated account, or nil when signed out.
    public func authenticatedAccountID() async -> String? {
        guard let auth else { return nil }
        return try? await auth.authenticatedSessionSnapshot().accountID
    }

    // MARK: - Private Addresses settings

    /// Adds the active IRX device directory and device-local private-address
    /// settings to the existing settings snapshot consumed by SwiftUI.
    public func settingsSnapshot(
        overlaying base: CmxIrohSettingsSnapshot
    ) async -> CmxIrohSettingsSnapshot {
        let privateSnapshot = if let activeAccountID {
            await customPrivatePaths.availableSnapshot(accountID: activeAccountID)
        } else {
            CmxIrohCustomPrivatePathSnapshot.unavailable
        }
        var macsByID: [String: CmxIrohSettingsSnapshot.PrivateNetworkMac] = [:]
        if let directory = deviceListBox.current {
            for entry in directory.entries.values {
                guard let deviceID = entry.deviceID else { continue }
                let identity = CmxMacAppInstanceIdentity(
                    macDeviceID: deviceID,
                    instanceTag: entry.tag
                )
                let supportsPrivatePaths = entry.capabilities?.contains(
                    "iroh.private_paths.v1"
                ) == true
                macsByID[identity.id] = .init(
                    macDeviceID: identity.macDeviceID,
                    instanceTag: identity.instanceTag,
                    displayName: identity.macDeviceID,
                    supportsPrivatePaths: supportsPrivatePaths
                )
            }
        }
        for configuration in privateSnapshot.configurations
        where macsByID[configuration.id] == nil {
            macsByID[configuration.id] = .init(
                macDeviceID: configuration.macDeviceID,
                instanceTag: configuration.instanceTag,
                displayName: configuration.macDisplayName
            )
        }
        return CmxIrohSettingsSnapshot(
            runtimeStatus: base.runtimeStatus,
            selectedTransportPath: base.selectedTransportPath,
            preference: base.preference,
            pathPreference: Self.forceRelayOnly ? .relayOnly : .automatic,
            managedRelays: base.managedRelays,
            customRelays: base.customRelays,
            privateNetworkMacs: macsByID.values.sorted { $0.id < $1.id },
            customPrivateNetworks: privateSnapshot.configurations.map {
                .init(
                    macDeviceID: $0.macDeviceID,
                    instanceTag: $0.instanceTag,
                    macDisplayName: $0.macDisplayName,
                    addresses: $0.addresses.map(\.value),
                    isEnabled: $0.isEnabled
                )
            },
            policySource: base.policySource,
            policySequence: base.policySequence,
            policyExpiresAt: base.policyExpiresAt,
            staleRelayIDs: base.staleRelayIDs,
            failureDescription: base.failureDescription,
            debugTransportVerificationMode: base.debugTransportVerificationMode
        )
    }

    public func settingsUpdates() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        settingsContinuations[id] = continuation
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeSettingsContinuation(id) }
        }
        return stream
    }

    public func refreshSettingsSnapshot() {
        publishSettingsUpdate()
    }

    public func upsertCustomPrivatePath(
        _ path: CmxIrohCustomPrivatePathDraft
    ) async throws {
        guard let activeAccountID else { throw CompositionError.notSignedIn }
        _ = try await customPrivatePaths.upsert(path, accountID: activeAccountID)
        await privatePathSettingsChanged(
            macDeviceID: path.macDeviceID,
            instanceTag: path.instanceTag
        )
    }

    public func removeCustomPrivatePath(
        macDeviceID: String,
        instanceTag: String?
    ) async throws {
        guard let activeAccountID else { throw CompositionError.notSignedIn }
        _ = try await customPrivatePaths.remove(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            accountID: activeAccountID
        )
        await privatePathSettingsChanged(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
    }

    private func privatePathSettingsChanged(
        macDeviceID: String,
        instanceTag: String?
    ) async {
        let requested = CmxMacAppInstanceIdentity(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
        var peers: [String] = []
        if let snapshot = deviceListBox.current {
            for (peerHex, entry) in snapshot.entries {
                guard let deviceID = entry.deviceID else { continue }
                let candidate = CmxMacAppInstanceIdentity(
                    macDeviceID: deviceID,
                    instanceTag: entry.tag
                )
                if candidate.id == requested.id {
                    peers.append(peerHex)
                }
            }
        }
        for peerHex in peers {
            if let route = routesByPeer[peerHex] {
                routesByPeer[peerHex] = (route.relayURL, [])
            }
            await enginesByPeer[peerHex]?.relayHintChanged(
                trigger: "private-path-change"
            )
        }
        publishSettingsUpdate()
    }

    private func removeSettingsContinuation(_ id: UUID) {
        settingsContinuations.removeValue(forKey: id)
    }

    private func publishSettingsUpdate() {
        for continuation in settingsContinuations.values {
            continuation.yield()
        }
    }

    // MARK: - Dialing

    private func peerTarget(for request: CmxByteTransportRequest) throws -> String {
        guard request.route.kind == .iroh,
            case let .peer(identity, pathHints) = request.route.endpoint
        else {
            throw CompositionError.unsupportedRoute
        }
        let now = Date()
        let relayURL = pathHints.first {
            $0.kind == .relayURL && $0.isUsable(at: now)
        }?.value
        let directAddresses = Self.forceRelayOnly
            ? []
            : pathHints.filter { $0.kind == .directAddress && $0.isUsable(at: now) }
                .map(\.value)
        // Attach tickets strip path hints, so a nil hint here is normal;
        // never clobber a relay already resolved from discovery with nil.
        let existing = routesByPeer[identity.endpointID]
        if let expectedPeerDeviceID = request.expectedPeerDeviceID {
            expectedDeviceIDByPeer[identity.endpointID] = expectedPeerDeviceID
        }
        routesByPeer[identity.endpointID] = (
            relayURL ?? existing?.relayURL,
            directAddresses.isEmpty ? (existing?.directAddresses ?? []) : directAddresses
        )
        dialIntentByPeer[identity.endpointID] = request.irohDirectOnlyDialCandidates.map {
            .direct($0)
        } ?? .automatic
        return identity.endpointID
    }

    private enum IrxDialIntent: Equatable, Sendable {
        case automatic
        case direct([CmxIrohDirectDialCandidate])
    }

    private static func directDialAddresses(
        candidates: [CmxIrohDirectDialCandidate],
        directPorts: CmxIrohDirectPorts?
    ) -> [String] {
        var seen = Set<String>()
        return candidates.prefix(16).compactMap { candidate in
            guard let address = try? CmxIrohCustomPrivateAddress(candidate.address) else {
                return nil
            }
            let port = candidate.port ?? (
                address.family == .ipv4 ? directPorts?.ipv4 : directPorts?.ipv6
            )
            guard let port, port != 0 else { return nil }
            let value = address.socketAddress(port: port)
            guard seen.insert(value).inserted else { return nil }
            return value
        }
    }

    private func ensureSession(
        forPeer peerHex: String,
        trigger: String
    ) async throws -> IrxClientSession {
        let engine = engine(forPeer: peerHex)
        let desired = dialIntentByPeer[peerHex] ?? .automatic
        let replaceForIntent = activeDialIntentByPeer[peerHex].map { $0 != desired } ?? false
        return try await engine.ensureSession(
            explicit: replaceForIntent,
            trigger: trigger
        )
    }

    /// The target's home relay from the account registry: the Mac registers
    /// the relay its endpoint actually homes on, and dialing any OTHER relay
    /// is a black hole (the relay only forwards to peers connected to it).
    private func refreshRouteFromDiscovery(
        peerHex: String,
        broker: IrxBrokerService
    ) async -> (binding: CmxIrohBrokerBinding, discovery: CmxIrohDiscoveryResponse)? {
        guard let discovery = try? await broker.discover(maximumAge: 30),
              let binding = discovery.bindings.first(where: {
                  $0.endpointID.endpointID == peerHex
              }) else { return nil }
        let now = Date()
        let relay = binding.pathHints.first {
            $0.kind == .relayURL && $0.isUsable(at: now)
        }?.value
        let direct = binding.pathHints.filter {
            $0.kind == .directAddress && $0.isUsable(at: now)
        }.map(\.value)
        routesByPeer[peerHex] = (
            relay,
            direct
        )
        return (binding, discovery)
    }

    /// A network generation change invalidates every cached direct coordinate.
    /// The next automatic dial rebuilds public candidates from authenticated
    /// broker discovery and LAN candidates from the new Bonjour generation.
    /// Clearing the combined cache is deliberate: retaining a public hint is
    /// safe but would make it possible for a stale private coordinate to be
    /// retried when broker discovery is temporarily unavailable.
    private func invalidateCachedDirectRoutesForNetworkChange() {
        guard !routesByPeer.isEmpty else { return }
        for peerHex in routesByPeer.keys {
            guard let route = routesByPeer[peerHex] else { continue }
            routesByPeer[peerHex] = (route.relayURL, [])
        }
        Self.journal.record(
            "client-runtime", "direct-routes-invalidated",
            ["reason": "network-path-change"]
        )
    }

    private func engine(forPeer peerHex: String) -> IrxPeerEngine {
        if let existing = enginesByPeer[peerHex] { return existing }
        let engine = IrxPeerEngine(
            journal: Self.journal,
            label: String(peerHex.prefix(12))
        ) { [weak self] in
            guard let self else { throw CompositionError.notSignedIn }
            return try await self.dialOnce(peerHex: peerHex)
        }
        enginesByPeer[peerHex] = engine
        return engine
    }

    /// Refuses a dial the device list forbids. FAIL CLOSED only when there
    /// is something to judge: a snapshot exists (entry missing/revoked, or
    /// the whole lease stale). BOOTSTRAP EXCEPTION: when NO directory has
    /// ever been received or restored (fresh install, first ever dial racing
    /// the first control-plane hello), the dial proceeds; the Mac's own list
    /// judge remains the authority that actually admits.
    private func enforceDialGate(peerHex: String) throws {
        guard let snapshot = deviceListBox.current else { return }
        let refuse: (String) -> Void = { reason in
            Self.journal.record(
                "client-dial", "dial-refused",
                ["reason": reason, "peer": String(peerHex.prefix(12))]
            )
        }
        guard snapshot.isFresh(now: .now) else {
            refuse("stale")
            throw DeviceListDialRefusal.staleLease
        }
        guard let entry = snapshot.entries[peerHex] else {
            refuse("absent")
            throw DeviceListDialRefusal.unknownEndpoint
        }
        if entry.revoked {
            refuse("revoked")
            throw IrxAdmissionDenied(code: .revoked)
        }
    }

    /// One dial: cached credentials + ready endpoint, then connect + one
    /// GRANTLESS round-trip admission (the Mac judges our TLS key against
    /// its device list; no pair-grant fetch sits on this path anymore).
    private func dialOnce(peerHex: String) async throws -> IrxClientSession {
        let broker = try await provisionedBroker()
        guard let supervisor = endpointSupervisor, let autopilot else {
            throw CompositionError.notSignedIn
        }
        try enforceDialGate(peerHex: peerHex)
        let credentials = try await autopilot.usableCredentials()
        let dialIntent = dialIntentByPeer[peerHex] ?? .automatic
        let dialNetworkGeneration = await networkPathState.snapshot().generation
        var relayURL: String?
        var directAddresses: [String] = []
        let discoveredRoute: (binding: CmxIrohBrokerBinding, discovery: CmxIrohDiscoveryResponse)?
        switch dialIntent {
        case let .direct(candidates):
            // Port-less Direct candidates may use only the broker's current
            // per-family UDP port. This reads metadata, never a broker path,
            // and still fails closed if no usable pinned address remains.
            let needsPublishedPorts = candidates.contains { $0.port == nil }
            let route = needsPublishedPorts
                ? await refreshRouteFromDiscovery(peerHex: peerHex, broker: broker)
                : nil
            discoveredRoute = route
            directAddresses = Self.directDialAddresses(
                candidates: candidates,
                directPorts: route?.binding.directPorts
            )
            guard !directAddresses.isEmpty else {
                Self.journal.record(
                    "client-dial", "direct-candidates-unusable",
                    ["peer": String(peerHex.prefix(12)), "count": String(candidates.count)]
                )
                throw CompositionError.directDialUnavailable
            }
        case .automatic:
            discoveredRoute = Self.forceRelayOnly
                ? nil
                : await refreshRouteFromDiscovery(peerHex: peerHex, broker: broker)
            relayURL = routesByPeer[peerHex]?.relayURL
            directAddresses = routesByPeer[peerHex]?.directAddresses ?? []
        }
        if !Self.forceRelayOnly,
           case .automatic = dialIntent,
           let discoveredRoute,
           let expectedDeviceID = expectedDeviceIDByPeer[peerHex]
        {
            let authenticatedBindings = discoveredRoute.discovery.bindings.map {
                CmxIrohBrokerBindingMetadata(binding: $0)
            }
            if case let .found(peers) = await lanPeerDiscovery.discover(
                rendezvous: discoveredRoute.discovery.lanRendezvous,
                authenticatedBindings: authenticatedBindings,
                expectedMacDeviceID: expectedDeviceID,
                expectedEndpointID: discoveredRoute.binding.endpointID
            ) {
                var direct = Array(directAddresses.prefix(16))
                var seenDirect = Set(direct)
                for peer in peers
                    where peer.binding.endpointID == discoveredRoute.binding.endpointID
                        && direct.count < 16
                {
                    for hint in peer.pathHints where direct.count < 16 {
                        guard seenDirect.insert(hint.value).inserted else { continue }
                        direct.append(hint.value)
                    }
                }
                directAddresses = direct
                routesByPeer[peerHex] = (relayURL, direct)
                Self.journal.record(
                    "client-dial", "lan-hints-adopted",
                    [
                        "peer": String(peerHex.prefix(12)),
                        "count": String(direct.count),
                    ]
                )
            }
        }
        if !Self.forceRelayOnly,
           case .automatic = dialIntent,
           let discoveredRoute,
           let activeAccountID
        {
            let configured = await customPrivatePaths.enabledPaths(
                forMacDeviceID: discoveredRoute.binding.deviceID,
                instanceTag: discoveredRoute.binding.tag,
                accountID: activeAccountID
            )
            let privateAddresses = CmxIrohCustomPrivatePathBootstrap.dialAddresses(
                configured,
                directPorts: discoveredRoute.binding.directPorts
            )
            if !privateAddresses.isEmpty {
                var seenDirect = Set(directAddresses)
                for address in privateAddresses where directAddresses.count < 16 {
                    guard seenDirect.insert(address).inserted else { continue }
                    directAddresses.append(address)
                }
                routesByPeer[peerHex] = (relayURL, directAddresses)
                Self.journal.record(
                    "client-dial", "private-hints-adopted",
                    [
                        "peer": String(peerHex.prefix(12)),
                        "count": String(privateAddresses.count),
                    ]
                )
            }
        }
        Self.journal.record(
            "client-dial", "target-resolved",
            [
                "peer": String(peerHex.prefix(12)),
                "relay": relayURL ?? "-",
                "direct": String(directAddresses.count),
                "intent": dialIntent == .automatic ? "automatic" : "direct",
            ]
        )
        if case .automatic = dialIntent, relayURL == nil {
            // Stale/missing hint (e.g. the Mac's registered hint lapsed):
            // fall back to our own relay rather than refusing outright; the
            // fleet is small enough that co-homing is common, and a wrong
            // guess fails in one dial timeout instead of stranding the peer.
            relayURL = credentials.first?.relayURL
            Self.journal.record(
                "client-dial", "relay-fallback",
                ["peer": String(peerHex.prefix(12)), "relay": relayURL ?? "-"]
            )
        }
        if case .automatic = dialIntent,
           await networkPathState.snapshot().generation != dialNetworkGeneration
        {
            Self.journal.record(
                "client-dial", "network-path-changed-before-dial",
                ["peer": String(peerHex.prefix(12))]
            )
            invalidateCachedDirectRoutesForNetworkChange()
            throw CompositionError.networkPathChanged
        }
        let address = try supervisor.dialAddress(
            peerEndpointIDHex: peerHex,
            relayURL: relayURL,
            directAddresses: directAddresses
        )
        let connection = try await supervisor.dial(
            address: address, credentials: credentials)
        // Grantless hello v2: no pair-grant fetch or mint precedes the dial.
        // (Old Macs that still require a grant deny with `invalid-grant`;
        // the engine parks until they update - list-auth Macs deploy first.)
        let (admit, control) = try await IrxAdmission.performClient(
            connection: connection,
            journal: Self.journal
        )
        // Credit the server-opened events lane now that admission holds.
        await connection.raiseRemoteStreamCredit(bi: 0, uni: 4)
        // Automatic path mode: authorize NAT traversal so iroh can upgrade
        // this session off the relay make-before-break (direct/LAN paths).
        if !Self.forceRelayOnly, case .automatic = dialIntent {
            await connection.authorizeDirectPaths()
        }
        activeDialIntentByPeer[peerHex] = dialIntent
        return IrxClientSession(
            connection: connection,
            admit: admit,
            control: control,
            establishedAt: Date()
        )
    }

    // MARK: - Seam surface consumed by cmuxApp

    public func serverEventByteStream(
        for request: CmxByteTransportRequest
    ) async throws -> CmxIndependentEventByteStream {
        let peerHex = try peerTarget(for: request)
        let session = try await ensureSession(forPeer: peerHex, trigger: "server-events")
        guard !claimedEventSessions.contains(session.admit.session) else {
            throw CompositionError.unsupportedRoute
        }
        claimedEventSessions.insert(session.admit.session)
        let connection = session.connection
        let journal = Self.journal
        return AsyncThrowingStream { continuation in
            let pump = Task {
                guard
                    let (descriptor, reader) = try await connection.acceptUniLane(),
                    descriptor.lane == .events
                else {
                    journal.record("client-events", "lane-missing")
                    continuation.finish(
                        throwing: IrxConnectionError.closed(nil))
                    return
                }
                journal.record("client-events", "lane-accepted")
                do {
                    while let chunk = try await reader.readRaw() {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                pump.cancel()
            }
        }
    }

    public func openTerminalLane(
        for request: CmxByteTransportRequest,
        surfaceID: UUID,
        cursor: UInt64? = nil
    ) async throws -> MobileIrohTerminalLane {
        let peerHex = try peerTarget(for: request)
        let session = try await ensureSession(forPeer: peerHex, trigger: "terminal-lane")
        let lane = try await session.connection.openLane(
            IrxLaneDescriptor(
                lane: .terminal,
                resource: "terminal:\(surfaceID.uuidString.lowercased())",
                cursor: cursor
            )
        )
        Self.journal.record(
            "client-terminal", "lane-opened",
            [
                "surface": surfaceID.uuidString.lowercased(),
                "cursor": cursor.map(String.init) ?? "-",
            ]
        )
        return MobileIrohTerminalLane(stream: lane.bidirectional())
    }

    public func openArtifactLane(
        for request: CmxByteTransportRequest,
        resourceID: String,
        offset: UInt64
    ) async throws -> any MobileArtifactLaneConnection {
        let peerHex = try peerTarget(for: request)
        let session = try await ensureSession(forPeer: peerHex, trigger: "artifact-lane")
        let lane = try await session.connection.openLane(
            IrxLaneDescriptor(lane: .artifact, resource: resourceID, offset: offset)
        )
        return IrxArtifactLane(lane: lane)
    }

    public func openSimulatorStreamLane(
        for request: CmxByteTransportRequest,
        panelID: UUID
    ) async throws -> MobileIrohSimulatorStreamLane {
        let peerHex = try peerTarget(for: request)
        let session = try await ensureSession(
            forPeer: peerHex,
            trigger: "simulator-stream-lane"
        )
        // Same legacy resource dialect the terminal lane uses; the Mac's
        // dialect server routes it to MobileHostIrohSimulatorStreamLaneHandler.
        let lane = try await session.connection.openLane(
            IrxLaneDescriptor(
                lane: .simulatorStream,
                resource: "simstream:\(panelID.uuidString.lowercased())"
            )
        )
        Self.journal.record(
            "client-simstream", "lane-opened",
            ["panel": panelID.uuidString.lowercased()]
        )
        return MobileIrohSimulatorStreamLane(stream: lane.bidirectional())
    }

    /// The deferred transport the RPC layer connects through. Each RPC client
    /// generation claims one admitted session's control lane and releases that
    /// claim when the transport closes.
    public func transport(
        for request: CmxByteTransportRequest
    ) async throws -> any CmxByteTransport {
        let peerHex = try peerTarget(for: request)
        let ownerID = UUID()
        return IrxControlByteTransport(
            closeCode: .explicitRedial,
            establish: { [weak self] in
                guard let self else {
                    throw CompositionError.notSignedIn
                }
                return try await self.claimControlLane(
                    peerHex: peerHex,
                    ownerID: ownerID
                )
            },
            onClose: { [weak self] in
                await self?.releaseControlLane(ownerID: ownerID)
            }
        )
    }

    private func claimControlLane(
        peerHex: String,
        ownerID: UUID
    ) async throws -> (IrxConnection, IrxLaneStream) {
        let session = try await ensureSession(forPeer: peerHex, trigger: "control-transport")
        guard controlLaneClaims.claim(
            sessionID: session.admit.session,
            ownerID: ownerID
        ) else {
            // One admitted session exposes one control lane. Returning a
            // transient closed error lets the caller's bounded retry policy
            // wait for the current owner to drain, while preserving the
            // healthy QUIC session for the current owner.
            Self.journal.record(
                "client-runtime", "control-lane-busy",
                ["peer": peerHex.prefix(12).lowercased()]
            )
            throw IrxConnectionError.closed(nil)
        }
        return (session.connection, session.control)
    }

    private func releaseControlLane(ownerID: UUID) {
        controlLaneClaims.release(ownerID: ownerID)
    }
}

/// Artifact lane over irx: bounded reads down, no upstream bytes.
struct IrxArtifactLane: MobileArtifactLaneConnection {
    let lane: IrxLaneStream

    func receive(maximumByteCount: Int) async throws -> Data? {
        try await lane.reader.readRaw(maximumByteCount: maximumByteCount)
    }

    func close() async {
        await lane.close()
    }
}

extension MobileIrxRuntimeComposition: CmxIrohDeferredTransportProviding {}
