import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The Move-to-Window submenu must reflect the app-window topology at the
/// moment the context menu OPENS, not the (possibly stale) topology captured
/// when the row was last rendered. The SwiftUI list deferred this through
/// `TabItemWorkspaceContextMenuContent`; the AppKit list preserves it by
/// building a fresh `NSMenu` per open (`SidebarWorkspaceTableController.menu(forRow:)`
/// → `SidebarWorkspaceRowContextMenuFactory.makeMenu`), which resolves
/// `actions.currentWindowMoveTargets()` at build time.
@Suite
struct SidebarWorkspaceContextMenuWindowTargetsTests {
    @Test
    @MainActor
    func menuBuildResolvesWindowTargetsAtOpenTimeNotRowBuildTime() throws {
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
        let workspaceId = UUID()
        let snapshot = try Self.rowSnapshot(workspaceId: workspaceId)

        // Building the row value the table renders from must not resolve
        // app-window state; only presenting the menu may.
        let row = SidebarWorkspaceListRow(workspace: snapshot)
        #expect(!row.isGroupHeader)
        #expect(resolvedTopologies.isEmpty)

        // A second window appears after the row was built; the menu opened
        // afterwards must include it.
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

        let menu = SidebarWorkspaceRowContextMenuFactory.makeMenu(
            snapshot: snapshot,
            actions: actions
        )
        #expect(resolvedTopologies == [[firstWindowId, laterWindowId]])

        let submenu = try Self.moveToWindowSubmenu(in: menu)
        #expect(submenu.items.count == 4)

        let newWindowItem = submenu.items[0]
        #expect(newWindowItem.title == String(
            localized: "contextMenu.newWindow",
            defaultValue: "New Window"
        ))
        #expect(newWindowItem.isEnabled)

        #expect(submenu.items[1].isSeparatorItem)

        // The current window is listed but disabled; the other window is a
        // live target.
        #expect(submenu.items[2].title == "Window 1")
        #expect(!submenu.items[2].isEnabled)
        #expect(submenu.items[3].title == "Window 2")
        #expect(submenu.items[3].isEnabled)
    }

    @Test
    @MainActor
    func everyMenuOpenResolvesAFreshTopology() throws {
        let windowA = UUID()
        let windowB = UUID()
        var currentTargets = [
            SidebarWorkspaceWindowMoveTarget(windowId: windowA, label: "Window A", isCurrentWindow: true)
        ]
        var resolutionCount = 0
        let actions = Self.actions {
            resolutionCount += 1
            return currentTargets
        }
        let snapshot = try Self.rowSnapshot(workspaceId: UUID())

        let firstMenu = SidebarWorkspaceRowContextMenuFactory.makeMenu(
            snapshot: snapshot,
            actions: actions
        )
        #expect(resolutionCount == 1)
        let firstSubmenu = try Self.moveToWindowSubmenu(in: firstMenu)
        #expect(firstSubmenu.items.map(\.title).contains("Window A"))
        #expect(!firstSubmenu.items.map(\.title).contains("Window B"))

        // Topology changes between opens; the next open re-resolves rather
        // than reusing anything cached from the previous menu.
        currentTargets = [
            SidebarWorkspaceWindowMoveTarget(windowId: windowA, label: "Window A", isCurrentWindow: false),
            SidebarWorkspaceWindowMoveTarget(windowId: windowB, label: "Window B", isCurrentWindow: true),
        ]
        let secondMenu = SidebarWorkspaceRowContextMenuFactory.makeMenu(
            snapshot: snapshot,
            actions: actions
        )
        #expect(resolutionCount == 2)
        let secondSubmenu = try Self.moveToWindowSubmenu(in: secondMenu)
        let windowAItem = try #require(secondSubmenu.items.first { $0.title == "Window A" })
        let windowBItem = try #require(secondSubmenu.items.first { $0.title == "Window B" })
        #expect(windowAItem.isEnabled)
        #expect(!windowBItem.isEnabled)
    }

    @Test
    @MainActor
    func selectedTargetInvokesMoveWithTheMenuTargets() throws {
        let workspaceId = UUID()
        let destinationWindowId = UUID()
        var moves: [(workspaceIds: [UUID], windowId: UUID)] = []
        let actions = Self.actions(
            currentWindowMoveTargets: {
                [SidebarWorkspaceWindowMoveTarget(
                    windowId: destinationWindowId,
                    label: "Other Window",
                    isCurrentWindow: false
                )]
            },
            moveTargetsToWindow: { workspaceIds, windowId in
                moves.append((workspaceIds, windowId))
            }
        )
        let snapshot = try Self.rowSnapshot(workspaceId: workspaceId)
        let menu = SidebarWorkspaceRowContextMenuFactory.makeMenu(
            snapshot: snapshot,
            actions: actions
        )
        let submenu = try Self.moveToWindowSubmenu(in: menu)
        let targetItem = try #require(submenu.items.first { $0.title == "Other Window" })

        // Selecting the item routes the snapshot's target ids to the chosen
        // window through the closure bundle.
        let target = try #require(targetItem.target as? NSObject)
        let action = try #require(targetItem.action)
        _ = target.perform(action, with: targetItem)
        #expect(moves.count == 1)
        #expect(moves.first?.workspaceIds == [workspaceId])
        #expect(moves.first?.windowId == destinationWindowId)
    }

    // MARK: - Helpers

    @MainActor
    private static func moveToWindowSubmenu(in menu: NSMenu) throws -> NSMenu {
        let title = String(
            localized: "contextMenu.moveWorkspaceToWindow",
            defaultValue: "Move Workspace to Window"
        )
        let item = try #require(
            menu.items.first { $0.title == title },
            "menu is missing the Move-to-Window submenu item"
        )
        return try #require(item.submenu)
    }

    @MainActor
    private static func rowSnapshot(workspaceId: UUID) throws -> SidebarWorkspaceRowSnapshot {
        let suiteName = "SidebarWorkspaceContextMenuWindowTargetsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        return SidebarWorkspaceRowSnapshot(
            workspaceId: workspaceId,
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
                targetWorkspaceIds: [workspaceId],
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
        currentWindowMoveTargets: @escaping () -> [SidebarWorkspaceWindowMoveTarget],
        moveTargetsToWindow: @escaping ([UUID], UUID) -> Void = { _, _ in }
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
            moveTargetsToWindow: moveTargetsToWindow,
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
                openPane: {}
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
            onContextMenuDisappear: {}
        )
    }
}
