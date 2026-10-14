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
/// share the runtime coordinator's exclusion policy. The flow owns only the
/// optimistic projection and preserves it when the coordinator refuses a
/// request from another surface.
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
        #expect(flow.pendingTeamCreate?.displayName == "New Team")
        #expect(flow.isCreatingTeam)

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
        #expect(flow.pendingTeamCreate?.displayName == "First Team")
        #expect(flow.isCreatingTeam)

        await client.releaseCreate()
        let created = try await first.value
        #expect(created.id == "team-new-1")
        #expect(flow.confirmedTeamID == "team-new-1")
    }

    /// The Cloud header shows a pending create as the active team, standing in
    /// for teams the coordinator lists mid-create, while the confirmed scope
    /// stays on the previous team until the server answers.
    @Test func pendingCreateIsProjectedUntilTheServerAnswers() async throws {
        let client = TeamChangeAuthClient()
        let flow = try await makeFlow(client: client)
        await client.holdNextCreate()
        let create = Task { try await flow.createTeam(displayName: "  Launch Crew ") }
        try await waitUntil { await client.isHoldingCreate }

        #expect(flow.pendingTeamCreate == PendingTeamCreate(
            displayName: "Launch Crew",
            existingTeamIDs: ["team-a", "team-b"]
        ))
        #expect(flow.isCreatingTeam)
        #expect(flow.confirmedTeamID == "team-a")

        await client.releaseCreate()
        _ = try await create.value
        #expect(flow.pendingTeamCreate == nil)
        #expect(flow.confirmedTeamID == "team-new-1")
    }

    @Test func rejectedCreateClearsTheProjectionAndKeepsTheTeam() async throws {
        let client = TeamChangeAuthClient()
        let flow = try await makeFlow(client: client)
        await client.failNextCreate()

        await #expect(throws: TeamChangeRejectedError.self) {
            _ = try await flow.createTeam(displayName: "Taken Team")
        }
        #expect(flow.pendingTeamCreate == nil)
        #expect(flow.confirmedTeamID == "team-a")
        #expect(flow.availableTeams.map(\.id) == ["team-a", "team-b"])
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

    /// The coordinator clears its busy flag before the first caller resumes
    /// and clears its optimistic projection. A second accepted create can
    /// therefore overlap that continuation; the first cleanup must not clear
    /// the second request's projection.
    @Test func overlappingAcceptedCreatesKeepTheLatestProjectionOwned() async throws {
        let client = TeamChangeAuthClient()
        let flow = try await makeFlow(client: client)
        await client.holdNextCreate()
        let first = Task { try await flow.createTeam(displayName: "First Team") }
        try await waitUntil { await client.isHoldingCreate }

        let second = Task { @MainActor in
            while flow.isCreatingTeam { await Task.yield() }
            return try await flow.createTeam(displayName: "Second Team")
        }
        await client.holdNextCreate()
        await client.releaseCreate()
        try await waitUntil { await client.isHoldingCreate }

        let firstResult = try await first.value
        #expect(firstResult.id == "team-new-1")
        #expect(flow.pendingTeamCreate?.displayName == "Second Team")
        #expect(flow.isCreatingTeam)

        await client.releaseCreate()
        let secondResult = try await second.value
        #expect(secondResult.id == "team-new-2")
        #expect(flow.pendingTeamCreate == nil)
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
