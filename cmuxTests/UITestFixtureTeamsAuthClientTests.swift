import CMUXAuthCore
import CmuxAuthRuntime
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
/// Session priming refreshes teams whenever `CMUX_UITEST_AUTH_FIXTURE_TEAMS`
/// is set, so every team call in a fixture-teams launch must stay off the
/// live client, even when the value is malformed.
@Suite("UI test fixture teams client")
struct UITestFixtureTeamsAuthClientTests {
    @Test func malformedTeamsStillKeepTeamCallsOffTheLiveClient() async throws {
        let live = TeamChangeAuthClient()
        let client = UITestFixtureTeamsAuthClient.wrapping(live, environment: [
            "CMUX_UITEST_AUTH_FIXTURE": "1",
            "CMUX_UITEST_AUTH_FIXTURE_TEAMS": "not a team list",
        ])

        #expect(try await client.listTeams().isEmpty)
        try await client.setSelectedTeam(id: nil)
        #expect(await live.selectCount == 0)
    }

    @Test func launchesWithoutFixtureTeamsUseTheLiveClient() async throws {
        let live = TeamChangeAuthClient()
        let client = UITestFixtureTeamsAuthClient.wrapping(live, environment: [
            "CMUX_UITEST_AUTH_FIXTURE": "1",
        ])

        #expect(try await client.listTeams().map(\.id) == ["team-a", "team-b"])
    }
}
#endif
