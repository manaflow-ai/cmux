import CmuxSidebar
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension SidebarWorkspaceSnapshotRefreshPolicyTests {
    @Test func contextMenuAgentActivityChangeUpdatesDisplayedSpinnerImmediately() {
        let current = Self.snapshot(
            latestConversationMessage: "old message",
            activeCodingAgentCount: 0
        )
        let next = Self.snapshot(
            latestConversationMessage: "new message",
            activeCodingAgentCount: 1
        )

        let decision = SidebarWorkspaceSnapshotRefreshPolicy().decision(
            current: current,
            next: next,
            force: false,
            contextMenuVisible: true
        )

        #expect(decision.workspaceSnapshotStorage?.activeCodingAgentCount == 1)
        #expect(decision.workspaceSnapshotStorage?.latestConversationMessage == "old message")
        #expect(decision.pendingWorkspaceSnapshot == next)
        #expect(decision.hasDeferredWorkspaceObservationInvalidation)
    }

    @Test func presentationKeyChangesWhenAgentActivityVisibilityChanges() {
        let hidden = Self.presentationKey(showsAgentActivity: false)
        let visible = Self.presentationKey(showsAgentActivity: true)

        #expect(hidden != visible)
        #expect(!hidden.showsAgentActivity)
        #expect(visible.showsAgentActivity)
    }
}
