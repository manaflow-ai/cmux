import CMUXMobileCore
import CmuxAuthRuntime
public import CmuxIrohTransport
import CmuxMobileRPC
import CmuxMobileShell
import CmuxMobileTransport
import CryptoKit
import Foundation
import OSLog

nonisolated private let mobileIrohLog = Logger(
    subsystem: "dev.cmux.ios",
    category: "iroh-runtime"
)

/// Resume-once guard for the forget deadline race: whichever racer claims
/// first owns the continuation, and the loser's late completion is discarded.
private actor MobileIrohForgetRaceGate {
    private var claimed = false

    func claim() -> Bool {
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Keeps synchronous Keychain and defaults work off the UI actor while
/// serializing concurrent activation reads through one identity owner.
///
/// `UserDefaults` documents its API as thread-safe but does not conform to
/// `Sendable`. Keep the unchecked boundary private and pass only this owner
/// across the actor boundary.
private final class MobileIrohSendableDefaults: @unchecked Sendable {
    let value: UserDefaults

    init(_ value: UserDefaults) {
        self.value = value
    }
}

/// Resolves the durable device id off the MainActor: the witness
/// (`identifierForVendor`) is captured with one cheap MainActor hop, then the
/// Keychain reads/writes, the defaults mirror, and the continuity probe all
/// run on this actor's executor so activation never blocks app UI on Keychain
/// service latency.
private actor MobileIrohDurableDeviceIDResolver {
    private let defaults: MobileIrohSendableDefaults
    private let appNamespace: MobileIOSAppNamespace
    private let keychainAccessGroup: String?

    init(
        defaults: MobileIrohSendableDefaults,
        appNamespace: MobileIOSAppNamespace,
        keychainAccessGroup: String?
    ) {
        self.defaults = defaults
        self.appNamespace = appNamespace
        self.keychainAccessGroup = keychainAccessGroup
    }

    func resolve() async -> String? {
        let witness = await DeviceRegistryService.currentDeviceWitness()
        return appNamespace.durableDeviceRegistryDeviceID(
            keychainAccessGroup: keychainAccessGroup,
            defaults: defaults.value,
            deviceWitness: witness,
            evidence: MobileIrohRuntimeComposition.sameDeviceEvidenceProbe(
                bundleIdentifier: appNamespace.bundleIdentifier
            )
        )
    }
}

#if DEBUG
/// DEBUG same-device evidence: dev builds keep iroh endpoint identities in a
/// development FILE store, not the Keychain, so continuity is proven by any
/// record in that store. The filesystem is always readable, so the verdict is
/// two-state (never `.unavailable`).
struct MobileIrohDevelopmentFileEvidenceProbe: SameDeviceEvidenceProbing {
    let bundleIdentifier: String?

    func probe() -> SameDeviceEvidence {
        #if targetEnvironment(simulator)
        // The dev launcher seeds a deterministic UserDefaults mirror because
        // unsigned Simulator apps cannot read Keychain. A Simulator cannot be
        // the destination of an iPhone backup restore, so that mirror is local
        // same-device evidence even before the development identity file exists.
        return .present
        #else
        let exists = CmxIrohDevelopmentFileIdentityStore(
            directory: MobileIrohRuntimeComposition.developmentStoreDirectory(
                service: "identity",
                bundleIdentifier: bundleIdentifier
            )
        ).containsAnyRecord()
        return exists ? .present : .absent
        #endif
    }
}
#endif

/// Process-owned iOS composition for account-scoped Iroh networking.
@MainActor
public final class MobileIrohRuntimeComposition:
    CmxIrohDeferredTransportProviding,
    MobileIrohMacDiscovering,
    MobileIrohMacForgetting
{
    enum SettingsError: Error, Equatable {
        case unavailable
        case incompleteCustomRelay
        case missingCustomRelay
        case unavailableCustomPrivatePath
    }
    typealias BrokerFactory = @Sendable (
        _ tokenSource: CmxIrohBrokerTokenSource,
        _ bindingAuthorization: CmxIrohBindingRequestAuthorization?,
        _ discoveryScope: CmxConnectivityDiscoveryScope?
    ) throws -> any CmxIrohClientBrokerServing

    private struct BrokerBundle {
        let client: any CmxIrohClientBrokerServing
        let relayPolicy: (any CmxIrohRelayPolicyServing)?
    }

    private enum SignOutPhase {
        case idle
        case preparing(Task<CmxIrohClientSignOutPreparation, Never>)
        case awaitingRemote(CmxIrohClientSignOutPreparation)
        case quarantined(CmxIrohClientSignOutPreparation)
        case recovering(
            CmxIrohClientSignOutPreparation,
            Task<SignOutRecoveryOutcome, Never>
        )

        var allowsLifecycle: Bool {
            if case .idle = self { return true }
            return false
        }
    }

    private enum SignOutRecoveryOutcome: Equatable, Sendable {
        case revoked
        case durablyQueued
        case notDurable

        var canReleaseQuarantine: Bool {
            self != .notDurable
        }
    }

    private enum ReconcileOutcome {
        case inactive
        case ready
        case failed(any Error)
    }

    private static let capabilities = ["mobile-rpc-v1", "multistream-v1"]
    /// The stable factory registered before debug-loopback and Tailscale fallbacks.
    public lazy var transportFactory = CmxConnectivityDeferredTransportFactory(
        provider: self
    )

    /// Broker-verified personal-account Mac routes and live discovery candidates.
    public let routeCatalog: MobileIrohRouteCatalog

    private let appInstances: CmxIrohAppInstanceRepository
    private let identities: CmxIrohIdentityRepository
    private let brokerCredentials: CmxIrohBrokerCredentialRepository
    private let pendingRevocations: CmxIrohPendingRevocationOutbox
    private let offlinePolicies: CmxIrohClientOfflinePolicyCache
    private let customRelayProfiles: CmxIrohCustomRelayProfileStore?
    private let relayPolicyCache: CmxIrohRelayPolicyCache
    private let relayPreferenceStore: CmxIrohRelayPreferenceStore
    private let customRelayCredentials: CmxIrohCustomRelayCredentialStore
    private let customPrivatePaths: CmxIrohCustomPrivatePathStore
    private let networkPathSnapshotComposer: CmxIrohNetworkPathSnapshotComposer
    private let relayPolicyTrustRoot: CmxIrohRelayPolicyTrustRoot?
    private let endpointFactoryProvider:
        @MainActor (CmxIrohTransportVerificationMode) -> any CmxIrohEndpointFactory
    private var transportVerificationMode: CmxIrohTransportVerificationMode
    private let automaticRelayCredentialRefreshEnabled: Bool
    /// The app defaults handle, retained under its existing DEBUG-era name.
    private let debugDefaults: UserDefaults?
    private let brokerFactory: BrokerFactory
    private let brokerBackpressureGate: CmxIrohBrokerBackpressureGate
    /// Resolves the durable device id at activation time, or `nil` when the
    /// durable identity store is unavailable (Keychain locked before first
    /// unlock, or a persistent write failure). Re-read on every activation
    /// rather than captured once at init: a value captured while the store was
    /// unavailable would be an ephemeral throwaway id, and registering a binding
    /// under it would orphan the retained `(user, device, tag)` binding. When
    /// this returns `nil`, activation defers and retries on the next reconcile.
    private let deviceID: @Sendable () async -> String?
    private let clientNamespace: String
    private let tag: String
    private let discoveryCompatibilityPolicy: MobileMacBuildCompatibilityPolicy?
    private let now: @Sendable () -> Date
    private let startNetworkPathObservation: @Sendable (
        _ onPathChange: @escaping @Sendable () async -> Void
    ) async -> Void
    /// Shared client backoff armed by a failed activation. While armed, dial
    /// and preparation churn cannot re-run registration, discovery, and
    /// relay-policy against the broker; field phones wedged in that loop sent
    /// mutation requests every 2-10 seconds for 40+ hours.
    private let activationRetryBackoff: CmxIrohReconnectBackoff
    /// Fresh per-lifecycle ladder for the relay-policy refresh loop, sharing
    /// the activation ladder's foreground bounds but not its failure streak.
    private let makeRelayPolicyRefreshBackoff: @Sendable () -> CmxIrohReconnectBackoff
    private var activationRetryAt: Date?
    private var activationBackoffAccountID: String?
    /// Safe failure category paired with the shared activation backoff window.
    /// Timing remains owned exclusively by ``activationRetryBackoff``.
    private var activationFailureKind: DiagnosticFailureKind?
    private let networkPathSnapshot: @Sendable () async throws -> CmxIrohNetworkPathSnapshot
    private let lanPeerDiscovery: CmxIrohLANPeerDiscovery?
    /// Shared release-safe event ring. Its event schema has no string payloads,
    /// so runtime failures cannot leak peer identities, routes, or credentials.
    private let diagnosticLog: DiagnosticLog?
    private let authObserver = MobileIrohAuthObserver()

    private weak var auth: AuthCoordinator?
    private var connectivityInvalidationSubscriber:
        CmxConnectivityInvalidationSubscriber?
    private var connectivityInvalidationAccountID: String?
    private var authObservationTask: Task<Void, Never>?
    private var transitionTask: Task<Void, Never>?
    private let connectionReadiness: MobileIrohConnectionReadinessOwner
    private var sceneTransitionTask: Task<Void, Never>?
    private var permissionRefreshTask: Task<Void, Never>?
    /// A scene can become inactive for system UI without ever entering the
    /// background. Only a cold activation or a return from `.background`
    /// should revalidate auth and restart foreground networking.
    private var requiresFullForegroundRefreshOnNextActive = true
    // Internal read access lets the dedicated DEBUG-only release-gate
    // extension inspect the exact runtime without shipping test entrypoints on
    // this production composition type. Runtime ownership remains private.
    private(set) var runtime: CmxIrohClientRuntime?
    private var relayPolicyService: CmxIrohRelayPolicyService?
    private var relayPolicyEffective: CmxIrohEffectiveRelayPolicy?
    private var relayPolicyDiagnostics: CmxIrohRelayDiagnosticsSnapshot?
    private var relayPolicyEndpointID: CmxIrohPeerIdentity?
    private var relayPolicyObservationTask: Task<Void, Never>?
    private var relayPolicyRefreshTask: Task<Void, Never>?
    private var selectedPathObservationTask: Task<Void, Never>?
    private var irohSettingsContinuations: [UUID: AsyncStream<CmxIrohSettingsSnapshot>.Continuation] = [:]
    private var observedAuthState: MobileIrohAuthState?
    private var observedAccountID: String? { observedAuthState?.accountID }
    private var activeAccountID: String?
    private let diagnosticArchive = DiagnosticReportArchive.defaultArchive()
    private var previousLaunchDiagnosticReport: DiagnosticReport??
    private var lastKnownBindingAccountID: String?
    private var lastKnownBindingTag: String?
    private var lastKnownBindingID: String?
    private var lifecycleRevision: UInt64 = 0
    private var signOutPhase = SignOutPhase.idle
    private var signOutObservedAuthClear = false
    private var signOutAuthRevisionAtPreparation: UInt64?

    /// Creates the production iOS Iroh composition with device-only persistence.
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
        let keychainAccessGroup = injectedKeychainAccessGroup
            ?? Self.keychainAccessGroup(infoDictionary: infoDictionary)
        #if DEBUG
        let transportVerificationMode = Self.initialTransportVerificationMode(
            defaults: defaults
        )
        let automaticRelayCredentialRefreshEnabled = ProcessInfo.processInfo.environment[
            "CMUX_IROH_DISABLE_RELAY_CREDENTIAL_REFRESH"
        ] != "1"
        #else
        let transportVerificationMode = CmxIrohTransportVerificationMode.automatic
        let automaticRelayCredentialRefreshEnabled = true
        #endif
        let installState = CmxIrohUserDefaultsInstallStateStore(defaults: defaults)
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
        let networkPathState = MobileIrohNetworkPathState()
        let durableDeviceIDResolver = MobileIrohDurableDeviceIDResolver(
            defaults: MobileIrohSendableDefaults(defaults),
            appNamespace: appNamespace,
            keychainAccessGroup: keychainAccessGroup
        )
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
        self.init(
            appInstances: CmxIrohAppInstanceRepository(store: installState),
            identities: CmxIrohIdentityRepository(
                secureStore: Self.identityStore(
                    appNamespace: appNamespace,
                    keychainAccessGroup: keychainAccessGroup
                ),
                installState: installState
            ),
            brokerCredentials: CmxIrohBrokerCredentialRepository(
                secureStore: Self.credentialStore(
                    service: "broker-credentials",
                    appNamespace: appNamespace,
                    keychainAccessGroup: keychainAccessGroup
                ),
                installState: installState
            ),
            pendingRevocations: CmxIrohPendingRevocationOutbox(
                secureStore: Self.credentialStore(
                    service: "pending-revocations",
                    appNamespace: appNamespace,
                    keychainAccessGroup: keychainAccessGroup
                )
            ),
            offlinePolicies: CmxIrohClientOfflinePolicyCache(
                secureStore: Self.credentialStore(
                    service: "client-offline-policy",
                    appNamespace: appNamespace,
                    keychainAccessGroup: keychainAccessGroup
                )
            ),
            customRelayProfiles: CmxIrohCustomRelayProfileStore(
                secureStore: Self.credentialStore(
                    service: "custom-relays",
                    appNamespace: appNamespace,
                    keychainAccessGroup: keychainAccessGroup
                )
            ),
            relayPolicyCache: CmxIrohRelayPolicyCache(
                secureStore: Self.credentialStore(
                    service: "relay-policy",
                    appNamespace: appNamespace,
                    keychainAccessGroup: keychainAccessGroup
                )
            ),
            relayPreferenceStore: CmxIrohRelayPreferenceStore(
                secureStore: Self.credentialStore(
                    service: "relay-preference",
                    appNamespace: appNamespace,
                    keychainAccessGroup: keychainAccessGroup
                )
            ),
            customRelayCredentials: CmxIrohCustomRelayCredentialStore(
                secureStore: Self.credentialStore(
                    service: "custom-relay-credentials",
                    appNamespace: appNamespace,
                    keychainAccessGroup: keychainAccessGroup
                )
            ),
            customPrivatePaths: CmxIrohCustomPrivatePathStore(store: installState),
            networkPathSnapshotComposer: CmxIrohNetworkPathSnapshotComposer(),
            relayPolicyTrustRoot: Self.relayPolicyTrustRoot(
                infoDictionary: infoDictionary
            ),
            endpointFactory: CmxIrohLibEndpointFactory(
                transportVerificationMode: transportVerificationMode
            ),
            endpointFactoryProvider: { mode in
                CmxIrohLibEndpointFactory(transportVerificationMode: mode)
            },
            transportVerificationMode: transportVerificationMode,
            automaticRelayCredentialRefreshEnabled: automaticRelayCredentialRefreshEnabled,
            brokerFactory: { tokenSource, bindingAuthorization, discoveryScope in
                guard let baseURL else {
                    throw CmxIrohTrustBrokerClientError.invalidBaseURL
                }
                return try CmxIrohTrustBrokerClient(
                    baseURL: baseURL,
                    tokenSource: tokenSource,
                    clientNamespace: bindingAuthorization?.clientNamespace
                        ?? appNamespace.bundleIdentifier,
                    bindingAuthorization: bindingAuthorization,
                    discoveryScope: discoveryScope,
                    backpressureMode: .callerOwned
                )
            },
            brokerBackpressureGate: CmxIrohBrokerBackpressureGate(
                store: CmxIrohUserDefaultsInstallStateStore(defaults: defaults)
            ),
            deviceID: { await durableDeviceIDResolver.resolve() },
            clientNamespace: appNamespace.bundleIdentifier,
            tag: Self.currentTag(
                infoDictionary: infoDictionary,
                bundleIdentifier: bundleIdentifier
            ),
            discoveryCompatibilityPolicy: discoveryCompatibilityPolicy,
            now: { Date() },
            lanPeerDiscovery: lanPeerDiscovery,
            startNetworkPathObservation: { onPathChange in
                await networkPathState.start(
                    reachability: reachability,
                    onPathChange: {
                        await lanPeerDiscovery.pathDidChange()
                        await onPathChange()
                    }
                )
            },
            networkPathSnapshot: {
                await networkPathState.snapshot()
            },
            diagnosticLog: diagnosticLog,
            debugDefaults: defaults
        )
    }

    init(
        appInstances: CmxIrohAppInstanceRepository,
        identities: CmxIrohIdentityRepository,
        brokerCredentials: CmxIrohBrokerCredentialRepository,
        pendingRevocations: CmxIrohPendingRevocationOutbox,
        offlinePolicies: CmxIrohClientOfflinePolicyCache = CmxIrohClientOfflinePolicyCache(),
        customRelayProfiles: CmxIrohCustomRelayProfileStore? = nil,
        relayPolicyCache: CmxIrohRelayPolicyCache = CmxIrohRelayPolicyCache(),
        relayPreferenceStore: CmxIrohRelayPreferenceStore = CmxIrohRelayPreferenceStore(),
        customRelayCredentials: CmxIrohCustomRelayCredentialStore = CmxIrohCustomRelayCredentialStore(),
        customPrivatePaths: CmxIrohCustomPrivatePathStore = CmxIrohCustomPrivatePathStore(),
        networkPathSnapshotComposer: CmxIrohNetworkPathSnapshotComposer =
            CmxIrohNetworkPathSnapshotComposer(),
        relayPolicyTrustRoot: CmxIrohRelayPolicyTrustRoot? = nil,
        endpointFactory: any CmxIrohEndpointFactory,
        endpointFactoryProvider: (
            @MainActor (CmxIrohTransportVerificationMode) -> any CmxIrohEndpointFactory
        )? = nil,
        transportVerificationMode: CmxIrohTransportVerificationMode = .automatic,
        automaticRelayCredentialRefreshEnabled: Bool = true,
        brokerFactory: @escaping BrokerFactory,
        brokerBackpressureGate: CmxIrohBrokerBackpressureGate = CmxIrohBrokerBackpressureGate(),
        deviceID: @escaping @Sendable () async -> String?,
        clientNamespace: String = "legacy",
        tag: String,
        discoveryCompatibilityPolicy: MobileMacBuildCompatibilityPolicy? = nil,
        now: @escaping @Sendable () -> Date,
        connectionReadiness: MobileIrohConnectionReadinessOwner =
            MobileIrohConnectionReadinessOwner(),
        routeCatalog: MobileIrohRouteCatalog = MobileIrohRouteCatalog(),
        lanPeerDiscovery: CmxIrohLANPeerDiscovery? = nil,
        startNetworkPathObservation: @escaping @Sendable (
            _ onPathChange: @escaping @Sendable () async -> Void
        ) async -> Void = { _ in },
        networkPathSnapshot: @escaping @Sendable () async throws -> CmxIrohNetworkPathSnapshot = {
            CmxIrohNetworkPathSnapshot(generation: 1, activeNetworkProfiles: [])
        },
        activationRetryBackoff: CmxIrohReconnectBackoff? = nil,
        makeRelayPolicyRefreshBackoff: (
            @Sendable () -> CmxIrohReconnectBackoff
        )? = nil,
        diagnosticLog: DiagnosticLog? = nil,
        debugDefaults: UserDefaults? = nil
    ) {
        self.appInstances = appInstances
        self.identities = identities
        self.brokerCredentials = brokerCredentials
        self.pendingRevocations = pendingRevocations
        self.offlinePolicies = offlinePolicies
        self.customRelayProfiles = customRelayProfiles
        self.relayPolicyCache = relayPolicyCache
        self.relayPreferenceStore = relayPreferenceStore
        self.customRelayCredentials = customRelayCredentials
        self.customPrivatePaths = customPrivatePaths
        self.networkPathSnapshotComposer = networkPathSnapshotComposer
        self.relayPolicyTrustRoot = relayPolicyTrustRoot
        self.endpointFactoryProvider = endpointFactoryProvider ?? { _ in endpointFactory }
        self.transportVerificationMode = transportVerificationMode
        self.automaticRelayCredentialRefreshEnabled = automaticRelayCredentialRefreshEnabled
        self.debugDefaults = debugDefaults
        self.brokerFactory = brokerFactory
        self.brokerBackpressureGate = brokerBackpressureGate
        self.deviceID = deviceID
        self.clientNamespace = clientNamespace
        self.tag = tag
        self.discoveryCompatibilityPolicy = discoveryCompatibilityPolicy
        self.now = now
        self.connectionReadiness = connectionReadiness
        self.routeCatalog = routeCatalog
        self.lanPeerDiscovery = lanPeerDiscovery
        self.startNetworkPathObservation = startNetworkPathObservation
        self.networkPathSnapshot = networkPathSnapshot
        self.activationRetryBackoff = activationRetryBackoff
            ?? CmxIrohReconnectBackoff()
        self.makeRelayPolicyRefreshBackoff = makeRelayPolicyRefreshBackoff
            ?? { CmxIrohReconnectBackoff() }
        self.diagnosticLog = diagnosticLog
    }

    private func makeBrokerBundle(
        accountID: String,
        tokenSource: CmxIrohBrokerTokenSource,
        bindingAuthorization: CmxIrohBindingRequestAuthorization? = nil,
        discoveryScope: CmxConnectivityDiscoveryScope? = nil
    ) throws -> BrokerBundle {
        let rawClient = try brokerFactory(
            tokenSource,
            bindingAuthorization,
            discoveryScope
        )
        let client = CmxIrohBackpressuredClientBroker(
            broker: rawClient,
            gate: brokerBackpressureGate,
            accountID: accountID
        )
        let relayPolicy = (rawClient as? any CmxIrohRelayPolicyServing).map {
            CmxIrohBackpressuredRelayPolicyBroker(
                broker: $0,
                gate: brokerBackpressureGate,
                accountID: accountID
            )
        }
        return BrokerBundle(client: client, relayPolicy: relayPolicy)
    }

    /// Starts auth observation after the coordinator's launch restore completes.
    ///
    /// - Parameter auth: The process-owned authentication coordinator.
    public func configure(
        auth: AuthCoordinator,
        connectivityInvalidationBaseURL: URL? = nil
    ) {
        self.auth = auth
        if let connectivityInvalidationBaseURL {
            connectivityInvalidationSubscriber = CmxConnectivityInvalidationSubscriber(
                serviceBaseURL: connectivityInvalidationBaseURL,
                accessToken: { [weak auth] in
                    try? await auth?.accessToken()
                },
                handler: { [weak self] invalidation in
                    await self?.receiveConnectivityInvalidation(invalidation)
                }
            )
        } else {
            connectivityInvalidationSubscriber = nil
        }
        authObservationTask?.cancel()
        authObservationTask = Task { @MainActor [weak self, weak auth] in
            guard let auth else { return }
            await self?.startNetworkPathObservation({ [weak self] in
                // A path change is a fresh network state: the failure streak
                // that armed the activation backoff belonged to the old path.
                await self?.clearActivationRetryBackoff()
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

    private func setConnectivityInvalidationAccount(_ accountID: String?) async {
        guard connectivityInvalidationAccountID != accountID else { return }
        connectivityInvalidationAccountID = accountID
        await connectivityInvalidationSubscriber?.stop()
        if accountID != nil {
            await connectivityInvalidationSubscriber?.start()
        }
    }

    private func receiveConnectivityInvalidation(
        _ invalidation: CmxConnectivityInvalidation
    ) async {
        guard connectivityInvalidationAccountID != nil,
              connectivityInvalidationAccountID == observedAccountID,
              let runtime else { return }
        let outcome = await runtime.reconcileConnectivityRevision(
            invalidation.revision
        )
        if let event = Self.discoveryRefreshFailureEvent(for: outcome) {
            diagnosticLog?.record(event)
        }
    }

    /// Waits for the authenticated endpoint, broker binding, and relay policy.
    ///
    /// Tagged attach-URL launches use this barrier before starting the shell's
    /// bounded pairing attempt. Transport creation calls the same entrypoint,
    /// so readiness policy cannot drift between automatic and interactive use.
    public func prepareForConnection() async {
        _ = await settleConnectionReadiness()
    }

    /// Refreshes the current account runtime and returns its live pairable Macs.
    ///
    /// The catalog keeps cached bindings in a separate route-only view, so this
    /// method can never turn an offline cache entry into a first pairing.
    public func discoverLiveMacs() async -> [MobileDiscoveredIrohMac] {
        diagnosticLog?.record(DiagnosticEvent(.discoveryStarted, a: DiagnosticTransportKind.iroh.rawValue))
        let readiness = await settleConnectionReadiness()
        guard let runtime else {
            diagnosticLog?.record(DiagnosticEvent(
                .discoveryFailed,
                a: DiagnosticTransportKind.iroh.rawValue,
                b: readiness.failureKind.rawValue
            ))
            return []
        }
        let refreshOutcome = await runtime.refreshLiveDiscoveryOutcome()
        guard refreshOutcome == .refreshed else {
            guard self.runtime === runtime else { return [] }
            await routeCatalog.clearLiveMacCandidates(scope: lifecycleRevision)
            if let event = Self.discoveryRefreshFailureEvent(for: refreshOutcome) {
                diagnosticLog?.record(event)
            }
            return []
        }
        guard self.runtime === runtime else { return [] }
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
        await runtime?.invalidateDiscoverySnapshot(forMacDeviceID: deviceID)
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

    nonisolated static func discoveryRefreshFailureEvent(
        for outcome: CmxIrohLiveDiscoveryRefreshOutcome
    ) -> DiagnosticEvent? {
        guard case let .failed(failure) = outcome else { return nil }
        return DiagnosticEvent(
            .discoveryFailed,
            a: DiagnosticTransportKind.iroh.rawValue,
            b: failure.rawValue
        )
    }

    /// Resolves a disconnected transport from the active account runtime.
    public func transport(
        for request: CmxByteTransportRequest
    ) async throws -> any CmxByteTransport {
        let runtime = try await preparedRuntimeForConnection()
        return try runtime.transportFactory.makeTransport(for: request)
    }

    /// Opens a terminal or artifact stream on the pooled admitted connection.
    ///
    /// - Parameters:
    ///   - request: The exact Iroh peer route and intended Mac device binding.
    ///   - lane: The terminal or artifact lane declaration.
    ///   - priority: Iroh's relative stream priority.
    /// - Returns: The opened lane after its binary header is written.
    public func openBidirectionalLane(
        for request: CmxByteTransportRequest,
        lane: CmxIrohLane,
        priority: Int32
    ) async throws -> CmxIrohBidirectionalStream {
        let runtime = try await preparedRuntimeForConnection()
        return try await runtime.openBidirectionalLane(
            for: request,
            lane: lane,
            priority: priority
        )
    }

    /// Opens a production terminal byte lane for one exact Mac surface.
    ///
    /// The caller persists `cursor` as it applies raw PTY bytes, then supplies
    /// that cursor when reopening after a stream failure so the Mac can replay
    /// from its bounded byte history without duplicating output.
    public func openTerminalLane(
        for request: CmxByteTransportRequest,
        surfaceID: UUID,
        cursor: UInt64? = nil,
        priority: Int32 = 0
    ) async throws -> MobileIrohTerminalLane {
        let resourceID = try CmxIrohResourceID("terminal:\(surfaceID.uuidString.lowercased())")
        let stream = try await openBidirectionalLane(
            for: request,
            lane: .terminal(resourceID: resourceID, cursor: cursor),
            priority: priority
        )
        return MobileIrohTerminalLane(stream: stream)
    }

    /// Opens a low-priority raw artifact lane for an opaque Mac-issued capability.
    public func openArtifactLane(
        for request: CmxByteTransportRequest,
        resourceID: String,
        offset: UInt64,
        priority: Int32 = -10
    ) async throws -> any MobileArtifactLaneConnection {
        let capability = try CmxIrohResourceID(resourceID)
        let stream = try await openBidirectionalLane(
            for: request,
            lane: .artifact(resourceID: capability, offset: offset),
            priority: priority
        )
        do {
            try await stream.sendStream.finish()
            return MobileIrohArtifactLane(stream: stream)
        } catch {
            await stream.sendStream.reset(errorCode: 0)
            await stream.receiveStream.stop(errorCode: 0)
            throw error
        }
    }

    /// Starts the one server-event byte stream on the pooled admitted connection.
    public func serverEventByteStream(
        for request: CmxByteTransportRequest
    ) async throws -> CmxIndependentEventByteStream {
        let runtime = try await preparedRuntimeForConnection()
        return try await runtime.serverEventByteStream(for: request)
    }

    private func settleConnectionReadiness()
        async -> MobileIrohConnectionReadinessOutcome
    {
        await reconcileLiveAuthIfNeeded()
        let outcome = await connectionReadiness.wait(now: now)
        await sceneTransitionTask?.value
        if runtime != nil { return .ready }
        let accountID = observedAccountID ?? activeAccountID
        guard accountID != nil || !signOutPhase.allowsLifecycle else {
            return outcome
        }
        return .failed(await retryAwarePreparationFailure(
            accountID: accountID,
            fallbackKind: outcome.failureKind ?? .endpointUnavailable
        ))
    }

    private func preparedRuntimeForConnection() async throws
        -> CmxIrohClientRuntime
    {
        let readiness = await settleConnectionReadiness()
        if case let .failed(error) = readiness {
            throw error
        }
        return try await runtimeForDial()
    }

    private func runtimeForDial() async throws -> CmxIrohClientRuntime {
        while true {
            if let runtime { return runtime }
            guard let accountID = observedAccountID ?? activeAccountID else {
                throw CmxIrohClientRuntimeError.inactive
            }
            let remaining = await brokerActivationRetryAfterSeconds(
                accountID: accountID
            )
            if let runtime { return runtime }
            guard (observedAccountID ?? activeAccountID) == accountID else {
                try Task.checkCancellation()
                continue
            }
            if let remaining {
                throw MobileIrohRuntimePreparationError(
                    diagnosticFailureKind: .endpointUnavailable,
                    retryAfterSeconds: remaining
                )
            }
            throw await retryAwarePreparationFailure(
                accountID: accountID,
                fallbackKind: .endpointUnavailable
            )
        }
    }

    /// Projects the one shared activation-backoff window through every public
    /// connection entrypoint. Broker cooldown may raise the floor, but it never
    /// creates a second local retry ladder.
    private func retryAwarePreparationFailure(
        accountID: String?,
        fallbackKind: DiagnosticFailureKind
    ) async -> MobileIrohRuntimePreparationError {
        var retryAfterSeconds = max(
            1,
            Int(CmxIrohReconnectBackoffConfiguration.foreground.floor.rounded(.up))
        )
        var failureKind = fallbackKind
        if activationBackoffAccountID == accountID,
           let activationRetryAt {
            retryAfterSeconds = max(
                retryAfterSeconds,
                Int(activationRetryAt.timeIntervalSince(now()).rounded(.up))
            )
            failureKind = activationFailureKind ?? failureKind
        }
        if let accountID,
           let brokerFloor = await brokerActivationRetryAfterSeconds(
               accountID: accountID
           ) {
            retryAfterSeconds = max(retryAfterSeconds, brokerFloor)
        }
        return MobileIrohRuntimePreparationError(
            diagnosticFailureKind: failureKind,
            retryAfterSeconds: retryAfterSeconds
        )
    }

    private func brokerActivationRetryAfterSeconds(accountID: String) async -> Int? {
        var longest: Int?
        for operation in [
            CmxIrohBrokerOperation.revocation,
            .relayCredential,
            .registration,
            .discovery,
        ] {
            if let remaining = await brokerBackpressureGate.remainingSeconds(
                accountID: accountID,
                operation: operation
            ) {
                longest = max(longest ?? remaining, remaining)
            }
        }
        return longest
    }

    /// Preserves the endpoint when iOS backgrounds the scene.
    /// Archives the diagnostic ring without touching the runtime. Called on
    /// scene inactivation (the app switcher opening) so a force-quit that
    /// never delivers a background transition still leaves the previous
    /// launch's events exportable.
    public func archiveDiagnostics() {
        diagnosticLog?.record(DiagnosticEvent(
            .appLifecycleChanged,
            a: DiagnosticAppLifecyclePhase.inactive.rawValue
        ))
        persistDiagnosticsSnapshot()
    }

    /// Reads the previous launch's archive (once) and replaces it with the
    /// current ring, off the main actor: backgrounding must not spend the
    /// suspension window on filesystem work.
    private func persistDiagnosticsSnapshot() {
        guard let diagnosticLog, let diagnosticArchive else { return }
        let needsPreviousLoad = previousLaunchDiagnosticReport == nil
        Task.detached(priority: .utility) { [weak self] in
            let previous = needsPreviousLoad ? diagnosticArchive.load() : nil
            if needsPreviousLoad {
                await self?.cachePreviousLaunchReport(previous)
            }
            diagnosticArchive.save(await diagnosticLog.snapshot())
        }
    }

    private func cachePreviousLaunchReport(_ report: DiagnosticReport?) {
        guard previousLaunchDiagnosticReport == nil else { return }
        previousLaunchDiagnosticReport = .some(report)
    }

    public func didEnterBackground() {
        diagnosticLog?.record(DiagnosticEvent(
            .appLifecycleChanged,
            a: DiagnosticAppLifecyclePhase.background.rawValue
        ))
        requiresFullForegroundRefreshOnNextActive = true
        permissionRefreshTask?.cancel()
        permissionRefreshTask = nil
        guard signOutPhase.allowsLifecycle else { return }
        sceneTransitionTask?.cancel()
        // Archive the diagnostic ring so a later relaunch keeps the events
        // around a drop exportable.
        persistDiagnosticsSnapshot()
        let runtime = runtime
        sceneTransitionTask = Task {
            await runtime?.didEnterBackground()
        }
    }

    /// Health-checks and refreshes the preserved endpoint on a real foreground return.
    ///
    /// Transient inactive edges caused by system UI only re-check Local Network
    /// permission. They do not revalidate auth, clear retry backoff, or restart
    /// the transport runtime.
    ///
    /// - Returns: `true` for a cold activation or a return from background;
    ///   `false` for a transient inactive-to-active edge.
    @discardableResult
    public func didBecomeActive() -> Bool {
        diagnosticLog?.record(DiagnosticEvent(
            .appLifecycleChanged,
            a: DiagnosticAppLifecyclePhase.active.rawValue
        ))
        let requiresFullRefresh = requiresFullForegroundRefreshOnNextActive
        requiresFullForegroundRefreshOnNextActive = false
        guard requiresFullRefresh else {
            permissionRefreshTask?.cancel()
            let lanPeerDiscovery = lanPeerDiscovery
            permissionRefreshTask = Task {
                await lanPeerDiscovery?.permissionMayHaveChanged()
            }
            return false
        }

        // The user is looking at the app: any armed activation backoff resets
        // to its floor so recovery is immediate rather than mid-nap.
        clearActivationRetryBackoff()
        guard signOutPhase.allowsLifecycle else { return true }
        permissionRefreshTask?.cancel()
        permissionRefreshTask = nil
        sceneTransitionTask?.cancel()
        let auth = auth
        let runtime = runtime
        let lanPeerDiscovery = lanPeerDiscovery
        let diagnosticLog = diagnosticLog
        sceneTransitionTask = Task {
            if let auth {
                diagnosticLog?.recordAppEvent(.authRevalidationStarted)
                await auth.revalidateSession()
                guard !Task.isCancelled else {
                    diagnosticLog?.recordAppEvent(
                        .authRevalidationFailed,
                        failure: .cancelled
                    )
                    return
                }
                guard auth.isAuthenticated else {
                    diagnosticLog?.recordAppEvent(
                        .authRevalidationFailed,
                        failure: .authorizationFailed
                    )
                    return
                }
                diagnosticLog?.recordAppEvent(.authRevalidationSucceeded)
            }
            await lanPeerDiscovery?.permissionMayHaveChanged()
            guard !Task.isCancelled else { return }
            do {
                try await runtime?.didBecomeActive()
            } catch {
                mobileIrohLog.error(
                    "Iroh foreground health check failed: \(String(describing: error), privacy: .private)"
                )
            }
        }
        return true
    }

    /// Synchronously fences lifecycle work and starts local sign-out cleanup.
    ///
    /// Local identity state is wiped only after the binding revocation is
    /// durably queued. A storage failure keeps that exact account and binding
    /// quarantined for the captured-token hook or a later same-account sign-in.
    ///
    /// - Returns: The shared preparation operation for this sign-out attempt.
    public func beginSignOutPreparation()
        -> Task<CmxIrohClientSignOutPreparation, Never>
    {
        switch signOutPhase {
        case let .preparing(operation):
            return operation
        case let .awaitingRemote(preparation),
             let .quarantined(preparation):
            return Task { preparation }
        case let .recovering(preparation, operation):
            return Task { @MainActor [weak self] in
                _ = await self?.waitForRecovery(operation)
                return preparation
            }
        case .idle:
            break
        }

        signOutObservedAuthClear = false
        signOutAuthRevisionAtPreparation = auth?.signOutRevision
        clearActivationRetryBackoff()
        connectionReadiness.begin(revision: lifecycleRevision &+ 1)
        let operation = Task { @MainActor [weak self] in
            guard let self else {
                return CmxIrohClientSignOutPreparation(
                    pendingRevocation: nil,
                    wasPersisted: true
                )
            }
            return await self.performSignOutPreparation()
        }
        signOutPhase = .preparing(operation)
        return operation
    }

    /// Waits for the shared local preparation operation.
    public func prepareSignOut() async -> CmxIrohClientSignOutPreparation {
        await beginSignOutPreparation().value
    }

    /// Completes remote revocation after auth has already cleared local tokens.
    ///
    /// Cancellation stops waiting immediately while the credential-free local
    /// preparation continues and durably queues any pending revocation.
    public func completeSignOutAfterAuthClear(
        _ operation: Task<CmxIrohClientSignOutPreparation, Never>,
        accessToken: String?,
        refreshToken: String?
    ) async {
        guard let preparation = await cancellationAwareValue(of: operation) else {
            return
        }
        await revokeAfterSignOut(
            preparation,
            accessToken: accessToken,
            refreshToken: refreshToken
        )
    }

    private func performSignOutPreparation() async -> CmxIrohClientSignOutPreparation {
        let fallbackAccountID = activeAccountID
            ?? observedAccountID
            ?? lastKnownBindingAccountID
        observedAuthState = MobileIrohAuthState(accountID: nil)
        lifecycleRevision &+= 1
        let revision = lifecycleRevision
        let previous = transitionTask
        transitionTask = nil
        previous?.cancel()
        await previous?.value
        await lanPeerDiscovery?.stop()

        let previousRuntime = runtime
        runtime = nil
        selectedPathObservationTask?.cancel()
        selectedPathObservationTask = nil
        activeAccountID = nil
        diagnosticArchive?.clear()
        previousLaunchDiagnosticReport = .some(nil)
        let fallbackBindingID = lastKnownBindingID
        let preparation: CmxIrohClientSignOutPreparation
        if let previousRuntime {
            preparation = await previousRuntime.deactivateForSignOut()
        } else {
            preparation = await enqueueFallbackRevocation(
                accountID: fallbackAccountID,
                bindingID: fallbackBindingID
            )
            if preparation.wasPersisted {
                await wipeLocalState()
            }
        }
        if preparation.wasPersisted {
            clearLastKnownBinding()
            signOutPhase = .awaitingRemote(preparation)
        } else {
            if preparation.pendingRevocation != nil {
                mobileIrohLog.error("Iroh binding revocation queue failed")
            }
            signOutPhase = .quarantined(preparation)
        }
        connectionReadiness.complete(revision: revision, outcome: .inactive)
        await diagnosticLog?.clear()
        return preparation
    }

    /// Best-effort revokes the prepared binding with auth's captured token pair.
    ///
    /// Remote failure is logged and never reconstructs local endpoint or cache state.
    ///
    /// - Parameters:
    ///   - preparation: The binding captured by ``prepareSignOut()``.
    ///   - accessToken: Auth's access token captured before local auth teardown.
    ///   - refreshToken: Auth's refresh token captured before local auth teardown.
    public func revokeAfterSignOut(
        _ preparation: CmxIrohClientSignOutPreparation,
        accessToken: String?,
        refreshToken: String?
    ) async {
        guard phaseOwns(preparation) else {
            await revokeStalePreparation(
                preparation,
                accessToken: accessToken,
                refreshToken: refreshToken
            )
            return
        }
        guard let pendingRevocation = preparation.pendingRevocation else {
            await releaseSignOutQuarantine(preparation)
            finishSignOutPhase()
            return
        }
        guard let accessToken,
              !accessToken.isEmpty,
              let refreshToken,
              !refreshToken.isEmpty else {
            if preparation.wasPersisted {
                await releaseSignOutQuarantine(preparation)
                finishSignOutPhase()
            } else {
                signOutPhase = .quarantined(preparation)
            }
            return
        }
        do {
            let broker = try makeBrokerBundle(
                accountID: pendingRevocation.accountID,
                tokenSource: CmxIrohBrokerTokenSource(
                    // The pair was captured together up front, so it is coherent
                    // by construction.
                    credentialPair: {
                        CmxIrohBrokerCredentials(
                            accessToken: accessToken,
                            refreshToken: refreshToken
                        )
                    }
                ),
                bindingAuthorization: preparation.bindingAuthorization
            ).client
            let released = await recoverSignOutQuarantine(
                preparation,
                using: broker
            )
            if released { finishSignOutPhase() }
        } catch is CancellationError {
            return
        } catch {
            mobileIrohLog.error(
                "Iroh binding revoke failed: \(String(describing: error), privacy: .private)"
            )
        }
    }

    private func cancellationAwareValue(
        of operation: Task<CmxIrohClientSignOutPreparation, Never>
    ) async -> CmxIrohClientSignOutPreparation? {
        let stream = AsyncStream<CmxIrohClientSignOutPreparation> { continuation in
            let waiter = Task { @MainActor in
                let value = await operation.value
                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }
                continuation.yield(value)
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                waiter.cancel()
            }
        }
        for await value in stream {
            return value
        }
        return nil
    }

    private func applyAuthState(_ state: MobileIrohAuthState) async {
        await setConnectivityInvalidationAccount(state.accountID)
        guard await prepareForAuthReconcile(accountID: state.accountID) else {
            return
        }
        guard authStateRequiresReconcile(state) else { return }
        let previousObservedAccountID = observedAccountID
        observedAuthState = state
        let transition = scheduleReconcile(
            targetAccountID: state.accountID,
            eraseAccountState: state.accountID == nil
                || (previousObservedAccountID != nil
                    && previousObservedAccountID != state.accountID)
                || (activeAccountID != nil && activeAccountID != state.accountID)
        )
        await transition.value
    }

    private func finishSignOutPhase() {
        guard signOutPhase.allowsLifecycle else { return }
        guard let auth else { return }
        let state = MobileIrohAuthState(
            accountID: auth.isAuthenticated ? auth.currentUser?.id : nil
        )
        guard authStateRequiresReconcile(state) else { return }
        let accountID = state.accountID
        let previousObservedAccountID = observedAccountID
        observedAuthState = state
        _ = scheduleReconcile(
            targetAccountID: accountID,
            eraseAccountState: accountID == nil
                || (previousObservedAccountID != nil
                    && previousObservedAccountID != accountID)
                || (activeAccountID != nil && activeAccountID != accountID)
        )
    }

    private func reconcileLiveAuthIfNeeded() async {
        guard let auth else { return }
        await auth.awaitBootstrapped()
        let state = MobileIrohAuthState(
            accountID: auth.isAuthenticated ? auth.currentUser?.id : nil
        )
        let accountID = state.accountID
        guard await prepareForAuthReconcile(accountID: accountID) else {
            return
        }
        guard authStateRequiresReconcile(state) else { return }
        let previousObservedAccountID = observedAccountID
        observedAuthState = state
        _ = scheduleReconcile(
            targetAccountID: accountID,
            eraseAccountState: accountID == nil
                || (previousObservedAccountID != nil
                    && previousObservedAccountID != accountID)
                || (activeAccountID != nil && activeAccountID != accountID)
        )
    }

    private func authStateRequiresReconcile(_ state: MobileIrohAuthState) -> Bool {
        guard observedAuthState == state else { return true }
        guard let accountID = state.accountID else { return false }
        guard runtime == nil, transitionTask == nil else { return false }
        guard activationBackoffAccountID == accountID,
              let activationRetryAt else { return true }
        return now() >= activationRetryAt
    }

    private func prepareForAuthReconcile(accountID: String?) async -> Bool {
        if accountID == nil, !signOutPhase.allowsLifecycle {
            signOutObservedAuthClear = true
        }
        if !signOutPhase.allowsLifecycle,
           let signOutAuthRevisionAtPreparation,
           let auth,
           auth.signOutRevision != signOutAuthRevisionAtPreparation {
            signOutObservedAuthClear = true
        }
        if !signOutPhase.allowsLifecycle,
           activationBackoffAccountID == accountID,
           let activationRetryAt,
           now() < activationRetryAt {
            return false
        }
        switch signOutPhase {
        case .idle:
            return true
        case let .preparing(operation):
            _ = await operation.value
            return await prepareForAuthReconcile(accountID: accountID)
        case let .recovering(preparation, operation):
            guard await completeSignOutRecovery(
                preparation,
                operation: operation
            ) else {
                if let accountID {
                    armSignOutRecoveryBackoff(accountID: accountID)
                }
                return false
            }
            return await prepareForAuthReconcile(accountID: accountID)
        case let .awaitingRemote(preparation):
            // The nil state is auth's local-first clear and must not overtake
            // its captured-token remote hook. A later explicit sign-in can
            // safely proceed because this preparation is already durable.
            guard accountID != nil,
                  signOutObservedAuthClear,
                  preparation.wasPersisted else { return false }
            await releaseSignOutQuarantine(preparation)
            return signOutPhase.allowsLifecycle
        case let .quarantined(preparation):
            guard signOutObservedAuthClear,
                  let pendingRevocation = preparation.pendingRevocation,
                  accountID == pendingRevocation.accountID,
                  let auth else { return false }
            do {
                let expectedAccountID = pendingRevocation.accountID
                let broker = try makeBrokerBundle(
                    accountID: expectedAccountID,
                    tokenSource: CmxIrohBrokerTokenSource(
                        // An ATOMIC authenticated snapshot per fetch, pinned to
                        // the PENDING revocation's account: the equality guard
                        // above ran before this destructive retry, and the
                        // user can switch accounts before the revoke request
                        // captures credentials — an unpinned live read would
                        // then send account B's tokens with account A's
                        // pending binding id. A mismatch yields nil and the
                        // retry fails closed.
                        credentialPair: { [weak auth] in
                            guard let auth,
                                  let session = try? await auth.authenticatedSessionSnapshot(),
                                  session.accountID == expectedAccountID else {
                                return nil
                            }
                            return CmxIrohBrokerCredentials(
                                accessToken: session.accessToken,
                                refreshToken: session.refreshToken
                            )
                        }
                    ),
                    bindingAuthorization: preparation.bindingAuthorization
                ).client
                let recovered = await recoverSignOutQuarantine(
                    preparation,
                    using: broker
                )
                if !recovered {
                    armSignOutRecoveryBackoff(accountID: expectedAccountID)
                }
                return recovered
            } catch {
                mobileIrohLog.error(
                    "Iroh binding revoke retry failed: \(String(describing: error), privacy: .private)"
                )
                armActivationRetryBackoff(
                    accountID: pendingRevocation.accountID,
                    error: error
                )
                return false
            }
        }
    }

    private func armSignOutRecoveryBackoff(accountID: String) {
        armActivationRetryBackoff(
            accountID: accountID,
            error: MobileIrohRuntimePreparationError(
                diagnosticFailureKind: .endpointUnavailable,
                retryAfterSeconds: nil
            )
        )
    }

    private func phaseOwns(
        _ preparation: CmxIrohClientSignOutPreparation
    ) -> Bool {
        switch signOutPhase {
        case let .awaitingRemote(current),
             let .quarantined(current),
             let .recovering(current, _):
            return current == preparation
        case .idle, .preparing:
            return false
        }
    }

    private func recoverSignOutQuarantine(
        _ preparation: CmxIrohClientSignOutPreparation,
        using broker: any CmxIrohClientBrokerServing
    ) async -> Bool {
        let operation: Task<SignOutRecoveryOutcome, Never>
        if case let .recovering(current, existingOperation) = signOutPhase {
            guard current == preparation else { return false }
            operation = existingOperation
        } else {
            guard phaseOwns(preparation) else { return false }
            let pendingRevocations = pendingRevocations
            operation = Task {
                await Self.attemptRevocation(
                    preparation,
                    using: broker,
                    pendingRevocations: pendingRevocations
                )
            }
            signOutPhase = .recovering(preparation, operation)
        }
        return await completeSignOutRecovery(
            preparation,
            operation: operation
        )
    }

    /// Completes one shared recovery exactly once on the MainActor.
    ///
    /// Any auth or sign-out waiter may resume first after the detached broker
    /// work. Letting that first waiter finalize the phase prevents an
    /// already-complete task from becoming a recursive MainActor livelock.
    private func completeSignOutRecovery(
        _ preparation: CmxIrohClientSignOutPreparation,
        operation: Task<SignOutRecoveryOutcome, Never>
    ) async -> Bool {
        let outcome = await waitForRecovery(operation)
        guard case let .recovering(current, _) = signOutPhase,
              current == preparation else {
            return outcome.canReleaseQuarantine
        }
        guard outcome.canReleaseQuarantine else {
            signOutPhase = .quarantined(preparation)
            mobileIrohLog.error("Iroh binding revocation queue remains unavailable")
            return false
        }
        await releaseSignOutQuarantine(preparation)
        return true
    }

    private func waitForRecovery(
        _ operation: Task<SignOutRecoveryOutcome, Never>
    ) async -> SignOutRecoveryOutcome {
        await withTaskCancellationHandler {
            await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    private nonisolated static func attemptRevocation(
        _ preparation: CmxIrohClientSignOutPreparation,
        using broker: any CmxIrohClientBrokerServing,
        pendingRevocations: CmxIrohPendingRevocationOutbox
    ) async -> SignOutRecoveryOutcome {
        do {
            try await preparation.revoke(
                using: broker,
                pendingRevocations: pendingRevocations
            )
            return .revoked
        } catch {
            guard let pending = preparation.pendingRevocation else {
                return .revoked
            }
            if preparation.wasPersisted {
                return .durablyQueued
            }
            let stored = try? await pendingRevocations.pending(
                accountID: pending.accountID
            )
            return stored?.contains(pending) == true
                ? .durablyQueued
                : .notDurable
        }
    }

    private func releaseSignOutQuarantine(
        _ preparation: CmxIrohClientSignOutPreparation
    ) async {
        guard phaseOwns(preparation) else { return }
        await wipeLocalState()
        if lastKnownBindingID == preparation.bindingID {
            clearLastKnownBinding()
        }
        signOutObservedAuthClear = false
        signOutAuthRevisionAtPreparation = nil
        signOutPhase = .idle
    }

    private func revokeStalePreparation(
        _ preparation: CmxIrohClientSignOutPreparation,
        accessToken: String?,
        refreshToken: String?
    ) async {
        guard let pendingRevocation = preparation.pendingRevocation,
              let accessToken,
              !accessToken.isEmpty,
              let refreshToken,
              !refreshToken.isEmpty,
              let broker = try? makeBrokerBundle(
                  accountID: pendingRevocation.accountID,
                  tokenSource: CmxIrohBrokerTokenSource(
                      // The pair was captured together up front, so it is
                      // coherent by construction.
                      credentialPair: {
                          CmxIrohBrokerCredentials(
                              accessToken: accessToken,
                              refreshToken: refreshToken
                          )
                      }
                  ),
                  bindingAuthorization: preparation.bindingAuthorization
              ).client else { return }
        do {
            try await preparation.revoke(
                using: broker,
                pendingRevocations: pendingRevocations
            )
        } catch {
            mobileIrohLog.error(
                "Stale Iroh binding revoke failed: \(String(describing: error), privacy: .private)"
            )
        }
    }

    @discardableResult
    private func scheduleReconcile(
        targetAccountID: String?,
        eraseAccountState: Bool,
        restartActiveRuntime: Bool = false
    ) -> Task<Void, Never> {
        lifecycleRevision &+= 1
        let revision = lifecycleRevision
        connectionReadiness.begin(revision: revision)
        let previous = transitionTask
        previous?.cancel()
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            guard revision == self.lifecycleRevision,
                  self.signOutPhase.allowsLifecycle,
                  !Task.isCancelled else {
                self.connectionReadiness.abandon(revision: revision)
                return
            }
            let outcome = await self.reconcile(
                targetAccountID: targetAccountID,
                eraseAccountState: eraseAccountState,
                restartActiveRuntime: restartActiveRuntime,
                revision: revision
            )
            guard revision == self.lifecycleRevision,
                  !Task.isCancelled else {
                self.connectionReadiness.abandon(revision: revision)
                return
            }
            switch outcome {
            case .inactive:
                self.connectionReadiness.complete(
                    revision: revision,
                    outcome: .inactive
                )
            case .ready:
                self.connectionReadiness.complete(
                    revision: revision,
                    outcome: .ready
                )
            case let .failed(error):
                let failure = await self.retryAwarePreparationFailure(
                    accountID: targetAccountID,
                    fallbackKind: DiagnosticFailureKind.classify(error)
                )
                guard revision == self.lifecycleRevision,
                      !Task.isCancelled else {
                    self.connectionReadiness.abandon(revision: revision)
                    return
                }
                self.connectionReadiness.complete(
                    revision: revision,
                    outcome: .failed(failure)
                )
            }
            self.transitionTask = nil
        }
        transitionTask = task
        return task
    }

    private func reconcile(
        targetAccountID: String?,
        eraseAccountState: Bool,
        restartActiveRuntime: Bool,
        revision: UInt64
    ) async -> ReconcileOutcome {
        if restartActiveRuntime
            || activeAccountID != targetAccountID
            || targetAccountID == nil
        {
            let shouldErase = !restartActiveRuntime && eraseAccountState
                && (targetAccountID == nil || activeAccountID != targetAccountID)
            let previousRuntime = runtime
            let previousAccountID = activeAccountID ?? lastKnownBindingAccountID
            let fallbackBindingID = lastKnownBindingID
            runtime = nil
            selectedPathObservationTask?.cancel()
            selectedPathObservationTask = nil
            activeAccountID = nil
            if shouldErase {
                diagnosticArchive?.clear()
                previousLaunchDiagnosticReport = .some(nil)
            }
            await lanPeerDiscovery?.stop()
            if let previousRuntime {
                if shouldErase {
                    let preparation = await previousRuntime.deactivateForSignOut()
                    if preparation.wasPersisted {
                        clearLastKnownBinding()
                    } else if preparation.pendingRevocation != nil {
                        mobileIrohLog.error("Iroh binding revocation queue failed")
                        signOutPhase = .quarantined(preparation)
                    }
                } else {
                    await previousRuntime.stop()
                }
                diagnosticLog?.record(DiagnosticEvent(.endpointStopped, a: DiagnosticTransportKind.iroh.rawValue))
            } else if shouldErase {
                let preparation = await enqueueFallbackRevocation(
                    accountID: previousAccountID,
                    bindingID: fallbackBindingID
                )
                if preparation.wasPersisted {
                    await wipeLocalState()
                    clearLastKnownBinding()
                } else {
                    signOutPhase = .quarantined(preparation)
                }
            }
            clearRelayPolicyRuntimeState()
        }
        guard revision == lifecycleRevision,
              !Task.isCancelled,
              signOutPhase.allowsLifecycle else { return .inactive }
        guard let targetAccountID else { return .inactive }
        guard runtime == nil else { return .ready }
        if activationBackoffAccountID != targetAccountID {
            // A different account never inherits another account's streak.
            clearActivationRetryBackoff()
        } else if let activationRetryAt, now() < activationRetryAt {
            // A recent activation failure armed the client backoff: skip the
            // broker-bound attempt entirely. scenePhase-active transitions,
            // network-path changes, and account switches clear the window
            // immediately, so a real state change always retries at the floor.
            return .failed(MobileIrohRuntimePreparationError(
                diagnosticFailureKind: activationFailureKind
                    ?? .endpointUnavailable,
                retryAfterSeconds: max(
                    1,
                    Int(activationRetryAt.timeIntervalSince(now()).rounded(.up))
                )
            ))
        }
        diagnosticLog?.record(DiagnosticEvent(
            .endpointStarting,
            a: DiagnosticTransportKind.iroh.rawValue
        ))
        do {
            try await activate(accountID: targetAccountID, revision: revision)
            clearActivationRetryBackoff()
            return .ready
        } catch is CancellationError {
            return .inactive
        } catch {
            diagnosticLog?.record(DiagnosticEvent(
                .endpointFailed,
                a: DiagnosticTransportKind.iroh.rawValue,
                b: Self.diagnosticFailureKind(for: error).rawValue
            ))
            mobileIrohLog.error(
                "Iroh client activation failed: \(String(describing: error), privacy: .private)"
            )
            armActivationRetryBackoff(accountID: targetAccountID, error: error)
            return .failed(error)
        }
    }

    /// Arms the shared client backoff after one failed broker-bound activation.
    ///
    /// External churn (every dial, discovery, and preparation re-triggers a
    /// reconcile while no runtime exists) must not translate into broker
    /// traffic; without a client-side window a wedged phone re-ran
    /// registration, discovery, and relay-policy every few seconds
    /// indefinitely. Local precondition deferrals never arm the window: they
    /// made no broker request and the next reconcile may legitimately retry
    /// immediately.
    private func armActivationRetryBackoff(accountID: String, error: any Error) {
        activationFailureKind = DiagnosticFailureKind.classify(error)
        if (error as? CmxIrohClientRuntimeError) == .inactive { return }
        let delay = activationRetryBackoff.nextDelay(
            retryAfterSeconds: (error as? any CmxRetryAfterProviding)?
                .retryAfterSeconds
        )
        activationBackoffAccountID = accountID
        activationRetryAt = now().addingTimeInterval(delay)
        diagnosticLog?.record(DiagnosticEvent(
            .retryScheduled,
            ms: UInt32(clamping: Int(delay * 1_000)),
            a: DiagnosticTransportKind.iroh.rawValue
        ))
    }

    private func clearActivationRetryBackoff() {
        activationRetryBackoff.reset()
        activationRetryAt = nil
        activationBackoffAccountID = nil
        activationFailureKind = nil
    }

    private func activate(accountID: String, revision: UInt64) async throws {
        guard let auth else { throw CmxIrohClientRuntimeError.inactive }
        // Resolve the durable device id BEFORE any iroh identity exists. The
        // device-id resolver's continuity probe treats a device-local iroh
        // identity as proof the install continues on this hardware; creating
        // the identity first (below) would hand a phone restored from a
        // pre-witness backup its own moments-old identity as "evidence" and
        // adopt the migrated mirror id — two phones sharing one
        // (user, device, tag) slot.
        guard let durableDeviceID = await deviceID() else {
            // The durable identity store is unavailable (Keychain locked before
            // first unlock, or a persistent write failure). Registering a
            // binding under an ephemeral throwaway id would orphan the retained
            // `(user, device, tag)` binding, so defer activation and retry on
            // the next reconcile once the store becomes readable.
            mobileIrohLog.error("Iroh activation deferred: durable device id unavailable")
            throw CmxIrohClientRuntimeError.inactive
        }
        let deviceID = cmxCanonicalDeviceID(durableDeviceID)
        let appInstanceID = try await appInstances.appInstanceID(
            accountID: accountID,
            tag: tag
        )
        let identity = try await identities.identity(
            accountID: accountID,
            appInstanceID: appInstanceID
        )
        let endpointID = try Self.peerIdentity(for: identity)
        let cachedBinding = try await brokerCredentials.loadBinding(
            accountID: accountID,
            appInstanceID: appInstanceID
        )
        let bindingMatches = cachedBinding.map {
            $0.deviceID == deviceID
                && $0.appInstanceID == appInstanceID
                && $0.clientNamespace == clientNamespace
                && $0.tag == tag
                && $0.platform == .ios
                && $0.endpointID == endpointID
                && $0.identityGeneration == identity.generation
        } ?? false
        let cachedManagedRelayURLs: Set<String>
        if let relayPolicyTrustRoot,
           let cachedPolicy = try? await relayPolicyCache.load(
               trustRoot: relayPolicyTrustRoot,
               now: now()
           ) {
            cachedManagedRelayURLs = Set(cachedPolicy.relays.map(\.url))
        } else {
            cachedManagedRelayURLs = []
        }
        let cachedRelay: CmxIrohRelayTokenResponse?
        if let cachedBinding, bindingMatches {
            lastKnownBindingID = cachedBinding.bindingID
            lastKnownBindingAccountID = accountID
            lastKnownBindingTag = tag
            cachedRelay = try await brokerCredentials.loadRelayCredential(
                accountID: accountID,
                binding: cachedBinding,
                expectedRelayFleet: cachedManagedRelayURLs,
                now: now()
            )
        } else {
            if cachedBinding != nil {
                try? await brokerCredentials.deleteBinding(
                    accountID: accountID,
                    appInstanceID: appInstanceID
                )
            }
            cachedRelay = nil
        }

        // Pin the activation's broker to the session identity that owns
        // `accountID` — a cheap LOCAL check (no token read, no network), so an
        // offline launch still constructs the runtime and reaches the cached
        // relay/offline-policy recovery paths. Every broker request then
        // re-checks the pin and re-reads a coherent pair from the token store:
        // an account switch fails closed per request (no wrong-account server
        // mutations before the lifecycle revision guard runs), and an ordinary
        // token rotation never strands the long-lived runtime on a frozen
        // activation-time pair.
        guard auth.currentUser?.id == accountID else {
            throw CmxIrohClientRuntimeError.inactive
        }
        let brokerBundle = try makeBrokerBundle(
            accountID: accountID,
            tokenSource: brokerTokenSource(pinnedTo: accountID),
            bindingAuthorization: try cachedBinding.flatMap { binding in
                guard bindingMatches else { return nil }
                return try CmxIrohBindingRequestAuthorization(
                    bindingID: binding.bindingID,
                    clientNamespace: clientNamespace,
                    identity: identity,
                    endpointID: endpointID
                )
            },
            discoveryScope: try CmxConnectivityDiscoveryScope(
                deviceID: deviceID,
                appInstanceID: appInstanceID,
                tag: tag,
                platform: .ios,
                peerPlatform: .mac,
                peerTags: Self.discoveryPeerTags(
                    for: discoveryCompatibilityPolicy
                ),
                peerPairingEnabled: true
            )
        )
        let broker = brokerBundle.client
        let endpointRelayProfile: CmxIrohEndpointRelayProfile?
        let managedRelayURLs: Set<String>
        let resolvedPolicyService: CmxIrohRelayPolicyService?
        let resolvedEffectivePolicy: CmxIrohEffectiveRelayPolicy?
        var freshRelayCredential: CmxIrohRelayTokenResponse?
        var relayPolicyNeedsImmediateRefresh = false
        if let relayPolicyTrustRoot {
            let service = CmxIrohRelayPolicyService(
                policyCache: relayPolicyCache,
                preferenceStore: relayPreferenceStore,
                credentialStore: customRelayCredentials,
                broker: brokerBundle.relayPolicy
            )
            let effective: CmxIrohEffectiveRelayPolicy
            if Self.protocolConfiguration(for: transportVerificationMode)
                .allowsNATTraversalAfterAdmission {
                // Restore verified local authority first. The live refresh
                // starts after activation, keeping broker latency off the
                // direct-path discovery critical path.
                effective = await service.restore(
                    accountID: accountID,
                    trustRoot: relayPolicyTrustRoot,
                    relayCredential: cachedRelay,
                    now: now()
                )
                relayPolicyNeedsImmediateRefresh = true
            } else {
                diagnosticLog?.record(DiagnosticEvent(.relayPolicyRefreshStarted))
                do {
                    let outcome = try await service.refreshWithCredential(
                        endpointID: endpointID,
                        accountID: accountID,
                        trustRoot: relayPolicyTrustRoot,
                        now: now()
                    )
                    effective = outcome.effective
                    freshRelayCredential = outcome.relayCredential
                    diagnosticLog?.record(DiagnosticEvent(.relayPolicyRefreshSucceeded))
                } catch {
                    diagnosticLog?.record(DiagnosticEvent(
                        .relayPolicyRefreshFailed,
                        b: Self.diagnosticFailureKind(for: error).rawValue
                    ))
                    effective = await service.restore(
                        accountID: accountID,
                        trustRoot: relayPolicyTrustRoot,
                        relayCredential: cachedRelay,
                        now: now()
                    )
                    relayPolicyNeedsImmediateRefresh = true
                }
            }
            endpointRelayProfile = effective.endpointRelayProfile
            managedRelayURLs = Set(effective.managedPolicy?.relays.map(\.url) ?? [])
            resolvedPolicyService = service
            resolvedEffectivePolicy = effective
        } else {
            switch await customRelayProfiles?.loadSelection() {
            case nil, .managed:
                endpointRelayProfile = nil
            case let .custom(profile):
                endpointRelayProfile = CmxIrohEndpointRelayProfile(customProfile: profile)
            case .customUnavailable:
                mobileIrohLog.error(
                    "Custom relay profile unavailable; managed relays remain disabled"
                )
                endpointRelayProfile = .unavailableCustomOverride
            }
            managedRelayURLs = []
            resolvedPolicyService = nil
            resolvedEffectivePolicy = nil
        }
        let compatibleCachedRelay = cachedRelay.flatMap { relay in
            Set(relay.relayFleet) == managedRelayURLs ? relay : nil
        }
        let freshCompatibleRelay = freshRelayCredential.flatMap { relay in
            Set(relay.relayFleet) == managedRelayURLs ? relay : nil
        }
        let configuration = CmxIrohClientRuntimeConfiguration(
            accountID: accountID,
            deviceID: deviceID,
            appInstanceID: appInstanceID,
            clientNamespace: clientNamespace,
            tag: tag,
            displayName: nil,
            identity: identity,
            capabilities: Self.capabilities,
            managedRelayURLs: managedRelayURLs,
            endpointRelayProfile: endpointRelayProfile,
            cachedRelayCredential: freshCompatibleRelay ?? compatibleCachedRelay,
            cachedBinding: bindingMatches ? cachedBinding : nil
        )
        let credentialRepository = brokerCredentials
        let routeCatalog = routeCatalog
        let lanPeerDiscovery = lanPeerDiscovery
        let clock = now
        let activeRelayPolicyService = resolvedPolicyService
        let transportVerificationMode = transportVerificationMode
        let customPrivatePaths = customPrivatePaths
        let networkPathSnapshotComposer = networkPathSnapshotComposer
        let platformNetworkPathSnapshot = networkPathSnapshot
        let runtime = try CmxIrohClientRuntime(
            factory: endpointFactoryProvider(transportVerificationMode),
            broker: broker,
            configuration: configuration,
            pendingRevocations: pendingRevocations,
            protocolConfiguration: Self.protocolConfiguration(
                for: transportVerificationMode
            ),
            diagnosticLog: diagnosticLog,
            offlinePolicyCache: offlinePolicies,
            networkPathSnapshot: {
                let platform = try await platformNetworkPathSnapshot()
                let custom = await customPrivatePaths.availableSnapshot(
                    accountID: accountID
                )
                return await networkPathSnapshotComposer.compose(
                    platform: platform,
                    custom: custom
                )
            },
            lanFallback: { [diagnosticLog] target, bindings, rendezvous in
                guard let lanPeerDiscovery else { return [] }
                switch await lanPeerDiscovery.discover(
                    rendezvous: rendezvous,
                    authenticatedBindings: bindings,
                    expectedMacDeviceID: target.deviceID,
                    expectedEndpointID: target.endpointID
                ) {
                case let .found(peers):
                    var hints: [CmxIrohPathHint] = []
                    for peer in peers where peer.binding == target {
                        for hint in peer.pathHints where !hints.contains(hint) {
                            hints.append(hint)
                            if hints.count == CmxIrohLANTXTRecord.maximumAddressCount {
                                break
                            }
                        }
                        if hints.count == CmxIrohLANTXTRecord.maximumAddressCount {
                            break
                        }
                    }
                    diagnosticLog?.record(DiagnosticEvent(
                        .transportLANDiscovery,
                        a: DiagnosticLANDiscoveryOutcome.found.rawValue,
                        b: hints.count
                    ))
                    return hints
                case .notFound:
                    diagnosticLog?.record(DiagnosticEvent(
                        .transportLANDiscovery,
                        a: DiagnosticLANDiscoveryOutcome.notFound.rawValue,
                        b: 0
                    ))
                    return []
                case .policyDenied:
                    diagnosticLog?.record(DiagnosticEvent(
                        .transportLANDiscovery,
                        a: DiagnosticLANDiscoveryOutcome.policyDenied.rawValue,
                        b: 0
                    ))
                    return []
                }
            },
            customPrivateFallback: { expectedMacDeviceID, expectedInstanceTag in
                await customPrivatePaths.enabledPaths(
                    forMacDeviceID: expectedMacDeviceID,
                    instanceTag: expectedInstanceTag,
                    accountID: accountID
                )
            },
            automaticRelayCredentialRefreshEnabled: automaticRelayCredentialRefreshEnabled,
            handleBinding: { [weak self] binding, discovery in
                guard await self?.allowsPersistence(
                    accountID: accountID,
                    revision: revision
                ) == true else { return false }
                try? await credentialRepository.saveBinding(
                    CmxIrohBrokerBindingMetadata(binding: binding),
                    accountID: accountID
                )
                guard await self?.allowsPersistence(
                    accountID: accountID,
                    revision: revision
                ) == true,
                await routeCatalog.replace(
                    with: discovery,
                    scope: revision
                ) else { return false }
                return await MainActor.run {
                    guard let self,
                          revision == self.lifecycleRevision,
                          self.signOutPhase.allowsLifecycle,
                          self.observedAccountID == accountID else { return false }
                    self.lastKnownBindingID = binding.bindingID
                    self.lastKnownBindingAccountID = accountID
                    self.lastKnownBindingTag = self.tag
                    return true
                }
            },
            handleCachedBindings: { [weak self] bindings, _ in
                guard await self?.allowsPersistence(
                    accountID: accountID,
                    revision: revision
                ) == true else { return }
                await routeCatalog.replaceCachedBindings(bindings, scope: revision)
            },
            handleRelayCredential: { [weak self] response, binding in
                guard await self?.allowsPersistence(
                    accountID: accountID,
                    revision: revision
                ) == true else { return }
                let expectedRelayFleet = await activeRelayPolicyService?.managedPolicy()
                    .map { Set($0.relays.map(\.url)) } ?? managedRelayURLs
                try? await credentialRepository.saveRelayCredential(
                    response,
                    accountID: accountID,
                    binding: CmxIrohBrokerBindingMetadata(binding: binding),
                    expectedRelayFleet: expectedRelayFleet,
                    now: clock()
                )
            },
            handleLocalDeactivation: { [appInstances, identities, brokerCredentials] in
                await routeCatalog.deactivate(scope: revision)
                await lanPeerDiscovery?.stop()
                try? await brokerCredentials.deactivate()
                try? await identities.deactivate()
                await appInstances.deactivate()
            },
            handlePolicyInvalidation: { [weak self] in
                await routeCatalog.deactivate(scope: revision)
                await lanPeerDiscovery?.stop()
                try? await credentialRepository.deactivate()
                await MainActor.run {
                    guard let self,
                          revision == self.lifecycleRevision,
                          self.activeAccountID == accountID else { return }
                    self.runtime = nil
                    self.selectedPathObservationTask?.cancel()
                    self.selectedPathObservationTask = nil
                    self.clearLastKnownBinding()
                }
            }
        )
        await routeCatalog.activate(scope: revision)
        do {
            try await runtime.start()
        } catch {
            await runtime.stop()
            await routeCatalog.deactivate(scope: revision)
            throw error
        }
        guard revision == lifecycleRevision,
              !Task.isCancelled,
              signOutPhase.allowsLifecycle,
              observedAccountID == accountID else {
            if !signOutPhase.allowsLifecycle || observedAccountID != accountID {
                _ = await runtime.deactivateForSignOut()
            } else {
                await runtime.stop()
            }
            throw CancellationError()
        }
        self.runtime = runtime
        activeAccountID = accountID
        diagnosticLog?.record(DiagnosticEvent(.endpointActive, a: DiagnosticTransportKind.iroh.rawValue))
        relayPolicyService = resolvedPolicyService
        relayPolicyEffective = resolvedEffectivePolicy
        relayPolicyDiagnostics = await resolvedPolicyService?.diagnosticsSnapshot()
        relayPolicyEndpointID = endpointID
        observeSelectedPathChanges(
            runtime: runtime,
            accountID: accountID,
            revision: revision
        )
        observeRelayPolicyDiagnostics(
            service: resolvedPolicyService,
            accountID: accountID,
            revision: revision
        )
        scheduleRelayPolicyRefresh(
            service: resolvedPolicyService,
            accountID: accountID,
            endpointID: endpointID,
            trustRoot: relayPolicyTrustRoot,
            revision: revision,
            refreshImmediately: relayPolicyNeedsImmediateRefresh
        )
        publishIrohSettingsUpdate()
    }

    private func allowsPersistence(
        accountID: String,
        revision: UInt64
    ) -> Bool {
        revision == lifecycleRevision
            && signOutPhase.allowsLifecycle
            && observedAccountID == accountID
    }

    private func wipeLocalState() async {
        let accountID = activeAccountID ?? lastKnownBindingAccountID
        await lanPeerDiscovery?.stop()
        await routeCatalog.clear()
        try? await brokerCredentials.deactivate()
        try? await offlinePolicies.deactivate()
        try? await identities.deactivate()
        if let accountID {
            try? await relayPreferenceStore.deactivate(accountID: accountID)
            try? await customRelayCredentials.deactivate(accountID: accountID)
        }
        await appInstances.deactivate()
        clearRelayPolicyRuntimeState()
    }

    private func enqueueFallbackRevocation(
        accountID: String?,
        bindingID: String?
    ) async -> CmxIrohClientSignOutPreparation {
        guard let accountID,
              let bindingID,
              lastKnownBindingAccountID == nil
                  || lastKnownBindingAccountID == accountID,
              lastKnownBindingTag == nil || lastKnownBindingTag == tag,
              let pending = try? CmxIrohPendingRevocation(
                  accountID: accountID,
                  tag: tag,
                  bindingID: bindingID
              ) else {
            return CmxIrohClientSignOutPreparation(
                pendingRevocation: nil,
                wasPersisted: true
            )
        }
        do {
            try await pendingRevocations.enqueue(pending)
            if lastKnownBindingID == bindingID {
                clearLastKnownBinding()
            }
            return CmxIrohClientSignOutPreparation(
                pendingRevocation: pending,
                wasPersisted: true
            )
        } catch {
            mobileIrohLog.error(
                "Iroh binding revocation queue failed: \(String(describing: error), privacy: .private)"
            )
            return CmxIrohClientSignOutPreparation(
                pendingRevocation: pending,
                wasPersisted: false
            )
        }
    }

    private func clearLastKnownBinding() {
        lastKnownBindingID = nil
        lastKnownBindingAccountID = nil
        lastKnownBindingTag = nil
    }

    func currentNetworkPathSnapshot() async throws -> CmxIrohNetworkPathSnapshot {
        try await networkPathSnapshot()
    }

    private static func peerIdentity(
        for identity: CmxIrohIdentityMaterial
    ) throws -> CmxIrohPeerIdentity {
        let privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: identity.secretKey.bytes
        )
        return try CmxIrohPeerIdentity(
            endpointID: privateKey.publicKey.rawRepresentation
                .map { String(format: "%02x", $0) }
                .joined()
        )
    }

    private static func identityStore(
        appNamespace: MobileIOSAppNamespace,
        keychainAccessGroup: String?
    ) -> any CmxIrohSecureIdentityStoring {
        #if DEBUG
        CmxIrohDevelopmentFileIdentityStore(
            directory: developmentStoreDirectory(
                service: "identity",
                bundleIdentifier: appNamespace.bundleIdentifier
            )
        )
        #else
        CmxIrohKeychainIdentityStore(
            service: appNamespace.keychainService(
                base: "com.cmuxterm.iroh.endpoint-identity.v1"
            ),
            accessGroup: keychainAccessGroup,
            legacyService: "com.cmuxterm.iroh.endpoint-identity.v1"
        )
        #endif
    }

    /// The same-device evidence probe `DeviceRegistryService` gates pre-witness
    /// mirror adoption on, aware of where THIS composition actually stores iroh
    /// endpoint identities.
    ///
    /// In Release the identity is an `AfterFirstUnlockThisDeviceOnly` Keychain
    /// item that never travels in a device backup, so its presence proves the
    /// install is continuing on the same hardware — exactly the
    /// in-place-upgrade population whose live binding the mirror id must keep;
    /// `IrohEndpointIdentityEvidenceProbe` reports it three-state (present /
    /// absent / Keychain-locked). In DEBUG the identity lives in a development
    /// FILE store instead, so probing the Keychain would report `.absent` for
    /// every continuing dev install and mint (stranding the dev binding behind
    /// `endpoint_already_bound`); probe the file store there. Every production
    /// caller resolving the device id must pass THIS probe, so concurrent
    /// resolutions agree.
    nonisolated static func sameDeviceEvidenceProbe(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> any SameDeviceEvidenceProbing {
        #if DEBUG
        MobileIrohDevelopmentFileEvidenceProbe(bundleIdentifier: bundleIdentifier)
        #else
        IrohEndpointIdentityEvidenceProbe()
        #endif
    }

    private static func credentialStore(
        service: String,
        appNamespace: MobileIOSAppNamespace,
        keychainAccessGroup: String?
    ) -> any CmxIrohSecureCredentialStoring {
        #if DEBUG
        CmxIrohDevelopmentFileCredentialStore(
            directory: developmentStoreDirectory(
                service: service,
                bundleIdentifier: appNamespace.bundleIdentifier
            )
        )
        #else
        CmxIrohKeychainCredentialStore(
            service: appNamespace.keychainService(
                base: "com.cmuxterm.iroh.\(service).v1"
            ),
            accessGroup: keychainAccessGroup,
            legacyService: "com.cmuxterm.iroh.\(service).v1"
        )
        #endif
    }

    static func keychainAccessGroup(
        infoDictionary: [String: Any]?
    ) -> String? {
        MobileKeychainAccessGroupPolicy.resolve(
            infoDictionary?["CMUXKeychainAccessGroup"] as? String
        )
    }

    static func initialTransportVerificationMode(
        defaults: UserDefaults
    ) -> CmxIrohTransportVerificationMode {
        #if DEBUG
        if let rawValue = defaults.string(
            forKey: CmxIrohTransportVerificationMode.debugDefaultsKey
        ), let mode = CmxIrohTransportVerificationMode(rawValue: rawValue) {
            return mode
        }
        #endif
        return CmxIrohPathPreference.stored(in: defaults).transportVerificationMode
    }

    #if DEBUG
    static func debugTransportVerificationMode(
        defaults: UserDefaults
    ) -> CmxIrohTransportVerificationMode {
        initialTransportVerificationMode(defaults: defaults)
    }

    nonisolated fileprivate static func developmentStoreDirectory(
        service: String,
        bundleIdentifier: String?
    ) -> URL {
        let rawBundleScope = bundleIdentifier ?? "dev.cmux.ios.debug"
        let bundleScope = String(rawBundleScope.map { character in
            character.isASCII
                && (character.isLetter
                    || character.isNumber
                    || ["-", ".", "_"].contains(character))
                ? character
                : "_"
        })
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return applicationSupport
            .appendingPathComponent("iroh-debug", isDirectory: true)
            .appendingPathComponent(bundleScope, isDirectory: true)
            .appendingPathComponent(service, isDirectory: true)
    }
    #endif

    static func protocolConfiguration(
        for mode: CmxIrohTransportVerificationMode
    ) -> CmxIrohProtocolConfiguration {
        CmxIrohProtocolConfiguration(
            alpn: CmxIrohProtocolConfiguration.cmuxMobileV1.alpn,
            maximumHeaderByteCount: CmxIrohProtocolConfiguration.cmuxMobileV1
                .maximumHeaderByteCount,
            maximumConcurrentClientApplicationLaneCount: 5,
            allowsNATTraversalAfterAdmission: mode.allowsNATTraversalAfterAdmission
        )
    }

    nonisolated private static func diagnosticFailureKind(
        for error: any Error
    ) -> DiagnosticFailureKind {
        DiagnosticFailureKind.classify(error)
    }

    nonisolated private static func discoveryPeerTags(
        for policy: MobileMacBuildCompatibilityPolicy?
    ) -> [String]? {
        switch policy {
        case let .development(expectedInstanceTag, additionalInstanceTags):
            [expectedInstanceTag] + additionalInstanceTags.sorted()
        case .official:
            ["default", "nightly"]
        case nil:
            nil
        }
    }

    private static func currentTag(
        infoDictionary: [String: Any]?,
        bundleIdentifier: String?
    ) -> String {
        let raw = MobileIOSBuildScope.current(
            infoDictionary: infoDictionary,
            bundleIdentifier: bundleIdentifier
        )?.value ?? "default"
        let normalized = String(raw.prefix(64)).lowercased().map { character in
            (character.isASCII && (character.isLetter || character.isNumber))
                || ["-", ".", ":", "_"].contains(character)
                ? character
                : "-"
        }
        let value = String(normalized)
        return value.isEmpty ? "default" : value
    }

    static func resolvedBrokerBaseURL(
        apiBaseURL: String,
        infoDictionary: [String: Any]?,
        bundleIdentifier: String? = nil,
        allowsLoopback: Bool = true
    ) -> URL? {
        if let baked = infoDictionary?["CMUXIrohBrokerBaseURL"] as? String {
            let trimmed = baked.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return validatedBrokerBaseURL(trimmed, allowsLoopback: allowsLoopback)
            }
        }
        let authEnvironment = (infoDictionary?["CMUXAuthEnvironment"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if authEnvironment == "production" {
            return URL(string: "https://cmux.com")
        }
        if MobileIOSBuildScope.current(
            infoDictionary: infoDictionary,
            bundleIdentifier: bundleIdentifier
        ) != nil {
            return URL(string: "https://cmux-staging.vercel.app")
        }
        return validatedBrokerBaseURL(apiBaseURL, allowsLoopback: allowsLoopback)
    }

    private static func validatedBrokerBaseURL(
        _ rawValue: String,
        allowsLoopback: Bool
    ) -> URL? {
        guard let url = URL(string: rawValue),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }
        if scheme == "https" { return url }
        let loopbackHosts = ["127.0.0.1", "::1", "localhost"]
        guard allowsLoopback,
              scheme == "http",
              loopbackHosts.contains(host) else { return nil }
        return url
    }
}

extension MobileIrohRuntimeComposition: CmxIrohSettingsControlling {
    public func irohSettingsSnapshot() async -> CmxIrohSettingsSnapshot {
        let service = relayPolicyService
        let effective = await service?.effectivePolicy() ?? relayPolicyEffective
        let diagnostics = await service?.diagnosticsSnapshot() ?? relayPolicyDiagnostics
        let managedPolicy = await service?.managedPolicy() ?? effective?.managedPolicy
        let runtimeState = await runtime?.snapshot().state
        let selectedPath = await runtime?.selectedTransportPath(
            relayPolicy: effective
        ) ?? .unavailable
        let configuration = effective?.requestedConfiguration
        let requested = configuration?.activePreference
        let selectedIDs = configuration?.selectedManagedRelayIDs.isEmpty == false
            ? configuration?.selectedManagedRelayIDs ?? []
            : Set(diagnostics?.selectedRelayIDs ?? [])
        let configuredCredentialIDs = if let service, let activeAccountID {
            await service.configuredCustomCredentialRelayIDs(accountID: activeAccountID)
        } else {
            Optional<Set<String>>.none
        }
        let privatePathSnapshot: CmxIrohCustomPrivatePathSnapshot
        // Fall back to the observed account like the settings mutations do:
        // activeAccountID is nil while a transport-mode change restarts the
        // runtime, and snapshots published mid-restart must not drop the
        // persisted private-address configurations from Settings.
        if let accountID = observedAccountID ?? activeAccountID {
            privatePathSnapshot = await customPrivatePaths.availableSnapshot(
                accountID: accountID
            )
        } else {
            privatePathSnapshot = .unavailable
        }
        let liveMacs = await routeCatalog.liveMacCandidates(preferredTag: tag)
        var privateNetworkMacsByID: [String: CmxIrohSettingsSnapshot.PrivateNetworkMac] = [:]
        for mac in liveMacs {
            let identity = CmxMacAppInstanceIdentity(
                macDeviceID: mac.deviceID,
                instanceTag: mac.instanceTag
            )
            let id = identity.id
            if privateNetworkMacsByID[id] == nil {
                privateNetworkMacsByID[id] = .init(
                    macDeviceID: identity.macDeviceID,
                    instanceTag: identity.instanceTag,
                    displayName: mac.displayName ?? "",
                    supportsPrivatePaths: mac.capabilities.contains(
                        "iroh.private_paths.v1"
                    )
                )
            }
        }
        for configuration in privatePathSnapshot.configurations {
            if privateNetworkMacsByID[configuration.id] == nil {
                privateNetworkMacsByID[configuration.id] = .init(
                    macDeviceID: configuration.macDeviceID,
                    instanceTag: configuration.instanceTag,
                    displayName: configuration.macDisplayName
                )
            }
        }
        #if DEBUG
        let debugTransportVerificationMode: CmxIrohTransportVerificationMode? =
            debugDefaults == nil ? nil : transportVerificationMode
        #else
        let debugTransportVerificationMode: CmxIrohTransportVerificationMode? = nil
        #endif
        return CmxIrohSettingsSnapshot(
            runtimeStatus: Self.settingsRuntimeStatus(
                runtimeState,
                failure: diagnostics?.failure,
                selectedPath: selectedPath
            ),
            selectedTransportPath: selectedPath,
            preference: Self.settingsPreference(requested),
            pathPreference: debugDefaults.map {
                CmxIrohPathPreference.stored(in: $0)
            } ?? .automatic,
            managedRelays: managedPolicy?.relays.map { relay in
                CmxIrohSettingsSnapshot.ManagedRelay(
                    id: relay.id,
                    provider: relay.provider,
                    region: relay.region,
                    url: relay.url,
                    isSelected: selectedIDs.contains(relay.id)
                )
            } ?? [],
            customRelays: Self.settingsCustomRelays(
                configuration: configuration,
                configuredCredentialIDs: configuredCredentialIDs
            ),
            privateNetworkMacs: privateNetworkMacsByID.values.sorted {
                if $0.displayName != $1.displayName {
                    return $0.displayName.localizedCaseInsensitiveCompare(
                        $1.displayName
                    ) == .orderedAscending
                }
                return $0.id < $1.id
            },
            customPrivateNetworks: privatePathSnapshot.configurations.map {
                CmxIrohSettingsSnapshot.CustomPrivateNetwork(
                    macDeviceID: $0.macDeviceID,
                    instanceTag: $0.instanceTag,
                    macDisplayName: $0.macDisplayName,
                    addresses: $0.addresses.map(\.value),
                    isEnabled: $0.isEnabled
                )
            },
            policySource: Self.settingsPolicySource(effective),
            policySequence: diagnostics?.policySequence,
            policyExpiresAt: diagnostics?.policyExpiresAt,
            staleRelayIDs: Set(diagnostics?.staleRelayIDs ?? []),
            failureDescription: diagnostics?.failure?.rawValue,
            debugTransportVerificationMode: debugTransportVerificationMode
        )
    }

    public func irohSettingsUpdates() -> AsyncStream<CmxIrohSettingsSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            irohSettingsContinuations[id] = continuation
            Task { @MainActor [weak self] in
                guard let self else { return }
                continuation.yield(await self.irohSettingsSnapshot())
            }
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in
                    self?.irohSettingsContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    public func setIrohRelayPreference(
        _ preference: CmxIrohRelayPreferenceDraft
    ) async throws {
        let validated = try preference.validated()
        let context = try relaySettingsContext()
        let current = await context.service.accountConfiguration() ?? .automatic
        let mapped: CmxIrohAccountRelayPreference
        switch validated {
        case .automatic:
            mapped = .automatic
        case let .managed(ids):
            mapped = .managed(ids)
        case .custom:
            guard !current.customRelays.isEmpty else {
                throw SettingsError.incompleteCustomRelay
            }
            mapped = .custom(current.customRelays)
        }
        let effective = try await context.service.setConfiguration(
            current.updatingActivePreference(mapped),
            accountID: context.accountID,
            trustRoot: context.trustRoot,
            now: now()
        )
        try await applyRelayPolicy(effective)
        await refreshRelayPolicyAfterMutation(context)
    }

    public func upsertIrohCustomRelay(
        _ relay: CmxIrohCustomRelayDraft,
        deviceSecret: String?
    ) async throws {
        let context = try relaySettingsContext()
        let current = await context.service.accountConfiguration() ?? .automatic
        var definitions = current.customRelays
        let requestedID = relay.id?.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = (requestedID?.isEmpty == false ? requestedID : nil)?
            .lowercased() ?? UUID().uuidString.lowercased()
        let existingIndex = definitions.firstIndex(where: { $0.id == id })
        let existingDefinition = existingIndex.map { definitions[$0] }
        if relay.authMode == .deviceSecret,
           existingDefinition?.authMode != .staticToken,
           deviceSecret?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw SettingsError.incompleteCustomRelay
        }
        let displayName = relay.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let definition = try CmxIrohCustomRelayDefinition(
            id: id,
            url: Self.canonicalRelayURL(relay.url),
            provider: relay.provider.trimmingCharacters(in: .whitespacesAndNewlines),
            region: relay.region.trimmingCharacters(in: .whitespacesAndNewlines),
            displayName: displayName.isEmpty ? nil : displayName,
            authMode: relay.authMode == .deviceSecret ? .staticToken : .none
        )
        if let existingIndex {
            definitions[existingIndex] = definition
        } else {
            definitions.append(definition)
        }
        var effective = try await context.service.setConfiguration(
            current.replacingCustomRelays(definitions),
            accountID: context.accountID,
            trustRoot: context.trustRoot,
            now: now()
        )
        try await applyRelayPolicy(effective)
        if definition.authMode == .staticToken, let deviceSecret {
            effective = try await context.service.setStaticCredential(
                deviceSecret,
                relayID: definition.id,
                relayURL: definition.url,
                accountID: context.accountID,
                trustRoot: context.trustRoot,
                now: now()
            )
            try await applyRelayPolicy(effective)
        }
        await refreshRelayPolicyAfterMutation(context)
    }

    public func removeIrohCustomRelay(id: String) async throws {
        let context = try relaySettingsContext()
        let current = await context.service.accountConfiguration() ?? .automatic
        guard current.customRelays.contains(where: { $0.id == id }) else {
            throw SettingsError.missingCustomRelay
        }
        let remaining = current.customRelays.filter { $0.id != id }
        let effective = try await context.service.setConfiguration(
            current.replacingCustomRelays(remaining),
            accountID: context.accountID,
            trustRoot: context.trustRoot,
            now: now()
        )
        try await applyRelayPolicy(effective)
        await refreshRelayPolicyAfterMutation(context)
    }

    public func testIrohCustomRelay(id: String) async -> CmxIrohRelayTestResult {
        guard let effective = await relayPolicyService?.effectivePolicy(),
              let definition = effective.requestedConfiguration?.customRelays.first(where: {
                  $0.id == id
              }),
              !effective.missingCredentialRelayIDs.contains(id) else {
            return .incomplete
        }
        // Device-secret relays may bind credentials to the live EndpointID.
        // The isolated probe intentionally uses an unpersisted throwaway key.
        guard definition.authMode == .none,
              let relay = try? CmxIrohCustomRelay(url: definition.url),
              let profile = try? CmxIrohCustomRelayProfile(relays: [relay]) else {
            return .incomplete
        }
        switch await CmxIrohCustomRelayProbe().probe(
            profile: CmxIrohEndpointRelayProfile(customProfile: profile)
        ) {
        case .reachable:
            return .reachable(latencyMilliseconds: nil)
        case .invalidProfile, .bindFailed, .endpointClosed, .timedOut:
            return .failed
        }
    }

    public func runIrohConnectionCheck() async -> CmxIrohConnectionCheckReport {
        await refreshIrohSettings()
        let snapshot = await irohSettingsSnapshot()
        let diagnostics = await irohDiagnosticReport()
        let relayReachability: CmxIrohConnectionCheckReport.RelayReachability
        if transportVerificationMode == .directOnly {
            // Relays are administratively excluded by the transport mode; a
            // failed relay probe here must not send users to corporate IT.
            relayReachability = .notConfigured
        } else if let profile = await relayPolicyService?.effectivePolicy()?.endpointRelayProfile,
                  !profile.allowedRelayURLs.isEmpty {
            if let isReachable = await runtime?.hasReachableRelay(in: profile.allowedRelayURLs) {
                relayReachability = isReachable ? .reachable : .unreachable
            } else {
                relayReachability = .unavailable
            }
        } else {
            relayReachability = .notConfigured
        }
        let macDiscovery: CmxIrohConnectionCheckReport.MacDiscovery =
            await routeCatalog.liveMacCandidates(preferredTag: tag).isEmpty ? .missing : .found
        return CmxIrohConnectionCheckReport(
            role: .mobileClient,
            snapshot: snapshot,
            diagnostics: diagnostics,
            relayReachability: relayReachability,
            macDiscovery: macDiscovery
        )
    }

    public func upsertIrohCustomPrivatePath(
        _ path: CmxIrohCustomPrivatePathDraft
    ) async throws {
        guard let activeAccountID else {
            throw SettingsError.unavailableCustomPrivatePath
        }
        _ = try await customPrivatePaths.upsert(
            path,
            accountID: activeAccountID
        )
        publishIrohSettingsUpdate()
    }

    public func removeIrohCustomPrivatePath(
        macDeviceID: String,
        instanceTag: String?
    ) async throws {
        guard let activeAccountID else {
            throw SettingsError.unavailableCustomPrivatePath
        }
        _ = try await customPrivatePaths.remove(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            accountID: activeAccountID
        )
        publishIrohSettingsUpdate()
    }

    public func refreshIrohSettings() async {
        guard let context = try? relaySettingsContext() else {
            publishIrohSettingsUpdate()
            return
        }
        diagnosticLog?.record(DiagnosticEvent(.relayPolicyRefreshStarted))
        do {
            let effective = try await context.service.refresh(
                endpointID: context.endpointID,
                accountID: context.accountID,
                trustRoot: context.trustRoot,
                now: now()
            )
            try await applyRelayPolicy(effective)
            diagnosticLog?.record(DiagnosticEvent(.relayPolicyRefreshSucceeded))
        } catch {
            diagnosticLog?.record(DiagnosticEvent(
                .relayPolicyRefreshFailed,
                b: Self.diagnosticFailureKind(for: error).rawValue
            ))
            relayPolicyDiagnostics = await context.service.diagnosticsSnapshot()
            publishIrohSettingsUpdate()
        }
    }

    public func irohDiagnosticReport() async -> DiagnosticReport {
        await diagnosticLog?.snapshot() ?? .empty
    }

    public func exportIrohDiagnosticReport() async -> Data {
        await diagnosticLog?.export() ?? Data()
    }

    public func clearIrohDiagnosticReport() async {
        await diagnosticLog?.clear()
        diagnosticArchive?.clear()
        previousLaunchDiagnosticReport = .some(nil)
        publishIrohSettingsUpdate()
    }

    public func irohPreviousLaunchDiagnosticReport() async -> DiagnosticReport? {
        if let cached = previousLaunchDiagnosticReport { return cached }
        let loaded = diagnosticArchive?.load()
        previousLaunchDiagnosticReport = .some(loaded)
        return loaded
    }

    private func observeRelayPolicyDiagnostics(
        service: CmxIrohRelayPolicyService?,
        accountID: String,
        revision: UInt64
    ) {
        relayPolicyObservationTask?.cancel()
        guard let service else { return }
        relayPolicyObservationTask = Task { @MainActor [weak self] in
            let snapshots = await service.diagnosticsSnapshots()
            for await snapshot in snapshots {
                guard !Task.isCancelled,
                      let self,
                      revision == self.lifecycleRevision,
                      self.activeAccountID == accountID else { return }
                self.relayPolicyDiagnostics = snapshot
                self.relayPolicyEffective = await service.effectivePolicy()
                self.publishIrohSettingsUpdate()
            }
        }
    }

    private func observeSelectedPathChanges(
        runtime: CmxIrohClientRuntime,
        accountID: String,
        revision: UInt64
    ) {
        selectedPathObservationTask?.cancel()
        selectedPathObservationTask = Task { @MainActor [weak self] in
            let changes = await runtime.selectedTransportPathChanges()
            for await _ in changes {
                guard !Task.isCancelled,
                      let self,
                      revision == self.lifecycleRevision,
                      self.activeAccountID == accountID,
                      self.runtime === runtime else { return }
                let selectedPath = await runtime.selectedTransportPath(
                    relayPolicy: self.relayPolicyEffective
                )
                self.diagnosticLog?.record(DiagnosticEvent(
                    .selectedPathChanged,
                    a: DiagnosticPathKind(selectedPath).rawValue
                ))
                self.publishIrohSettingsUpdate()
            }
        }
    }

    /// Refreshes the signed relay catalog before expiry and removes relay
    /// authority at expiry when the broker remains unavailable. The endpoint
    /// and authenticated sessions remain available for direct Iroh paths.
    private func scheduleRelayPolicyRefresh(
        service: CmxIrohRelayPolicyService?,
        accountID: String,
        endpointID: CmxIrohPeerIdentity,
        trustRoot: CmxIrohRelayPolicyTrustRoot?,
        revision: UInt64,
        refreshImmediately: Bool
    ) {
        relayPolicyRefreshTask?.cancel()
        guard Self.shouldScheduleRelayPolicyRefresh(
            automaticRelayCredentialRefreshEnabled:
                automaticRelayCredentialRefreshEnabled,
            serviceAvailable: service != nil,
            trustRootAvailable: trustRoot != nil
        ),
        let service,
        let trustRoot else {
            relayPolicyRefreshTask = nil
            return
        }
        let refreshBackoff = makeRelayPolicyRefreshBackoff()
        relayPolicyRefreshTask = Task { @MainActor [weak self] in
            var retryAt: Date?
            var relayAuthorityExpired = false
            var shouldRefreshImmediately = refreshImmediately
            while !Task.isCancelled {
                guard let self,
                      revision == self.lifecycleRevision,
                      self.activeAccountID == accountID,
                      self.relayPolicyService === service else { return }
                let snapshot = await service.diagnosticsSnapshot()
                let current = self.now()
                let attemptAt: Date
                if shouldRefreshImmediately {
                    attemptAt = current
                    shouldRefreshImmediately = false
                } else {
                    attemptAt = Self.relayPolicyRefreshAttemptDate(
                        policyExpiresAt: relayAuthorityExpired
                            ? nil
                            : snapshot.policyExpiresAt,
                        retryAt: retryAt,
                        now: current
                    )
                }
                let delay = attemptAt.timeIntervalSince(current)
                if delay > 0 {
                    do {
                        try await Task.sleep(for: .seconds(delay))
                    } catch {
                        return
                    }
                }
                let wakeDate = self.now()
                if let retryAt,
                   retryAt > wakeDate,
                   Self.shouldDeactivateRelayPolicy(
                       policyExpiresAt: snapshot.policyExpiresAt,
                       now: wakeDate
                   ) {
                    let expired = await service.restore(
                        accountID: accountID,
                        trustRoot: trustRoot,
                        now: wakeDate
                    )
                    try? await self.applyRelayPolicy(expired)
                    relayAuthorityExpired = true
                    continue
                }
                guard !Task.isCancelled,
                      revision == self.lifecycleRevision,
                      self.activeAccountID == accountID,
                      self.relayPolicyService === service else { return }
                self.diagnosticLog?.record(DiagnosticEvent(.relayPolicyRefreshStarted))
                do {
                    let effective = try await service.refresh(
                        endpointID: endpointID,
                        accountID: accountID,
                        trustRoot: trustRoot,
                        now: self.now()
                    )
                    try await self.applyRelayPolicy(effective)
                    retryAt = nil
                    refreshBackoff.reset()
                    relayAuthorityExpired = false
                    self.diagnosticLog?.record(DiagnosticEvent(.relayPolicyRefreshSucceeded))
                } catch {
                    self.diagnosticLog?.record(DiagnosticEvent(
                        .relayPolicyRefreshFailed,
                        b: Self.diagnosticFailureKind(for: error).rawValue
                    ))
                    let failureDate = self.now()
                    if Self.shouldDeactivateRelayPolicy(
                        policyExpiresAt: snapshot.policyExpiresAt,
                        now: failureDate
                    ) {
                        let expired = await service.restore(
                            accountID: accountID,
                            trustRoot: trustRoot,
                            now: failureDate
                        )
                        try? await self.applyRelayPolicy(expired)
                        relayAuthorityExpired = true
                    } else {
                        self.relayPolicyDiagnostics = await service.diagnosticsSnapshot()
                        self.publishIrohSettingsUpdate()
                    }
                    // The shared foreground ladder replaces the host-profile
                    // exponential schedule whose 30 s first retry produced the
                    // observed 32-36 s naps after a single transient blip.
                    let retryDelay = refreshBackoff.nextDelay(
                        retryAfterSeconds: (error as? any CmxRetryAfterProviding)?
                            .retryAfterSeconds
                    )
                    retryAt = failureDate.addingTimeInterval(retryDelay)
                    self.diagnosticLog?.record(DiagnosticEvent(
                        .retryScheduled,
                        ms: UInt32(clamping: Int(retryDelay * 1_000)),
                        a: DiagnosticTransportKind.iroh.rawValue
                    ))
                }
            }
        }
    }

    /// The signed policy bootstrap includes a fresh relay credential. Tests
    /// that suspend automatic credential renewal must therefore suspend this
    /// lane as well as the credential coordinator's timer.
    nonisolated static func shouldScheduleRelayPolicyRefresh(
        automaticRelayCredentialRefreshEnabled: Bool,
        serviceAvailable: Bool,
        trustRootAvailable: Bool
    ) -> Bool {
        automaticRelayCredentialRefreshEnabled
            && serviceAvailable
            && trustRootAvailable
    }

    nonisolated static func relayPolicyRefreshAttemptDate(
        policyExpiresAt: Date?,
        retryAt: Date?,
        now: Date
    ) -> Date {
        if let retryAt {
            return min(retryAt, policyExpiresAt ?? retryAt)
        }
        if let policyExpiresAt {
            return policyExpiresAt.addingTimeInterval(-60)
        }
        return now.addingTimeInterval(30)
    }

    nonisolated static func shouldDeactivateRelayPolicy(
        policyExpiresAt: Date?,
        now: Date
    ) -> Bool {
        guard let policyExpiresAt else { return false }
        return now >= policyExpiresAt
    }

    private func publishIrohSettingsUpdate() {
        guard !irohSettingsContinuations.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await self.irohSettingsSnapshot()
            for continuation in self.irohSettingsContinuations.values {
                continuation.yield(snapshot)
            }
        }
    }

    private func relaySettingsContext() throws -> (
        service: CmxIrohRelayPolicyService,
        accountID: String,
        endpointID: CmxIrohPeerIdentity,
        trustRoot: CmxIrohRelayPolicyTrustRoot
    ) {
        guard let relayPolicyService,
              let activeAccountID,
              let relayPolicyEndpointID,
              let relayPolicyTrustRoot else { throw SettingsError.unavailable }
        return (relayPolicyService, activeAccountID, relayPolicyEndpointID, relayPolicyTrustRoot)
    }

    private func refreshRelayPolicyAfterMutation(
        _ context: (
            service: CmxIrohRelayPolicyService,
            accountID: String,
            endpointID: CmxIrohPeerIdentity,
            trustRoot: CmxIrohRelayPolicyTrustRoot
        )
    ) async {
        do {
            let effective = try await context.service.refresh(
                endpointID: context.endpointID,
                accountID: context.accountID,
                trustRoot: context.trustRoot,
                now: now()
            )
            try await applyRelayPolicy(effective)
        } catch {
            relayPolicyDiagnostics = await context.service.diagnosticsSnapshot()
            publishIrohSettingsUpdate()
        }
    }

    private func applyRelayPolicy(
        _ effective: CmxIrohEffectiveRelayPolicy
    ) async throws {
        relayPolicyEffective = effective
        relayPolicyDiagnostics = await relayPolicyService?.diagnosticsSnapshot()
        if let runtime {
            try await runtime.replaceRelayPolicy(effective)
        }
        publishIrohSettingsUpdate()
    }

    private func clearRelayPolicyRuntimeState() {
        relayPolicyObservationTask?.cancel()
        relayPolicyObservationTask = nil
        relayPolicyRefreshTask?.cancel()
        relayPolicyRefreshTask = nil
        relayPolicyService = nil
        relayPolicyEffective = nil
        relayPolicyDiagnostics = nil
        relayPolicyEndpointID = nil
        publishIrohSettingsUpdate()
    }

    private nonisolated static func settingsRuntimeStatus(
        _ state: CmxIrohClientRuntimeState?,
        failure: CmxIrohRelayPolicyFailure?,
        selectedPath: CmxIrohSelectedTransportPath
    ) -> CmxIrohSettingsSnapshot.RuntimeStatus {
        if failure != nil { return .degraded }
        switch state {
        case .active: return CmxIrohSettingsSnapshot.RuntimeStatus(activePath: selectedPath)
        case .starting: return .starting
        case .failed, .quarantined: return .degraded
        case .inactive, .stopping, .signingOut, nil: return .inactive
        }
    }

    private nonisolated static func settingsPreference(
        _ preference: CmxIrohAccountRelayPreference?
    ) -> CmxIrohRelayPreferenceDraft {
        switch preference {
        case .automatic, nil: return .automatic
        case let .managed(ids): return .managed(ids)
        case .custom: return .custom
        }
    }

    private nonisolated static func settingsCustomRelays(
        configuration: CmxIrohAccountRelayConfiguration?,
        configuredCredentialIDs: Set<String>?
    ) -> [CmxIrohSettingsSnapshot.CustomRelay] {
        configuration?.customRelays.map { relay in
            let credentialState: CmxIrohSettingsSnapshot.CredentialState
            if relay.authMode == .none {
                credentialState = .notRequired
            } else if configuredCredentialIDs == nil {
                credentialState = .unavailable
            } else {
                credentialState = configuredCredentialIDs?.contains(relay.id) == true
                    ? .configured
                    : .missing
            }
            return CmxIrohSettingsSnapshot.CustomRelay(
                id: relay.id,
                displayName: relay.displayName ?? relay.id,
                provider: relay.provider,
                region: relay.region,
                url: relay.url,
                authMode: relay.authMode == .staticToken ? .deviceSecret : .none,
                credentialState: credentialState
            )
        } ?? []
    }

    private nonisolated static func settingsPolicySource(
        _ effective: CmxIrohEffectiveRelayPolicy?
    ) -> CmxIrohSettingsSnapshot.PolicySource {
        guard let effective else { return .unavailable }
        return effective.usedCachedPolicy ? .cached : .server
    }

    private nonisolated static func canonicalRelayURL(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return trimmed }
        components.host = components.host?.lowercased()
        if components.path.isEmpty { components.path = "/" }
        return components.string ?? trimmed
    }

    nonisolated static func relayPolicyTrustRoot(
        infoDictionary: [String: Any]?
    ) -> CmxIrohRelayPolicyTrustRoot? {
        CmxIrohRelayPolicyTrustRoot.appPinned(infoDictionary: infoDictionary)
    }
}

/// Failure surfaced when a hidden computer cannot be forgotten.
enum MobileIrohForgetError: Error {
    /// No account is authenticated, so no bindings can be revoked.
    case notAuthenticated
    /// The authenticated account changed after the forget began, so the revoke
    /// was aborted rather than applied to a different account's bindings.
    case accountChanged
    /// The requested Mac belongs to another build lane.
    case incompatibleBuild
    /// The operation's total deadline elapsed before every matching binding was
    /// revoked. Already-applied revokes stand; retrying the forget re-discovers
    /// and revokes only what remains.
    case deadlineExceeded
}

extension MobileIrohRuntimeComposition {
    /// Revokes every non-revoked binding for one saved computer.
    ///
    /// Uses a direct authenticated broker (no endpoint/runtime required), so an
    /// offline Mac's binding is still listed by ``CmxIrohClientBrokerServing/discover()``
    /// and can be revoked. Matches by canonical device id, and by exact tag when
    /// the caller knows the app instance, then revokes each match. A no-match
    /// discovery is treated as already-forgotten and succeeds.
    public func forgetComputer(
        macDeviceID: String,
        instanceTag: String?,
        expectedAccountID: String
    ) async throws {
        // Race the WHOLE forget — credential capture, discovery, backpressure
        // waits, and every revoke — against the deadline, WITHOUT structurally
        // awaiting the loser: a task group waits for every child before
        // returning, so a revoke suspended on a dependency that ignores
        // cooperative cancellation would keep the forget (and its UI busy
        // state) stuck past the deadline — exactly the stalled-request case
        // the deadline exists to recover from. Unstructured tasks racing
        // through a one-shot gate let the deadline RETURN immediately;
        // cancellation is still requested on both racers, in-flight URLSession
        // work unwinds cooperatively in the background, already-applied
        // revokes stand, and a retry re-discovers only what remains.
        let gate = MobileIrohForgetRaceGate()
        let outcome = await withCheckedContinuation { (
            continuation: CheckedContinuation<Result<Void, any Error>?, Never>
        ) in
            let work = Task { [weak self] in
                let result: Result<Void, any Error>
                do {
                    guard let self else { throw MobileIrohForgetError.notAuthenticated }
                    try await self.revokeMatchingBindings(
                        macDeviceID: macDeviceID,
                        instanceTag: instanceTag,
                        expectedAccountID: expectedAccountID
                    )
                    result = .success(())
                } catch {
                    result = .failure(error)
                }
                if await gate.claim() {
                    continuation.resume(returning: result)
                }
            }
            Task {
                try? await Self.forgetDeadlineSleep(Self.forgetRevokeDeadlineSeconds)
                if await gate.claim() {
                    work.cancel()
                    continuation.resume(returning: nil)
                }
            }
        }
        guard let outcome else { throw MobileIrohForgetError.deadlineExceeded }
        try outcome.get()
    }

    private func revokeMatchingBindings(
        macDeviceID: String,
        instanceTag: String?,
        expectedAccountID: String
    ) async throws {
        guard let auth else { throw MobileIrohForgetError.notAuthenticated }
        if let instanceTag, !isCompatibleMacTag(instanceTag) {
            throw MobileIrohForgetError.incompatibleBuild
        }
        // Capture the account identity AND both tokens as one consistent snapshot
        // from a single auth-session generation, so the revoke acts with
        // credentials that provably belong to `expectedAccountID`. Reading the
        // observed identity and the live tokens separately (the previous approach)
        // let a lagging observed id authorize the revoke while `currentTokens()`
        // already returned a different account's freshly stored tokens.
        let session: AuthenticatedSessionSnapshot
        do {
            session = try await auth.authenticatedSessionSnapshot()
        } catch {
            throw MobileIrohForgetError.notAuthenticated
        }
        guard session.accountID == expectedAccountID else {
            throw MobileIrohForgetError.accountChanged
        }
        let broker = try makeBrokerBundle(
            accountID: expectedAccountID,
            tokenSource: brokerTokenSource(pinnedSession: session),
            bindingAuthorization: try await managementBindingAuthorization(
                accountID: expectedAccountID
            )
        ).client
        let snapshot = try await broker.discover()
        // The authenticated session can change while discover() is in flight
        // (sign-out then sign-in, even as the same user). Revoking now would target
        // the NEW session's bindings, so re-validate before any mutation.
        try ensureSessionUnchanged(
            generation: session.generation,
            expectedAccountID: expectedAccountID
        )
        let canonicalTarget = cmxCanonicalDeviceID(macDeviceID)
        let matches = snapshot.bindings.filter { binding in
            let bindingIdentity = CmxMacAppInstanceIdentity(
                macDeviceID: binding.deviceID,
                instanceTag: binding.tag
            )
            guard bindingIdentity.macDeviceID == canonicalTarget else {
                return false
            }
            guard isCompatibleMacTag(bindingIdentity.instanceTag) else {
                return false
            }
            if let instanceTag {
                return bindingIdentity.instanceTag == CmxMacAppInstanceIdentity(
                    macDeviceID: canonicalTarget,
                    instanceTag: instanceTag
                ).instanceTag
            }
            return true
        }
        // Bound the WHOLE operation. Each revoke request carries its own network
        // timeout, so a large sequential loop could keep the forget (and its UI
        // progress state) busy for tens of minutes. Past the deadline, stop and
        // surface the failure: already-applied revokes stand, and retrying the
        // forget re-discovers and revokes only what remains.
        let deadline = now().addingTimeInterval(Self.forgetRevokeDeadlineSeconds)
        for binding in matches {
            guard now() < deadline else {
                throw MobileIrohForgetError.deadlineExceeded
            }
            try ensureSessionUnchanged(
                generation: session.generation,
                expectedAccountID: expectedAccountID
            )
            try await broker.forgetMac(bindingID: binding.bindingID)
        }
    }

    private func isCompatibleMacTag(_ candidate: String?) -> Bool {
        if let discoveryCompatibilityPolicy {
            return discoveryCompatibilityPolicy.allows(instanceTag: candidate)
        }
        let normalized = candidate?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized == tag.lowercased()
    }

    private func managementBindingAuthorization(
        accountID: String
    ) async throws -> CmxIrohBindingRequestAuthorization {
        let appInstanceID = try await appInstances.appInstanceID(
            accountID: accountID,
            tag: tag
        )
        let identity = try await identities.identity(
            accountID: accountID,
            appInstanceID: appInstanceID
        )
        let endpointID = try Self.peerIdentity(for: identity)
        guard let binding = try await brokerCredentials.loadBinding(
            accountID: accountID,
            appInstanceID: appInstanceID
        ),
        binding.appInstanceID == appInstanceID,
        binding.clientNamespace == clientNamespace,
        binding.tag == tag,
        binding.platform == .ios,
        binding.endpointID == endpointID,
        binding.identityGeneration == identity.generation else {
            throw CmxIrohClientRuntimeError.inactive
        }
        return try CmxIrohBindingRequestAuthorization(
            bindingID: binding.bindingID,
            clientNamespace: clientNamespace,
            identity: identity,
            endpointID: endpointID
        )
    }

    /// Total wall-clock budget for one forget's revoke loop. Six sequential
    /// worst-case broker timeouts fit comfortably; a healthy broker revokes
    /// dozens of bindings well within it.
    private static let forgetRevokeDeadlineSeconds: TimeInterval = 60

    /// Cancellable sleeper backing the forget deadline race — an intentional
    /// bounded timeout (cancelled with the race, never a synchronization
    /// substitute). Static because extensions cannot hold instance storage.
    private static let forgetDeadlineSleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Throws if the authenticated session that initiated the forget was replaced,
    /// so a revoke can never land on a different session's bindings. Requires both
    /// the session generation and the account id to be unchanged: the generation
    /// catches a sign-out/sign-in even when the same account signs back in, while
    /// the account id catches a switch to a different user.
    private func ensureSessionUnchanged(
        generation: UInt64,
        expectedAccountID: String
    ) throws {
        guard sessionMatches(generation: generation, accountID: expectedAccountID) else {
            throw MobileIrohForgetError.accountChanged
        }
    }

    /// Whether the live auth session is still the exact one (generation + account)
    /// the forget pinned to.
    private func sessionMatches(generation: UInt64, accountID: String) -> Bool {
        guard let auth else { return false }
        return auth.authSessionGeneration == generation && auth.currentUser?.id == accountID
    }

    /// Broker token source for LONG-LIVED clients (the activation runtime):
    /// pinned to the activating ACCOUNT, re-reading an ATOMIC authenticated
    /// snapshot on every request. Freezing an activation-time pair would go
    /// stale the moment an ordinary force refresh rotates the Stack pair,
    /// leaving the runtime's relay refresh and discovery failing until an
    /// unrelated reconcile. The snapshot binds identity and credentials in one
    /// capture — it rejects reads while a session transition owns the token
    /// store — so a sign-out/sign-in completing while the read is suspended can
    /// never hand this runtime a DIFFERENT account's credentials; the account
    /// pin then fails closed on any switch. The pin is deliberately NOT
    /// generation-scoped: every completed sign-in advances the generation, and
    /// a same-account re-sign-in must keep this runtime serviceable — it is
    /// still the same user, so serving the new session's credentials is the
    /// correct behavior, whereas a generation pin would strand the runtime on
    /// nil credentials until a restart. (Short-lived destructive operations —
    /// the forget's frozen pair — stay strictly generation-pinned.) The
    /// snapshot's pair capture is store-level (no network while the stored
    /// access token is valid), so this stays cheap per request.
    private func brokerTokenSource(
        pinnedTo expectedAccountID: String
    ) -> CmxIrohBrokerTokenSource {
        .accountPinned(
            to: expectedAccountID,
            snapshot: { [weak auth] in
                guard let auth else { return nil }
                let session: AuthenticatedSessionSnapshot
                do {
                    session = try await auth.authenticatedSessionSnapshot()
                } catch AuthError.unauthorized {
                    // Definitively signed out: fail closed (the broker reports
                    // missingAuthentication and activation stops).
                    return nil
                }
                // Every other failure (revalidation owns the token store, an
                // expired access token's re-mint is in flight or offline) is
                // transient: rethrow so the broker classifies it connectivity
                // and activation falls back to the cached verified policy
                // instead of failing closed on every launch.
                return CmxIrohAccountCredentialSnapshot(
                    accountID: session.accountID,
                    credentials: CmxIrohBrokerCredentials(
                        accessToken: session.accessToken,
                        refreshToken: session.refreshToken
                    )
                )
            },
            forceRefresh: { [weak auth] in
                guard let auth else { return }
                _ = try await auth.forceRefreshAccessToken()
            }
        )
    }

    /// Broker token source that reuses the ONE coherent credential pair captured
    /// when the forget started, for every broker leg.
    ///
    /// Each fetch performs only the CHEAP local session check (generation +
    /// account, no network). Re-capturing a session snapshot per request would
    /// mint a fresh Stack access token for the discovery and for EVERY sequential
    /// revoke, turning one destructive action into an unbounded chain of network
    /// mints that can stall for minutes and fail during a Stack outage despite
    /// the valid pinned credentials already in hand. The pinned pair is coherent
    /// by construction (minted together in one snapshot), and the access token
    /// always travels with its refresh token, so the server can re-mint on its
    /// side if the access token expires mid-operation. A mid-forget sign-out or
    /// account switch fails the local check and yields `nil`, so the revoke
    /// fails safely rather than acting as the wrong user.
    private func brokerTokenSource(
        pinnedSession session: AuthenticatedSessionSnapshot
    ) -> CmxIrohBrokerTokenSource {
        CmxIrohBrokerTokenSource(
            credentialPair: { [weak self] in
                await self?.pinnedBrokerCredentials(session)
            }
        )
    }

    /// The pinned pair while the live auth session still matches the snapshot's
    /// generation and account; `nil` once the session moved.
    private func pinnedBrokerCredentials(
        _ session: AuthenticatedSessionSnapshot
    ) -> CmxIrohBrokerCredentials? {
        guard sessionMatches(
            generation: session.generation,
            accountID: session.accountID
        ) else { return nil }
        return CmxIrohBrokerCredentials(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken
        )
    }

    public func setIrohPathPreference(
        _ preference: CmxIrohPathPreference
    ) async throws {
        guard let defaults = debugDefaults else { throw SettingsError.unavailable }
        defaults.set(
            preference.rawValue,
            forKey: CmxIrohPathPreference.defaultsKey
        )
        #if DEBUG
        defaults.removeObject(
            forKey: CmxIrohTransportVerificationMode.debugDefaultsKey
        )
        #endif
        let mode = preference.transportVerificationMode
        guard transportVerificationMode != mode else {
            publishIrohSettingsUpdate()
            return
        }
        transportVerificationMode = mode
        publishIrohSettingsUpdate()
        guard let accountID = observedAccountID ?? activeAccountID else { return }
        await scheduleReconcile(
            targetAccountID: accountID,
            eraseAccountState: false,
            restartActiveRuntime: true
        ).value
    }
}

#if DEBUG
extension MobileIrohRuntimeComposition: CmxIrohDebugSettingsControlling {
    public func setIrohDebugTransportVerificationMode(
        _ mode: CmxIrohTransportVerificationMode
    ) async throws {
        guard transportVerificationMode != mode else { return }
        guard let debugDefaults else { throw SettingsError.unavailable }

        debugDefaults.set(
            mode.rawValue,
            forKey: CmxIrohTransportVerificationMode.debugDefaultsKey
        )
        transportVerificationMode = mode
        publishIrohSettingsUpdate()

        guard let accountID = observedAccountID ?? activeAccountID else { return }
        await scheduleReconcile(
            targetAccountID: accountID,
            eraseAccountState: false,
            restartActiveRuntime: true
        ).value
    }
}
#endif
