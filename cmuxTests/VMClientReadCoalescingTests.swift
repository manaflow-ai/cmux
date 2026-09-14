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
    @Test("A hidden panel cancels its list and cannot start stats from a late result")
    func hiddenPanelCancelsFollowupWork() async throws {
        let fixture = try await CloudRefreshFixture.make()
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        let model = MachinesPanelViewModel(client: fixture.client)
        model.startPolling()
        await CloudRefreshURLProtocol.waitUntilStarted()
        model.stopPolling()
        await CloudRefreshURLProtocol.waitUntilStopped()
        #expect(!model.isLoading)
        #expect(model.machines.isEmpty)
        NotificationCenter.default.post(name: .cmuxCloudReadNetworkRecovered, object: nil)
        #expect(await CloudRefreshURLProtocol.requestCounts().values.reduce(0, +) == 1)
    }

    @Test("Dropping a view model releases it and cancels its pending list")
    func viewModelTeardown() async throws {
        let fixture = try await CloudRefreshFixture.make()
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        var model: MachinesPanelViewModel? = MachinesPanelViewModel(client: fixture.client)
        weak var weakModel = model
        model?.refresh()
        await CloudRefreshURLProtocol.waitUntilStarted()
        model = nil
        #expect(weakModel == nil)
        await CloudRefreshURLProtocol.waitUntilStopped()
    }

    @Test("A failed stats sample clears the last live reading")
    func failedStatsAreUnavailable() async throws {
        let fixture = try await CloudRefreshFixture.make()
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        let model = MachinesPanelViewModel(client: fixture.client)
        defer { model.stopPolling() }
        model.refresh()
        try await eventually { model.machines.first?.stats?.state == .awake }
        await CloudRefreshURLProtocol.configure(.statsUnavailable)
        model.refresh()
        try await eventually { !model.isLoading && model.machines.first?.stats == nil }
        #expect(model.machines.count == 1)
        #expect(model.listProblem == nil)
    }

    @Test("The VM operation budget cancels a slow transport")
    func totalRequestBudget() async throws {
        let fixture = try await CloudRefreshFixture.make(readRequests: CloudReadRequestCoordinator(budget: .milliseconds(100)))
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        do { _ = try await fixture.client.stats(id: "fixture-0"); Issue.record("request exceeded its total budget") }
        catch { #expect((error as? URLError)?.code == .timedOut) }
        await CloudRefreshURLProtocol.waitUntilStopped()
    }

    @Test("HTTP Retry-After exceeds the budget without an early automatic retry")
    func retryAfterAcrossCalls() async throws {
        let clock = CloudReadManualClock()
        let reads = CloudReadRequestCoordinator(clock: CloudRequestClock(clock))
        let fixture = try await CloudRefreshFixture.make(readRequests: reads)
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        await CloudRefreshURLProtocol.configure(.throttled)
        for _ in 0..<2 {
            do { _ = try await fixture.client.stats(id: "fixture-0"); Issue.record("throttle succeeded") }
            catch VMClientError.httpStatus(429, _) {} catch { Issue.record("\(error)") }
        }
        #expect(await CloudRefreshURLProtocol.requestCounts().values.reduce(0, +) == 1)
        await CloudRefreshURLProtocol.configure(.normal)
        clock.advance(by: .seconds(60))
        #expect(try await fixture.client.stats(id: "fixture-0").state == .awake)
        #expect(await CloudRefreshURLProtocol.requestCounts().values.reduce(0, +) == 2)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
    }

}

@MainActor
struct CloudRefreshFixture {
    let client: VMClient
    let session: URLSession

    static func make(readRequests: CloudReadRequestCoordinator = CloudReadRequestCoordinator()) async throws -> Self {
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
            machineCache: CloudMachineCache(defaults: defaults), readRequests: readRequests
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
