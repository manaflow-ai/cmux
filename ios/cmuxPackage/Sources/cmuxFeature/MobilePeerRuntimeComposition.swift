import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileRPC
import CmuxMobileShell
import CmuxMobileTransport
import CmuxPeerTransport
import CmuxPeerTransportCore
import Foundation
import OSLog

nonisolated let mobilePeerLog = Logger(
    subsystem: "dev.cmux.ios",
    category: "peer-runtime"
)

/// Source-compatibility alias: the composition root and app target keep the
/// historical type name while the implementation runs on CmuxPeerTransport.
public typealias MobileIrohRuntimeComposition = MobilePeerRuntimeComposition

/// The account/relay/policy state published by one successful endpoint
/// activation, consumed by Settings snapshots and the transport layer.
struct MobilePeerActivationState: Sendable {
    let accountID: String
    let deviceID: String
    let appInstanceID: String
    let binding: PeerBrokerBinding
    let endpointID: CmxIrohPeerIdentity
    let identityGeneration: Int
    /// Relay URLs actually applied to the endpoint (post policy filtering).
    let relayURLs: [String]
    /// Managed catalog rows for Settings (id/provider/region/url).
    let managedRelayCatalog: [MobilePeerManagedRelayInfo]
    let policy: MobilePeerRelayPolicyState
    let generation: PeerTransportGeneration
}

struct MobilePeerManagedRelayInfo: Sendable, Equatable {
    let id: String
    let provider: String
    let region: String
    let url: String
}

struct MobilePeerRelayPolicyState: Sendable, Equatable {
    enum Source: Sendable, Equatable {
        case server
        case cached
        case unavailable
    }

    let source: Source
    let sequence: Int64?
    let expiresAt: Date?

    static let unavailable = MobilePeerRelayPolicyState(
        source: .unavailable,
        sequence: nil,
        expiresAt: nil
    )
}

