import AuthenticationServices
import CMUXAuthCore
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxMobileShell
import CmuxMobileTransport
import Foundation
import Testing
@testable import cmuxFeature

/// `MobileIrohRuntimeComposition.shutdown()` is the live backend switch's
/// teardown for the OLD iroh graph. Before it existed, nothing ever cancelled
/// the auth observation `configure(auth:)` started or released the
/// connectivity invalidation subscriber; a replaced composition would keep
/// reconciling (and wiping account state) against auth events belonging to
/// the NEW graph's coordinator lifecycle.
@MainActor
@Suite struct MobileIrohRuntimeCompositionShutdownTests {
    /// Control: without shutdown, a sign-out observed through the auth stream
    /// erases the account-scoped state (the app-instance id rotates). This
    /// pins the drain mechanics the shutdown test's negative assertion needs.
    @Test func signOutBeforeShutdownStillErasesAccountState() async throws {
        let fixture = try await MobileIrohShutdownFixture.make()

        await fixture.auth.signOut()

        var erased = false
        for _ in 0..<4_000 {
            await Task.yield()
            let currentID = try await fixture.appInstances.appInstanceID(
                accountID: MobileIrohShutdownFixture.accountID,
                tag: fixture.tag
            )
            if currentID != fixture.appInstanceID {
                erased = true
                break
            }
        }
        #expect(erased)
    }

    @Test func authStateChangesNoLongerReconcileAfterShutdown() async throws {
        let fixture = try await MobileIrohShutdownFixture.make()
        await fixture.composition.shutdown()
        let bindCountAfterShutdown = await fixture.endpointFactory.bindCount()

        await fixture.auth.signOut()
        // Generous drain: were the observation still alive, the sign-out
        // reconcile would rotate the app-instance id well within this window
        // (see the control test above).
        for _ in 0..<4_000 {
            await Task.yield()
        }

        // The observation is gone: no erase reconcile ran, the account's
        // app-instance id survives, and no new activation was attempted.
        #expect(
            try await fixture.appInstances.appInstanceID(
                accountID: MobileIrohShutdownFixture.accountID,
                tag: fixture.tag
            ) == fixture.appInstanceID
        )
        #expect(await fixture.endpointFactory.bindCount() == bindCountAfterShutdown)
        #expect(fixture.composition.runtime == nil)
    }

    @Test func shutdownStopsAndReleasesTheConnectivityInvalidationSubscriber() async throws {
        let fixture = try await MobileIrohShutdownFixture.make(
            // Never dialed in this test: the subscriber only starts once an
            // authenticated account is observed AND started; asserting the
            // handle is released proves shutdown addressed it either way.
            connectivityInvalidationBaseURL: URL(string: "http://127.0.0.1:9")
        )
        #expect(fixture.composition.connectivityInvalidationSubscriber != nil)

        await fixture.composition.shutdown()

        #expect(fixture.composition.connectivityInvalidationSubscriber == nil)
    }

    @Test func shutdownIsIdempotent() async throws {
        let fixture = try await MobileIrohShutdownFixture.make()
        await fixture.composition.shutdown()
        await fixture.composition.shutdown()
        #expect(fixture.composition.runtime == nil)
    }
}

// MARK: - Fixture

private enum MobileIrohShutdownTestError: Error {
    case unavailable
}

private struct MobileIrohShutdownFixture {
    static let accountID = "account-a"
    static let deviceID = "123e4567-e89b-42d3-a456-426614174171"

    let composition: MobileIrohRuntimeComposition
    let auth: AuthCoordinator
    let appInstances: CmxIrohAppInstanceRepository
    let endpointFactory: MobileIrohShutdownEndpointFactory
    let appInstanceID: String
    let tag: String

