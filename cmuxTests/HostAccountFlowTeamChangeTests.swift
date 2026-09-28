import CMUXAuthCore
import CmuxAuthRuntime
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Team changes from every surface (the Cloud picker, Settings and the socket)
/// go through ``HostAccountFlow``. A later coordinator mutation fails an
/// earlier one, so the flow must refuse a change that would fail a pending
/// create, whichever surface asks.
@MainActor
@Suite("Host account flow team changes")
struct HostAccountFlowTeamChangeTests {
    @Test func switchDuringPendingCreateIsRefusedAndTheCreateCompletes() async throws {
        let client = TeamChangeAuthClient()
        let flow = try await makeFlow(client: client)
        await client.holdNextCreate()
        let create = Task { try await flow.createTeam(displayName: "New Team") }
        try await waitUntil { await client.isHoldingCreate }

        await #expect(throws: TeamChangeInProgressError()) {
            try await flow.selectTeam(id: "team-b")
        }
        #expect(await client.selectCount == 0)
        #expect(flow.selectedTeamID == "team-a")
        #expect(flow.confirmedTeamID == "team-a")

        await client.releaseCreate()
        let created = try await create.value
        #expect(created.id == "team-new-1")
        #expect(flow.confirmedTeamID == "team-new-1")
    }

    @Test func createDuringPendingSwitchIsRefusedWithoutCreatingATeam() async throws {
        let client = TeamChangeAuthClient()
        let flow = try await makeFlow(client: client)
        await client.holdNextSelect()
        let select = Task { try await flow.selectTeam(id: "team-b") }
        try await waitUntil { await client.isHoldingSelect }

        await #expect(throws: TeamChangeInProgressError()) {
            _ = try await flow.createTeam(displayName: "New Team")
        }
        #expect(await client.createCount == 0)

        await client.releaseSelect()
        try await select.value
        #expect(flow.confirmedTeamID == "team-b")
    }

    @Test func createDuringPendingCreateIsRefusedAndTheFirstCreateCompletes() async throws {
        let client = TeamChangeAuthClient()
        let flow = try await makeFlow(client: client)
        await client.holdNextCreate()
        let first = Task { try await flow.createTeam(displayName: "First Team") }
        try await waitUntil { await client.isHoldingCreate }

        await #expect(throws: TeamChangeInProgressError()) {
            _ = try await flow.createTeam(displayName: "Second Team")
        }
        #expect(await client.createCount == 1)

        await client.releaseCreate()
        let created = try await first.value
        #expect(created.id == "team-new-1")
        #expect(flow.confirmedTeamID == "team-new-1")
    }

    /// Only a create holds other changes; a later switch still replaces a
    /// pending one, and the superseded switch fails.
    @Test func switchDuringPendingSwitchReplacesIt() async throws {
        let client = TeamChangeAuthClient()
        let flow = try await makeFlow(client: client)
        await client.holdNextSelect()
        let first = Task { try await flow.selectTeam(id: "team-b") }
        try await waitUntil { await client.isHoldingSelect }
        #expect(flow.selectedTeamID == "team-b")

        try await flow.selectTeam(id: "team-a")
        await client.releaseSelect()
        await #expect(throws: AuthError.unauthorized) { try await first.value }
        #expect(flow.selectedTeamID == "team-a")
        #expect(flow.confirmedTeamID == "team-a")
        #expect(await client.selectCount == 2)
    }

    private func makeFlow(client: TeamChangeAuthClient) async throws -> HostAccountFlow {
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

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await condition(), "The fake client never held the request.")
    }
}