/// Process-owned iOS composition for account-scoped peer networking, built on
/// `CmuxPeerTransport`. One `PeerEndpointManager` exists per process; its
/// activation lifecycle (identity, broker registration behind the cooldown
/// ledger, relay policy resolve plus token mint, endpoint bind, level-triggered
/// rebuild on watchdog death) is owned by one `PeerConnectionSupervisor` whose
/// "session" is the active endpoint runtime.
@MainActor
public final class MobilePeerRuntimeComposition:
    MobileIrohMacDiscovering,
    MobileIrohMacForgetting
{
    enum SettingsError: Error, Equatable {
        case unavailable
        case incompleteCustomRelay
        case missingCustomRelay
        case unavailableCustomPrivatePath
    }

    nonisolated static let capabilities = ["mobile-rpc-v1", "multistream-v1"]

    // MARK: - Immutable configuration

    let clientNamespace: String
    let tag: String
    let discoveryCompatibilityPolicy: MobileMacBuildCompatibilityPolicy?
    let brokerBaseURL: URL?
    let relayPolicyTrustRoot: PeerRelayPolicyTrustRoot?
    /// The app defaults handle, retained under its existing DEBUG-era name.
    let debugDefaults: UserDefaults?
    let now: @Sendable () -> Date
    let diagnosticLog: DiagnosticLog?
    /// Resolves the durable device id at activation time, or `nil` when the
    /// durable identity store is unavailable. Re-read on every activation.
    let deviceID: @Sendable () async -> String?
    private let startNetworkPathObservation: @Sendable (
        _ onPathChange: @escaping @Sendable () async -> Void
    ) async -> Void

    // MARK: - Engine collaborators (one per process)

    let endpointManager: PeerEndpointManager
    let dialer: PeerConnectionDialer
    /// Account-scoped broker rate-limit floors that outlive endpoint teardown.
    let cooldownLedger: PeerBrokerCooldownLedger
    let identities: PeerIdentityRepository
    let offlineGrants: PeerOfflineGrantCache
    let relayPolicyCache: PeerRelayPolicyCache
    let appInstances: MobilePeerAppInstanceRegistry
    private(set) var supervisor: PeerConnectionSupervisor!
    private let activator: MobilePeerEndpointActivator

    // MARK: - Public composition surface

    /// Broker-verified personal-account Mac routes and live discovery candidates.
    public let routeCatalog: MobileIrohRouteCatalog

    /// The stable factory registered before debug-loopback and Tailscale fallbacks.
    public lazy var transportFactory = MobilePeerDeferredTransportFactory(provider: self)

    // MARK: - Live state (MainActor)

    private(set) weak var auth: AuthCoordinator?
    private(set) var transportVerificationMode: CmxIrohTransportVerificationMode
    var observedAuthState: MobileIrohAuthState?
    var observedAccountID: String? { observedAuthState?.accountID }
    /// Published by the endpoint activator after each successful activation.
    private(set) var activation: MobilePeerActivationState?
    private(set) var supervisorState = PeerConnectionSupervisorState.idle
    private(set) var lastActivationFailureKind: DiagnosticFailureKind?
    private(set) var lastActivationFailureDescription: String?
    private(set) var lastActivationRetryAfterSeconds: Int?
    var lifecycleRevision: UInt64 = 0
    var irohSettingsContinuations: [UUID: AsyncStream<CmxIrohSettingsSnapshot>.Continuation] = [:]
    let diagnosticArchive = DiagnosticReportArchive.defaultArchive()
    var previousLaunchDiagnosticReport: DiagnosticReport??
    var requiresFullForegroundRefreshOnNextActive = true
    private var authObservationTask: Task<Void, Never>?
    var permissionRefreshTask: Task<Void, Never>?
    private let authObserver = MobileIrohAuthObserver()
    /// Per-account-runtime verified-discovery reuse window for client dials.
    var discoveryProvider: PeerDiscoveryContextProvider?
    /// The authenticated broker client owned by the current endpoint runtime.
    var accountBroker: PeerTrustBrokerClient?
    /// Live admitted sessions keyed by remote endpoint id (see +Transport).
    var sessionsByEndpointID: [String: MobilePeerSessionBox] = [:]
    var sessionTasksByEndpointID: [String: Task<MobilePeerSessionBox, any Error>] = [:]
    /// One shared sign-out preparation per attempt (see +SignOut).
    var signOutOperation: Task<MobilePeerSignOutPreparation, Never>?
    var signOutInProgress = false

    // MARK: - Init

    /// Creates the production iOS peer composition with device-only persistence.
    ///
    /// - Parameters:
    ///   - apiBaseURL: The authenticated cmux web API origin.
    ///   - reachability: The process-wide network path observer.
    ///   - defaults: This app installation's defaults domain.
    ///   - infoDictionary: Build metadata used to derive tagged-build scope.
    ///   - bundleIdentifier: The installed app identifier used as a scope fallback.
    public convenience init(
        apiBaseURL: String,
        reachability: any ReachabilityProviding,
        discoveryCompatibilityPolicy: MobileMacBuildCompatibilityPolicy? = nil,
        defaults: UserDefaults = .standard,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appNamespace injectedAppNamespace: MobileIOSAppNamespace? = nil,
        keychainAccessGroup injectedKeychainAccessGroup: String? = nil,
        diagnosticLog: DiagnosticLog? = nil
    ) {
        guard let appNamespace = injectedAppNamespace
            ?? MobileIOSAppNamespace(bundleIdentifier: bundleIdentifier)
        else {
            preconditionFailure("cmux iOS requires a valid bundle identifier")
        }
        let keychainAccessGroup = MobilePeerKeychainAccessGroupValidator.entitledGroup(
            injectedKeychainAccessGroup
                ?? Self.keychainAccessGroup(infoDictionary: infoDictionary)
        )
        #if DEBUG
        let transportVerificationMode = Self.initialTransportVerificationMode(
            defaults: defaults
        )
        #else
        let transportVerificationMode = CmxIrohTransportVerificationMode.automatic
        #endif
        #if targetEnvironment(simulator)
        let allowsLoopbackBrokerOrigin = true
        #else
        let allowsLoopbackBrokerOrigin = false
        #endif
        let baseURL = Self.resolvedBrokerBaseURL(
            apiBaseURL: apiBaseURL,
            infoDictionary: infoDictionary,
            bundleIdentifier: bundleIdentifier,
            allowsLoopback: allowsLoopbackBrokerOrigin
        )
        let durableDeviceIDResolver = MobilePeerDurableDeviceIDResolver(
            defaults: MobilePeerSendableDefaults(defaults),
            appNamespace: appNamespace,
            keychainAccessGroup: keychainAccessGroup
        )
        self.init(
            brokerBaseURL: baseURL,
            identities: PeerIdentityRepository(
                secureStore: Self.identityStore(appNamespace: appNamespace),
                installState: PeerUserDefaultsInstallStateStore(defaults: defaults)
            ),
            offlineGrants: PeerOfflineGrantCache(
                secureStore: Self.credentialStore(
                    service: "client-offline-policy",
                    appNamespace: appNamespace
                )
            ),
            relayPolicyCache: PeerRelayPolicyCache(
                store: MobilePeerRelayPolicyRecordStore(
                    store: Self.credentialStore(
                        service: "relay-policy",
                        appNamespace: appNamespace
                    )
                )
            ),
            appInstances: MobilePeerAppInstanceRegistry(
                store: PeerUserDefaultsInstallStateStore(defaults: defaults)
            ),
            relayPolicyTrustRoot: Self.relayPolicyTrustRoot(
                infoDictionary: infoDictionary
            ),
            transportVerificationMode: transportVerificationMode,
            deviceID: { await durableDeviceIDResolver.resolve() },
            clientNamespace: appNamespace.bundleIdentifier,
            tag: Self.currentTag(
                infoDictionary: infoDictionary,
                bundleIdentifier: bundleIdentifier
            ),
            discoveryCompatibilityPolicy: discoveryCompatibilityPolicy,
            now: { Date() },
            startNetworkPathObservation: { onPathChange in
                let changes = reachability.pathChanges()
                Task {
                    for await _ in changes {
                        await onPathChange()
                    }
                }
            },
            diagnosticLog: diagnosticLog,
            debugDefaults: defaults
        )
    }

    init(
        brokerBaseURL: URL?,
        endpointManager: PeerEndpointManager = PeerEndpointManager(),
        identities: PeerIdentityRepository = PeerIdentityRepository(),
        offlineGrants: PeerOfflineGrantCache = PeerOfflineGrantCache(),
        relayPolicyCache: PeerRelayPolicyCache = PeerRelayPolicyCache(
            store: MobilePeerInMemoryRelayPolicyStore()
        ),
        appInstances: MobilePeerAppInstanceRegistry = MobilePeerAppInstanceRegistry(
            store: PeerUserDefaultsInstallStateStore()
        ),
        cooldownLedger: PeerBrokerCooldownLedger = PeerBrokerCooldownLedger(),
        relayPolicyTrustRoot: PeerRelayPolicyTrustRoot? = nil,
        transportVerificationMode: CmxIrohTransportVerificationMode = .automatic,
        brokerClientFactory: MobilePeerEndpointActivator.BrokerClientFactory? = nil,
        deviceID: @escaping @Sendable () async -> String?,
        clientNamespace: String = "legacy",
        tag: String,
        discoveryCompatibilityPolicy: MobileMacBuildCompatibilityPolicy? = nil,
        now: @escaping @Sendable () -> Date,
        routeCatalog: MobileIrohRouteCatalog = MobileIrohRouteCatalog(),
        startNetworkPathObservation: @escaping @Sendable (
            _ onPathChange: @escaping @Sendable () async -> Void
        ) async -> Void = { _ in },
        backoffProfile: PeerReconnectBackoff.Profile = .foregroundClient,
        diagnosticLog: DiagnosticLog? = nil,
        debugDefaults: UserDefaults? = nil
    ) {
        self.brokerBaseURL = brokerBaseURL
        self.endpointManager = endpointManager
        self.dialer = PeerConnectionDialer(manager: endpointManager)
        self.identities = identities
        self.offlineGrants = offlineGrants
        self.relayPolicyCache = relayPolicyCache
        self.appInstances = appInstances
        self.cooldownLedger = cooldownLedger
        self.relayPolicyTrustRoot = relayPolicyTrustRoot
        self.transportVerificationMode = transportVerificationMode
        self.deviceID = deviceID
        self.clientNamespace = clientNamespace
        self.tag = tag
        self.discoveryCompatibilityPolicy = discoveryCompatibilityPolicy
        self.now = now
        self.routeCatalog = routeCatalog
        self.startNetworkPathObservation = startNetworkPathObservation
        self.diagnosticLog = diagnosticLog
        self.debugDefaults = debugDefaults
        let activator = MobilePeerEndpointActivator(
            brokerClientFactory: brokerClientFactory
        )
        self.activator = activator
        activator.composition = self
        self.supervisor = PeerConnectionSupervisor(
            establisher: activator,
            backoffProfile: backoffProfile,
            onStateChange: { [weak self, diagnosticLog] state in
                Task { @MainActor [weak self] in
                    self?.supervisorStateChanged(state)
                }
                if case .waitingToRetry = state {
                    diagnosticLog?.record(DiagnosticEvent(
                        .retryScheduled,
                        a: DiagnosticTransportKind.iroh.rawValue
                    ))
                }
            }
        )
    }

    // MARK: - Configuration

    /// Starts auth observation after the coordinator's launch restore completes.
    ///
    /// - Parameters:
    ///   - auth: The process-owned authentication coordinator.
    ///   - connectivityInvalidationBaseURL: Accepted for source compatibility.
    ///     The server-push connectivity-invalidation channel is deferred in the
    ///     peer-transport composition; presence pushes still invalidate
    ///     discovery through ``invalidateDiscovery(forMacDeviceID:)``.
    public func configure(
        auth: AuthCoordinator,
        connectivityInvalidationBaseURL: URL? = nil
    ) {
        _ = connectivityInvalidationBaseURL
        self.auth = auth
        authObservationTask?.cancel()
        authObservationTask = Task { @MainActor [weak self, weak auth] in
            guard let auth else { return }
            await self?.startNetworkPathObservation({ [weak self] in
                // A path change is fresh network state: the supervisor resets
                // its ladder on this trigger and collapses any retry wait.
                await self?.supervisor.note(trigger: .networkPathChanged)
            })
            await auth.awaitBootstrapped()
            guard !Task.isCancelled, let self else { return }
            let states = self.authObserver.states(for: auth)
            for await state in states {
                guard !Task.isCancelled else { return }
                await self.applyAuthState(state)
            }
        }
    }

    // MARK: - Auth lifecycle

    private func applyAuthState(_ state: MobileIrohAuthState) async {
        let previous = observedAuthState
        observedAuthState = state
        guard previous?.accountID != state.accountID else {
            // Same account: make sure a signed-in account has a live attempt.
            if state.accountID != nil, !signOutInProgress {
                await supervisor.note(trigger: .launch)
            }
            return
        }
        await switchAccount(
            to: state.accountID,
            eraseAccountState: state.accountID == nil || previous?.accountID != nil
        )
    }

    func reconcileLiveAuthIfNeeded() async {
        guard let auth else { return }
        await auth.awaitBootstrapped()
        let state = MobileIrohAuthState(
            accountID: auth.isAuthenticated ? auth.currentUser?.id : nil
        )
        await applyAuthState(state)
    }

    /// Tears down the previous account runtime and starts the new one.
    func switchAccount(to accountID: String?, eraseAccountState: Bool) async {
        lifecycleRevision &+= 1
        let revision = lifecycleRevision
        await closeAllSessions(reason: "account change")
        await supervisor.shutDown(reason: "account change")
        discoveryProvider = nil
        clearActivationState()
        diagnosticLog?.record(DiagnosticEvent(
            .endpointStopped,
            a: DiagnosticTransportKind.iroh.rawValue
        ))
        if eraseAccountState {
            await wipeLocalState()
            diagnosticArchive?.clear()
            previousLaunchDiagnosticReport = .some(nil)
        }
        guard let accountID, !signOutInProgress else {
            await routeCatalog.clear()
            publishIrohSettingsUpdate()
            return
        }
        _ = accountID
        await routeCatalog.activate(scope: revision)
        await supervisor.noteAuthorizationRestored()
        await supervisor.note(trigger: .launch)
        publishIrohSettingsUpdate()
    }

    func wipeLocalState() async {
        await routeCatalog.clear()
        try? await identities.deactivate()
        try? await offlineGrants.deactivate()
        try? await relayPolicyCache.deactivate()
        await appInstances.deactivate()
        if let accountID = observedAccountID ?? activation?.accountID {
            await cooldownLedger.clear(key: .init(accountID: accountID))
        }
    }

    // MARK: - Readiness

    /// Waits for the authenticated endpoint, broker binding, and relay plan.
    ///
    /// Tagged attach-URL launches use this barrier before starting the shell's
    /// bounded pairing attempt. Transport creation calls the same entrypoint,
    /// so readiness policy cannot drift between automatic and interactive use.
    public func prepareForConnection() async {
        await reconcileLiveAuthIfNeeded()
        await ensureSupervisorStarted()
        _ = await supervisor.awaitSettled()
    }

    /// Nudges the supervisor when an account is observed and no session/attempt
    /// exists. Automatic triggers join an in-flight attempt and are satisfied
    /// by a live runtime, so calling this repeatedly is churn-safe; the broker
    /// cooldown ledger keeps forced retries away from the server.
    private func ensureSupervisorStarted() async {
        guard observedAccountID != nil, !signOutInProgress else { return }
        await supervisor.note(trigger: .launch)
    }

    /// Throws the standard retry-aware failure when no endpoint runtime is up.
    func requireReadyRuntime() async throws -> MobilePeerActivationState {
        await reconcileLiveAuthIfNeeded()
        await ensureSupervisorStarted()
        _ = await supervisor.awaitSettled()
        if let activation, supervisorState == .ready {
            return activation
        }
        throw await preparationFailure()
    }

    func preparationFailure() async -> MobilePeerRuntimePreparationError {
        var retryAfterSeconds = lastActivationRetryAfterSeconds ?? 1
        var failureKind = lastActivationFailureKind ?? .endpointUnavailable
        if observedAccountID == nil {
            failureKind = .authorizationFailed
        }
        if case let .denied(reason) = supervisorState {
            failureKind = .authorizationFailed
            _ = reason
        }
        if let accountID = observedAccountID,
           let cooldown = await cooldownLedger.activeCooldown(
               key: .init(accountID: accountID)
           ) {
            retryAfterSeconds = max(
                retryAfterSeconds,
                Int(cooldown.components.seconds) + 1
            )
        }
        return MobilePeerRuntimePreparationError(
            diagnosticFailureKind: failureKind,
            retryAfterSeconds: max(1, retryAfterSeconds)
        )
    }

    // MARK: - Discovery

    /// Refreshes the current account runtime and returns its live pairable Macs.
    ///
    /// The catalog keeps cached bindings in a separate route-only view, so this
    /// method can never turn an offline cache entry into a first pairing.
    public func discoverLiveMacs() async -> [MobileDiscoveredIrohMac] {
        diagnosticLog?.record(DiagnosticEvent(
            .discoveryStarted,
            a: DiagnosticTransportKind.iroh.rawValue
        ))
        await reconcileLiveAuthIfNeeded()
        _ = await supervisor.awaitSettled()
        guard let activation, let discoveryProvider else {
            diagnosticLog?.record(DiagnosticEvent(
                .discoveryFailed,
                a: DiagnosticTransportKind.iroh.rawValue,
                b: (lastActivationFailureKind ?? .endpointUnavailable).rawValue
            ))
            return []
        }
        let revision = lifecycleRevision
        await discoveryProvider.invalidateAll()
        do {
            let snapshot = try await freshDiscoverySnapshot(activation: activation)
            guard revision == lifecycleRevision else { return [] }
            await routeCatalog.replace(with: snapshot, scope: revision)
        } catch {
            guard revision == lifecycleRevision else { return [] }
            await routeCatalog.clearLiveMacCandidates(scope: revision)
            diagnosticLog?.record(DiagnosticEvent(
                .discoveryFailed,
                a: DiagnosticTransportKind.iroh.rawValue,
                b: DiagnosticFailureKind.classify(error).rawValue
            ))
            return []
        }
        let candidates = await routeCatalog.liveMacCandidates(
            preferredTag: tag,
            compatibleWith: discoveryCompatibilityPolicy
        )
        recordDiscoveryOutcome(candidateCount: candidates.count)
        return candidates
    }

    /// Drops reusable broker discovery state for one Mac after a presence
    /// route push, so the next dial rebuilds its plan from a fresh snapshot
    /// instead of redialing the Mac's pre-relaunch route state.
    public func invalidateDiscovery(forMacDeviceID deviceID: String) async {
        await discoveryProvider?.invalidate(macDeviceID: cmxCanonicalDeviceID(deviceID))
        await supervisor.note(trigger: .presencePush)
    }

    private func recordDiscoveryOutcome(candidateCount: Int) {
        if candidateCount > 0 {
            diagnosticLog?.record(DiagnosticEvent(
                .discoverySucceeded,
                a: DiagnosticTransportKind.iroh.rawValue
            ))
        } else {
            diagnosticLog?.record(DiagnosticEvent(
                .discoveryFailed,
                a: DiagnosticTransportKind.iroh.rawValue,
                b: DiagnosticFailureKind.noRoute.rawValue
            ))
        }
    }

    // MARK: - Engine state publication (called by the activator)

    func supervisorStateChanged(_ state: PeerConnectionSupervisorState) {
        supervisorState = state
        if case .ready = state {
            lastActivationFailureKind = nil
            lastActivationFailureDescription = nil
            lastActivationRetryAfterSeconds = nil
        }
        publishIrohSettingsUpdate()
    }

    func publishActivation(_ state: MobilePeerActivationState) {
        activation = state
        lastActivationFailureKind = nil
        lastActivationFailureDescription = nil
        lastActivationRetryAfterSeconds = nil
        publishIrohSettingsUpdate()
    }

    func publishActivationFailure(
        kind: DiagnosticFailureKind,
        description: String,
        retryAfterSeconds: Int?
    ) {
        lastActivationFailureKind = kind
        lastActivationFailureDescription = description
        lastActivationRetryAfterSeconds = retryAfterSeconds
        publishIrohSettingsUpdate()
        #if DEBUG
        // Dev diagnosability: the coded logs flatten transient reasons, and
        // device os_log does not reliably reach the syslog relay. Keep the
        // latest exact reason in a pullable file beside the network log.
        if let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            let stamp = ISO8601DateFormatter().string(from: Date())
            try? Data("\(stamp) \(kind) \(description)\n".utf8).write(
                to: support.appendingPathComponent("cmux-activation-failure.txt"),
                options: [.atomic]
            )
        }
        #endif
    }

    func clearActivationState() {
        activation = nil
    }

    /// Test seam: drives the composition's observed account without a live
    /// `AuthCoordinator`. Production account changes flow through
    /// ``configure(auth:connectivityInvalidationBaseURL:)`` observation.
    func setObservedAuthStateForTesting(accountID: String?) {
        observedAuthState = MobileIrohAuthState(accountID: accountID)
    }

    /// The current activation inputs the establisher snapshots per attempt.
    func activationInputs() -> MobilePeerActivationInputs? {
        guard let accountID = observedAccountID, !signOutInProgress else {
            return nil
        }
        return MobilePeerActivationInputs(
            accountID: accountID,
            tag: tag,
            clientNamespace: clientNamespace,
            transportVerificationMode: transportVerificationMode,
            lifecycleRevision: lifecycleRevision,
            discoveryPeerTags: Self.discoveryPeerTags(
                for: discoveryCompatibilityPolicy
            )
        )
    }

    /// Applies a verification-mode change through ONE endpoint rebind without
    /// identity rotation: the supervisor replaces the endpoint runtime, and the
    /// next activation reads the new mode.
    func applyTransportVerificationMode(
        _ mode: CmxIrohTransportVerificationMode
    ) async {
        guard transportVerificationMode != mode else { return }
        transportVerificationMode = mode
        publishIrohSettingsUpdate()
        guard observedAccountID != nil else { return }
        await closeAllSessions(reason: "transport mode changed")
        await supervisor.note(trigger: .connectionMethodChanged)
        _ = await supervisor.awaitSettled()
    }
}
