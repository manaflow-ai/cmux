import Foundation
import Combine
import Testing
import CmuxSidebar

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct WorkspaceManualPullRequestTests {
    @Test func manualPullRequestSurvivesWatcherRefreshAndDeduplicatesPanelState() throws {
        let workspace = Workspace(title: "Test")
        let panelId = try #require(workspace.focusedPanelId)
        let url = try #require(URL(string: "https://github.com/manaflow-ai/cmux/pull/12746"))

        workspace.attachManualPullRequest(
            number: 12746,
            label: "PR",
            url: url,
            status: .open,
            branch: "feature/sidebar-pr"
        )
        workspace.updatePanelGitBranch(panelId: panelId, branch: "feature/sidebar-pr", isDirty: false)
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 12746,
            label: "PR",
            url: url,
            status: .open,
            branch: "feature/sidebar-pr"
        )

        #expect(workspace.sidebarPullRequestsInDisplayOrder().count == 1)

        workspace.updatePanelGitBranch(panelId: panelId, branch: "main", isDirty: false)

        #expect(workspace.sidebarPullRequestsInDisplayOrder().count == 1)
        #expect(workspace.sidebarPullRequestsInDisplayOrder().first?.number == 12746)
    }

    @Test func manualPullRequestCanBeReplacedAndCleared() throws {
        let workspace = Workspace(title: "Test")
        let firstURL = try #require(URL(string: "https://github.com/manaflow-ai/cmux/pull/12746"))
        let secondURL = try #require(URL(string: "https://github.com/manaflow-ai/cmux/pull/12747"))

        workspace.attachManualPullRequest(
            number: 12746,
            label: "PR",
            url: firstURL,
            status: .open,
            branch: nil
        )
        workspace.attachManualPullRequest(
            number: 12747,
            label: "PR",
            url: secondURL,
            status: .open,
            branch: nil
        )

        #expect(workspace.sidebarPullRequestsInDisplayOrder().map(\.url) == [secondURL])

        workspace.clearManualPullRequest()

        #expect(workspace.sidebarPullRequestsInDisplayOrder().isEmpty)
    }

    @Test func watcherStatusSurvivesBranchChangeAndClearKeepsAutomaticRows() throws {
        let workspace = Workspace(title: "Test")
        let panel = try #require(workspace.focusedPanelId)
        let url = try #require(URL(string: "https://github.com/owner/repo/pull/123"))
        workspace.updatePanelGitBranch(panelId: panel, branch: "feature", isDirty: false)
        workspace.attachManualPullRequest(number: 123, label: "PR", url: url, status: .open, branch: "feature")
        for status in [SidebarPullRequestStatus.closed, .open, .merged] {
            workspace.updatePanelPullRequest(panelId: panel, number: 123, label: "PR", url: url, status: status, branch: "feature")
            #expect(workspace.sidebarPullRequestsInDisplayOrder().map(\.status) == [status])
        }
        workspace.updatePanelGitBranch(panelId: panel, branch: "main", isDirty: false)
        #expect(workspace.sidebarPullRequestsInDisplayOrder().map(\.status) == [.merged])
        workspace.updatePanelPullRequest(panelId: panel, number: 124, label: "PR", url: URL(string: "https://github.com/owner/repo/pull/124")!, status: .open, branch: "main")
        workspace.clearManualPullRequest()
        #expect(workspace.sidebarPullRequestsInDisplayOrder().map(\.number) == [124])
    }

    @Test func handoffPublishesImmediatelyAndRepeatedAttachIsIdempotent() throws {
        let workspace = Workspace(title: "Test")
        let url = try #require(URL(string: "https://github.com/owner/repo/pull/123"))
        var emissions = 0
        let token = workspace.makeSidebarObservationPublisher().dropFirst().sink { emissions += 1 }
        defer { token.cancel() }
        workspace.attachManualPullRequest(number: 123, label: "PR", url: url, status: .open, branch: nil)
        #expect(emissions == 1)
        workspace.attachManualPullRequest(number: 123, label: "PR", url: url, status: .open, branch: nil)
        #expect(emissions == 1)
        workspace.clearManualPullRequest()
        #expect(emissions == 2)
    }

    @Test func handoffStatusOverridesEarlierWatcherState() throws {
        let workspace = Workspace(title: "Test")
        let panel = try #require(workspace.focusedPanelId)
        let url = try #require(URL(string: "https://github.com/owner/repo/pull/123"))
        workspace.updatePanelGitBranch(panelId: panel, branch: "feature", isDirty: false)
        workspace.updatePanelPullRequest(panelId: panel, number: 123, label: "PR", url: url, status: .open, branch: "feature")
        workspace.attachManualPullRequest(number: 123, label: "PR", url: url, status: .closed, branch: "feature")
        #expect(workspace.sidebarPullRequestsInDisplayOrder().map(\.status) == [.closed])
    }

}
