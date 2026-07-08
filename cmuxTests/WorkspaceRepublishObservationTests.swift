import Observation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Mutable flag captured by Observation's Sendable onChange closure in tests.
final class ObservationChangeFlag: @unchecked Sendable {
    private(set) var fired = false

    func mark() {
        fired = true
    }
}

/// Same-state refreshes of focused-panel git metadata must not invalidate the
/// workspace's Observation-tracked git properties (extracted from
/// `WorkspaceUnitTests.swift`, where these assertions counted object-wide
/// will-change publishes before the Observation migration).
@MainActor
final class WorkspaceRepublishObservationTests: XCTestCase {
    func testUpdatingFocusedPanelGitBranchWithSameStateDoesNotRepublishWorkspace() {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        let firstChangeFlag = ObservationChangeFlag()
        withObservationTracking {
            _ = workspace.panelGitBranches
            _ = workspace.gitBranch
        } onChange: {
            firstChangeFlag.mark()
        }

        workspace.updatePanelGitBranch(panelId: panelId, branch: "main", isDirty: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))

        XCTAssertTrue(
            firstChangeFlag.fired,
            "Expected the first focused branch update to publish workspace changes"
        )

        let identicalChangeFlag = ObservationChangeFlag()
        withObservationTracking {
            _ = workspace.panelGitBranches
            _ = workspace.gitBranch
        } onChange: {
            identicalChangeFlag.mark()
        }

        workspace.updatePanelGitBranch(panelId: panelId, branch: "main", isDirty: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))

        XCTAssertFalse(
            identicalChangeFlag.fired,
            "Expected identical focused branch refreshes to avoid extra workspace publishes"
        )
    }

    func testUpdatingFocusedPanelPullRequestWithSameStateDoesNotRepublishWorkspace() {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        workspace.updatePanelGitBranch(panelId: panelId, branch: "feature/sidebar-pr", isDirty: false)

        let firstChangeFlag = ObservationChangeFlag()
        withObservationTracking {
            _ = workspace.panelPullRequests
            _ = workspace.pullRequest
        } onChange: {
            firstChangeFlag.mark()
        }

        let pullRequestURL = URL(string: "https://github.com/manaflow-ai/cmux/pull/2388")!
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 2388,
            label: "PR",
            url: pullRequestURL,
            status: .open,
            branch: "feature/sidebar-pr"
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))

        XCTAssertTrue(
            firstChangeFlag.fired,
            "Expected the first focused pull request update to publish workspace changes"
        )

        let identicalChangeFlag = ObservationChangeFlag()
        withObservationTracking {
            _ = workspace.panelPullRequests
            _ = workspace.pullRequest
        } onChange: {
            identicalChangeFlag.mark()
        }

        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 2388,
            label: "PR",
            url: pullRequestURL,
            status: .open,
            branch: "feature/sidebar-pr"
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))

        XCTAssertFalse(
            identicalChangeFlag.fired,
            "Expected identical focused pull request refreshes to avoid extra workspace publishes"
        )
    }
}
