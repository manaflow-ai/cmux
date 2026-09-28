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

    /// A superseded switch can still be in flight after the switch that
    /// replaced it finishes, and a create must wait for it too.
    @Test func createWaitsForASupersededSwitchStillInFlight() async throws {
        let client = TeamChangeAuthClient()
        let flow = try await makeFlow(client: client)
        await client.holdNextSelect()
        let first = Task { try await flow.selectTeam(id: "team-b") }
        try await waitUntil { await client.isHoldingSelect }
        try await flow.selectTeam(id: "team-a")

        #expect(flow.isSelectingTeam)
        await #expect(throws: TeamChangeInProgressError()) {
            _ = try await flow.createTeam(displayName: "New Team")
        }
        #expect(await client.createCount == 0)

        await client.releaseSelect()
        await #expect(throws: AuthError.unauthorized) { try await first.value }
        #expect(!flow.isSelectingTeam)
    }

    private func makeFlow(client: TeamChangeAuthClient) async throws -> HostAccountFlow {
        try await HostAccountFlow.makeForTeamChangeTests(client: client)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await condition(), "The fake client never held the request.")
    }
}
