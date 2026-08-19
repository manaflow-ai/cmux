import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileShell
import CmuxPeerTransport
import CmuxPeerTransportCore
import Foundation
import OSLog

/// The MainActor-owned inputs one activation attempt snapshots at its start.
struct MobilePeerActivationInputs: Sendable {
    let accountID: String
    let tag: String
    let clientNamespace: String
    let transportVerificationMode: CmxIrohTransportVerificationMode
    let lifecycleRevision: UInt64
    let discoveryPeerTags: [String]?
}

/// The single owner of the endpoint ACTIVATION sequence, driven exclusively by
/// the `PeerConnectionSupervisor`: identity, broker registration behind the
/// account cooldown ledger, relay policy resolve plus relay token mint,
/// endpoint bind, health watchdog. Every failure maps into the supervisor's
/// `PeerDialFailure` taxonomy so retry policy lives in exactly one place.
///
/// `@unchecked Sendable`: the weak composition reference is MainActor-isolated
/// and only ever touched on the MainActor.
final class MobilePeerEndpointActivator: PeerSessionEstablishing, @unchecked Sendable {
    typealias BrokerClientFactory = @Sendable (
        _ baseURL: URL,
        _ tokenProvider: PeerBrokerTokenProvider,
        _ clientNamespace: String,
        _ discoveryScope: PeerDiscoveryScope?
    ) throws -> PeerTrustBrokerClient

    @MainActor weak var composition: MobilePeerRuntimeComposition?

    private let brokerClientFactory: BrokerClientFactory

    init(brokerClientFactory: BrokerClientFactory? = nil) {
        self.brokerClientFactory = brokerClientFactory
            ?? { baseURL, tokenProvider, clientNamespace, discoveryScope in
                try PeerTrustBrokerClient(
                    baseURL: baseURL,
                    tokenProvider: tokenProvider,
                    clientNamespace: clientNamespace,
                    discoveryScope: discoveryScope
                )
            }
    }

    func establish(context: PeerDialContext) async throws -> any PeerSessionHandle {
        let snapshot = await MainActor.run { [weak composition] in
            composition.map { composition in
                (
                    inputs: composition.activationInputs(),
                    brokerBaseURL: composition.brokerBaseURL,
                    trustRoot: composition.relayPolicyTrustRoot,
                    diagnosticLog: composition.diagnosticLog,
                    now: composition.now
                )
            }
        }
        guard let snapshot, let inputs = snapshot.inputs else {
            throw PeerDialFailure(
                classification: .authorizationDenied,
                reason: "no authenticated account"
            )
        }
        let diagnosticLog = snapshot.diagnosticLog
        let now = snapshot.now
        diagnosticLog?.record(DiagnosticEvent(
            .endpointStarting,
            a: DiagnosticTransportKind.iroh.rawValue
        ))
        do {
            let session = try await activate(
                inputs: inputs,
                brokerBaseURL: snapshot.brokerBaseURL,
                trustRoot: snapshot.trustRoot,
                diagnosticLog: diagnosticLog,
                now: now
            )
            diagnosticLog?.record(DiagnosticEvent(
                .endpointActive,
                a: DiagnosticTransportKind.iroh.rawValue
            ))
            return session
        } catch let failure as PeerDialFailure {
            try Task.checkCancellation()
            #if DEBUG
            // The privacy-coded diagnostic ring flattens every transient
            // reason to one kind; dev builds surface the exact step so a
            // wedged activation is diagnosable from the device console.
            Logger(subsystem: "dev.cmux.ios", category: "peer-transport")
                .error("endpoint activation failed: \(failure.reason, privacy: .public)")
            #endif
            diagnosticLog?.record(DiagnosticEvent(
                .endpointFailed,
                a: DiagnosticTransportKind.iroh.rawValue,
                b: Self.failureKind(for: failure).rawValue
            ))
            let retrySeconds = failure.retryAfter.map {
                Int($0.components.seconds) + 1
            }
            await MainActor.run { [weak composition] in
                composition?.publishActivationFailure(
                    kind: Self.failureKind(for: failure),
                    description: failure.reason,
                    retryAfterSeconds: retrySeconds
                )
            }
            throw failure
        }
    }

    // MARK: - Activation sequence

