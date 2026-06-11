import XCTest
import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Combine

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Sidebar git branches and pull requests
extension WorkspacePanelGitBranchTests {
    func testSidebarGitBranchesFollowLeftToRightSplitOrder() {
        let workspace = Workspace()
        guard let leftPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        workspace.updatePanelGitBranch(panelId: leftPanelId, branch: "main", isDirty: false)
        guard let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split panel to be created")
            return
        }
        workspace.updatePanelGitBranch(panelId: rightPanel.id, branch: "feature/sidebar", isDirty: true)

        let ordered = workspace.sidebarGitBranchesInDisplayOrder()
        XCTAssertEqual(ordered.map(\.branch), ["main", "feature/sidebar"])
        XCTAssertEqual(ordered.map(\.isDirty), [false, true])
    }

    func testUpdatingFocusedPanelGitBranchWithSameStateDoesNotRepublishWorkspace() {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        // `Workspace` is `@Observable` (no `objectWillChange`); assert on the
        // git-facing tracked state the update can mutate instead.
        final class ChangeFlag: @unchecked Sendable { var didChange = false }

        func trackGitState(_ flag: ChangeFlag) {
            withObservationTracking {
                _ = workspace.panelGitBranches
                _ = workspace.gitBranch
                _ = workspace.pullRequest
                _ = workspace.panelPullRequests
            } onChange: {
                flag.didChange = true
            }
        }

        let firstUpdateFlag = ChangeFlag()
        trackGitState(firstUpdateFlag)

        workspace.updatePanelGitBranch(panelId: panelId, branch: "main", isDirty: false)

        XCTAssertTrue(
            firstUpdateFlag.didChange,
            "Expected the first focused branch update to publish workspace changes"
        )

        let identicalUpdateFlag = ChangeFlag()
        trackGitState(identicalUpdateFlag)

        workspace.updatePanelGitBranch(panelId: panelId, branch: "main", isDirty: false)

        XCTAssertFalse(
            identicalUpdateFlag.didChange,
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

        // `Workspace` is `@Observable` (no `objectWillChange`); assert on the
        // pull-request-facing tracked state the update can mutate instead.
        final class ChangeFlag: @unchecked Sendable { var didChange = false }

        func trackPullRequestState(_ flag: ChangeFlag) {
            withObservationTracking {
                _ = workspace.panelPullRequests
                _ = workspace.pullRequest
                _ = workspace.panelGitBranches
                _ = workspace.gitBranch
            } onChange: {
                flag.didChange = true
            }
        }

        let pullRequestURL = URL(string: "https://github.com/manaflow-ai/cmux/pull/2388")!

        let firstUpdateFlag = ChangeFlag()
        trackPullRequestState(firstUpdateFlag)

        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 2388,
            label: "PR",
            url: pullRequestURL,
            status: .open,
            branch: "feature/sidebar-pr"
        )

        XCTAssertTrue(
            firstUpdateFlag.didChange,
            "Expected the first focused pull request update to publish workspace changes"
        )

        let identicalUpdateFlag = ChangeFlag()
        trackPullRequestState(identicalUpdateFlag)

        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 2388,
            label: "PR",
            url: pullRequestURL,
            status: .open,
            branch: "feature/sidebar-pr"
        )

        XCTAssertFalse(
            identicalUpdateFlag.didChange,
            "Expected identical focused pull request refreshes to avoid extra workspace publishes"
        )
    }

    func testSidebarObservationPublisherEmitsForFocusedGitBranchChangesOnlyOncePerState() {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        var publishCount = 0
        let cancellable = workspace.sidebarObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }

        workspace.updatePanelGitBranch(panelId: panelId, branch: "main", isDirty: false)
        let baselinePublishCount = publishCount
        XCTAssertGreaterThan(
            baselinePublishCount,
            0,
            "Expected focused git branch updates to invalidate sidebar rows"
        )

        workspace.updatePanelGitBranch(panelId: panelId, branch: "main", isDirty: false)
        XCTAssertEqual(
            publishCount,
            baselinePublishCount,
            "Expected identical git metadata refreshes to be ignored by sidebar rows"
        )
    }

    func testSidebarObservationPublisherIgnoresRemoteHeartbeatOnlyChanges() {
        let workspace = Workspace()

        var publishCount = 0
        let cancellable = workspace.sidebarObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }

        workspace.remoteHeartbeatCount = 1
        workspace.remoteLastHeartbeatAt = Date()

        XCTAssertEqual(
            publishCount,
            0,
            "Expected non-visible remote heartbeat updates to avoid invalidating sidebar rows"
        )
    }

    @MainActor
    func testSidebarPullRequestsTrackFocusedPanelOnly() {
        let workspace = Workspace()
        guard let firstPanelId = workspace.focusedPanelId,
              let paneId = workspace.paneId(forPanelId: firstPanelId),
              let secondPanel = workspace.newTerminalSurface(inPane: paneId, focus: false) else {
            XCTFail("Expected focused panel and a second panel")
            return
        }

        workspace.updatePanelGitBranch(panelId: firstPanelId, branch: "main", isDirty: false)
        workspace.updatePanelGitBranch(panelId: secondPanel.id, branch: "feature/sidebar-pr", isDirty: false)
        workspace.updatePanelPullRequest(
            panelId: secondPanel.id,
            number: 1629,
            label: "PR",
            url: URL(string: "https://github.com/manaflow-ai/cmux/pull/1629")!,
            status: .open
        )

        XCTAssertNil(workspace.pullRequest)
        XCTAssertTrue(
            workspace.sidebarPullRequestsInDisplayOrder().isEmpty,
            "Expected background panel PRs to stay hidden while the focused panel has no PR"
        )

        workspace.focusPanel(secondPanel.id)

        XCTAssertEqual(
            workspace.sidebarPullRequestsInDisplayOrder().map(\.number),
            [1629]
        )
    }

    func testSidebarOrderingUsesPaneOrderThenTabOrderWithBranchDeduping() {
        let workspace = Workspace()
        guard let leftFirstPanelId = workspace.focusedPanelId,
              let leftPaneId = workspace.paneId(forPanelId: leftFirstPanelId),
              let rightFirstPanel = workspace.newTerminalSplit(from: leftFirstPanelId, orientation: .horizontal),
              let rightPaneId = workspace.paneId(forPanelId: rightFirstPanel.id),
              let leftSecondPanel = workspace.newTerminalSurface(inPane: leftPaneId, focus: false),
              let rightSecondPanel = workspace.newTerminalSurface(inPane: rightPaneId, focus: false) else {
            XCTFail("Expected panes and panels for ordering test")
            return
        }

        XCTAssertTrue(workspace.reorderSurface(panelId: leftFirstPanelId, toIndex: 0))
        XCTAssertTrue(workspace.reorderSurface(panelId: leftSecondPanel.id, toIndex: 1))
        XCTAssertTrue(workspace.reorderSurface(panelId: rightFirstPanel.id, toIndex: 0))
        XCTAssertTrue(workspace.reorderSurface(panelId: rightSecondPanel.id, toIndex: 1))

        workspace.updatePanelGitBranch(panelId: leftFirstPanelId, branch: "main", isDirty: false)
        workspace.updatePanelGitBranch(panelId: leftSecondPanel.id, branch: "feature/left", isDirty: false)
        workspace.updatePanelGitBranch(panelId: rightFirstPanel.id, branch: "main", isDirty: true)
        workspace.updatePanelGitBranch(panelId: rightSecondPanel.id, branch: "feature/right", isDirty: false)

        XCTAssertEqual(
            workspace.sidebarOrderedPanelIds(),
            [leftFirstPanelId, leftSecondPanel.id, rightFirstPanel.id, rightSecondPanel.id]
        )

        let branches = workspace.sidebarGitBranchesInDisplayOrder()
        XCTAssertEqual(branches.map(\.branch), ["main", "feature/left", "feature/right"])
        XCTAssertEqual(branches.map(\.isDirty), [true, false, false])
    }

    func testSidebarBranchDirectoryEntriesStayStableAcrossFocusedSplitChanges() {
        let workspace = Workspace()
        let leftLiveDirectory = "/repo/left/live"
        let rightFocusedDirectory = "/repo/right/focused"
        let leftFocusedDirectory = "/repo/left/focused"
        let rightRequestedDirectory = "/repo/right/requested"

        guard let leftPanelId = workspace.focusedPanelId else {
            XCTFail("Expected initial focused panel")
            return
        }

        workspace.updatePanelDirectory(panelId: leftPanelId, directory: leftLiveDirectory)

        guard let rightSplitPanel = workspace.newTerminalSplit(
            from: leftPanelId,
            orientation: .horizontal,
            focus: false
        ),
        let rightPaneId = workspace.paneId(forPanelId: rightSplitPanel.id),
        let rightRequestedPanel = workspace.newTerminalSurface(
            inPane: rightPaneId,
            focus: false,
            workingDirectory: rightRequestedDirectory
        ) else {
            XCTFail("Expected right split panes for sidebar directory ordering test")
            return
        }

        let orderedPanelIds = workspace.sidebarOrderedPanelIds()
        XCTAssertEqual(orderedPanelIds, [leftPanelId, rightSplitPanel.id, rightRequestedPanel.id])

        workspace.currentDirectory = rightFocusedDirectory
        let entriesWhenRightLooksFocused = workspace.sidebarBranchDirectoryEntriesInDisplayOrder(
            orderedPanelIds: orderedPanelIds
        )

        workspace.currentDirectory = leftFocusedDirectory
        let entriesWhenLeftLooksFocused = workspace.sidebarBranchDirectoryEntriesInDisplayOrder(
            orderedPanelIds: orderedPanelIds
        )

        XCTAssertEqual(
            entriesWhenRightLooksFocused,
            entriesWhenLeftLooksFocused,
            "Expected sidebar directory ordering to ignore focused-workspace cwd churn when panel-specific directories are available"
        )
        XCTAssertEqual(
            entriesWhenRightLooksFocused.map(\.directory),
            [leftLiveDirectory, rightRequestedDirectory]
        )
    }

    func testRemoteSidebarDirectoryCanonicalizationDedupesTildeAndAbsoluteHomePaths() {
        let workspace = Workspace()
        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "cmux-macmini",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64007,
                relayID: String(repeating: "a", count: 16),
                relayToken: String(repeating: "b", count: 64),
                localSocketPath: "/tmp/cmux-debug-test.sock",
                terminalStartupCommand: "ssh cmux-macmini"
            ),
            autoConnect: false
        )

        let liveDirectory = "/home/remoteuser/project"
        let requestedDirectory = "~/project"

        guard let firstPanelId = workspace.focusedPanelId,
              let paneId = workspace.paneId(forPanelId: firstPanelId),
              let requestedPanel = workspace.newTerminalSurface(
                  inPane: paneId,
                  focus: false,
                  workingDirectory: requestedDirectory
              ) else {
            XCTFail("Expected remote panels for sidebar directory canonicalization test")
            return
        }

        workspace.updatePanelDirectory(panelId: firstPanelId, directory: liveDirectory)

        let orderedPanelIds = workspace.sidebarOrderedPanelIds()
        XCTAssertEqual(orderedPanelIds, [firstPanelId, requestedPanel.id])

        XCTAssertEqual(
            workspace.sidebarDirectoriesInDisplayOrder(orderedPanelIds: orderedPanelIds),
            [liveDirectory]
        )
        XCTAssertEqual(
            workspace.sidebarBranchDirectoryEntriesInDisplayOrder(orderedPanelIds: orderedPanelIds).map(\.directory),
            [liveDirectory]
        )
    }

    func testSidebarDerivedCollectionsMatchWhenUsingPrecomputedPanelOrder() {
        let workspace = Workspace()
        guard let leftFirstPanelId = workspace.focusedPanelId,
              let leftPaneId = workspace.paneId(forPanelId: leftFirstPanelId),
              let rightFirstPanel = workspace.newTerminalSplit(from: leftFirstPanelId, orientation: .horizontal),
              let rightPaneId = workspace.paneId(forPanelId: rightFirstPanel.id),
              let leftSecondPanel = workspace.newTerminalSurface(inPane: leftPaneId, focus: false),
              let rightSecondPanel = workspace.newTerminalSurface(inPane: rightPaneId, focus: false) else {
            XCTFail("Expected panes and panels for precomputed ordering test")
            return
        }

        workspace.updatePanelGitBranch(panelId: leftFirstPanelId, branch: "main", isDirty: false)
        workspace.updatePanelGitBranch(panelId: leftSecondPanel.id, branch: "feature/left", isDirty: true)
        workspace.updatePanelGitBranch(panelId: rightFirstPanel.id, branch: "release/right", isDirty: false)

        workspace.updatePanelDirectory(panelId: leftFirstPanelId, directory: "/repo/left/root")
        workspace.updatePanelDirectory(panelId: leftSecondPanel.id, directory: "/repo/left/feature")
        workspace.updatePanelDirectory(panelId: rightFirstPanel.id, directory: "/repo/right/root")
        workspace.updatePanelDirectory(panelId: rightSecondPanel.id, directory: "/repo/right/extra")

        workspace.updatePanelPullRequest(
            panelId: leftFirstPanelId,
            number: 101,
            label: "PR",
            url: URL(string: "https://github.com/manaflow-ai/cmux/pull/101")!,
            status: .open
        )
        workspace.updatePanelPullRequest(
            panelId: rightFirstPanel.id,
            number: 18,
            label: "MR",
            url: URL(string: "https://gitlab.com/manaflow/cmux/-/merge_requests/18")!,
            status: .merged
        )

        let orderedPanelIds = workspace.sidebarOrderedPanelIds()

        XCTAssertEqual(
            workspace.sidebarGitBranchesInDisplayOrder(orderedPanelIds: orderedPanelIds).map { "\($0.branch)|\($0.isDirty)" },
            workspace.sidebarGitBranchesInDisplayOrder().map { "\($0.branch)|\($0.isDirty)" }
        )
        XCTAssertEqual(
            workspace.sidebarBranchDirectoryEntriesInDisplayOrder(orderedPanelIds: orderedPanelIds),
            workspace.sidebarBranchDirectoryEntriesInDisplayOrder()
        )
        XCTAssertEqual(
            workspace.sidebarPullRequestsInDisplayOrder(orderedPanelIds: orderedPanelIds),
            workspace.sidebarPullRequestsInDisplayOrder()
        )
    }

    func testClosingPaneDropsBranchesFromClosedSide() {
        let workspace = Workspace()
        guard let leftPanelId = workspace.focusedPanelId,
              let leftPaneId = workspace.paneId(forPanelId: leftPanelId),
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected left/right split panes")
            return
        }

        workspace.updatePanelGitBranch(panelId: leftPanelId, branch: "branch1", isDirty: false)
        workspace.updatePanelGitBranch(panelId: rightPanel.id, branch: "branch2", isDirty: false)

        XCTAssertEqual(workspace.sidebarGitBranchesInDisplayOrder().map(\.branch), ["branch1", "branch2"])
        XCTAssertTrue(workspace.bonsplitController.closePane(leftPaneId))
        XCTAssertEqual(workspace.sidebarGitBranchesInDisplayOrder().map(\.branch), ["branch2"])
    }

    // MARK: - Fork Conversation (new sibling tab)

}
