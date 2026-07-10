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
    typealias BrokerFactory = @Sendable (
        _ tokenSource: CmxIrohBrokerTokenSource
    ) throws -> any CmxIrohClientBrokerServing

    private static let managedRelayURLs: Set<String> = [
        "https://aps1-1.relay.lawrence.cmux.iroh.link/",
        "https://euc1-1.relay.lawrence.cmux.iroh.link/",
        "https://use1-1.relay.lawrence.cmux.iroh.link/",
        "https://usw1-1.relay.lawrence.cmux.iroh.link/",
    ]
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
    private let endpointFactory: any CmxIrohEndpointFactory
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
    private var observedAccountID: String?
    private var activeAccountID: String?
    private var lastKnownBindingAccountID: String?
    private var lastKnownBindingTag: String?
    private var lastKnownBindingID: String?
    private var lifecycleRevision: UInt64 = 0
    private var signOutPreparing = false

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
                secureStore: CmxIrohKeychainIdentityStore(),
                installState: installState
            ),
            brokerCredentials: CmxIrohBrokerCredentialRepository(
                secureStore: CmxIrohKeychainCredentialStore(),
                installState: installState
            ),
            pendingRevocations: CmxIrohPendingRevocationOutbox(
                secureStore: CmxIrohKeychainCredentialStore(
                    service: "com.cmuxterm.iroh.pending-revocations.v1"
                )
            ),
            endpointFactory: CmxIrohLibEndpointFactory(),
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
        endpointFactory: any CmxIrohEndpointFactory,
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
        self.endpointFactory = endpointFactory
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

    /// Resolves a disconnected transport from the active account runtime.
    public func transport(
        for request: CmxByteTransportRequest
    ) async throws -> any CmxByteTransport {
        await reconcileLiveAuthIfNeeded()
        await transitionTask?.value
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
        sceneTransitionTask?.cancel()
        let runtime = runtime
        sceneTransitionTask = Task {
            await runtime?.didEnterBackground()
        }
    }

    /// Health-checks and refreshes the preserved endpoint on foreground return.
    public func didBecomeActive() {
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

    /// Stops networking and wipes local Iroh state before auth clears its tokens.
    ///
    /// - Returns: The prior binding needed by the captured-token remote hook.
    public func prepareSignOut() async -> CmxIrohClientSignOutPreparation {
        signOutPreparing = true
        let fallbackAccountID = activeAccountID ?? observedAccountID
        observedAccountID = nil
        lifecycleRevision &+= 1
        let previous = transitionTask
        transitionTask = nil
        previous?.cancel()
        await previous?.value
        await lanPeerDiscovery?.stop()

        let previousRuntime = runtime
        runtime = nil
        activeAccountID = nil
        let fallbackBindingID = lastKnownBindingID
        if let previousRuntime {
            let preparation = await previousRuntime.deactivateForSignOut()
            if preparation.wasPersisted {
                clearLastKnownBinding()
            } else if preparation.pendingRevocation != nil {
                mobileIrohLog.error("Iroh binding revocation queue failed")
            }
            return preparation
        }
        let preparation = await enqueueFallbackRevocation(
            accountID: fallbackAccountID,
            bindingID: fallbackBindingID
        )
        await wipeLocalState()
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
        defer { finishSignOutPreparation() }
        guard preparation.pendingRevocation != nil,
              let accessToken,
              !accessToken.isEmpty,
              let refreshToken,
              !refreshToken.isEmpty else { return }
        do {
            let broker = try brokerFactory(
                CmxIrohBrokerTokenSource(
                    accessToken: { accessToken },
                    refreshToken: { refreshToken }
                )
            )
            try await preparation.revoke(
                using: broker,
                pendingRevocations: pendingRevocations
            )
            clearLastKnownBinding()
        } catch is CancellationError {
            return
        } catch {
            mobileIrohLog.error(
                "Iroh binding revoke failed: \(String(describing: error), privacy: .private)"
            )
        }
    }

    private func applyAuthState(_ state: MobileIrohAuthState) async {
        guard !signOutPreparing else { return }
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

    private func finishSignOutPreparation() {
        signOutPreparing = false
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
        guard !signOutPreparing else { return }
        let accountID = auth.isAuthenticated ? auth.currentUser?.id : nil
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
            let previousAccountID = activeAccountID
            let fallbackBindingID = lastKnownBindingID
            runtime = nil
            activeAccountID = nil
            await lanPeerDiscovery?.stop()
            if let previousRuntime {
                if shouldErase {
                    let preparation = await previousRuntime.deactivateForSignOut()
                    if preparation.wasPersisted {
                        clearLastKnownBinding()
                    } else if preparation.pendingRevocation != nil {
                        mobileIrohLog.error("Iroh binding revocation queue failed")
                    }
                } else {
                    await previousRuntime.stop()
                }
            } else if shouldErase {
                _ = await enqueueFallbackRevocation(
                    accountID: previousAccountID,
                    bindingID: fallbackBindingID
                )
                await wipeLocalState()
            }
        }
        guard revision == lifecycleRevision,
              !Task.isCancelled,
              !signOutPreparing,
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
        let cachedRelay: CmxIrohRelayTokenResponse?
        if let cachedBinding, bindingMatches {
            lastKnownBindingID = cachedBinding.bindingID
            lastKnownBindingAccountID = accountID
            lastKnownBindingTag = tag
            cachedRelay = try await brokerCredentials.loadRelayCredential(
                accountID: accountID,
                binding: cachedBinding,
                expectedRelayFleet: Self.managedRelayURLs,
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
        let configuration = CmxIrohClientRuntimeConfiguration(
            accountID: accountID,
            deviceID: deviceID,
            appInstanceID: appInstanceID,
            tag: tag,
            displayName: nil,
            identity: identity,
            capabilities: Self.capabilities,
            managedRelayURLs: Self.managedRelayURLs,
            cachedRelayCredential: cachedRelay
        )
        let credentialRepository = brokerCredentials
        let managedRelayURLs = Self.managedRelayURLs
        let routeCatalog = routeCatalog
        let lanPeerDiscovery = lanPeerDiscovery
        let clock = now
        let runtime = try CmxIrohClientRuntime(
            factory: endpointFactory,
            broker: broker,
            configuration: configuration,
            pendingRevocations: pendingRevocations,
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
                let binding = registration.binding
                try? await credentialRepository.saveBinding(
                    CmxIrohBrokerBindingMetadata(binding: binding),
                    accountID: accountID
                )
                await routeCatalog.replace(with: discovery, scope: revision)
                await MainActor.run {
                    guard let self,
                          revision == self.lifecycleRevision else { return }
                    self.lastKnownBindingID = binding.bindingID
                    self.lastKnownBindingAccountID = accountID
                    self.lastKnownBindingTag = self.tag
                }
            },
            handleCachedBindings: { bindings, _ in
                await routeCatalog.replaceCachedBindings(bindings, scope: revision)
            },
            handleRelayCredential: { response, binding in
                try? await credentialRepository.saveRelayCredential(
                    response,
                    accountID: accountID,
                    binding: CmxIrohBrokerBindingMetadata(binding: binding),
                    expectedRelayFleet: managedRelayURLs,
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
              !signOutPreparing,
              observedAccountID == accountID else {
            if signOutPreparing || observedAccountID != accountID {
                _ = await runtime.deactivateForSignOut()
            } else {
                await runtime.stop()
            }
            throw CancellationError()
        }
        self.runtime = runtime
        activeAccountID = accountID
    }

    private func wipeLocalState() async {
        await lanPeerDiscovery?.stop()
        await routeCatalog.clear()
        try? await brokerCredentials.deactivate()
        try? await offlinePolicies.deactivate()
        try? await identities.deactivate()
        await appInstances.deactivate()
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
