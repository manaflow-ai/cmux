import AppKit
import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct SidebarWorkspaceContextMenuWindowTargetsTests {
    @Test
    @MainActor
    func menuPresentationResolvesWindowTargetsAfterRowRender() throws {
        let firstWindowId = UUID()
        let laterWindowId = UUID()
        var currentTargets = [
            SidebarWorkspaceWindowMoveTarget(
                windowId: firstWindowId,
                label: "Window 1",
                isCurrentWindow: true
            )
        ]
        var resolvedTopologies: [[UUID]] = []
        let actions = Self.actions {
            resolvedTopologies.append(currentTargets.map(\.windowId))
            return currentTargets
        }
        let row = TabItemView(
            snapshot: try Self.rowSnapshot(),
            actions: actions
        )

        // Rendering the lazy row must not freeze or resolve app-window state.
        _ = row.body
        #expect(resolvedTopologies.isEmpty)

        currentTargets = [
            SidebarWorkspaceWindowMoveTarget(
                windowId: firstWindowId,
                label: "Window 1",
                isCurrentWindow: true
            ),
            SidebarWorkspaceWindowMoveTarget(
                windowId: laterWindowId,
                label: "Window 2",
                isCurrentWindow: false
            )
        ]

        // SwiftUI evaluates this deferred wrapper when presenting the menu.
        _ = TabItemWorkspaceContextMenuContent(row: row).body
        #expect(resolvedTopologies == [[firstWindowId, laterWindowId]])
    }

    @MainActor
    private static func rowSnapshot() throws -> SidebarWorkspaceRowSnapshot {
        let suiteName = "SidebarWorkspaceContextMenuWindowTargetsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        return SidebarWorkspaceRowSnapshot(
            workspaceId: UUID(),
            groupId: nil,
            index: 0,
            workspaceCount: 1,
            workspace: SidebarWorkspaceSnapshotRefreshPolicyTests.snapshot(),
            isActive: true,
            isMultiSelected: false,
            hasUserCustomTitle: false,
            hasCustomTitle: false,
            hasCustomDescription: false,
            customTitle: nil,
            workspaceShortcutDigit: nil,
            workspaceShortcutModifierSymbol: "⌘",
            canCloseWorkspace: false,
            unreadCount: 0,
            latestNotificationText: nil,
            showsAgentActivity: false,
            rowSpacing: 0,
            showsModifierShortcutHints: false,
            isPointerHovering: false,
            isBeingDragged: false,
            topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false,
            isBonsplitWorkspaceDropActive: false,
            settings: SidebarTabItemSettingsSnapshot(defaults: defaults),
            isChecklistExpanded: false,
            checklistAddFieldActivationToken: 0,
            isChecklistPopoverPresented: false,
            contextMenu: SidebarWorkspaceContextMenuSnapshot(
                targetWorkspaceIds: [],
                remoteTargetWorkspaceIds: [],
                allRemoteTargetsConnecting: false,
                allRemoteTargetsDisconnected: false,
                pinState: nil,
                groupMenuSnapshot: WorkspaceGroupMenuSnapshot(items: []),
                canCreateEmptyGroup: true,
                eligibleGroupTargetIds: [],
                allEligibleTargetsGroupId: nil,
                hasGroupedEligibleTarget: false,
                todoStatusLanes: [],
                canMarkRead: false,
                canMarkUnread: false,
                hasLatestNotification: false,
                notifications: []
            )
        )
    }

    @MainActor
    private static func actions(
        currentWindowMoveTargets: @escaping () -> [SidebarWorkspaceWindowMoveTarget]
    ) -> SidebarWorkspaceRowActions {
        SidebarWorkspaceRowActions(
            select: { _ in },
            setCustomTitle: { _ in },
            clearCustomTitle: {},
            clearCustomDescription: {},
            editDescription: {},
            closeWorkspace: {},
            moveBy: { _ in },
            moveTargetsToTop: { _ in },
            currentWindowMoveTargets: currentWindowMoveTargets,
            moveTargetsToWindow: { _, _ in },
            moveTargetsToNewWindow: { _ in },
            closeTargets: { _, _ in },
            closeOtherTargets: { _ in },
            closeTargetsBelow: {},
            closeTargetsAbove: {},
            performPin: {},
            createEmptyGroup: {},
            createGroup: { _ in },
            addTargetsToGroup: { _, _ in },
            removeTargetsFromGroup: { _ in },
            reconnectTargets: { _ in },
            disconnectTargets: { _ in },
            applyColor: { _, _ in },
            applyTodoStatus: { _, _ in },
            hideTodoStatus: { _ in },
            requestChecklistAdd: {},
            markRead: { _ in },
            markUnread: { _ in },
            clearLatestNotifications: { _ in },
            openNotification: { _ in },
            copyWorkspaceLinks: { _ in },
            openPullRequest: { _ in },
            openPort: { _ in },
            checklist: SidebarWorkspaceChecklistActions(
                setItemState: { _, _ in },
                removeItem: { _ in },
                addItem: { _ in },
                editItem: { _, _ in },
                moveItem: { _, _ in },
                openPane: {},
                addAttachments: { _ in },
                removeAttachment: { _, _ in },
                openAttachments: { _, _ in }
            ),
            onDragStart: { NSItemProvider() },
            bonsplitSourceWorkspaceId: { _ in nil },
            moveBonsplitTabToWorkspace: { _, _ in false },
            syncAfterBonsplitDrop: {},
            selectAfterBonsplitDrop: {},
            onToggleChecklistExpansion: {},
            onConsumeChecklistAddFieldActivation: {},
            onChecklistPopoverPresentedChange: { _ in },
            onContextMenuAppear: {},
            onContextMenuDisappear: {},
            onPointerFrameChange: { _ in },
            onPointerFrameDisappear: {}
        )
    }
}
