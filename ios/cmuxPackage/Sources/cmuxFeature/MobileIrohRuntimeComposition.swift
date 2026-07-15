import CMUXMobileCore
import CmuxAuthRuntime
public import CmuxIrohTransport
import CmuxMobileShell
import CmuxMobileTransport
import CryptoKit
import Foundation
import OSLog

nonisolated private let mobileIrohLog = Logger(
    subsystem: "dev.cmux.ios",
    category: "iroh-runtime"
)

/// Process-owned iOS composition for account-scoped Iroh networking.
@MainActor
public final class MobileIrohRuntimeComposition: CmxIrohDeferredTransportProviding {
    enum SettingsError: Error, Equatable {
        case unavailable
        case incompleteCustomRelay
        case missingCustomRelay
    }
    typealias BrokerFactory = @Sendable (
        _ tokenSource: CmxIrohBrokerTokenSource
    ) throws -> any CmxIrohClientBrokerServing

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

    private static let capabilities = ["mobile-rpc-v1", "multistream-v1"]
    /// The stable factory registered before debug-loopback and Tailscale fallbacks.
    public lazy var transportFactory = CmxIrohByteTransportFactory(
        deferredProvider: self
    )

    /// Broker-verified personal-account Mac routes used only for paired reconnects.
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
    private let relayPolicyTrustRoot: CmxIrohRelayPolicyTrustRoot?
    private let endpointFactory: any CmxIrohEndpointFactory
    private let transportVerificationMode: CmxIrohTransportVerificationMode
    private let brokerFactory: BrokerFactory
    private let deviceID: @Sendable () -> String
    private let tag: String
    private let now: @Sendable () -> Date
    private let startNetworkPathObservation: @Sendable () async -> Void
    private let networkPathSnapshot: @Sendable () async throws -> CmxIrohNetworkPathSnapshot
    private let lanPeerDiscovery: CmxIrohLANPeerDiscovery?
    private let authObserver = MobileIrohAuthObserver()

