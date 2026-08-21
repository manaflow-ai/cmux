import AuthenticationServices
import CMUXAuthCore
import CmuxAuthRuntime
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Minimal scriptable ``AuthClient`` for the interception tests: records the
/// calls that distinguish a REAL sign-out (local clear + revocation attempt)
/// from a park (neither).
private actor InterceptionFakeAuthClient: AuthClient {
    private(set) var clearLocalSessionCount = 0
    private(set) var revokeCount = 0

    func accessToken() async -> String? { nil }
    func refreshToken() async -> String? { nil }
    func forceRefreshAccessToken() async -> String? { nil }
    func currentUser(throwOnMissing: Bool) async throws -> CMUXAuthUser? { nil }
    func listTeams() async throws -> [CMUXAuthTeam] { [] }
    func sendMagicLinkEmail(email: String, callbackURL: String) async throws -> String { "nonce" }
    func signInWithMagicLink(code: String) async throws {}
    func signInWithCredential(email: String, password: String) async throws {}
    func signInWithOAuth(provider: String, anchor: any AuthPresentationAnchoring) async throws {}
    func storedAccessToken() async -> String? { nil }
    func clearLocalSession() async { clearLocalSessionCount += 1 }
    func clearLocalSession(ifRefreshTokenMatches refreshToken: String) async {
        clearLocalSessionCount += 1
    }
    func revokeSession(accessToken: String?, refreshToken: String?) async throws {
        revokeCount += 1
    }
    func freshAccessToken(accessToken: String?, refreshToken: String) async -> String? { nil }
}

private final class InterceptionAnchor: NSObject, AuthPresentationAnchoring {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        ASPresentationAnchor()
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        ASPresentationAnchor()
    }
}

/// Never-started browser session; the interception tests never sign in.
private final class InterceptionNoopSession: HostBrowserAuthSession {
    func start() -> Bool { false }
    func cancel() {}
}

@MainActor
private struct InterceptionNoopSessionFactory: HostBrowserAuthSessionFactory {
    func makeSession(
        signInURL: URL,
        callbackScheme: String,
        completion: @escaping @MainActor (HostBrowserAuthSessionResult) -> Void
    ) -> any HostBrowserAuthSession {
        InterceptionNoopSession()
    }
}

/// One fully wired ``HostAccountFlow`` over fakes, with an event log shared
/// by the sign-out chain (`beginSignOut`), the staging confirmation, and the
/// attached switch controller's steps, so the tests can assert the
/// interception ORDER (confirm → real sign-out → switch back), not just that
/// each piece ran.
@MainActor
private final class InterceptionHarness {
    private(set) var events: [String] = []
    let client = InterceptionFakeAuthClient()
    let defaults: UserDefaults
    private let suiteName: String
    var confirmAnswer = true
    private(set) var flow: HostAccountFlow!

    init(activeEnvironment: CMUXBackendEnvironmentOverride) {
        suiteName = "test.cmux.hostAccountFlowInterception.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let config = AuthConfig(
            stack: CMUXAuthConfig(projectId: "test", publishableClientKey: "test"),
            magicLinkCallbackURL: "http://localhost/auth/callback",
            apiBaseURL: "http://localhost"
        )
        let coordinator = AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: defaults, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: defaults, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: defaults, key: "selected_team"),
            anchor: InterceptionAnchor(),
            config: config,
            launch: AuthLaunchOptions(
                clearAuthRequested: false,
                mockDataEnabled: false,
                environment: [:],
                includesDevAuth: false
            )
        )
        let tokenStore = FileStackTokenStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-interception-\(UUID().uuidString)", isDirectory: true)
        )
        let browserSignIn = HostBrowserSignInFlow(
            coordinator: coordinator,
            tokenStore: tokenStore,
            sessionFactory: InterceptionNoopSessionFactory(),
            callbackRouter: AuthCallbackRouter(),
            makeSignInURL: { _ in URL(string: "https://example.com/sign-in")! },
            callbackScheme: { "cmux" },
            openExternalURL: { _ in false },
            beginSignOut: { [weak self] in self?.events.append("realSignOut") },
            beginSessionPark: { [weak self] in self?.events.append("park") },
            localSignOut: {},
            onSignedOut: { _, _ in }
        )
        let flow = HostAccountFlow(
            coordinator: coordinator,
            browserSignIn: browserSignIn,
            activeBackendEnvironmentOverride: activeEnvironment,
            backendEnvironmentPinnedByLaunchEnvironment: false,
            backendEnvironmentDefaults: defaults,
            confirmStagingSignOut: { [weak self] in
                self?.events.append("confirm")
                return self?.confirmAnswer ?? false
            }
        )
        self.flow = flow
        flow.attachBackendEnvironmentSwitchController(
            MacBackendEnvironmentSwitchController(
                steps: BackendEnvironmentSwitchTransaction.Steps(
                    isPinnedByBuild: { false },
                    activeEnvironment: { activeEnvironment },
                    parkSession: { [weak self] in self?.events.append("switch.park") },
                    quiesce: { [weak self] in self?.events.append("switch.quiesce") },
                    storeOverride: { [weak self] override in
                        override.store(in: self?.defaults ?? .standard)
                        self?.events.append("switch.store(\(override.rawValue))")
                    },
                    rebuild: { [weak self] override in
                        self?.events.append("switch.rebuild(\(override.rawValue))")
                    },
                    awaitRestoredUser: { nil },
                    promptSignIn: { [weak self] in
                        self?.events.append("switch.promptSignIn")
                        return nil
                    },
                    cancelSignInPrompt: {},
                    signOutEstablishedSession: {},
                    isEligible: { _ in false },
                    signInPromptFailure: { .failed }
                )
            )
        )
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    var switchedBackToProduction: Bool {
        events.contains("switch.store(production)")
    }
}

