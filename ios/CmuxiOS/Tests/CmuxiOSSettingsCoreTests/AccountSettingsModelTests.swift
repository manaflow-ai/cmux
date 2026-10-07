import CmuxiOSSettingsCore
import Testing

@MainActor
@Suite struct AccountSettingsModelTests {
    @Test func teamSwitchCommitsAtTheOwner() async {
        let controller = MockAccountController()
        let model = AccountSettingsModel(controller: controller)
        #expect(model.selectedTeam?.name == "Personal")
        await model.selectTeam("team-manaflow")
        #expect(model.selectedTeam?.name == "Manaflow")
        #expect(!model.teamChangeFailed)
    }

    @Test func refusedTeamSwitchKeepsTheOwnersValue() async {
        let controller = MockAccountController()
        controller.refusedTeams = ["team-manaflow"]
        let model = AccountSettingsModel(controller: controller)
        await model.selectTeam("team-manaflow")
        #expect(model.teamChangeFailed)
        #expect(model.snapshot.selectedTeamID == "team-personal")
    }

    @Test func completedDeletionSignsOut() async {
        let controller = MockAccountController()
        let model = AccountSettingsModel(controller: controller)
        await model.deleteAccount()
        #expect(controller.signOutCount == 1)
        #expect(model.deletionAlert == nil)
        #expect(!model.isDeleting)
    }

    @Test func incompleteCleanupSignsOutAfterAcknowledgement() async {
        let controller = MockAccountController(deletionResult: .success(.completedWithIncompleteServerCleanup))
        let model = AccountSettingsModel(controller: controller)
        await model.deleteAccount()
        #expect(model.deletionAlert == .serverCleanupIncomplete)
        #expect(controller.signOutCount == 0)
        await model.acknowledgeDeletionAlert()
        #expect(controller.signOutCount == 1)
        #expect(model.deletionAlert == nil)
    }

    @Test func retryableFailureKeepsTheSession() async {
        for failure in [AccountDeletionFailure.connection, .timedOut, .unknown, .stackDeleteIncomplete, .generic] {
            let controller = MockAccountController(deletionResult: .failure(failure))
            let model = AccountSettingsModel(controller: controller)
            await model.deleteAccount()
            #expect(model.deletionAlert == failure)
            await model.acknowledgeDeletionAlert()
            #expect(controller.signOutCount == 0, "\(failure)")
        }
    }

    @Test func unauthorizedSignsOutAfterAcknowledgement() async {
        let controller = MockAccountController(deletionResult: .failure(.unauthorized))
        let model = AccountSettingsModel(controller: controller)
        await model.deleteAccount()
        await model.acknowledgeDeletionAlert()
        #expect(controller.signOutCount == 1)
    }

    @Test func observeMirrorsOwnerChanges() async {
        let controller = MockAccountController()
        let model = AccountSettingsModel(controller: controller)
        let task = Task { await model.observe() }
        defer { task.cancel() }
        try? await controller.selectTeam("team-manaflow")
        while model.snapshot.selectedTeamID != "team-manaflow" { await Task.yield() }
        #expect(model.selectedTeam?.id == "team-manaflow")
    }
}