    private func activate(
        inputs: MobilePeerActivationInputs,
        brokerBaseURL: URL?,
        trustRoot: PeerRelayPolicyTrustRoot?,
        diagnosticLog: DiagnosticLog?,
        now: @escaping @Sendable () -> Date
    ) async throws -> MobilePeerEndpointSession {
        let engine = await MainActor.run { [weak composition] in
            composition.map {
                (
                    manager: $0.endpointManager,
                    ledger: $0.cooldownLedger,
                    identities: $0.identities,
                    appInstances: $0.appInstances,
                    relayPolicyCache: $0.relayPolicyCache,
                    deviceID: $0.deviceID
                )
            }
        }
        guard let engine else {
            throw PeerDialFailure(classification: .transient, reason: "composition released")
        }

        // 1. Broker cooldown floor persists across runtime teardown.
        let ledgerKey = PeerBrokerCooldownLedger.Key(accountID: inputs.accountID)
        if let cooldown = await engine.ledger.activeCooldown(key: ledgerKey) {
            throw PeerDialFailure(
                classification: .transient,
                reason: "broker cooldown active",
                retryAfter: cooldown
            )
        }

        // 2. Durable device id BEFORE any endpoint identity exists (restored
        // backups must not adopt a moments-old identity as continuity proof).
        guard let durableDeviceID = await engine.deviceID() else {
            throw PeerDialFailure(
                classification: .transient,
                reason: "durable device id unavailable"
            )
        }
        let deviceID = cmxCanonicalDeviceID(durableDeviceID)
        let appInstanceID = await engine.appInstances.appInstanceID(
            accountID: inputs.accountID,
            tag: inputs.tag
        )

        // 3. Stable per-(account, app-instance) endpoint identity.
        let identity: PeerEndpointIdentity
        do {
            identity = try await engine.identities.identity(
                accountID: inputs.accountID,
                appInstanceID: appInstanceID
            )
        } catch {
            throw PeerDialFailure(
                classification: .transient,
                reason: "identity unavailable: \(String(describing: error))"
            )
        }

        // 4. Registration with the trust broker (challenge + signed payload).
        guard let brokerBaseURL else {
            throw PeerDialFailure(
                classification: .authorizationDenied,
                reason: "broker origin unavailable"
            )
        }
        let broker: PeerTrustBrokerClient
        let signer: PeerRegistrationSigner
        let response: PeerBrokerRegistrationResponse
        do {
            signer = try PeerRegistrationSigner(
                identity: identity,
                endpointID: identity.endpointID.endpointID
            )
            let scope = try PeerDiscoveryScope(
                deviceID: deviceID,
                appInstanceID: appInstanceID,
                tag: inputs.tag,
                platform: .ios,
                peerPlatform: .mac,
                peerTags: inputs.discoveryPeerTags,
                peerPairingEnabled: true
            )
            broker = try brokerClientFactory(
                brokerBaseURL,
                await tokenProvider(pinnedTo: inputs.accountID),
                inputs.clientNamespace,
                scope
            )
            let payload = try PeerRegistrationPayload(
                deviceID: deviceID,
                appInstanceID: appInstanceID,
                clientNamespace: inputs.clientNamespace,
                tag: inputs.tag,
                platform: .ios,
                endpointID: identity.endpointID.endpointID,
                identityGeneration: identity.generation,
                pairingEnabled: true,
                capabilities: MobilePeerRuntimeComposition.capabilities,
                pathHints: []
            )
            let prepared = try signer.prepare(payload: payload)
            response = try await broker.register(prepared: prepared, signer: signer)
        } catch let error as PeerBrokerError {
            if case let .serverRateLimited(retryAfter) = error {
                await engine.ledger.noteRetryAfter(retryAfter, key: ledgerKey)
            }
            throw Self.dialFailure(for: error, stage: "registration")
        } catch let failure as PeerDialFailure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PeerDialFailure(
                classification: .transient,
                reason: "registration failed: \(String(describing: error))"
            )
        }

        // 5. Relay policy resolve (fail-closed cache) + relay token mint.
        let relayPlan = await resolveRelayPlan(
            inputs: inputs,
            identity: identity,
            registration: response,
            broker: broker,
            relayPolicyCache: engine.relayPolicyCache,
            trustRoot: trustRoot,
            diagnosticLog: diagnosticLog,
            now: now
        )

        // 6. Bind the process endpoint (one per process; rebind replaces).
        let generation: PeerTransportGeneration
        do {
            generation = try await engine.manager.activate(
                secretKey: identity.secretKey.bytes,
                relays: relayPlan.configs,
                directOnly: inputs.transportVerificationMode == .directOnly
            )
        } catch {
            throw PeerDialFailure(
                classification: .transient,
                reason: "endpoint bind failed: \(String(describing: error))"
            )
        }