    @MainActor
    static func make(
        connectivityInvalidationBaseURL: URL? = nil
    ) async throws -> Self {
        let tag = "test"
        let suiteName = "MobileIrohRuntimeCompositionShutdownTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let installState = CmxIrohUserDefaultsInstallStateStore(defaults: defaults)
        let appInstances = CmxIrohAppInstanceRepository(store: installState)
        let identities = CmxIrohIdentityRepository(
            secureStore: MobileIrohShutdownIdentityStore(),
            installState: installState
        )
        let brokerCredentials = CmxIrohBrokerCredentialRepository(
            secureStore: MobileIrohShutdownCredentialStore(),
            installState: installState
        )
        let appInstanceID = try await appInstances.appInstanceID(
            accountID: accountID,
            tag: tag
        )

        let user = CMUXAuthUser(
            id: accountID,
            primaryEmail: "a@example.com",
            displayName: "A"
        )
        let authStore = MobileIrohShutdownAuthKeyValueStore()
        let auth = AuthCoordinator(
            client: MobileIrohShutdownAuthClient(user: user),
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
            anchor: MobileIrohShutdownAuthAnchor(),
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
        try await auth.signInWithPassword(
            email: "a@example.com",
            password: "pw"
        )

        let endpointFactory = MobileIrohShutdownEndpointFactory()
        let stableDeviceID = deviceID
        let composition = MobileIrohRuntimeComposition(
            appInstances: appInstances,
            identities: identities,
            brokerCredentials: brokerCredentials,
            pendingRevocations: CmxIrohPendingRevocationOutbox(
                secureStore: MobileIrohShutdownCredentialStore()
            ),
            endpointFactory: endpointFactory,
            brokerFactory: { _, _, _ in MobileIrohShutdownBroker() },
            deviceID: { stableDeviceID },
            tag: tag,
            now: { Date(timeIntervalSince1970: 1_000) },
            debugDefaults: defaults
        )
        composition.configure(
            auth: auth,
            connectivityInvalidationBaseURL: connectivityInvalidationBaseURL
        )

        // Force one reconcile (mirrors the existing composition fixtures):
        // the dial fails because the endpoint factory refuses to bind, but it
        // proves the graph observed the signed-in account before the test
        // shuts it down or signs out.
        let remoteIdentity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "a", count: 64)
        )
        let request = CmxByteTransportRequest(
            route: try CmxAttachRoute(
                id: "iroh",
                kind: .iroh,
                endpoint: .peer(identity: remoteIdentity, pathHints: []),
                priority: 0
            ),
            expectedPeerDeviceID: "123e4567-e89b-42d3-a456-426614174174",
            authorizationMode: .transportAdmission
        )
        await #expect(throws: (any Error).self) {
            _ = try await composition.transport(for: request)
        }
        #expect(await endpointFactory.bindCount() > 0)

        return Self(
            composition: composition,
            auth: auth,
            appInstances: appInstances,
            endpointFactory: endpointFactory,
            appInstanceID: appInstanceID,
            tag: tag
        )
    }
}

// MARK: - Fakes (file-private, mirroring MobileIrohRuntimeCompositionTests)

private actor MobileIrohShutdownIdentityStore: CmxIrohSecureIdentityStoring {
    private var storage: [String: Data] = [:]

    func read(account: String) -> Data? { storage[account] }
    func write(_ data: Data, account: String) { storage[account] = data }
    func delete(account: String) { storage[account] = nil }
    func deleteAll() { storage.removeAll() }
}

private actor MobileIrohShutdownCredentialStore: CmxIrohSecureCredentialStoring {
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

private actor MobileIrohShutdownEndpointFactory: CmxIrohEndpointFactory {
    private var count = 0

    func bind(
        configuration _: CmxIrohEndpointConfiguration
    ) throws -> any CmxIrohEndpoint {
        count += 1
        throw MobileIrohShutdownTestError.unavailable
    }

    func bindCount() -> Int { count }
}

private actor MobileIrohShutdownBroker: CmxIrohClientBrokerServing {
    func register(
        prepared _: CmxIrohPreparedRegistration,
        signer _: CmxIrohRegistrationSigner
    ) throws -> CmxIrohRegistrationResponse {
        throw MobileIrohShutdownTestError.unavailable
    }

    func discover() throws -> CmxIrohDiscoveryResponse {
        throw MobileIrohShutdownTestError.unavailable
    }

    func issuePairGrant(
        initiatorBindingID _: String,
        acceptorBindingID _: String
    ) throws -> CmxIrohPairGrantResponse {
        throw MobileIrohShutdownTestError.unavailable
    }

    func issueRelayToken(
        bindingID _: String,
        endpointID _: CmxIrohPeerIdentity
    ) throws -> CmxIrohRelayTokenResponse {
        throw MobileIrohShutdownTestError.unavailable
    }

    func revoke(bindingID _: String) {}

    func revokeStale(bindingID _: String) {}

    func forgetMac(bindingID _: String) {}
}

private final class MobileIrohShutdownAuthKeyValueStore: CMUXAuthKeyValueStore {
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

private final class MobileIrohShutdownAuthAnchor: NSObject, AuthPresentationAnchoring,
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

private actor MobileIrohShutdownAuthClient: AuthClient {
    private var access: String? = "access"
    private var refresh: String? = "refresh"
    private var user: CMUXAuthUser

    init(user: CMUXAuthUser) { self.user = user }

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
        access
    }
}
