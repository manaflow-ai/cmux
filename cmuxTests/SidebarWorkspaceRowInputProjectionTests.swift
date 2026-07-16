import CmuxCore
import CmuxFoundation
import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct SidebarWorkspaceRowInputProjectionTests {
    @Test
    func coldPresentationCacheStillProjectsTheRealizedWorkspaceRow() throws {
        let workspaceId = UUID()
        let suiteName = "SidebarWorkspaceRowInputProjectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = SidebarWorkspaceRowModelSnapshot(
            workspaceId: workspaceId,
            groupId: nil,
            isPinned: false,
            hasUserCustomTitle: false,
            hasCustomTitle: false,
            hasCustomDescription: false,
            customTitle: nil,
            isRemoteContextMenuEligible: false,
            remoteConnectionState: .connected,
            inferredTaskStatus: .todo,
            activeTodoOverride: nil,
            isTodoStatusHidden: false
        )
        let projection = SidebarWorkspaceRowInputProjection(
            modelSnapshotsById: [workspaceId: model],
            workspaceSnapshotsById: [:],
            unreadSummariesByWorkspaceId: [:],
            tabIndexById: [workspaceId: 0],
            selectedContextTargetIds: [],
            selectedWorkspaceIds: [],
            activeWorkspaceId: workspaceId,
            hoveredRowId: nil,
            draggedWorkspaceId: nil,
            dropIndicator: nil,
            dropIndicatorScope: .raw,
            sidebarReorderIds: [workspaceId],
            expandedChecklistWorkspaceIds: [],
            checklistAddFieldActivationTokens: [:],
            checklistPopoverWorkspaceId: nil,
            workspaceCount: 1,
            canCloseWorkspace: false,
            workspaceShortcutModifierSymbol: "⌘",
            showsAgentActivity: false,
            showsNotificationMessage: false,
            liveShowsModifierShortcutHints: false,
            frozenShortcutHintsTabId: nil,
            frozenShortcutHintsValue: false,
            isBonsplitWorkspaceDropActive: false,
            rowSpacing: 2,
            settings: SidebarTabItemSettingsSnapshot(defaults: defaults)
        )

        #expect(
            projection.input(for: workspaceId) != nil,
            "A cold parent presentation cache must not remove a realized workspace row."
        )
        #expect(projection.input(for: UUID()) == nil)
    }
}