        // 7. Health watchdog: endpoint death is a REMOTE close of this
        // session, so the supervisor rebuilds the whole activation.
        let sessionBox = MobilePeerWeakSessionBox()
        let watchdog = PeerEndpointHealthWatchdog(
            interval: .seconds(15),
            probe: { [manager = engine.manager] in await manager.probeHealth() },
            recreate: { [sessionBox] reason in
                await sessionBox.session?.noteEndpointDied(reason: reason)
            }
        )
        let watchedSession = MobilePeerEndpointSession(
            manager: engine.manager,
            watchdog: watchdog
        )
        sessionBox.session = watchedSession
        await watchdog.start()

        // 8. Relay credential refresh keeps tokens live across their TTL.
        if !relayPlan.configs.isEmpty {
            let refreshTask = Self.relayRefreshTask(
                broker: broker,
                manager: engine.manager,
                endpointID: identity.endpointID,
                allowedRelayURLs: relayPlan.allowedRelayURLs,
                initialCredential: relayPlan.credential,
                now: now
            )
            await watchedSession.adoptRelayRefreshTask(refreshTask)
        }

        // 9. Publish account-runtime state for transports and Settings.
        let discoveryProvider = PeerDiscoveryContextProvider(
            now: now,
            discover: { [broker] in try await broker.discover() }
        )
        let activationState = MobilePeerActivationState(
            accountID: inputs.accountID,
            deviceID: deviceID,
            appInstanceID: appInstanceID,
            binding: response.binding,
            endpointID: identity.endpointID,
            identityGeneration: identity.generation,
            relayURLs: relayPlan.configs.map(\.url),
            managedRelayCatalog: relayPlan.catalog,
            policy: relayPlan.policyState,
            generation: generation
        )
        let embeddedDiscovery = response.embeddedDiscoveryComplete
            ? response.discovery
            : nil
        await MainActor.run { [weak composition] in
            guard let composition,
                  composition.lifecycleRevision == inputs.lifecycleRevision else { return }
            composition.accountBroker = broker
            composition.discoveryProvider = discoveryProvider
            composition.publishActivation(activationState)
            if let embeddedDiscovery {
                let revision = composition.lifecycleRevision
                let routeCatalog = composition.routeCatalog
                Task {
                    await routeCatalog.replace(with: embeddedDiscovery, scope: revision)
                }
            }
        }
        return watchedSession
    }

    // MARK: - Relay plan

    private struct RelayPlan {
        let configs: [PeerRelayEndpointConfig]
        let catalog: [MobilePeerManagedRelayInfo]
        let allowedRelayURLs: Set<String>?
        let credential: PeerBrokerRelayTokenResponse?
        let policyState: MobilePeerRelayPolicyState
    }

    private func resolveRelayPlan(
        inputs: MobilePeerActivationInputs,
        identity: PeerEndpointIdentity,
        registration: PeerBrokerRegistrationResponse,
        broker: PeerTrustBrokerClient,
        relayPolicyCache: PeerRelayPolicyCache,
        trustRoot: PeerRelayPolicyTrustRoot?,
        diagnosticLog: DiagnosticLog?,
        now: @Sendable () -> Date
    ) async -> RelayPlan {
        guard inputs.transportVerificationMode != .directOnly else {
            return RelayPlan(
                configs: [],
                catalog: [],
                allowedRelayURLs: nil,
                credential: nil,
                policyState: .unavailable
            )
        }

        // Verified cached policy constrains the relay fleet; every denial
        // class resolves to "no constraint from policy" and the endpoint uses
        // exactly the broker-minted, endpoint-bound credential fleet.
        var allowedRelayURLs: Set<String>?
        var catalog: [MobilePeerManagedRelayInfo] = []
        var policyState = MobilePeerRelayPolicyState.unavailable
        if let trustRoot {
            let resolution = await relayPolicyCache.resolve(trustRoot: trustRoot, now: now())
            if case let .verified(policy) = resolution {
                allowedRelayURLs = Set(policy.relays.map(\.url))
                catalog = policy.relays.map {
                    MobilePeerManagedRelayInfo(
                        id: $0.id,
                        provider: $0.provider,
                        region: $0.region,
                        url: $0.url
                    )
                }
                policyState = MobilePeerRelayPolicyState(
                    source: .cached,
                    sequence: policy.sequence,
                    expiresAt: Date(timeIntervalSince1970: TimeInterval(policy.expiresAt))
                )
            }
        }

        diagnosticLog?.record(DiagnosticEvent(.relayPolicyRefreshStarted))
        let credential: PeerBrokerRelayTokenResponse?
        var mintFailureReason: String?
        if case let .issued(embedded) = registration.relay {
            credential = embedded
        } else {
            do {
                credential = try await broker.relayToken(endpointID: identity.endpointID)
            } catch {
                credential = nil
                mintFailureReason = String(describing: error)
            }
        }
        guard let credential else {
            #if DEBUG
            Logger(subsystem: "dev.cmux.ios", category: "peer-transport")
                .error(
                    "relay credential mint failed: \(mintFailureReason ?? "?", privacy: .public)"
                )
            #endif
            diagnosticLog?.record(DiagnosticEvent(
                .relayPolicyRefreshFailed,
                b: DiagnosticFailureKind.endpointUnavailable.rawValue
            ))
            return RelayPlan(
                configs: [],
                catalog: catalog,
                allowedRelayURLs: allowedRelayURLs,
                credential: nil,
                policyState: policyState
            )
        }
        // A fresh install has no cached policy; the mint response bundles the
        // current signed policy, which installs through the same verify +
        // rollback-guarded cache path so the relay fleet becomes verified.
        if allowedRelayURLs == nil,
            let trustRoot,
            let signedPolicy = credential.signedPolicy,
            let installed = try? await relayPolicyCache.install(
                signedPolicy: signedPolicy,
                trustRoot: trustRoot,
                now: now()
            )
        {
            allowedRelayURLs = Set(installed.relays.map(\.url))
            catalog = installed.relays.map {
                MobilePeerManagedRelayInfo(
                    id: $0.id,
                    provider: $0.provider,
                    region: $0.region,
                    url: $0.url
                )
            }
            policyState = MobilePeerRelayPolicyState(
                source: .server,
                sequence: installed.sequence,
                expiresAt: Date(timeIntervalSince1970: TimeInterval(installed.expiresAt))
            )
        }
        diagnosticLog?.record(DiagnosticEvent(.relayPolicyRefreshSucceeded))
        let configs = Self.relayConfigs(
            from: credential,
            allowedRelayURLs: allowedRelayURLs
        )
        if catalog.isEmpty {
            catalog = configs.map {
                MobilePeerManagedRelayInfo(id: $0.url, provider: "", region: "", url: $0.url)
            }
        }
        return RelayPlan(
            configs: configs,
            catalog: catalog,
            allowedRelayURLs: allowedRelayURLs,
            credential: credential,
            policyState: policyState
        )
    }

    static func relayConfigs(
        from credential: PeerBrokerRelayTokenResponse,
        allowedRelayURLs: Set<String>?
    ) -> [PeerRelayEndpointConfig] {
        credential.credentials
            .filter { allowedRelayURLs?.contains($0.relayURL) ?? true }
            .map { PeerRelayEndpointConfig(url: $0.relayURL, authToken: $0.token) }
    }

    /// Re-mints endpoint-bound relay tokens before their refresh deadline and
    /// applies them make-before-break, so a live relay path never lapses on
    /// its 300-second credential TTL. Cancellation is wired to the endpoint
    /// session's lifecycle.
    private static func relayRefreshTask(
        broker: PeerTrustBrokerClient,
        manager: PeerEndpointManager,
        endpointID: CmxIrohPeerIdentity,
        allowedRelayURLs: Set<String>?,
        initialCredential: PeerBrokerRelayTokenResponse?,
        now: @escaping @Sendable () -> Date
    ) -> Task<Void, Never> {
        Task {
            var backoff = PeerReconnectBackoff(profile: .foregroundClient)
            var credential = initialCredential
            let clock = ContinuousClock()
            while !Task.isCancelled {
                let delay = Self.refreshDelay(credential: credential, now: now())
                do {
                    try await clock.sleep(for: delay)
                } catch {
                    return
                }
                do {
                    let fresh = try await broker.relayToken(endpointID: endpointID)
                    let freshConfigs = Self.relayConfigs(
                        from: fresh,
                        allowedRelayURLs: allowedRelayURLs
                    )
                    let staleURLs = Set(credential?.relayFleet ?? [])
                        .subtracting(freshConfigs.map(\.url))
                    try await manager.applyRelays(
                        insert: freshConfigs,
                        remove: Array(staleURLs).sorted()
                    )
                    credential = fresh
                    backoff.reset()
                } catch is CancellationError {
                    return
                } catch {
                    // Bounded ladder; the endpoint stays up on direct paths.
                    let retry = backoff.nextDelay()
                    do {
                        try await clock.sleep(for: retry)
                    } catch {
                        return
                    }
                }
            }
        }
    }

    static func refreshDelay(
        credential: PeerBrokerRelayTokenResponse?,
        now: Date
    ) -> Duration {
        let formatter = ISO8601DateFormatter()
        let earliest = credential?.credentials
            .compactMap { formatter.date(from: $0.refreshAfter) }
            .min()
        guard let earliest else { return .seconds(120) }
        return .seconds(max(15, earliest.timeIntervalSince(now)))
    }

    // MARK: - Token provider

    /// Broker token source for the LONG-LIVED endpoint runtime: pinned to the
    /// activating ACCOUNT, re-reading an atomic authenticated snapshot on
    /// every request so an ordinary token rotation never strands the runtime,
    /// while an account switch fails closed per request.
    @MainActor
    private func tokenProvider(pinnedTo accountID: String) -> PeerBrokerTokenProvider {
        let auth = composition?.auth
        return PeerBrokerTokenProvider(
            capture: { @MainActor [weak auth] in
                guard let auth else { return nil }
                let session: AuthenticatedSessionSnapshot
                do {
                    session = try await auth.authenticatedSessionSnapshot()
                } catch AuthError.unauthorized {
                    // Definitively signed out: fail closed.
                    return nil
                }
                guard session.accountID == accountID else { return nil }
                return PeerBrokerCredentials(
                    accessToken: session.accessToken,
                    refreshToken: session.refreshToken
                )
            },
            forceRefresh: { @MainActor [weak auth] in
                guard let auth else { return }
                _ = try await auth.forceRefreshAccessToken()
            }
        )
    }

    // MARK: - Failure mapping

    static func dialFailure(for error: PeerBrokerError, stage: String) -> PeerDialFailure {
        switch error {
        case .connectivity:
            return PeerDialFailure(
                classification: .transient,
                reason: "\(stage): broker unreachable"
            )
        case .unauthorized:
            return PeerDialFailure(
                classification: .authorizationDenied,
                reason: "\(stage): unauthorized"
            )
        case let .denied(statusCode, code):
            let reason = "\(stage): denied \(statusCode) \(code ?? "")"
            return PeerDialFailure(
                classification: error.isTransient ? .transient : .authorizationDenied,
                reason: reason
            )
        case let .serverRateLimited(retryAfter):
            return PeerDialFailure(
                classification: .transient,
                reason: "\(stage): rate limited",
                retryAfter: retryAfter ?? PeerBrokerCooldownLedger.headerlessFloor
            )
        case .protocolError:
            return PeerDialFailure(
                classification: .transient,
                reason: "\(stage): protocol error"
            )
        }
    }

    static func failureKind(for failure: PeerDialFailure) -> DiagnosticFailureKind {
        switch failure.classification {
        case .authorizationDenied:
            return .authorizationFailed
        case .unreachable, .transient:
            return .endpointUnavailable
        }
    }
}

// MARK: - Fresh discovery for discoverLiveMacs

extension MobilePeerRuntimeComposition {
    /// One authenticated broker discovery, gated by the account cooldown floor.
    func freshDiscoverySnapshot(
        activation: MobilePeerActivationState
    ) async throws -> PeerBrokerDiscoverySnapshot {
        guard let accountBroker else {
            throw MobilePeerRuntimePreparationError(
                diagnosticFailureKind: .endpointUnavailable,
                retryAfterSeconds: 1
            )
        }
        let ledgerKey = PeerBrokerCooldownLedger.Key(accountID: activation.accountID)
        if let cooldown = await cooldownLedger.activeCooldown(key: ledgerKey) {
            throw MobilePeerRuntimePreparationError(
                diagnosticFailureKind: .endpointUnavailable,
                retryAfterSeconds: Int(cooldown.components.seconds) + 1
            )
        }
        do {
            return try await accountBroker.discover()
        } catch let error as PeerBrokerError {
            if case let .serverRateLimited(retryAfter) = error {
                await cooldownLedger.noteRetryAfter(retryAfter, key: ledgerKey)
            }
            throw error
        }
    }
}
