import CmuxCloud
import CmuxAuthRuntime
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A Cloud surface names the team that owns its machine on every request, so
/// surfaces of several teams can stay open while the selected team changes.
@MainActor
extension VMClientReadCoalescingTests {
    @Test("An explicit owning team is the request's team header")
    func explicitTeamHeader() async throws {
        let fixture = try await CloudRefreshFixture.make(authClient: TeamChangeAuthClient(), fixtureTeams: true)
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        try await fixture.auth.selectTeam(id: "team-a")

        _ = try await fixture.client.stats(id: "fixture-0", teamID: "team-b")
        _ = try await fixture.client.stats(id: "fixture-1")

        #expect(await CloudRefreshURLProtocol.teamHeaders() == ["team-b", "team-a"])
    }

    @Test("Shared reads coalesce per owning team, never across teams")
    func explicitTeamCoalescingKey() async throws {
        let fixture = try await CloudRefreshFixture.make(authClient: TeamChangeAuthClient(), fixtureTeams: true)
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        try await fixture.auth.selectTeam(id: "team-a")
        await CloudRefreshURLProtocol.holdResponses()

        let teamA = Task { try await fixture.client.stats(id: "fixture-0", teamID: "team-a") }
        let teamB = Task { try await fixture.client.stats(id: "fixture-0", teamID: "team-b") }
        await CloudRefreshURLProtocol.waitUntilStarted(2)
        let joinedTeamB = Task { try await fixture.client.stats(id: "fixture-0", teamID: "team-b") }
        await CloudRefreshURLProtocol.releaseResponses()
        _ = try await teamA.value
        _ = try await teamB.value
        _ = try await joinedTeamB.value

        #expect(await CloudRefreshURLProtocol.requestCounts()["/api/vm/fixture-0/stats"] == 2)
        #expect(Set(await CloudRefreshURLProtocol.teamHeaders().compactMap { $0 }) == ["team-a", "team-b"])
    }

    @Test("A selection change does not cancel an owning-team request, only a selected-team one")
    func explicitTeamSurvivesSelectionChange() async throws {
        let fixture = try await CloudRefreshFixture.make(authClient: TeamChangeAuthClient(), fixtureTeams: true)
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        try await fixture.auth.selectTeam(id: "team-a")
        await CloudRefreshURLProtocol.holdResponses()

        let owned = Task { try await fixture.client.stats(id: "fixture-0", teamID: "team-a") }
        let selected = Task { try await fixture.client.stats(id: "fixture-1") }
        await CloudRefreshURLProtocol.waitUntilStarted(2)
        try await fixture.auth.selectTeam(id: "team-b")
        #expect(fixture.auth.resolvedTeamID == "team-b")
        await CloudRefreshURLProtocol.releaseResponses()

        let ownedResult = await owned.result
        #expect(throws: Never.self) { try ownedResult.get() }
        do {
            _ = try await selected.value
            Issue.record("A read bound to the previous selection was published into the new team")
        } catch is CancellationError {
        } catch VMClientError.notSignedIn {
        } catch { Issue.record("Unexpected selection-change error: \(error)") }
    }
}
