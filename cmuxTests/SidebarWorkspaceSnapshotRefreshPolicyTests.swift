import AppKit
import CmuxSidebar
import CmuxWorkspaces
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct SidebarWorkspaceSnapshotRefreshPolicyTests {
    @Test func contextMenuPinChangeUpdatesDisplayedFieldsAndDefersNoisyFields() {
        let currentAgentRows = [Self.agentStatusRow(value: "Running")]
        let current = Self.snapshot(
            title: "lmao",
            isPinned: false,
            customColorHex: nil,
            remoteConnectionStatusText: "Connected",
            latestConversationMessage: "old message",
            agentStatusRows: currentAgentRows,
            listeningPorts: [3000],
            finderDirectoryPath: "/old"
        )
        let next = Self.snapshot(
            title: "lmao",
            isPinned: true,
            customColorHex: nil,
            remoteConnectionStatusText: "Disconnected",
            latestConversationMessage: "new message",
            agentStatusRows: [],
            listeningPorts: [3000, 4000],
            finderDirectoryPath: nil
        )

        let decision = SidebarWorkspaceSnapshotRefreshPolicy().decision(
            current: current,
            next: next,
            force: false,
            contextMenuVisible: true
        )

        var expectedDisplayed = current
        expectedDisplayed = expectedDisplayed.applyingContextMenuImmediateFields(from: next)
        #expect(decision.workspaceSnapshotStorage == expectedDisplayed)
        #expect(decision.workspaceSnapshotStorage?.isPinned == true)
        #expect(decision.workspaceSnapshotStorage?.remoteConnectionStatusText == "Connected")
        #expect(decision.workspaceSnapshotStorage?.latestConversationMessage == "old message")
        #expect(decision.workspaceSnapshotStorage?.listeningPorts == [3000])
        // Agent rows are noisy telemetry: they must survive the immediate
        // context-menu refresh unchanged, like metadataEntries/listeningPorts.
        #expect(decision.workspaceSnapshotStorage?.agentStatusRows == currentAgentRows)
        #expect(decision.workspaceSnapshotStorage?.finderDirectoryPath == nil)
        #expect(decision.pendingWorkspaceSnapshot == next)
        #expect(decision.hasDeferredWorkspaceObservationInvalidation)
    }

    @Test func contextMenuImmediateOnlyChangeDoesNotCreateDeferredFlush() {
        let current = Self.snapshot(
            title: "old",
            customDescription: nil,
            isPinned: false,
            customColorHex: nil,
            finderDirectoryPath: nil
        )
        let next = Self.snapshot(
            title: "new",
            customDescription: "description",
            isPinned: true,
            customColorHex: "#C0392B",
            finderDirectoryPath: "/tmp/workspace"
        )

        let decision = SidebarWorkspaceSnapshotRefreshPolicy().decision(
            current: current,
            next: next,
            force: false,
            contextMenuVisible: true
        )

        #expect(decision.workspaceSnapshotStorage == next)
        #expect(decision.pendingWorkspaceSnapshot == nil)
        #expect(!decision.hasDeferredWorkspaceObservationInvalidation)
    }

    @Test func contextMenuMediaActivityChangeUpdatesDisplayedGlyphImmediately() {
        let current = Self.snapshot(
            remoteConnectionStatusText: "Connected",
            latestConversationMessage: "old message",
            listeningPorts: [3000],
            mediaActivity: BrowserMediaActivity(isPlayingAudio: true)
        )
        let next = Self.snapshot(
            remoteConnectionStatusText: "Disconnected",
            latestConversationMessage: "new message",
            listeningPorts: [3000, 4000],
            mediaActivity: BrowserMediaActivity(isPlayingAudio: false)
        )

        let decision = SidebarWorkspaceSnapshotRefreshPolicy().decision(
            current: current,
            next: next,
            force: false,
            contextMenuVisible: true
        )

        #expect(decision.workspaceSnapshotStorage?.mediaActivity.isPlayingAudio == false)
        #expect(decision.workspaceSnapshotStorage?.remoteConnectionStatusText == "Connected")
        #expect(decision.workspaceSnapshotStorage?.latestConversationMessage == "old message")
        #expect(decision.workspaceSnapshotStorage?.listeningPorts == [3000])
        #expect(decision.pendingWorkspaceSnapshot == next)
        #expect(decision.hasDeferredWorkspaceObservationInvalidation)
    }

    @Test func closedContextMenuStoresNextAndClearsPending() {
        let current = Self.snapshot(title: "old", isPinned: false)
        let next = Self.snapshot(title: "new", isPinned: true)

        let decision = SidebarWorkspaceSnapshotRefreshPolicy().decision(
            current: current,
            next: next,
            force: false,
            contextMenuVisible: false
        )

        #expect(decision.workspaceSnapshotStorage == next)
        #expect(decision.pendingWorkspaceSnapshot == nil)
        #expect(!decision.hasDeferredWorkspaceObservationInvalidation)
    }

    private static func snapshot(
        presentationKey: SidebarWorkspaceSnapshotBuilder.PresentationKey? = nil,
        title: String = "workspace",
        customDescription: String? = nil,
        isPinned: Bool = false,
        customColorHex: String? = nil,
        remoteConnectionStatusText: String = "Disconnected",
        latestConversationMessage: String? = nil,
        agentStatusRows: [SidebarAgentStatusRow] = [],
        listeningPorts: [Int] = [],
        finderDirectoryPath: String? = nil,
        mediaActivity: BrowserMediaActivity = BrowserMediaActivity()
    ) -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        SidebarWorkspaceSnapshotBuilder.Snapshot(
            presentationKey: presentationKey ?? Self.presentationKey(),
            title: title,
            customDescription: customDescription,
            isPinned: isPinned,
            customColorHex: customColorHex,
            remoteWorkspaceSidebarText: nil,
            remoteConnectionStatusText: remoteConnectionStatusText,
            remoteStateHelpText: "",
            showsRemoteReconnectAffordance: false,
            copyableSidebarSSHError: nil,
            latestConversationMessage: latestConversationMessage,
            metadataEntries: [],
            agentStatusRows: agentStatusRows,
            metadataBlocks: [],
            latestLog: nil,
            progress: nil,
            compactGitBranchSummaryText: nil,
            compactDirectoryCandidates: [],
            compactBranchDirectoryCandidates: [],
            branchDirectoryLines: [],
            branchLinesContainBranch: false,
            pullRequestRows: [],
            listeningPorts: listeningPorts,
            finderDirectoryPath: finderDirectoryPath,
            mediaActivity: mediaActivity
        )
    }

    private static func agentStatusRow(value: String) -> SidebarAgentStatusRow {
        SidebarAgentStatusRow(
            panelId: UUID(),
            statusKey: "claude_code",
            value: value,
            icon: nil,
            color: nil,
            url: nil,
            format: .plain,
            lifecycle: nil,
            paneLabel: nil,
            priority: 0,
            timestamp: Date(timeIntervalSince1970: 0)
        )
    }

    private static func presentationKey(
        showsWorkspaceDescription: Bool = true,
        usesVerticalBranchLayout: Bool = true,
        showsGitBranch: Bool = true,
        usesViewportAwarePath: Bool = false,
        visibleAuxiliaryDetails: SidebarWorkspaceAuxiliaryDetailVisibility = SidebarWorkspaceAuxiliaryDetailVisibility(
            showsMetadata: true,
            showsLog: true,
            showsProgress: true,
            showsBranchDirectory: true,
            showsPullRequests: true,
            showsPorts: true
        )
    ) -> SidebarWorkspaceSnapshotBuilder.PresentationKey {
        SidebarWorkspaceSnapshotBuilder.PresentationKey(
            showsWorkspaceDescription: showsWorkspaceDescription,
            usesVerticalBranchLayout: usesVerticalBranchLayout,
            showsGitBranch: showsGitBranch,
            usesViewportAwarePath: usesViewportAwarePath,
            visibleAuxiliaryDetails: visibleAuxiliaryDetails
        )
    }
}
