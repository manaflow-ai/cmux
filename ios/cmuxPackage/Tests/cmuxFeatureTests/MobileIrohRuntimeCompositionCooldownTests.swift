import AuthenticationServices
import CMUXAuthCore
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import cmuxFeature

@MainActor
@Suite("Mobile Iroh runtime composition broker cooldown", .serialized)
struct MobileIrohRuntimeCompositionCooldownTests {
    /// The production readiness owner is the event-driven barrier. Tests inject
    /// deterministic jitter and await that same barrier instead of polling the
    /// main actor with wall-clock sleeps.
    private func settleActivation(
        _ fixture: MobileIrohCooldownFixture,
        expecting condition: @escaping () async -> Bool
    ) async {
        await fixture.composition.prepareForConnection()
        if !(await condition()) {
            Issue.record("Connection readiness settled before the activation outcome")
        }
    }

    @Test
    func discoveryRateLimitFloorsOnlyDiscoveryAndSurfacesRetryAfter() async throws {
        let fixture = try await MobileIrohCooldownFixture.make(
            registrationError: nil,
            discoveryError: CmxIrohTrustBrokerClientError.rateLimited(
                code: nil,
                retryAfterSeconds: 600
            )
        )

        await settleActivation(fixture) {
            guard await fixture.broker.discoveryRequestCount() >= 1 else {
                return false
            }
            return (await fixture.diagnosticLog.snapshot()).events.contains {
                $0.code == .endpointFailed
            }
        }
        let discoveryCountAtFloor = await fixture.broker.discoveryRequestCount()
        #expect(discoveryCountAtFloor == 1)
        #expect((await fixture.diagnosticLog.snapshot()).events.contains {
            $0.code == .endpointFailed
        })

        // Registration and discovery are separate broker operations. Re-driving
        // activation may refresh registration, but the floored discovery route
        // must remain free until the broker's Retry-After deadline expires.
        await fixture.composition.prepareForConnection()
        await fixture.composition.prepareForConnection()
        #expect(await fixture.broker.discoveryRequestCount() == discoveryCountAtFloor)

        let dialError: any Error
        do {
            _ = try await fixture.composition.transport(for: fixture.request)
            Issue.record("Expected transport creation to fail while activation is cooling down")
            return
        } catch {
            dialError = error
        }
        #expect(await fixture.broker.discoveryRequestCount() == discoveryCountAtFloor)
        #expect((dialError as? any CmxRetryAfterProviding)?.retryAfterSeconds ?? 0 > 0)

        fixture.clock.advance(by: 751)
        await settleActivation(fixture) {
            await fixture.broker.discoveryRequestCount() > discoveryCountAtFloor
        }
        #expect(await fixture.broker.discoveryRequestCount() == discoveryCountAtFloor + 1)
    }

    @Test
    func nonRateLimitedFailureBacksOffAcrossConnectionEntryPoints() async throws {
        let fixture = try await MobileIrohCooldownFixture.make(
            registrationError: MobileIrohCooldownTestError.unavailable
        )

        await settleActivation(fixture) {
            await fixture.broker.totalRequestCount() >= 1
        }
        // Drain any still-running reconcile before counting, so the settled
        // baseline is stable against task-scheduling noise.
        await fixture.composition.prepareForConnection()
        let settledRequestCount = await fixture.broker.totalRequestCount()

        let transportError: any Error
        do {
            _ = try await fixture.composition.transport(for: fixture.request)
            Issue.record("Expected inactive transport creation to fail")
            return
        } catch {
            transportError = error
        }
        #expect((transportError as? any CmxRetryAfterProviding)?.retryAfterSeconds ?? 0 > 0)

        let laneError: any Error
        do {
            _ = try await fixture.composition.openBidirectionalLane(
                for: fixture.request,
                lane: .terminal(
                    resourceID: try CmxIrohResourceID(
                        "terminal:123e4567-e89b-42d3-a456-426614174099"
                    ),
                    cursor: nil
                ),
                priority: 0
            )
            Issue.record("Expected inactive lane creation to fail")
            return
        } catch {
            laneError = error
        }
        #expect((laneError as? any CmxRetryAfterProviding)?.retryAfterSeconds ?? 0 > 0)

        let eventStreamError: any Error
        do {
            _ = try await fixture.composition.serverEventByteStream(for: fixture.request)
            Issue.record("Expected inactive event stream creation to fail")
            return
        } catch {
            eventStreamError = error
        }
        #expect((eventStreamError as? any CmxRetryAfterProviding)?.retryAfterSeconds ?? 0 > 0)
        #expect(
            await fixture.broker.totalRequestCount() == settledRequestCount,
            "transport, lane, and event-stream callers must share one activation backoff"
        )
    }

    @Test
    func clientBackoffBoundsFailingActivationRetries() async throws {
        let fixture = try await MobileIrohCooldownFixture.make(
            registrationError: MobileIrohCooldownTestError.unavailable
        )
        await settleActivation(fixture) {
            await fixture.broker.totalRequestCount() >= 1
        }
        await fixture.composition.prepareForConnection()
        let settled = await fixture.broker.totalRequestCount()

        // The injected clock is frozen inside the armed backoff window, so
        // every re-driven preparation and dial must stay broker-silent. Before
        // the client backoff existed, each of these re-ran registration.
        for _ in 0 ..< 20 {
            await fixture.composition.prepareForConnection()
        }
        _ = try? await fixture.composition.transport(for: fixture.request)
        _ = try? await fixture.composition.transport(for: fixture.request)
        #expect(await fixture.broker.totalRequestCount() == settled)

        // The armed nap is observable and bounded by the foreground cap: no
        // multi-minute sleep can be scheduled while the app is active.
        let scheduled = (await fixture.diagnosticLog.snapshot()).events.filter {
            $0.code == .retryScheduled
        }
        #expect(!scheduled.isEmpty)
        #expect(scheduled.allSatisfy { ($0.ms ?? .max) <= 30_000 })

        // Past the foreground cap, exactly one further attempt runs; its
        // failure re-arms the window and later drives stay broker-silent.
        fixture.clock.advance(by: 31)
        await settleActivation(fixture) {
            await fixture.broker.totalRequestCount() > settled
        }
        #expect(await fixture.broker.totalRequestCount() == settled + 1)
        for _ in 0 ..< 5 {
            await fixture.composition.prepareForConnection()
        }
        #expect(await fixture.broker.totalRequestCount() == settled + 1)
    }

    @Test
    func networkPathChangeResetsActivationBackoff() async throws {
        let fixture = try await MobileIrohCooldownFixture.make(
            registrationError: MobileIrohCooldownTestError.unavailable
        )
        await settleActivation(fixture) {
            await fixture.broker.totalRequestCount() >= 1
        }
        await fixture.composition.prepareForConnection()
        let settled = await fixture.broker.totalRequestCount()
        await fixture.composition.prepareForConnection()
        #expect(await fixture.broker.totalRequestCount() == settled)

        // A network-path-change signal clears the armed window: the failure
        // streak belonged to the previous path.
        var invoked = await fixture.networkPathChangeHook.invoke()
        for _ in 0 ..< 200 where !invoked {
            try? await Task.sleep(nanoseconds: 10_000_000)
            invoked = await fixture.networkPathChangeHook.invoke()
        }
        #expect(invoked)
        await settleActivation(fixture) {
            await fixture.broker.totalRequestCount() > settled
        }
        #expect(await fixture.broker.totalRequestCount() == settled + 1)
    }

    @Test
    func failingActivationFollowsExactSeededSchedule() async throws {
        let seed: UInt64 = 0xB0FF
        let fixture = try await MobileIrohCooldownFixture.make(
            registrationError: MobileIrohCooldownTestError.unavailable,
            activationBackoff: CmxIrohReconnectBackoff(seed: seed),
            diagnosticCapacity: 4_096
        )
        await settleActivation(fixture) {
            await fixture.broker.totalRequestCount() >= 1
        }
        await fixture.composition.prepareForConnection()
        #expect(await fixture.broker.totalRequestCount() == 1)

        // A twin ladder with the same seed predicts the exact schedule: the
        // first attempt at t=0, each retry at the first whole second on or
        // after the previous attempt time plus its drawn delay.
        let horizon = 600.0
        let twin = CmxIrohReconnectBackoff(seed: seed)
        var expectedDelays: [TimeInterval] = []
        var expectedAttemptCount = 1
        var attemptAt = 0.0
        while true {
            let delay = twin.nextDelay()
            expectedDelays.append(delay)
            let nextAttemptAt = (attemptAt + delay).rounded(.up)
            guard nextAttemptAt <= horizon else { break }
            attemptAt = nextAttemptAt
            expectedAttemptCount += 1
        }

        // Simulate ten foreground minutes, redriving the ladder every second.
        for _ in 0 ..< Int(horizon) {
            fixture.clock.advance(by: 1)
            await fixture.composition.prepareForConnection()
        }
        #expect(await fixture.broker.totalRequestCount() == expectedAttemptCount)

        // Every scheduled nap matches the twin's draw, and none exceeds the
        // foreground cap.
        let scheduledMS = (await fixture.diagnosticLog.snapshot()).events
            .filter { $0.code == .retryScheduled }
            .compactMap(\.ms)
        let expectedMS = expectedDelays.prefix(expectedAttemptCount).map {
            UInt32(clamping: Int($0 * 1_000))
        }
        #expect(scheduledMS == Array(expectedMS))
        #expect(scheduledMS.allSatisfy { $0 <= 30_000 })
    }

    @Test
    func scenePhaseActiveResetsActivationBackoff() async throws {
        let fixture = try await MobileIrohCooldownFixture.make(
            registrationError: MobileIrohCooldownTestError.unavailable
        )
        await settleActivation(fixture) {
            await fixture.broker.totalRequestCount() >= 1
        }
        await fixture.composition.prepareForConnection()
        let settled = await fixture.broker.totalRequestCount()
        await fixture.composition.prepareForConnection()
        #expect(await fixture.broker.totalRequestCount() == settled)

        // Returning to the foreground clears the armed window without any
        // clock advance: the very next preparation retries immediately.
        fixture.composition.didBecomeActive()
        await settleActivation(fixture) {
            await fixture.broker.totalRequestCount() > settled
        }
        #expect(await fixture.broker.totalRequestCount() == settled + 1)
    }

    /// Activation resolves the signed policy once and never mints a relay
    /// credential: the connect path is tokenless (relay allow hook).
    @Test
    func relayPolicyBootstrapMintsNothing() async throws {
        let fixture = try await MobileIrohCooldownFixture.makeSuccessfulBootstrap()

        await fixture.broker.waitForBootstrapRequest()

        #expect(fixture.composition.runtime != nil)
        #expect(await fixture.broker.bootstrapRequestCount() >= 1)
    }

    @Test
    func suspendedRelayRefreshCannotBlockDirectPathActivation() async throws {
        let fixture = try await MobileIrohCooldownFixture.makeSuccessfulBootstrap(
            suspendRelayBootstrap: true
        )

        await fixture.broker.waitForBootstrapRequest()

        #expect(fixture.composition.runtime != nil)
        #expect((await fixture.diagnosticLog.snapshot()).events.contains {
            $0.code == .endpointActive
        })
        await fixture.broker.resumeRelayBootstrap()
    }

    @Test
    func activeRuntimeRateLimitFloorsRelayRefreshWithoutBlockingDiscovery() async throws {
        let fixture = try await MobileIrohCooldownFixture.makeSuccessfulBootstrap()
        await settleActivation(fixture) {
            fixture.composition.runtime != nil
        }
        #expect(fixture.composition.runtime != nil)

        let requestCountBeforeRateLimit = await fixture.broker.totalRequestCount()
        let bootstrapCountBeforeRateLimit = await fixture.broker.bootstrapRequestCount()
        await fixture.broker.setRelayBootstrapRateLimit(retryAfterSeconds: 600)

        await fixture.composition.refreshIrohSettings()
        let requestCountAtFloor = await fixture.broker.totalRequestCount()
        let bootstrapCountAtFloor = await fixture.broker.bootstrapRequestCount()
        #expect(requestCountAtFloor == requestCountBeforeRateLimit + 1)
        #expect(bootstrapCountAtFloor == bootstrapCountBeforeRateLimit + 1)

        // Relay refreshes share one operation floor. Authenticated discovery is
        // a separate server budget and must remain usable while that floor is active.
        await fixture.composition.refreshIrohSettings()
        await fixture.composition.prepareForConnection()
        _ = await fixture.composition.discoverLiveMacs()
        _ = await fixture.composition.discoverLiveMacs()
        await fixture.composition.refreshIrohSettings()

        #expect(await fixture.broker.bootstrapRequestCount() == bootstrapCountAtFloor)
        #expect(await fixture.broker.totalRequestCount() > requestCountAtFloor)
        #expect(await fixture.broker.discoveryRequestCount() > 1)
    }

    @Test
    func liveMacDiscoveryForcesFreshBrokerSnapshotAfterActivation() async throws {
        let fixture = try await MobileIrohCooldownFixture.makeSuccessfulBootstrap()
        await settleActivation(fixture) {
            fixture.composition.runtime != nil
        }

        let activationDiscoveryCount = await fixture.broker.discoveryRequestCount()
        #expect(activationDiscoveryCount == 1)

        _ = await fixture.composition.discoverLiveMacs()

        #expect(await fixture.broker.discoveryRequestCount() == activationDiscoveryCount + 1)
    }

    @Test
    func activeRuntimeRateLimitSurvivesCompositionRecreation() async throws {
        let fixture = try await MobileIrohCooldownFixture.makeSuccessfulBootstrap()
        await settleActivation(fixture) {
            fixture.composition.runtime != nil
        }
        #expect(fixture.composition.runtime != nil)

        await fixture.broker.setRelayBootstrapRateLimit(retryAfterSeconds: 600)
        await fixture.composition.refreshIrohSettings()
        let requestCountAtFloor = await fixture.broker.totalRequestCount()
        let bootstrapCountAtFloor = await fixture.broker.bootstrapRequestCount()

        // Rebuild the process-owned composition over the same injected
        // UserDefaults domain and repositories. A new gate instance must restore
        // the relay-operation floor while registration and discovery remain usable.
        let recreated = fixture.recreatingComposition()
        await settleActivation(recreated) {
            recreated.composition.runtime != nil
        }

        #expect(recreated.composition.runtime != nil)
        #expect(await recreated.broker.totalRequestCount() > requestCountAtFloor)
        #expect(await recreated.broker.bootstrapRequestCount() == bootstrapCountAtFloor)

        await recreated.composition.refreshIrohSettings()
        #expect(await recreated.broker.bootstrapRequestCount() == bootstrapCountAtFloor)
    }
}