@MainActor
@Suite("HostAccountFlow sign-out interception")
struct HostAccountFlowSignOutInterceptionTests {
    @Test("Production sign-out is direct: no confirmation, no switch")
    func productionSignOutIsDirect() async {
        let harness = InterceptionHarness(activeEnvironment: .production)
        defer { harness.cleanUp() }

        await harness.flow.signOut()

        #expect(!harness.events.contains("confirm"))
        #expect(harness.events.contains("realSignOut"))
        #expect(!harness.switchedBackToProduction)
        let revokes = await harness.client.revokeCount
        #expect(revokes == 1)
    }

    @Test("Declined staging confirmation signs nothing out and switches nothing")
    func declinedStagingConfirmationDoesNothing() async {
        let harness = InterceptionHarness(activeEnvironment: .staging)
        defer { harness.cleanUp() }
        harness.confirmAnswer = false

        await harness.flow.signOut()

        #expect(harness.events == ["confirm"])
        let clears = await harness.client.clearLocalSessionCount
        let revokes = await harness.client.revokeCount
        #expect(clears == 0)
        #expect(revokes == 0)
    }

    @Test("Confirmed staging sign-out runs confirm → real sign-out → switch to production")
    func confirmedStagingSignOutChainsInOrder() async {
        let harness = InterceptionHarness(activeEnvironment: .staging)
        defer { harness.cleanUp() }
        harness.confirmAnswer = true

        await harness.flow.signOut()

        let confirmIndex = harness.events.firstIndex(of: "confirm")
        let signOutIndex = harness.events.firstIndex(of: "realSignOut")
        let switchIndex = harness.events.firstIndex(of: "switch.park")
        #expect(confirmIndex != nil && signOutIndex != nil && switchIndex != nil)
        if let confirmIndex, let signOutIndex, let switchIndex {
            #expect(confirmIndex < signOutIndex)
            #expect(signOutIndex < switchIndex)
        }
        // The REAL sign-out ran (local clear + revocation attempt), and the
        // chain committed production (which removes the override key).
        let clears = await harness.client.clearLocalSessionCount
        let revokes = await harness.client.revokeCount
        #expect(clears >= 1)
        #expect(revokes == 1)
        #expect(harness.switchedBackToProduction)
        #expect(harness.defaults.string(
            forKey: CMUXBackendEnvironmentOverride.defaultsKey
        ) == nil)
        // Production restore never prompts.
        #expect(!harness.events.contains("switch.promptSignIn"))
    }

    @Test("The socket sign-out skips the confirmation but chains and reports the switch")
    func socketSignOutSkipsConfirmationButChains() async {
        let harness = InterceptionHarness(activeEnvironment: .staging)
        defer { harness.cleanUp() }

        let returnedToProduction = await harness.flow.signOut(timeout: 5)

        #expect(returnedToProduction)
        #expect(!harness.events.contains("confirm"))
        #expect(harness.events.contains("realSignOut"))
        #expect(harness.switchedBackToProduction)
    }

    @Test("The socket sign-out on production reports no environment change")
    func socketSignOutOnProductionReportsNoSwitch() async {
        let harness = InterceptionHarness(activeEnvironment: .production)
        defer { harness.cleanUp() }

        let returnedToProduction = await harness.flow.signOut(timeout: 5)

        #expect(!returnedToProduction)
        #expect(!harness.events.contains("confirm"))
        #expect(!harness.switchedBackToProduction)
    }
}
