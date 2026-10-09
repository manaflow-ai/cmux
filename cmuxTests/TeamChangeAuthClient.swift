import CMUXAuthCore
import CmuxAuthRuntime
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A team create or switch the fake server refused.
struct TeamChangeRejectedError: Error {}

/// Serves two teams and can hold the next team create or team switch open
/// until the test releases it, so a test can start a second change mid-flight.
/// It can also refuse the next create or switch.
actor TeamChangeAuthClient: AuthClient {
    private var teams: [CMUXAuthTeam]
    private(set) var createCount = 0
    private(set) var selectCount = 0
    private var holdsNextCreate = false
    private var holdsNextSelect = false
    private var heldCreate: CheckedContinuation<Void, Never>?
    private var heldSelect: CheckedContinuation<Void, Never>?
    private var failsNextCreate = false
    private var failsNextSelect = false

    init(firstTeamName: String = "Team A") {
        teams = [
            CMUXAuthTeam(id: "team-a", displayName: firstTeamName),
            CMUXAuthTeam(id: "team-b", displayName: "Team B"),
        ]
    }

    func holdNextCreate() { holdsNextCreate = true }
    func holdNextSelect() { holdsNextSelect = true }
    func failNextCreate() { failsNextCreate = true }
    func failNextSelect() { failsNextSelect = true }
    var isHoldingCreate: Bool { heldCreate != nil }
    var isHoldingSelect: Bool { heldSelect != nil }

    func releaseCreate() {
        heldCreate?.resume()
        heldCreate = nil
    }

    func releaseSelect() {
        heldSelect?.resume()
        heldSelect = nil
    }

    func createTeam(displayName: String) async throws -> CMUXAuthTeam {
        createCount += 1
        let team = CMUXAuthTeam(id: "team-new-\(createCount)", displayName: displayName)
        if holdsNextCreate {
            holdsNextCreate = false
            await withCheckedContinuation { heldCreate = $0 }
        }
        if failsNextCreate {
            failsNextCreate = false
            throw TeamChangeRejectedError()
        }
        teams.append(team)
        return team
    }

    func setSelectedTeam(id: String?) async throws {
        selectCount += 1
        if holdsNextSelect {
            holdsNextSelect = false
            await withCheckedContinuation { heldSelect = $0 }
        }
        if failsNextSelect {
            failsNextSelect = false
            throw TeamChangeRejectedError()
        }
    }

    func listTeams() async throws -> [CMUXAuthTeam] { teams }
    func accessToken() async -> String? { "fixture-access" }
    func refreshToken() async -> String? { "fixture-refresh" }
    func forceRefreshAccessToken() async -> String? { "fixture-access" }
    func currentUser(throwOnMissing: Bool) async throws -> CMUXAuthUser? {
        CMUXAuthUser(id: "fixture", primaryEmail: "fixture@example.test", displayName: "Fixture")
    }
    func sendMagicLinkEmail(email: String, callbackURL: String) async throws -> String { "fixture" }
    func signInWithMagicLink(code: String) async throws {}
    func signInWithCredential(email: String, password: String) async throws {}
    func signInWithOAuth(provider: String, anchor: any AuthPresentationAnchoring) async throws {}
    func storedAccessToken() async -> String? { "fixture-access" }
    func clearLocalSession() async {}
    func clearLocalSession(ifRefreshTokenMatches refreshToken: String) async {}
    func revokeSession(accessToken: String?, refreshToken: String?) async throws {}
    func freshAccessToken(accessToken: String?, refreshToken: String) async -> String? { accessToken }
}

extension HostAccountFlow {
    /// A signed-in flow over `client`, with `team-a` confirmed.
    static func makeForTeamChangeTests(client: TeamChangeAuthClient) async throws -> HostAccountFlow {
        let defaults = try #require(UserDefaults(suiteName: "HostAccountFlowTeamChangeTests.\(UUID())"))
        let anchor = AuthPresentationContextProvider()
        let coordinator = AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: defaults, key: "session"),
            userCache: CMUXAuthIdentityStore(keyValueStore: defaults, key: "user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: defaults, key: "team"),
            anchor: anchor,
            config: AuthConfig(
                stack: CMUXAuthConfig(projectId: "fixture", publishableClientKey: "fixture"),
                magicLinkCallbackURL: "http://127.0.0.1:1/callback", apiBaseURL: "http://127.0.0.1:1"
            ),
            launch: AuthLaunchOptions(
                clearAuthRequested: false, mockDataEnabled: false,
                environment: [
                    "CMUX_UITEST_AUTH_FIXTURE": "1",
                    "CMUX_UITEST_AUTH_USER_ID": "fixture",
                    "CMUX_UITEST_AUTH_FIXTURE_TEAMS": "1",
                ],
                includesDevAuth: true
            )
        )
        coordinator.start()
        await coordinator.awaitBootstrapped()
        try #require(coordinator.isAuthenticated)
        try #require(coordinator.availableTeams.map(\.id) == ["team-a", "team-b"])
        let signInURL = try #require(URL(string: "http://127.0.0.1:1/sign-in"))
        let browserSignIn = HostBrowserSignInFlow(
            coordinator: coordinator,
            tokenStore: FileStackTokenStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("HostAccountFlowTeamChangeTests-\(UUID())", isDirectory: true)
            ),
            sessionFactory: ASWebBrowserAuthSessionFactory(anchor: anchor),
            callbackRouter: AuthCallbackRouter(),
            makeSignInURL: { _ in signInURL },
            callbackScheme: { "cmux-test" },
            openExternalURL: { _ in false }
        )
        let flow = HostAccountFlow(coordinator: coordinator, browserSignIn: browserSignIn)
        try #require(flow.confirmedTeamID == "team-a")
        return flow
    }
}