private enum MobileIrohCooldownTestError: Error {
    case unavailable
}

private final class MobileIrohCooldownTestClock: Sendable {
    private let seconds: Atomic<Int64>

    init(_ date: Date) {
        seconds = Atomic(Int64(date.timeIntervalSince1970))
    }

    func now() -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds.load(ordering: .relaxed)))
    }

    func advance(by interval: Int64) {
        seconds.store(
            seconds.load(ordering: .relaxed) + interval,
            ordering: .relaxed
        )
    }
}

@MainActor
private struct MobileIrohCooldownFixture {
    static let accountID = "account-a"
    static let deviceID = "123e4567-e89b-42d3-a456-426614174071"
    static let appInstanceUUID = UUID(
        uuidString: "123e4567-e89b-42d3-a456-426614174072"
    )!
    static let tag = "test"
    // Anchored to the wall clock: the runtime constructs its relay credential
    // coordinator with a real-time clock, so fixture credentials must be valid
    // against real time. Cooldown timing still flows through the injected clock.
    static let now = Date()

    let composition: MobileIrohRuntimeComposition
    let broker: MobileIrohCooldownBroker
    let clock: MobileIrohCooldownTestClock
    let request: CmxByteTransportRequest
    let diagnosticLog: DiagnosticLog
    /// The composition observes auth weakly (the app shell owns the
    /// coordinator); the fixture must retain it or every reconcile silently
    /// no-ops against a deallocated coordinator.
    let auth: AuthCoordinator
    /// Captures the reachability-change hook the composition registers, so a
    /// test can simulate one network-path-change signal.
    let networkPathChangeHook: MobileIrohCooldownHookBox
    private let compositionFactory: @MainActor () -> MobileIrohRuntimeComposition

