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
    /// Re-drives the lifecycle until the broker fake has seen activity (or the
    /// runtime activated). Auth observation and reconcile coalesce across
    /// main-actor tasks, so a single prepareForConnection can settle before
    /// the first activation lands; short bounded sleeps (max ~5s) let every
    /// executor drain between attempts.
    private func settleActivation(
        _ fixture: MobileIrohCooldownFixture,
        until condition: @escaping () async -> Bool
    ) async {
        for _ in 0 ..< 500 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
            await fixture.composition.prepareForConnection()
        }
    }

    @Test
    func rateLimitFloorsActivationAndSurfacesRetryAfter() async throws {
        let fixture = try await MobileIrohCooldownFixture.make(
            registrationError: CmxIrohTrustBrokerClientError.rateLimited(
                code: nil,
                retryAfterSeconds: 600
            )
        )

        await settleActivation(fixture) {
            await fixture.broker.totalRequestCount() >= 1
        }
        let flooredRequestCount = await fixture.broker.totalRequestCount()
        #expect(flooredRequestCount >= 1)
        #expect((await fixture.diagnosticLog.snapshot()).events.contains {
            $0.code == .endpointFailed
        })

        // Within the Retry-After floor every further attempt must be free.
        await fixture.composition.prepareForConnection()
        await fixture.composition.prepareForConnection()
        #expect(await fixture.broker.totalRequestCount() == flooredRequestCount)

        let dialError: any Error
        do {
            _ = try await fixture.composition.transport(for: fixture.request)
            Issue.record("Expected transport creation to fail while activation is cooling down")
            return
        } catch {
            dialError = error
        }
        #expect(await fixture.broker.totalRequestCount() == flooredRequestCount)
        #expect((dialError as? any CmxRetryAfterProviding)?.retryAfterSeconds ?? 0 > 0)

        fixture.clock.advance(by: 601)
        await settleActivation(fixture) {
            await fixture.broker.totalRequestCount() > flooredRequestCount
        }
        #expect(await fixture.broker.totalRequestCount() == flooredRequestCount + 1)
    }

    @Test
    func nonRateLimitedFailureKeepsInactiveDialBehavior() async throws {
        let fixture = try await MobileIrohCooldownFixture.make(
            registrationError: MobileIrohCooldownTestError.unavailable
        )

        await settleActivation(fixture) {
            await fixture.broker.totalRequestCount() >= 1
        }
        let settledRequestCount = await fixture.broker.totalRequestCount()

        let transportError: any Error
        do {
            _ = try await fixture.composition.transport(for: fixture.request)
            Issue.record("Expected inactive transport creation to fail")
            return
        } catch {
            transportError = error
        }
        #expect(transportError as? CmxIrohClientRuntimeError == .inactive)
        #expect((transportError as? any CmxRetryAfterProviding)?.retryAfterSeconds == nil)

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
        #expect(laneError as? CmxIrohClientRuntimeError == .inactive)
        #expect((laneError as? any CmxRetryAfterProviding)?.retryAfterSeconds == nil)

        let eventStreamError: any Error
        do {
            _ = try await fixture.composition.serverEventByteStream(for: fixture.request)
            Issue.record("Expected inactive event stream creation to fail")
            return
        } catch {
            eventStreamError = error
        }
        #expect(eventStreamError as? CmxIrohClientRuntimeError == .inactive)
        #expect((eventStreamError as? any CmxRetryAfterProviding)?.retryAfterSeconds == nil)
        // No cooldown for non-rate-limited failures: each dial retried a
        // fresh activation and reached the broker again.
        #expect(await fixture.broker.totalRequestCount() > settledRequestCount)
    }

    @Test
    func freshRelayBootstrapCredentialAvoidsSecondMint() async throws {
        let fixture = try await MobileIrohCooldownFixture.makeSuccessfulBootstrap()

        await settleActivation(fixture) {
            fixture.composition.runtime != nil
        }

        #expect(fixture.composition.runtime != nil)
        #expect(await fixture.broker.bootstrapRequestCount() >= 1)
        #expect(await fixture.broker.relayTokenRequestCount() == 0)
    }

    @Test
    func activeRuntimeRateLimitFloorsPolicyRefreshAndDiscovery() async throws {
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

        // This is the field loop: settings refresh and discovery can both
        // re-enter the broker while the already-active runtime reconnects.
        // The first 429 owns the whole account-scoped request floor.
        await fixture.composition.refreshIrohSettings()
        await fixture.composition.prepareForConnection()
        _ = await fixture.composition.discoverLiveMacs()
        _ = await fixture.composition.discoverLiveMacs()
        await fixture.composition.refreshIrohSettings()

        #expect(await fixture.broker.totalRequestCount() == requestCountAtFloor)
        #expect(await fixture.broker.bootstrapRequestCount() == bootstrapCountAtFloor)
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
        let diagnosticCountAtFloor = (await fixture.diagnosticLog.snapshot()).events.count

        // Rebuild the process-owned composition over the same injected
        // UserDefaults domain and repositories. A persisted floor must be
        // restored before the replacement can perform any broker work.
        let recreated = fixture.recreatingComposition()
        await settleActivation(recreated) {
            if recreated.composition.runtime != nil { return true }
            if await recreated.broker.totalRequestCount() > requestCountAtFloor { return true }
            let events = (await recreated.diagnosticLog.snapshot()).events
            return events.dropFirst(diagnosticCountAtFloor).contains {
                $0.code == .endpointFailed
            }
        }

        #expect(await recreated.broker.totalRequestCount() == requestCountAtFloor)
        do {
            _ = try await recreated.composition.transport(for: recreated.request)
            Issue.record("Expected the recreated composition to restore the broker cooldown")
        } catch {
            #expect((error as? any CmxRetryAfterProviding)?.retryAfterSeconds ?? 0 > 0)
        }
        #expect(await recreated.broker.totalRequestCount() == requestCountAtFloor)
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
    private let compositionFactory: @MainActor () -> MobileIrohRuntimeComposition

    static func make(
        registrationError: any Error
    ) async throws -> Self {
        try await make(registrationError: registrationError, relayPolicy: nil)
    }

    static func makeSuccessfulBootstrap() async throws -> Self {
        let policy = MobileIrohCooldownRelayPolicyFixture(now: now)
        return try await make(
            registrationError: nil,
            relayPolicy: policy
        )
    }

    private static func make(
        registrationError: (any Error)?,
        relayPolicy: MobileIrohCooldownRelayPolicyFixture?
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
            registration: registration,
            discovery: discovery,
            bootstrap: try relayPolicy?.bootstrap()
        )
        let credentialStore = MobileIrohCooldownCredentialStore()
        let clock = MobileIrohCooldownTestClock(now)
        let diagnosticLog = DiagnosticLog(capacity: 64, role: .mobileClient)
        let stableDeviceID = deviceID
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
                brokerFactory: { _ in broker },
                deviceID: { stableDeviceID },
                tag: tag,
                now: { clock.now() },
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

    func bootstrap() throws -> CmxIrohRelayBootstrapResponse {
        CmxIrohRelayBootstrapResponse(
            relayToken: relayCredential(),
            relayPolicy: try CmxIrohRelayPolicyResponse(
                policy: signedPolicy(),
                preference: .automatic,
                preferenceRevision: 1
            )
        )
    }

    func relayCredential() -> CmxIrohRelayTokenResponse {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return CmxIrohRelayTokenResponse(
            token: "aaaa",
            expiresAt: formatter.string(from: now.addingTimeInterval(3_600)),
            refreshAfter: formatter.string(from: now.addingTimeInterval(1_800)),
            relayFleet: relayURLs
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
    private let registration: CmxIrohRegistrationResponse
    private let discoveryResponse: CmxIrohDiscoveryResponse
    private let bootstrap: CmxIrohRelayBootstrapResponse?
    private var relayBootstrapRetryAfterSeconds: Int?
    private var totalRequests = 0
    private var bootstrapRequests = 0
    private var relayTokenRequests = 0

    init(
        registrationError: (any Error)?,
        registration: CmxIrohRegistrationResponse,
        discovery: CmxIrohDiscoveryResponse,
        bootstrap: CmxIrohRelayBootstrapResponse?
    ) {
        self.registrationError = registrationError
        self.registration = registration
        discoveryResponse = discovery
        self.bootstrap = bootstrap
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

    func discover() -> CmxIrohDiscoveryResponse {
        totalRequests += 1
        return discoveryResponse
    }

    func issuePairGrant(
        initiatorBindingID _: String,
        acceptorBindingID _: String
    ) throws -> CmxIrohPairGrantResponse {
        totalRequests += 1
        throw MobileIrohCooldownTestError.unavailable
    }

    func issueRelayToken(
        bindingID _: String,
        endpointID _: CmxIrohPeerIdentity
    ) throws -> CmxIrohRelayTokenResponse {
        totalRequests += 1
        relayTokenRequests += 1
        guard let credential = bootstrap?.relayToken else {
            throw MobileIrohCooldownTestError.unavailable
        }
        return credential
    }

    func revoke(bindingID _: String) {
        totalRequests += 1
    }

    func issueRelayBootstrap(
        endpointID _: CmxIrohPeerIdentity
    ) throws -> CmxIrohRelayBootstrapResponse {
        totalRequests += 1
        bootstrapRequests += 1
        if let relayBootstrapRetryAfterSeconds {
            throw CmxIrohTrustBrokerClientError.rateLimited(
                code: nil,
                retryAfterSeconds: relayBootstrapRetryAfterSeconds
            )
        }
        guard let bootstrap else { throw MobileIrohCooldownTestError.unavailable }
        return bootstrap
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
    func bootstrapRequestCount() -> Int { bootstrapRequests }
    func relayTokenRequestCount() -> Int { relayTokenRequests }
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

    func accept() -> (any CmxIrohConnection)? { nil }
    func replaceRelays(_: [CmxIrohRelayConfiguration]) {}

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

// The synchronous storage protocol is used only by one identity repository actor.
private final class MobileIrohCooldownIdentityStore: CmxIrohSecureIdentityStoring,
    @unchecked Sendable
{
    nonisolated(unsafe) private var storage: [String: Data] = [:]

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
