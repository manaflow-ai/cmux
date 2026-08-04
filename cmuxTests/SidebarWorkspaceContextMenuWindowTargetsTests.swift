import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct SidebarWorkspaceContextMenuWindowTargetsTests {
    @Test
    func menuPresentationResolvesWindowTargetsAtBuildTime() throws {
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
        let tabManager = TabManager()
        let workspace = try #require(tabManager.selectedTab)
        let commands = Self.commands(workspace: workspace, tabManager: tabManager) {
            resolvedTopologies.append(currentTargets.map(\.windowId))
            return currentTargets
        }

        // Constructing native row actions must not resolve app-window state.
        #expect(resolvedTopologies.isEmpty)

        let firstMenu = commands.makeContextMenu(onOpen: {}, onClose: {})
        #expect(!firstMenu.items.isEmpty)
        #expect(resolvedTopologies == [[firstWindowId]])

        currentTargets.append(
            SidebarWorkspaceWindowMoveTarget(
                windowId: laterWindowId,
                label: "Window 2",
                isCurrentWindow: false
            )
        )
        let secondMenu = commands.makeContextMenu(onOpen: {}, onClose: {})
        #expect(!secondMenu.items.isEmpty)
        #expect(resolvedTopologies == [
            [firstWindowId],
            [firstWindowId, laterWindowId],
        ])
    }

    private static func commands(
        workspace: Workspace,
        tabManager: TabManager,
        currentWindowMoveTargets: @escaping () -> [SidebarWorkspaceWindowMoveTarget]
    ) -> SidebarWorkspaceRowCommands {
        SidebarWorkspaceRowCommands(
            tab: workspace,
            tabManager: tabManager,
            notificationStore: nil,
            index: 0,
            contextMenuWorkspaceIds: [workspace.id],
            remoteContextMenuWorkspaceIds: [],
            allRemoteContextMenuTargetsConnecting: false,
            allRemoteContextMenuTargetsDisconnected: false,
            contextMenuPinState: nil,
            workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot(items: []),
            refreshSnapshot: {},
            readSelectedTabIds: { [workspace.id] },
            writeSelectedTabIds: { _ in },
            readLastSelectionIndex: { 0 },
            writeLastSelectionIndex: { _ in },
            setSelectionToTabs: {},
            currentWindowMoveTargets: currentWindowMoveTargets,
            snapshotProvider: { nil }
        )
    }
}
