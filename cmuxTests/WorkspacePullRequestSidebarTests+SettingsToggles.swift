import XCTest
import Darwin
import CmuxProcess

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Git watch and pull request visibility toggles
extension WorkspacePullRequestSidebarTests {
    func testDisablingGitWatchClearsCachedPullRequestBadgesWhenPullRequestsAreShownByDefault() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        let previousShowPullRequests = defaults.object(forKey: SidebarWorkspaceDetailDefaults.showPullRequestsKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
            restoreUserDefault(previousShowPullRequests, key: SidebarWorkspaceDetailDefaults.showPullRequestsKey)
        }

        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defaults.removeObject(forKey: SidebarWorkspaceDetailDefaults.showPullRequestsKey)
        XCTAssertTrue(
            SidebarWorkspaceDetailDefaults.showPullRequestsValue(defaults: defaults),
            "PR badges should be enabled by default so this covers the stale badge users see."
        )

        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let url = try XCTUnwrap(URL(string: "https://github.com/manaflow-ai/cmux/pull/2722"))

        workspace.updatePanelGitBranch(
            panelId: panelId,
            branch: "issue-2722-git-index-lock-poll",
            isDirty: false
        )
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 2722,
            label: "#2722",
            url: url,
            status: .open,
            branch: "issue-2722-git-index-lock-poll"
        )

        XCTAssertFalse(workspace.sidebarPullRequestsInDisplayOrder(orderedPanelIds: [panelId]).isEmpty)

        defaults.set(false, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        manager.sidebarGitMetadataWatchSettingsDidChangeForTesting()

        XCTAssertNil(workspace.gitBranch)
        XCTAssertNil(workspace.pullRequest)
        XCTAssertTrue(workspace.panelGitBranches.isEmpty)
        XCTAssertTrue(workspace.panelPullRequests.isEmpty)
        XCTAssertEqual(workspace.sidebarPullRequestsInDisplayOrder(orderedPanelIds: [panelId]), [])

        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
        }
        let response = TerminalController.shared.handleSocketLine(
            "report_pr 2722 https://github.com/manaflow-ai/cmux/pull/2722 --label=PR --state=open --branch=issue-2722-git-index-lock-poll --tab=\(workspace.id.uuidString) --panel=\(panelId.uuidString)"
        )
        XCTAssertEqual(response, "OK")
        TerminalMutationBus.shared.drainForTesting()

        XCTAssertTrue(
            workspace.panelPullRequests.isEmpty,
            "Stale shell report_pr messages must not repopulate PR badges while sidebar.watchGitStatus is disabled."
        )
        XCTAssertEqual(workspace.sidebarPullRequestsInDisplayOrder(orderedPanelIds: [panelId]), [])

        workspace.updatePanelGitBranch(
            panelId: panelId,
            branch: "issue-2722-git-index-lock-poll",
            isDirty: false
        )
        XCTAssertFalse(workspace.panelGitBranches.isEmpty)

        let branchResponse = TerminalController.shared.handleSocketLine(
            "report_git_branch main --status=unknown --tab=\(workspace.id.uuidString) --panel=\(panelId.uuidString)"
        )
        XCTAssertEqual(branchResponse, "OK")
        TerminalMutationBus.shared.drainForTesting()

        XCTAssertTrue(
            workspace.panelGitBranches.isEmpty,
            "Stale shell report_git_branch messages must not repopulate branch badges while sidebar.watchGitStatus is disabled."
        )
    }

    func testHiddenPullRequestsDoNotSchedulePullRequestPollingFromBranchReports() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        let previousShowPullRequests = defaults.object(forKey: SidebarWorkspaceDetailDefaults.showPullRequestsKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
            restoreUserDefault(previousShowPullRequests, key: SidebarWorkspaceDetailDefaults.showPullRequestsKey)
        }

        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defaults.set(false, forKey: SidebarWorkspaceDetailDefaults.showPullRequestsKey)

        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        manager.updateSurfaceGitBranch(
            tabId: workspace.id,
            surfaceId: panelId,
            branch: "issue-2746-rate-limit",
            isDirty: false
        )

        XCTAssertEqual(workspace.panelGitBranches[panelId]?.branch, "issue-2746-rate-limit")
        XCTAssertTrue(
            manager.workspacePullRequestTrackedPanelIdsForTesting(workspaceId: workspace.id).isEmpty,
            "Branch reports should keep branch metadata but must not arm any PR polling while sidebar.showPullRequests is false."
        )
    }

    func testDisablingPullRequestSidebarClearsCachedPullRequestsWithoutClearingBranches() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        let previousShowPullRequests = defaults.object(forKey: SidebarWorkspaceDetailDefaults.showPullRequestsKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
            restoreUserDefault(previousShowPullRequests, key: SidebarWorkspaceDetailDefaults.showPullRequestsKey)
        }

        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.showPullRequestsKey)

        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let url = try XCTUnwrap(URL(string: "https://github.com/manaflow-ai/cmux/pull/2746"))

        workspace.updatePanelGitBranch(
            panelId: panelId,
            branch: "issue-2746-rate-limit",
            isDirty: false
        )
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 2746,
            label: "PR",
            url: url,
            status: .open,
            branch: "issue-2746-rate-limit"
        )
        XCTAssertNotNil(workspace.panelPullRequests[panelId])

        defaults.set(false, forKey: SidebarWorkspaceDetailDefaults.showPullRequestsKey)
        manager.sidebarGitMetadataWatchSettingsDidChangeForTesting()

        XCTAssertEqual(workspace.panelGitBranches[panelId]?.branch, "issue-2746-rate-limit")
        XCTAssertNil(workspace.panelPullRequests[panelId])
        XCTAssertNil(workspace.pullRequest)
        XCTAssertTrue(
            manager.workspacePullRequestTrackedPanelIdsForTesting(workspaceId: workspace.id).isEmpty,
            "Disabling PR visibility should clear PR state and polling without disabling branch metadata."
        )

        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.showPullRequestsKey)
        manager.sidebarGitMetadataWatchSettingsDidChangeForTesting()

        XCTAssertEqual(workspace.panelGitBranches[panelId]?.branch, "issue-2746-rate-limit")
        XCTAssertEqual(
            manager.workspacePullRequestTrackedPanelIdsForTesting(workspaceId: workspace.id),
            Set([panelId]),
            "Re-enabling PR visibility should restart PR polling from preserved branch metadata."
        )
    }

}