    private weak var auth: AuthCoordinator?
    private var authObservationTask: Task<Void, Never>?
    private var transitionTask: Task<Void, Never>?
    private var sceneTransitionTask: Task<Void, Never>?
    private var runtime: CmxIrohClientRuntime?
    private var relayPolicyService: CmxIrohRelayPolicyService?
    private var relayPolicyEffective: CmxIrohEffectiveRelayPolicy?
    private var relayPolicyDiagnostics: CmxIrohRelayDiagnosticsSnapshot?
    private var relayPolicyEndpointID: CmxIrohPeerIdentity?
    private var relayPolicyObservationTask: Task<Void, Never>?
    private var relayPolicyRefreshTask: Task<Void, Never>?
    private var selectedPathObservationTask: Task<Void, Never>?
    private var irohSettingsContinuations: [UUID: AsyncStream<CmxIrohSettingsSnapshot>.Continuation] = [:]
    private var observedAccountID: String?
    private var activeAccountID: String?
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
        defaults: UserDefaults = .standard,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) {
        #if DEBUG
        let transportVerificationMode = Self.debugTransportVerificationMode(
            defaults: defaults
        )
        #else
        let transportVerificationMode = CmxIrohTransportVerificationMode.automatic
        #endif
        let installState = CmxIrohUserDefaultsInstallStateStore(defaults: defaults)
        let baseURL = URL(string: apiBaseURL)
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
        let stableDeviceID = DeviceRegistryService.deviceID(defaults: defaults)
        self.init(
            appInstances: CmxIrohAppInstanceRepository(store: installState),
            identities: CmxIrohIdentityRepository(
                secureStore: Self.identityStore(
                    bundleIdentifier: bundleIdentifier
                ),
                installState: installState
            ),
            brokerCredentials: CmxIrohBrokerCredentialRepository(
                secureStore: Self.credentialStore(
                    service: "broker-credentials",
                    bundleIdentifier: bundleIdentifier
                ),
                installState: installState
            ),
            pendingRevocations: CmxIrohPendingRevocationOutbox(
                secureStore: Self.credentialStore(
                    service: "pending-revocations",
                    bundleIdentifier: bundleIdentifier
                )
            ),
            offlinePolicies: CmxIrohClientOfflinePolicyCache(
                secureStore: Self.credentialStore(
                    service: "client-offline-policy",
                    bundleIdentifier: bundleIdentifier
                )
            ),
            customRelayProfiles: CmxIrohCustomRelayProfileStore(
                secureStore: Self.credentialStore(
                    service: "custom-relays",
                    bundleIdentifier: bundleIdentifier
                )
            ),
            relayPolicyCache: CmxIrohRelayPolicyCache(
                secureStore: Self.credentialStore(
                    service: "relay-policy",
                    bundleIdentifier: bundleIdentifier
                )
            ),
            relayPreferenceStore: CmxIrohRelayPreferenceStore(
                secureStore: Self.credentialStore(
                    service: "relay-preference",
                    bundleIdentifier: bundleIdentifier
                )
            ),
            customRelayCredentials: CmxIrohCustomRelayCredentialStore(
                secureStore: Self.credentialStore(
                    service: "custom-relay-credentials",
                    bundleIdentifier: bundleIdentifier
                )
            ),
            relayPolicyTrustRoot: Self.relayPolicyTrustRoot(
                infoDictionary: infoDictionary
            ),
            endpointFactory: CmxIrohLibEndpointFactory(
                transportVerificationMode: transportVerificationMode
            ),
            transportVerificationMode: transportVerificationMode,
            brokerFactory: { tokenSource in
                guard let baseURL else {
                    throw CmxIrohTrustBrokerClientError.invalidBaseURL
                }
                return try CmxIrohTrustBrokerClient(
                    baseURL: baseURL,
                    tokenSource: tokenSource
                )
            },
            deviceID: { stableDeviceID },
            tag: Self.currentTag(
                infoDictionary: infoDictionary,
                bundleIdentifier: bundleIdentifier
            ),
            now: { Date() },
            lanPeerDiscovery: lanPeerDiscovery,
            startNetworkPathObservation: {
                await networkPathState.start(
                    reachability: reachability,
                    onPathChange: { await lanPeerDiscovery.pathDidChange() }
                )
            },
            networkPathSnapshot: {
                await networkPathState.snapshot()
            }
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
        relayPolicyTrustRoot: CmxIrohRelayPolicyTrustRoot? = nil,
        endpointFactory: any CmxIrohEndpointFactory,
        transportVerificationMode: CmxIrohTransportVerificationMode = .automatic,
        brokerFactory: @escaping BrokerFactory,
        deviceID: @escaping @Sendable () -> String,
        tag: String,
        now: @escaping @Sendable () -> Date,
        routeCatalog: MobileIrohRouteCatalog = MobileIrohRouteCatalog(),
        lanPeerDiscovery: CmxIrohLANPeerDiscovery? = nil,
        startNetworkPathObservation: @escaping @Sendable () async -> Void = {},
        networkPathSnapshot: @escaping @Sendable () async throws -> CmxIrohNetworkPathSnapshot = {
            CmxIrohNetworkPathSnapshot(generation: 1, activeNetworkProfiles: [])
        }
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
        self.relayPolicyTrustRoot = relayPolicyTrustRoot
        self.endpointFactory = endpointFactory
        self.transportVerificationMode = transportVerificationMode
        self.brokerFactory = brokerFactory
        self.deviceID = deviceID
        self.tag = tag
        self.now = now
        self.routeCatalog = routeCatalog
        self.lanPeerDiscovery = lanPeerDiscovery
        self.startNetworkPathObservation = startNetworkPathObservation
        self.networkPathSnapshot = networkPathSnapshot
    }

    /// Starts auth observation after the coordinator's launch restore completes.
    ///
    /// - Parameter auth: The process-owned authentication coordinator.
    public func configure(auth: AuthCoordinator) {
        self.auth = auth
        authObservationTask?.cancel()
        authObservationTask = Task { @MainActor [weak self, weak auth] in
            guard let auth else { return }
            await self?.startNetworkPathObservation()
            await auth.awaitBootstrapped()
            guard !Task.isCancelled, let self else { return }
            let initial = MobileIrohAuthState(
                accountID: auth.isAuthenticated ? auth.currentUser?.id : nil
            )
            await self.applyAuthState(initial)
            let states = self.authObserver.states(for: auth)
            for await state in states {
                guard !Task.isCancelled else { return }
                await self.applyAuthState(state)
            }
        }
    }

    /// Waits for the authenticated endpoint, broker binding, and relay policy.
    ///
    /// Tagged attach-URL launches use this barrier before starting the shell's
    /// bounded pairing attempt. Transport creation calls the same entrypoint,
    /// so readiness policy cannot drift between automatic and interactive use.
    public func prepareForConnection() async {
        await reconcileLiveAuthIfNeeded()
        await transitionTask?.value
    }

    /// Resolves a disconnected transport from the active account runtime.
    public func transport(
        for request: CmxByteTransportRequest
    ) async throws -> any CmxByteTransport {
        await prepareForConnection()
        guard let runtime else { throw CmxIrohClientRuntimeError.inactive }
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
        await reconcileLiveAuthIfNeeded()
        await transitionTask?.value
        guard let runtime else { throw CmxIrohClientRuntimeError.inactive }
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

    /// Starts the one server-event byte stream on the pooled admitted connection.
    public func serverEventByteStream(
        for request: CmxByteTransportRequest
    ) async throws -> CmxIndependentEventByteStream {
        await reconcileLiveAuthIfNeeded()
        await transitionTask?.value
        guard let runtime else { throw CmxIrohClientRuntimeError.inactive }
        return try await runtime.serverEventByteStream(for: request)
    }

    /// Preserves the endpoint when iOS backgrounds the scene.
    public func didEnterBackground() {
        guard signOutPhase.allowsLifecycle else { return }
        sceneTransitionTask?.cancel()
        let runtime = runtime
        sceneTransitionTask = Task {
            await runtime?.didEnterBackground()
        }
    }

    /// Health-checks and refreshes the preserved endpoint on foreground return.
    public func didBecomeActive() {
        guard signOutPhase.allowsLifecycle else { return }
        sceneTransitionTask?.cancel()
        let runtime = runtime
        let lanPeerDiscovery = lanPeerDiscovery
        sceneTransitionTask = Task {
            await lanPeerDiscovery?.permissionMayHaveChanged()
            do {
                try await runtime?.didBecomeActive()
            } catch {
                mobileIrohLog.error(
                    "Iroh foreground health check failed: \(String(describing: error), privacy: .private)"
                )
            }
        }
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
        observedAccountID = nil
        lifecycleRevision &+= 1
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
        guard preparation.pendingRevocation != nil else {
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
            let broker = try brokerFactory(
                CmxIrohBrokerTokenSource(
                    accessToken: { accessToken },
                    refreshToken: { refreshToken }
                )
            )
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
        guard await prepareForAuthReconcile(accountID: state.accountID) else {
            return
        }
        let previousObservedAccountID = observedAccountID
        observedAccountID = state.accountID
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
        let accountID = auth.isAuthenticated ? auth.currentUser?.id : nil
        guard accountID != observedAccountID else { return }
        let previousObservedAccountID = observedAccountID
        observedAccountID = accountID
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
        let accountID = auth.isAuthenticated ? auth.currentUser?.id : nil
        guard await prepareForAuthReconcile(accountID: accountID) else {
            return
        }
        guard accountID != observedAccountID || runtime == nil && accountID != nil else {
            return
        }
        let previousObservedAccountID = observedAccountID
        observedAccountID = accountID
        let transition = scheduleReconcile(
            targetAccountID: accountID,
            eraseAccountState: accountID == nil
                || (previousObservedAccountID != nil
                    && previousObservedAccountID != accountID)
                || (activeAccountID != nil && activeAccountID != accountID)
        )
        await transition.value
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
            ) else { return false }
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
                  accountID == preparation.pendingRevocation?.accountID,
                  let auth else { return false }
            do {
                let broker = try brokerFactory(
                    CmxIrohBrokerTokenSource(
                        accessToken: { [weak auth] in
                            guard let auth,
                                  let tokens = try? await auth.currentTokens() else {
                                return nil
                            }
                            return tokens.accessToken
                        },
                        refreshToken: { [weak auth] in
                            guard let auth,
                                  let tokens = try? await auth.currentTokens() else {
                                return nil
                            }
                            return tokens.refreshToken
                        }
                    )
                )
                return await recoverSignOutQuarantine(
                    preparation,
                    using: broker
                )
            } catch {
                mobileIrohLog.error(
                    "Iroh binding revoke retry failed: \(String(describing: error), privacy: .private)"
                )
                return false
            }
        }
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
        guard preparation.pendingRevocation != nil,
              let accessToken,
              !accessToken.isEmpty,
              let refreshToken,
              !refreshToken.isEmpty,
              let broker = try? brokerFactory(
                  CmxIrohBrokerTokenSource(
                      accessToken: { accessToken },
                      refreshToken: { refreshToken }
                  )
              ) else { return }
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
        eraseAccountState: Bool
    ) -> Task<Void, Never> {
        lifecycleRevision &+= 1
        let revision = lifecycleRevision
        let previous = transitionTask
        previous?.cancel()
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self,
                  revision == self.lifecycleRevision,
                  self.signOutPhase.allowsLifecycle,
                  !Task.isCancelled else { return }
            await self.reconcile(
                targetAccountID: targetAccountID,
                eraseAccountState: eraseAccountState,
                revision: revision
            )
            if revision == self.lifecycleRevision {
                self.transitionTask = nil
            }
        }
        transitionTask = task
        return task
    }

    private func reconcile(
        targetAccountID: String?,
        eraseAccountState: Bool,
        revision: UInt64
    ) async {
        if activeAccountID != targetAccountID || targetAccountID == nil {
            let shouldErase = eraseAccountState
                && (targetAccountID == nil || activeAccountID != targetAccountID)
            let previousRuntime = runtime
            let previousAccountID = activeAccountID ?? lastKnownBindingAccountID
            let fallbackBindingID = lastKnownBindingID
            runtime = nil
            selectedPathObservationTask?.cancel()
            selectedPathObservationTask = nil
            activeAccountID = nil
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
              signOutPhase.allowsLifecycle,
              let targetAccountID,
              runtime == nil else { return }
        do {
            try await activate(accountID: targetAccountID, revision: revision)
        } catch is CancellationError {
            return
        } catch {
            mobileIrohLog.error(
                "Iroh client activation failed: \(String(describing: error), privacy: .private)"
            )
        }
    }

    private func activate(accountID: String, revision: UInt64) async throws {
        guard let auth else { throw CmxIrohClientRuntimeError.inactive }
        let appInstanceID = try await appInstances.appInstanceID(
            accountID: accountID,
            tag: tag
        )
        let identity = try await identities.identity(
            accountID: accountID,
            appInstanceID: appInstanceID
        )
        let endpointID = try Self.peerIdentity(for: identity)
        let deviceID = deviceID().lowercased()
        let cachedBinding = try await brokerCredentials.loadBinding(
            accountID: accountID,
            appInstanceID: appInstanceID
        )
        let bindingMatches = cachedBinding.map {
            $0.deviceID == deviceID
                && $0.appInstanceID == appInstanceID
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

        let broker = try brokerFactory(
            CmxIrohBrokerTokenSource(
                accessToken: { [weak auth] in
                    guard let auth,
                          let tokens = try? await auth.currentTokens() else { return nil }
                    return tokens.accessToken
                },
                refreshToken: { [weak auth] in
                    guard let auth,
                          let tokens = try? await auth.currentTokens() else { return nil }
                    return tokens.refreshToken
                }
            )
        )
        let endpointRelayProfile: CmxIrohEndpointRelayProfile?
        let managedRelayURLs: Set<String>
        let resolvedPolicyService: CmxIrohRelayPolicyService?
        let resolvedEffectivePolicy: CmxIrohEffectiveRelayPolicy?
        if let relayPolicyTrustRoot {
            let service = CmxIrohRelayPolicyService(
                policyCache: relayPolicyCache,
                preferenceStore: relayPreferenceStore,
                credentialStore: customRelayCredentials,
                broker: broker as? any CmxIrohRelayPolicyServing
            )
            let effective: CmxIrohEffectiveRelayPolicy
            do {
                effective = try await service.refresh(
                    endpointID: endpointID,
                    accountID: accountID,
                    trustRoot: relayPolicyTrustRoot,
                    now: now()
                )
            } catch {
                effective = await service.restore(
                    accountID: accountID,
                    trustRoot: relayPolicyTrustRoot,
                    relayCredential: cachedRelay,
                    now: now()
                )
                mobileIrohLog.error(
                    "Signed relay policy refresh failed; restored verified cache: \(String(describing: error), privacy: .private)"
                )
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
        let configuration = CmxIrohClientRuntimeConfiguration(
            accountID: accountID,
            deviceID: deviceID,
            appInstanceID: appInstanceID,
            tag: tag,
            displayName: nil,
            identity: identity,
            capabilities: Self.capabilities,
            managedRelayURLs: managedRelayURLs,
            endpointRelayProfile: endpointRelayProfile,
            cachedRelayCredential: compatibleCachedRelay
        )
        let credentialRepository = brokerCredentials
        let routeCatalog = routeCatalog
        let lanPeerDiscovery = lanPeerDiscovery
        let clock = now
        let activeRelayPolicyService = resolvedPolicyService
        let runtime = try CmxIrohClientRuntime(
            factory: endpointFactory,
            broker: broker,
            configuration: configuration,
            pendingRevocations: pendingRevocations,
            protocolConfiguration: Self.protocolConfiguration(
                for: transportVerificationMode
            ),
            offlinePolicyCache: offlinePolicies,
            networkPathSnapshot: networkPathSnapshot,
            lanFallback: { target, bindings, rendezvous in
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
                                return hints
                            }
                        }
                    }
                    return hints
                case .notFound, .policyDenied:
                    return []
                }
            },
            handleBinding: { [weak self] registration, discovery in
                guard await self?.allowsPersistence(
                    accountID: accountID,
                    revision: revision
                ) == true else { return }
                let binding = registration.binding
                try? await credentialRepository.saveBinding(
                    CmxIrohBrokerBindingMetadata(binding: binding),
                    accountID: accountID
                )
                guard await self?.allowsPersistence(
                    accountID: accountID,
                    revision: revision
                ) == true else { return }
                await routeCatalog.replace(with: discovery, scope: revision)
                await MainActor.run {
                    guard let self,
                          revision == self.lifecycleRevision else { return }
                    self.lastKnownBindingID = binding.bindingID
                    self.lastKnownBindingAccountID = accountID
                    self.lastKnownBindingTag = self.tag
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
            revision: revision
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
        bundleIdentifier: String?
    ) -> any CmxIrohSecureIdentityStoring {
        #if DEBUG
        CmxIrohDevelopmentFileIdentityStore(
            directory: developmentStoreDirectory(
                service: "identity",
                bundleIdentifier: bundleIdentifier
            )
        )
        #else
        CmxIrohKeychainIdentityStore()
        #endif
    }

    private static func credentialStore(
        service: String,
        bundleIdentifier: String?
    ) -> any CmxIrohSecureCredentialStoring {
        #if DEBUG
        CmxIrohDevelopmentFileCredentialStore(
            directory: developmentStoreDirectory(
                service: service,
                bundleIdentifier: bundleIdentifier
            )
        )
        #else
        CmxIrohKeychainCredentialStore(
            service: "com.cmuxterm.iroh.\(service).v1"
        )
        #endif
    }

    #if DEBUG
    static func debugTransportVerificationMode(
        defaults: UserDefaults
    ) -> CmxIrohTransportVerificationMode {
        guard let rawValue = defaults.string(
            forKey: CmxIrohTransportVerificationMode.debugDefaultsKey
        ) else { return .automatic }
        return CmxIrohTransportVerificationMode(rawValue: rawValue) ?? .automatic
    }

    private static func developmentStoreDirectory(
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
            maximumConcurrentClientApplicationLaneCount: 4,
            allowsNATTraversalAfterAdmission: mode.allowsNATTraversalAfterAdmission
        )
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
        return CmxIrohSettingsSnapshot(
            runtimeStatus: Self.settingsRuntimeStatus(
                runtimeState,
                failure: diagnostics?.failure,
                selectedPath: selectedPath
            ),
            selectedTransportPath: selectedPath,
            preference: Self.settingsPreference(requested),
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
            policySource: Self.settingsPolicySource(effective),
            policySequence: diagnostics?.policySequence,
            policyExpiresAt: diagnostics?.policyExpiresAt,
            staleRelayIDs: Set(diagnostics?.staleRelayIDs ?? []),
            failureDescription: diagnostics?.failure?.rawValue
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

    public func refreshIrohSettings() async {
        guard let context = try? relaySettingsContext() else {
            publishIrohSettingsUpdate()
            return
        }
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
        revision: UInt64
    ) {
        relayPolicyRefreshTask?.cancel()
        guard let service, let trustRoot else {
            relayPolicyRefreshTask = nil
            return
        }
        relayPolicyRefreshTask = Task { @MainActor [weak self] in
            var retryAt: Date?
            var failureCount = 0
            var relayAuthorityExpired = false
            while !Task.isCancelled {
                guard let self,
                      revision == self.lifecycleRevision,
                      self.activeAccountID == accountID,
                      self.relayPolicyService === service else { return }
                let snapshot = await service.diagnosticsSnapshot()
                let current = self.now()
                let attemptAt = Self.relayPolicyRefreshAttemptDate(
                    policyExpiresAt: relayAuthorityExpired
                        ? nil
                        : snapshot.policyExpiresAt,
                    retryAt: retryAt,
                    now: current
                )
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
                do {
                    let effective = try await service.refresh(
                        endpointID: endpointID,
                        accountID: accountID,
                        trustRoot: trustRoot,
                        now: self.now()
                    )
                    try await self.applyRelayPolicy(effective)
                    retryAt = nil
                    failureCount = 0
                    relayAuthorityExpired = false
                } catch {
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
                    let retryDelay = CmxIrohRetrySchedule().delay(
                        failureCount: failureCount,
                        retryAfterSeconds: (error as? CmxIrohTrustBrokerClientError)?
                            .retryAfterSeconds,
                        jitterUnitInterval: Double.random(in: 0 ... 1)
                    )
                    failureCount = min(failureCount + 1, 20)
                    retryAt = failureDate.addingTimeInterval(retryDelay)
                }
            }
        }
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
