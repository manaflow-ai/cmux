import Foundation
import Testing
import CmuxCloud

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct CloudVMLoadingPanelTests {
    @Test func loadingHeadlineReplacesBaseProgressCopyAndResets() {
        let panel = CloudVMLoadingPanel(workspaceId: UUID())
        panel.configureLoadingHeadline("Creating a workspace on early-plum-alpaca…")

        guard case .loading(let headline) = panel.phase else {
            Issue.record("headline configuration must remain in the loading phase")
            return
        }
        #expect(headline == "Creating a workspace on early-plum-alpaca…")
        panel.resetLoading()
        guard case .loading(let resetHeadline) = panel.phase else {
            Issue.record("reset must return to loading")
            return
        }
        #expect(resetHeadline == nil)
    }

    @Test func failureReplacesLoadingHeadlineAndShowsFailurePhase() {
        let panel = CloudVMLoadingPanel(workspaceId: UUID())
        panel.configureLoadingHeadline("Creating a workspace on early-plum-alpaca…")

        panel.showFailure("The Cloud VM service is unavailable")

        #expect(panel.hasFailed)
        #expect(!panel.isLoading)
        guard case .failed(let message, _) = panel.phase else {
            Issue.record("failure must be the sole presentation phase")
            return
        }
        #expect(message == "The Cloud VM service is unavailable")
    }

    @Test func teamPlanFailureKeepsScopedUpgradeMetadataAndExplanation() {
        let panel = CloudVMLoadingPanel(workspaceId: UUID())
        panel.showFailure(
            "Error: billing action https://cmux.com/dashboard/billing?team=team-trollol",
            refusalCode: CloudPlanRefusal.requiresTeamPlanCode,
            refusalTeamID: "team-trollol"
        )

        #expect(panel.teamPlanUpgradeID == "team-trollol")
        guard case .failed(let message, _) = panel.phase else {
            Issue.record("Team refusal must be a failed phase")
            return
        }
        #expect(message == CloudPlanRefusal.teamPlanMessage)
        panel.resetLoading()
        #expect(panel.teamPlanUpgradeID == nil)
    }
}
