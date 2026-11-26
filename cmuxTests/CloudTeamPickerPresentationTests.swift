import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The Create Team sheet closes before the server answers, so the Cloud
/// header reports how the create ended.
@MainActor
@Suite("Cloud team picker presentation")
struct CloudTeamPickerPresentationTests {
    private let createFailed = String(
        localized: "sidebar.account.createTeamFailed",
        defaultValue: "Could not create that team. Try again."
    )
    private let switchFailed = String(
        localized: "sidebar.account.switchTeamFailed",
        defaultValue: "Could not switch teams. Try again."
    )

    @Test func rejectedCreateReportsItAndKeepsTheNameForTheRetry() async throws {
        let client = TeamChangeAuthClient()
        let flow = try await HostAccountFlow.makeForTeamChangeTests(client: client)
        let presentation = CloudTeamPickerPresentation()
        await client.failNextCreate()

        presentation.createTeam(named: "Taken Team", accountFlow: flow)
        try await waitUntil { presentation.teamChangeError != nil }
        #expect(presentation.teamChangeError == createFailed)
        #expect(presentation.rejectedTeamName == "Taken Team")
        #expect(flow.pendingTeamCreate == nil)
        #expect(flow.confirmedTeamID == "team-a")

        presentation.createTeam(named: "Launch Crew", accountFlow: flow)
        #expect(presentation.teamChangeError == nil)
        #expect(presentation.rejectedTeamName == nil)
        try await waitUntil { flow.confirmedTeamID == "team-new-2" }
        #expect(presentation.teamChangeError == nil)
    }

    /// The server made the team, so retrying the name would make a second one.
    @Test func createdTeamThatFailsToSelectReportsAFailedSwitch() async throws {
        let client = TeamChangeAuthClient()
        let flow = try await HostAccountFlow.makeForTeamChangeTests(client: client)
        let presentation = CloudTeamPickerPresentation()
        await client.failNextSelect()

        presentation.createTeam(named: "Launch Crew", accountFlow: flow)
        try await waitUntil { presentation.teamChangeError != nil }
        #expect(presentation.teamChangeError == switchFailed)
        #expect(presentation.rejectedTeamName == nil)
        #expect(flow.availableTeams.contains { $0.id == "team-new-1" })
        #expect(flow.confirmedTeamID == "team-a")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "The team change never finished.")
    }
}
