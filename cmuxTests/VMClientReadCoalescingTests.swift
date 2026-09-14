import CMUXAuthCore
import CmuxAuthRuntime
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud read request ownership", .serialized)
struct VMClientReadCoalescingTests {
    @Test("Overlapping machine stats callers share one HTTP request")
    func statsReadersShareTransport() async throws {
        let fixture = try await CloudRefreshFixture.make()
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                for machine in 0..<10 {
                    group.addTask { _ = try? await fixture.client.stats(id: "fixture-\(machine)") }
                }
            }
        }
        let counts = await CloudRefreshURLProtocol.requestCounts()
        #expect(counts.count == 10)
        #expect(counts.values.allSatisfy { $0 == 1 }, "Four owners must share one read per machine: \(counts.values.sorted())")
    }

    @Test("Overlapping machine list callers share one HTTP request")
    func listReadersShareTransport() async throws {
        let fixture = try await CloudRefreshFixture.make()
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { _ = try? await fixture.client.listPage() }
            }
        }
        let counts = await CloudRefreshURLProtocol.requestCounts()
        #expect(counts.values.reduce(0, +) == 1)
    }
}

@MainActor
struct CloudRefreshFixture {
    let client: VMClient
    let session: URLSession

    static func make() async throws -> Self {
        let defaults = try #require(UserDefaults(suiteName: "CloudRefreshFixture.\(UUID())"))
        let auth = AuthCoordinator(
            client: CloudRefreshAuthClient(),
            sessionCache: CMUXAuthSessionCache(keyValueStore: defaults, key: "session"),
            userCache: CMUXAuthIdentityStore(keyValueStore: defaults, key: "user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: defaults, key: "team"),
            anchor: AuthPresentationContextProvider(),
            config: AuthConfig(
                stack: CMUXAuthConfig(projectId: "fixture", publishableClientKey: "fixture"),
                magicLinkCallbackURL: "http://127.0.0.1:1/callback", apiBaseURL: "http://127.0.0.1:1"
            ),
            launch: AuthLaunchOptions(
                clearAuthRequested: false, mockDataEnabled: false,
                environment: ["CMUX_UITEST_AUTH_FIXTURE": "1", "CMUX_UITEST_AUTH_USER_ID": "fixture"],
                includesDevAuth: true
            )
        )
        auth.start()
        await auth.awaitBootstrapped()
        try #require(auth.isAuthenticated)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudRefreshURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return Self(client: VMClient(
            session: session, auth: auth, checkpointRenames: CloudRenameCoordinator(),
            machineCache: CloudMachineCache(defaults: defaults)
        ), session: session)
    }
}

private actor CloudRefreshAuthClient: AuthClient {
    func accessToken() async -> String? { "fixture-access" }
    func refreshToken() async -> String? { "fixture-refresh" }
    func forceRefreshAccessToken() async -> String? { "fixture-access" }
    func currentUser(throwOnMissing: Bool) async throws -> CMUXAuthUser? {
        CMUXAuthUser(id: "fixture", primaryEmail: "fixture@example.test", displayName: "Fixture")
    }
    func listTeams() async throws -> [CMUXAuthTeam] { [] }
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