    static func make(
        registrationError: (any Error)?,
        discoveryError: (any Error)? = nil,
        activationBackoff: CmxIrohReconnectBackoff? = nil,
        diagnosticCapacity: Int = 64
    ) async throws -> Self {
        try await make(
            registrationError: registrationError,
            discoveryError: discoveryError,
            relayPolicy: nil,
            activationBackoff: activationBackoff,
            diagnosticCapacity: diagnosticCapacity
        )
    }

    static func makeSuccessfulBootstrap(
        suspendRelayBootstrap: Bool = false
    ) async throws -> Self {
        let policy = MobileIrohCooldownRelayPolicyFixture(now: now)
        return try await make(
            registrationError: nil,
            discoveryError: nil,
            relayPolicy: policy,
            suspendRelayBootstrap: suspendRelayBootstrap
        )
    }

    private static func make(
        registrationError: (any Error)?,
        discoveryError: (any Error)?,
        relayPolicy: MobileIrohCooldownRelayPolicyFixture?,
        suspendRelayBootstrap: Bool = false,
        activationBackoff: CmxIrohReconnectBackoff? = nil,
        diagnosticCapacity: Int = 64
    ) async throws -> Self {
        let suiteName = "MobileIrohRuntimeCompositionCooldownTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let installState = CmxIrohUserDefaultsInstallStateStore(defaults: defaults)
        let stableAppInstanceUUID = appInstanceUUID
        let appInstances = CmxIrohAppInstanceRepository(
            store: installState,
            makeUUID: { stableAppInstanceUUID }
        )
        let identities = CmxIrohIdentityRepository(
            secureStore: MobileIrohCooldownIdentityStore(),
            installState: installState,
            randomBytes: { Data(repeating: 7, count: 32) },
            marker: { "cooldown-test-install" }
        )
        let appInstanceID = try await appInstances.appInstanceID(
            accountID: accountID,
            tag: tag
        )
        let identity = try await identities.identity(
            accountID: accountID,
            appInstanceID: appInstanceID
        )
        let privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: identity.secretKey.bytes
        )
        let endpointID = try CmxIrohPeerIdentity(
            endpointID: privateKey.publicKey.rawRepresentation
                .map { String(format: "%02x", $0) }
                .joined()
        )
        let registration = try registrationResponse(
            appInstanceID: appInstanceID,
            endpointID: endpointID
        )
        let discovery = try discoveryResponse(
            binding: registration.binding,
            relayFleet: relayPolicy?.relayURLs ?? ["https://usc1.relay.cmux.dev/"]
        )
        let broker = MobileIrohCooldownBroker(
            registrationError: registrationError,
            discoveryError: discoveryError,
            registration: registration,
            discovery: discovery,
            bootstrap: try relayPolicy?.bootstrap(),
            suspendRelayBootstrap: suspendRelayBootstrap
        )
        let credentialStore = MobileIrohCooldownCredentialStore()
        let clock = MobileIrohCooldownTestClock(now)
        let diagnosticLog = DiagnosticLog(
            capacity: diagnosticCapacity,
            role: .mobileClient
        )
        let stableDeviceID = deviceID
        let networkPathChangeHook = MobileIrohCooldownHookBox()
        let brokerCredentials = CmxIrohBrokerCredentialRepository(
            secureStore: credentialStore,
            installState: installState
        )
        let pendingRevocations = CmxIrohPendingRevocationOutbox(
            secureStore: MobileIrohCooldownCredentialStore()
        )
        let offlinePolicies = CmxIrohClientOfflinePolicyCache(
            secureStore: MobileIrohCooldownCredentialStore()
        )
        let relayPolicyCache = CmxIrohRelayPolicyCache(
            secureStore: MobileIrohCooldownCredentialStore()
        )
        let relayPreferenceStore = CmxIrohRelayPreferenceStore(
            secureStore: MobileIrohCooldownCredentialStore()
        )
        let customRelayCredentials = CmxIrohCustomRelayCredentialStore(
            secureStore: MobileIrohCooldownCredentialStore()
        )
        let relayPolicyTrustRoot = try relayPolicy?.trustRoot()
        let endpointFactory = MobileIrohCooldownEndpointFactory(identity: endpointID)
        let compositionFactory: @MainActor () -> MobileIrohRuntimeComposition = {
            MobileIrohRuntimeComposition(
                appInstances: appInstances,
                identities: identities,
                brokerCredentials: brokerCredentials,
                pendingRevocations: pendingRevocations,
                offlinePolicies: offlinePolicies,
                relayPolicyCache: relayPolicyCache,
                relayPreferenceStore: relayPreferenceStore,
                customRelayCredentials: customRelayCredentials,
                relayPolicyTrustRoot: relayPolicyTrustRoot,
                endpointFactory: endpointFactory,
                brokerFactory: { _, _ in broker },
                brokerBackpressureGate: CmxIrohBrokerBackpressureGate(
                    store: CmxIrohUserDefaultsInstallStateStore(defaults: defaults),
                    now: { clock.now() }
                ),
                deviceID: { stableDeviceID },
                tag: tag,
                now: { clock.now() },
                startNetworkPathObservation: { onPathChange in
                    await networkPathChangeHook.set(onPathChange)
                },
                activationRetryBackoff: activationBackoff,
                diagnosticLog: diagnosticLog,
                debugDefaults: defaults
            )
        }
        let composition = compositionFactory()
        let authClient = MobileIrohCooldownAuthClient(
            user: CMUXAuthUser(
                id: accountID,
                primaryEmail: "a@example.com",
                displayName: "A"
            )
        )
        let authStore = MobileIrohCooldownAuthKeyValueStore()
        let auth = AuthCoordinator(
            client: authClient,
            sessionCache: CMUXAuthSessionCache(
                keyValueStore: authStore,
                key: "has-tokens"
            ),
            userCache: CMUXAuthIdentityStore(
                keyValueStore: authStore,
                key: "cached-user"
            ),
            teamSelection: CMUXAuthTeamSelectionStore(
                keyValueStore: authStore,
                key: "selected-team"
            ),
            anchor: MobileIrohCooldownAuthAnchor(),
            config: AuthConfig(
                stack: CMUXAuthConfig(
                    projectId: "test",
                    publishableClientKey: "test"
                ),
                magicLinkCallbackURL: "http://localhost/auth/callback",
                apiBaseURL: "http://localhost"
            ),
            launch: AuthLaunchOptions(
                clearAuthRequested: false,
                mockDataEnabled: false,
                environment: [:],
                includesDevAuth: false
            )
        )
        try await auth.signInWithPassword(email: "a@example.com", password: "pw")
        composition.configure(auth: auth)

