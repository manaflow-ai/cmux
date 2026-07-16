import CmuxCore
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
struct SidebarWorkspaceContextMenuTargetAggregateTests {
    @Test
    func selectedRowsReuseCorrectParentAggregateAndSingleRowsStayScoped() throws {
        let groupId = UUID()
        let connectingWorkspaceId = UUID()
        let disconnectedWorkspaceId = UUID()
        let anchorWorkspaceId = disconnectedWorkspaceId
        let singleWorkspaceId = UUID()
        let suiteName = "SidebarWorkspaceContextMenuTargetAggregateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)
        let rows = [
            connectingWorkspaceId: Self.rowInput(
                workspaceId: connectingWorkspaceId,
                groupId: groupId,
                unreadCount: 2,
                isMultiSelected: true,
                settings: settings
            ),
            disconnectedWorkspaceId: Self.rowInput(
                workspaceId: disconnectedWorkspaceId,
                groupId: groupId,
                unreadCount: 0,
                isMultiSelected: true,
                settings: settings
            ),
            singleWorkspaceId: Self.rowInput(
                workspaceId: singleWorkspaceId,
                groupId: nil,
                unreadCount: 0,
                isMultiSelected: false,
                settings: settings
            )
        ]
        let models = Dictionary(uniqueKeysWithValues: [
            Self.modelSnapshot(
                workspaceId: connectingWorkspaceId,
                groupId: groupId,
                isRemote: true,
                remoteState: .connecting
            ),
            Self.modelSnapshot(
                workspaceId: disconnectedWorkspaceId,
                groupId: groupId,
                isRemote: true,
                remoteState: .disconnected
            ),
            Self.modelSnapshot(
                workspaceId: singleWorkspaceId,
                groupId: nil,
                isRemote: false,
                remoteState: .connected
            )
        ].map { ($0.workspaceId, $0) })
        let unreadSummaries = [
            connectingWorkspaceId: SidebarWorkspaceUnreadSummary(
                unreadCount: 2,
                latestNotificationText: nil
            )
        ]
        let list = SidebarWorkspaceRowsSnapshot(
            modelSnapshotsById: models,
            groupRowsById: [:],
            selectedContextTargetIds: [connectingWorkspaceId, disconnectedWorkspaceId],
            anchorWorkspaceIds: [anchorWorkspaceId],
            workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot(items: []),
            canCreateEmptyGroup: true,
            unreadSummariesByWorkspaceId: unreadSummaries
        )

        let selected = list.selectedContextMenuTargetAggregate
        #expect(selected.targetWorkspaceIds == [connectingWorkspaceId, disconnectedWorkspaceId])
        #expect(selected.remoteTargetWorkspaceIds == [connectingWorkspaceId, disconnectedWorkspaceId])
        #expect(!selected.allRemoteTargetsConnecting)
        #expect(!selected.allRemoteTargetsDisconnected)
        #expect(selected.eligibleGroupTargetIds == [connectingWorkspaceId])
        #expect(selected.allEligibleTargetsGroupId == groupId)
        #expect(selected.hasGroupedEligibleTarget)
        #expect(selected.canMarkRead)
        #expect(selected.canMarkUnread)

        let secondSelected = try #require(rows[disconnectedWorkspaceId])
        #expect(list.contextMenuTargetAggregate(for: secondSelected) == selected)

        let singleInput = try #require(rows[singleWorkspaceId])
        let single = list.contextMenuTargetAggregate(for: singleInput)
        #expect(single.targetWorkspaceIds == [singleWorkspaceId])
        #expect(single.remoteTargetWorkspaceIds.isEmpty)
        #expect(!single.canMarkRead)
        #expect(single.canMarkUnread)
    }

    private static func rowInput(
        workspaceId: UUID,
        groupId: UUID?,
        unreadCount: Int,
        isMultiSelected: Bool,
        settings: SidebarTabItemSettingsSnapshot
    ) -> SidebarWorkspaceRowInput {
        SidebarWorkspaceRowInput(
            workspaceId: workspaceId,
            groupId: groupId,
            index: 0,
            workspaceCount: 3,
            workspace: SidebarWorkspaceSnapshotRefreshPolicyTests.snapshot(),
            isActive: false,
            isMultiSelected: isMultiSelected,
            hasUserCustomTitle: false,
            hasCustomTitle: false,
            hasCustomDescription: false,
            customTitle: nil,
            workspaceShortcutDigit: nil,
            workspaceShortcutModifierSymbol: "⌘",
            canCloseWorkspace: true,
            unreadCount: unreadCount,
            latestNotificationText: nil,
            showsAgentActivity: false,
            rowSpacing: 0,
            showsModifierShortcutHints: false,
            isPointerHovering: false,
            isBeingDragged: false,
            topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false,
            isBonsplitWorkspaceDropActive: false,
            settings: settings,
            isChecklistExpanded: false,
            checklistAddFieldActivationToken: 0,
            isChecklistPopoverPresented: false,
            contextMenuPinState: nil,
            inferredTaskStatus: .todo,
            activeTodoOverride: nil,
            isTodoStatusHidden: false
        )
    }

    private static func modelSnapshot(
        workspaceId: UUID,
        groupId: UUID?,
        isRemote: Bool,
        remoteState: WorkspaceRemoteConnectionState
    ) -> SidebarWorkspaceRowModelSnapshot {
        SidebarWorkspaceRowModelSnapshot(
            workspaceId: workspaceId,
            groupId: groupId,
            isPinned: false,
            hasUserCustomTitle: false,
            hasCustomTitle: false,
            hasCustomDescription: false,
            customTitle: nil,
            isRemoteContextMenuEligible: isRemote,
            remoteConnectionState: remoteState,
            inferredTaskStatus: .todo,
            activeTodoOverride: nil,
            isTodoStatusHidden: false
        )
    }
}