        return Self(
            composition: composition,
            broker: broker,
            clock: clock,
            request: try request(),
            diagnosticLog: diagnosticLog,
            auth: auth,
            networkPathChangeHook: networkPathChangeHook,
            compositionFactory: compositionFactory
        )
    }

    func recreatingComposition() -> Self {
        let recreated = compositionFactory()
        recreated.configure(auth: auth)
        return Self(
            composition: recreated,
            broker: broker,
            clock: clock,
            request: request,
            diagnosticLog: diagnosticLog,
            auth: auth,
            networkPathChangeHook: networkPathChangeHook,
            compositionFactory: compositionFactory
        )
    }

    private static func request() throws -> CmxByteTransportRequest {
        CmxByteTransportRequest(
            route: try CmxAttachRoute(
                id: "iroh",
                kind: .iroh,
                endpoint: .peer(
                    identity: CmxIrohPeerIdentity(
                        endpointID: String(repeating: "a", count: 64)
                    ),
                    pathHints: []
                ),
                priority: 0
            ),
            expectedPeerDeviceID: "123e4567-e89b-42d3-a456-426614174074",
            authorizationMode: .transportAdmission
        )
    }

    private static func registrationResponse(
        appInstanceID: String,
        endpointID: CmxIrohPeerIdentity
    ) throws -> CmxIrohRegistrationResponse {
        let object: [String: Any] = [
            "binding": bindingObject(
                appInstanceID: appInstanceID,
                endpointID: endpointID
            ),
            "relay": ["status": "not_requested"],
        ]
        return try JSONDecoder().decode(
            CmxIrohRegistrationResponse.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private static func discoveryResponse(
        binding: CmxIrohBrokerBinding,
        relayFleet: [String]
    ) throws -> CmxIrohDiscoveryResponse {
        let rendezvousKey = Data(repeating: 0, count: 32)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let bindingData = try JSONEncoder().encode(binding)
        let bindingJSON = try #require(
            JSONSerialization.jsonObject(with: bindingData) as? [String: Any]
        )
        let object: [String: Any] = [
            "route_contract_version": 1,
            "bindings": [bindingJSON],
            "relay_fleet": relayFleet,
            "lan_rendezvous": ["generation": 1, "key": rendezvousKey],
            "grant_verification_keys": [
                "version": 1,
                "current_kid": "test-key",
                "keys": [[
                    "kid": "test-key",
                    "alg": "EdDSA",
                    "spki_der_base64": "AA==",
                ]],
            ],
        ]
        return try JSONDecoder().decode(
            CmxIrohDiscoveryResponse.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private static func bindingObject(
        appInstanceID: String,
        endpointID: CmxIrohPeerIdentity
    ) -> [String: Any] {
        [
            "binding_id": "123e4567-e89b-42d3-a456-426614174073",
            "device_id": deviceID,
            "app_instance_id": appInstanceID,
            "tag": tag,
            "platform": "ios",
            "endpoint_id": endpointID.endpointID,
            "identity_generation": 1,
            "pairing_enabled": false,
            "capabilities": ["mobile-rpc-v1", "multistream-v1"],
            "path_hints": [],
            "last_seen_at": ISO8601DateFormatter().string(from: now),
        ]
    }
}

/// Captures the composition's reachability-change callback for tests.
actor MobileIrohCooldownHookBox {
    private var hook: (@Sendable () async -> Void)?

    func set(_ hook: @escaping @Sendable () async -> Void) {
        self.hook = hook
    }

    /// Runs the captured hook once, returning whether it was registered yet.
    func invoke() async -> Bool {
        guard let hook else { return false }
        await hook()
        return true
    }
}

private struct MobileIrohCooldownRelayPolicyFixture {
    let privateKey = Curve25519.Signing.PrivateKey()
    let now: Date
    let relayURLs = ["https://usc1.relay.cmux.dev/"]

    func trustRoot() throws -> CmxIrohRelayPolicyTrustRoot {
        try CmxIrohRelayPolicyTrustRoot(keys: [
            CmxIrohRelayPolicyVerificationKey(
                keyID: "policy-first",
                rawPublicKeyBase64: privateKey.publicKey.rawRepresentation
                    .base64EncodedString()
            ),
        ])
    }

    func bootstrap() throws -> CmxIrohRelayPolicyResponse {
        try CmxIrohRelayPolicyResponse(
            policy: signedPolicy(),
            preference: .automatic,
            preferenceRevision: 1
        )
    }

    private func signedPolicy() throws -> String {
        let header = try JSONSerialization.data(
            withJSONObject: [
                "alg": "EdDSA",
                "typ": "cmux-relay-policy-v1+jwt",
                "kid": "policy-first",
            ],
            options: [.sortedKeys]
        )
        let descriptors = relayURLs.map { url in
            [
                "id": "cmux-us",
                "provider": "cmux",
                "region": "us-central1",
                "url": url,
            ]
        }
        let nowSeconds = Int64(now.timeIntervalSince1970)
        let payload = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "jti": "123e4567-e89b-42d3-a456-426614174000",
                "sequence": 1,
                "iat": nowSeconds,
                "nbf": nowSeconds,
                "exp": nowSeconds + 3_600,
                "aud": "cmux-iroh-relay-policy",
                "relay_protocol": "iroh-relay-v1",
                "relays": descriptors,
            ],
            options: [.sortedKeys]
        )
        let input = "\(Self.base64URL(header)).\(Self.base64URL(payload))"
        let signature = try privateKey.signature(for: Data(input.utf8))
        return "\(input).\(Self.base64URL(signature))"
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private actor MobileIrohCooldownBroker:
    CmxIrohClientBrokerServing,
    CmxIrohRelayPolicyServing
{
    private let registrationError: (any Error)?
    private let discoveryError: (any Error)?
    private let registration: CmxIrohRegistrationResponse
    private let discoveryResponse: CmxIrohDiscoveryResponse
    private let bootstrap: CmxIrohRelayPolicyResponse?
    private var relayBootstrapRetryAfterSeconds: Int?
    private var totalRequests = 0
    private var discoveryRequests = 0
    private var bootstrapRequests = 0
    private var suspendRelayBootstrap: Bool
    private var relayBootstrapContinuation: CheckedContinuation<Void, Never>?
    private var bootstrapRequestWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        registrationError: (any Error)?,
        discoveryError: (any Error)?,
        registration: CmxIrohRegistrationResponse,
        discovery: CmxIrohDiscoveryResponse,
        bootstrap: CmxIrohRelayPolicyResponse?,
        suspendRelayBootstrap: Bool
    ) {
        self.registrationError = registrationError
        self.discoveryError = discoveryError
        self.registration = registration
        discoveryResponse = discovery
        self.bootstrap = bootstrap
        self.suspendRelayBootstrap = suspendRelayBootstrap
    }

    func setRelayBootstrapRateLimit(retryAfterSeconds: Int) {
        relayBootstrapRetryAfterSeconds = retryAfterSeconds
    }

    func register(
        prepared _: CmxIrohPreparedRegistration,
        signer _: CmxIrohRegistrationSigner
    ) throws -> CmxIrohRegistrationResponse {
        totalRequests += 1
        if let registrationError { throw registrationError }
        return registration
    }

    func discover() throws -> CmxIrohDiscoveryResponse {
        totalRequests += 1
        discoveryRequests += 1
        if let discoveryError { throw discoveryError }
        return discoveryResponse
    }

    func issuePairGrant(
        initiatorBindingID _: String,
        acceptorBindingID _: String
    ) throws -> CmxIrohPairGrantResponse {
        totalRequests += 1
        throw MobileIrohCooldownTestError.unavailable
    }

    func revoke(bindingID _: String) {
        totalRequests += 1
    }

    func fetchRelayPolicy() async throws -> CmxIrohRelayPolicyResponse {
        totalRequests += 1
        bootstrapRequests += 1
        let waiters = bootstrapRequestWaiters
        bootstrapRequestWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if suspendRelayBootstrap {
            await withCheckedContinuation { continuation in
                relayBootstrapContinuation = continuation
            }
        }
        if let relayBootstrapRetryAfterSeconds {
            throw CmxIrohTrustBrokerClientError.rateLimited(
                code: nil,
                retryAfterSeconds: relayBootstrapRetryAfterSeconds
            )
        }
        guard let bootstrap else { throw MobileIrohCooldownTestError.unavailable }
        return bootstrap
    }

    func resumeRelayBootstrap() {
        suspendRelayBootstrap = false
        relayBootstrapContinuation?.resume()
        relayBootstrapContinuation = nil
    }

    func relayPreference() throws -> CmxIrohRelayPreferenceResponse {
        totalRequests += 1
        throw MobileIrohCooldownTestError.unavailable
    }

    func updateRelayPreference(
        _: CmxIrohRelayPreferenceUpdateRequest
    ) throws -> CmxIrohRelayPreferenceResponse {
        totalRequests += 1
        throw MobileIrohCooldownTestError.unavailable
    }

    func totalRequestCount() -> Int { totalRequests }
    func discoveryRequestCount() -> Int { discoveryRequests }
    func bootstrapRequestCount() -> Int { bootstrapRequests }

    func waitForBootstrapRequest() async {
        guard bootstrapRequests == 0 else { return }
        await withCheckedContinuation { continuation in
            bootstrapRequestWaiters.append(continuation)
        }
    }
}

private actor MobileIrohCooldownEndpointFactory: CmxIrohEndpointFactory {
    private let identity: CmxIrohPeerIdentity

    init(identity: CmxIrohPeerIdentity) {
        self.identity = identity
    }

    func bind(
        configuration _: CmxIrohEndpointConfiguration
    ) -> any CmxIrohEndpoint {
        MobileIrohCooldownEndpoint(identity: identity)
    }
}

private actor MobileIrohCooldownEndpoint: CmxIrohEndpoint {
    private let peerIdentity: CmxIrohPeerIdentity

    init(identity: CmxIrohPeerIdentity) {
        peerIdentity = identity
    }

    func identity() -> CmxIrohPeerIdentity { peerIdentity }

    func address() -> CmxIrohEndpointAddress {
        CmxIrohEndpointAddress(identity: peerIdentity, pathHints: [])
    }

    func connect(
        to _: CmxIrohEndpointAddress,
        alpn _: Data
    ) throws -> any CmxIrohConnection {
        throw MobileIrohCooldownTestError.unavailable
    }

    func accept() -> (any CmxIrohIncomingConnection)? { nil }

    func healthEvents() -> AsyncStream<CmxIrohEndpointHealthEvent> {
        AsyncStream { $0.finish() }
    }

    func isHealthy() -> Bool { true }
    func close() {}
}

private actor MobileIrohCooldownCredentialStore: CmxIrohSecureCredentialStoring {
    private var storage: [String: Data] = [:]

    func read(account: String) -> Data? { storage[account] }

    func write(
        _ data: Data,
        account: String,
        accessibility _: CmxIrohSecureCredentialAccessibility
    ) {
        storage[account] = data
    }

    func delete(account: String) { storage[account] = nil }
    func deleteAll() { storage.removeAll() }
}

private actor MobileIrohCooldownIdentityStore: CmxIrohSecureIdentityStoring {
    private var storage: [String: Data] = [:]

    func read(account: String) -> Data? { storage[account] }
    func write(_ data: Data, account: String) { storage[account] = data }
    func delete(account: String) { storage[account] = nil }
    func deleteAll() { storage.removeAll() }
}

private final class MobileIrohCooldownAuthKeyValueStore: CMUXAuthKeyValueStore {
    private var storage: [String: Any] = [:]

    func bool(forKey defaultName: String) -> Bool {
        storage[defaultName] as? Bool ?? false
    }

    func data(forKey defaultName: String) -> Data? {
        storage[defaultName] as? Data
    }

    func string(forKey defaultName: String) -> String? {
        storage[defaultName] as? String
    }

    func set(_ value: Any?, forKey defaultName: String) {
        storage[defaultName] = value
    }

    func removeObject(forKey defaultName: String) {
        storage[defaultName] = nil
    }
}

private final class MobileIrohCooldownAuthAnchor: NSObject,
    AuthPresentationAnchoring,
    @unchecked Sendable
{
    func presentationAnchor(
        for session: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {
        ASPresentationAnchor()
    }

    func presentationAnchor(
        for controller: ASAuthorizationController
    ) -> ASPresentationAnchor {
        ASPresentationAnchor()
    }
}

private actor MobileIrohCooldownAuthClient: AuthClient {
    private var access: String? = "access"
    private var refresh: String? = "refresh"
    private let user: CMUXAuthUser

    init(user: CMUXAuthUser) {
        self.user = user
    }

    func accessToken() -> String? { access }
    func refreshToken() -> String? { refresh }
    func forceRefreshAccessToken() -> String? { access }
    func currentUser(throwOnMissing _: Bool) -> CMUXAuthUser? { user }
    func listTeams() -> [CMUXAuthTeam] { [] }
    func sendMagicLinkEmail(email _: String, callbackURL _: String) -> String { "nonce" }

    func signInWithMagicLink(code _: String) {
        access = "access"
        refresh = "refresh"
    }

    func signInWithCredential(email _: String, password _: String) {
        access = "access"
        refresh = "refresh"
    }

    func signInWithOAuth(
        provider _: String,
        anchor _: any AuthPresentationAnchoring
    ) {
        access = "access"
        refresh = "refresh"
    }

    func storedAccessToken() -> String? { access }

    func clearLocalSession() {
        access = nil
        refresh = nil
    }

    func clearLocalSession(ifRefreshTokenMatches refreshToken: String) {
        guard refresh == refreshToken else { return }
        access = nil
        refresh = nil
    }

    func revokeSession(accessToken _: String?, refreshToken _: String?) {}

    func freshAccessToken(
        accessToken: String?,
        refreshToken _: String
    ) -> String? {
        accessToken
    }
}
