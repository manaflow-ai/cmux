import Bonsplit
import CmuxCanvasUI
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private final class ReorderCanvasViewportSpy: CanvasViewportControlling {
    var modelDidChangeCount = 0
    var currentMagnification: CGFloat = 1
    var currentCenterInCanvas: CGPoint = .zero

    func revealPane(_ panelId: UUID, animated: Bool) {}
    func toggleOverview() {}
    func zoom(by factor: CGFloat) {}
    func resetZoom() {}
    func setViewport(center: CGPoint, magnification: CGFloat?) {}
    func modelDidChangeExternally(animated: Bool) { modelDidChangeCount += 1 }
}

@MainActor
@Suite("Reorder shortcut actions", .serialized)
struct ReorderShortcutActionTests {
    @Test func selectedSurfaceMovesByFinalPositionAndClampsAtEdges() throws {
        let workspace = Workspace()
        let firstPanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: firstPanelId))
        _ = try #require(workspace.newTerminalSurface(inPane: paneId, focus: false))
        _ = try #require(workspace.newTerminalSurface(inPane: paneId, focus: false))
        workspace.focusPanel(firstPanelId)
        let initialOrder = panelOrder(in: workspace, paneId: paneId)
        try #require(initialOrder.first == firstPanelId)
        let remainingPanelIds = initialOrder.filter { $0 != firstPanelId }
        try #require(remainingPanelIds.count == 2)

        #expect(workspace.moveSelectedSurface(by: 1))
        let middleOrder = [remainingPanelIds[0], firstPanelId, remainingPanelIds[1]]
        #expect(panelOrder(in: workspace, paneId: paneId) == middleOrder)
        #expect(workspace.focusedPanelId == firstPanelId)

        #expect(workspace.moveSelectedSurface(by: 1))
        let rightEdgeOrder = remainingPanelIds + [firstPanelId]
        #expect(panelOrder(in: workspace, paneId: paneId) == rightEdgeOrder)
        #expect(workspace.moveSelectedSurface(by: 1))
        #expect(panelOrder(in: workspace, paneId: paneId) == rightEdgeOrder)

        #expect(workspace.moveSelectedSurface(by: -1))
        #expect(panelOrder(in: workspace, paneId: paneId) == middleOrder)
    }

    @Test func singleSurfaceReorderIsANoOp() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: panelId))

        #expect(workspace.moveSelectedSurface(by: -1))
        #expect(workspace.moveSelectedSurface(by: 1))
        #expect(panelOrder(in: workspace, paneId: paneId) == [panelId])
    }

    @Test func selectedCanvasSurfaceMovesWithinVisiblePaneWithoutMutatingSplitOrder() throws {
        let workspace = Workspace()
        let firstPanelId = try #require(workspace.focusedPanelId)
        let splitPaneId = try #require(workspace.paneId(forPanelId: firstPanelId))
        let secondPanel = try #require(workspace.newTerminalSurface(inPane: splitPaneId, focus: false))
        let thirdPanel = try #require(workspace.newTerminalSurface(inPane: splitPaneId, focus: false))
        let splitOrder = panelOrder(in: workspace, paneId: splitPaneId)
        try #require(splitOrder.first == firstPanelId)

        workspace.canvasModel.syncPanes(panelIds: splitOrder, focusedPanelId: firstPanelId)
        #expect(workspace.canvasModel.joinPanel(secondPanel.id, withPaneContaining: firstPanelId))
        #expect(workspace.canvasModel.joinPanel(thirdPanel.id, withPaneContaining: firstPanelId))
        workspace.setLayoutMode(.canvas)
        workspace.focusPanel(firstPanelId)
        let canvasPaneId = try #require(workspace.canvasModel.paneID(containing: firstPanelId))
        let canvasOrder = try #require(
            workspace.canvasModel.layout.panelIds(in: canvasPaneId)?.map(\.rawValue)
        )
        try #require(canvasOrder.first == firstPanelId)
        let remainingCanvasPanelIds = canvasOrder.filter { $0 != firstPanelId }
        try #require(remainingCanvasPanelIds.count == 2)
        let viewport = ReorderCanvasViewportSpy()
        workspace.canvasModel.viewport = viewport

        #expect(workspace.moveSelectedSurface(by: -1))
        #expect(viewport.modelDidChangeCount == 0)

        #expect(workspace.moveSelectedSurface(by: 1))
        #expect(viewport.modelDidChangeCount == 1)
        #expect(
            workspace.canvasModel.layout.panelIds(in: canvasPaneId)?.map(\.rawValue) ==
                [remainingCanvasPanelIds[0], firstPanelId, remainingCanvasPanelIds[1]]
        )
        #expect(workspace.focusedPanelId == firstPanelId)
        #expect(panelOrder(in: workspace, paneId: splitPaneId) == splitOrder)
    }

    @Test func selectedWorkspaceMovesWithinItsPinTierAndStaysSelected() {
        let manager = TabManager()
        let firstPinned = manager.tabs[0]
        manager.setPinned(firstPinned, pinned: true)
        let secondPinned = manager.addWorkspace()
        manager.setPinned(secondPinned, pinned: true)
        let firstUnpinned = manager.addWorkspace()
        let secondUnpinned = manager.addWorkspace()

        manager.selectWorkspace(secondPinned)
        let initialOrder = [firstPinned.id, secondPinned.id, firstUnpinned.id, secondUnpinned.id]
        #expect(manager.tabs.map(\.id) == initialOrder)
        #expect(manager.moveSelectedWorkspace(by: 1))
        #expect(manager.tabs.map(\.id) == initialOrder)
        #expect(manager.moveSelectedWorkspace(by: -1))
        #expect(manager.tabs.map(\.id) == [secondPinned.id, firstPinned.id, firstUnpinned.id, secondUnpinned.id])
        #expect(manager.selectedTabId == secondPinned.id)
        #expect(manager.moveSelectedWorkspace(by: -1))
        #expect(manager.tabs.map(\.id) == [secondPinned.id, firstPinned.id, firstUnpinned.id, secondUnpinned.id])

        manager.selectWorkspace(firstUnpinned)
        #expect(manager.moveSelectedWorkspace(by: -1))
        #expect(manager.tabs.map(\.id) == [secondPinned.id, firstPinned.id, firstUnpinned.id, secondUnpinned.id])
        #expect(manager.moveSelectedWorkspace(by: 1))
        #expect(manager.tabs.map(\.id) == [secondPinned.id, firstPinned.id, secondUnpinned.id, firstUnpinned.id])
        #expect(manager.selectedTabId == firstUnpinned.id)
        #expect(manager.moveSelectedWorkspace(by: 1))
        #expect(manager.tabs.map(\.id) == [secondPinned.id, firstPinned.id, secondUnpinned.id, firstUnpinned.id])
    }

    @Test func movementActionsArePublicAndHaveAlignedCollisionFreeDefaults() throws {
        let actions: [KeyboardShortcutSettings.Action] = [
            .moveSurfaceLeft,
            .moveSurfaceRight,
            .moveSurfaceToPreviousPane,
            .moveSurfaceToNextPane,
            .moveSurfaceToPaneLeft,
            .moveSurfaceToPaneRight,
            .moveSurfaceToPaneUp,
            .moveSurfaceToPaneDown,
            .moveWorkspaceUp,
            .moveWorkspaceDown,
        ]

        for action in actions {
            #expect(KeyboardShortcutSettings.publicShortcutActions.contains(action))
            #expect(KeyboardShortcutSettings.settingsVisibleActions.contains(action))
            let settingsAction = try #require(ShortcutAction(rawValue: action.rawValue))
            let settingsStroke = try #require(settingsAction.defaultStroke)
            let runtimeShortcut = action.defaultShortcut
            #expect(settingsAction.displayName == action.label)
            #expect(settingsStroke.key == runtimeShortcut.key)
            #expect(settingsStroke.command == runtimeShortcut.command)
            #expect(settingsStroke.shift == runtimeShortcut.shift)
            #expect(settingsStroke.option == runtimeShortcut.option)
            #expect(settingsStroke.control == runtimeShortcut.control)
            #expect(
                !KeyboardShortcutSettings.Action.allCases.contains {
                    $0 != action && $0.defaultShortcut == runtimeShortcut
                }
            )
        }

        #expect(ContentView.commandPaletteShortcutAction(forCommandID: "palette.moveWorkspaceUp") == .moveWorkspaceUp)
        #expect(ContentView.commandPaletteShortcutAction(forCommandID: "palette.moveWorkspaceDown") == .moveWorkspaceDown)
        for movement in SurfacePaneMovement.allCases {
            #expect(
                ContentView.commandPaletteShortcutAction(
                    forCommandID: movement.commandID
                ) == movement.shortcutAction
            )
        }

        let previousDefault =
            KeyboardShortcutSettings.Action.moveSurfaceToPreviousPane.defaultShortcut
        #expect(previousDefault.key == "[")
        #expect(previousDefault.command)
        #expect(previousDefault.shift)
        #expect(!previousDefault.option)
        #expect(previousDefault.control)

        let nextDefault =
            KeyboardShortcutSettings.Action.moveSurfaceToNextPane.defaultShortcut
        #expect(nextDefault.key == "]")
        #expect(nextDefault.command)
        #expect(nextDefault.shift)
        #expect(!nextDefault.option)
        #expect(nextDefault.control)
        let directionalDefaults: [
            KeyboardShortcutSettings.Action: String
        ] = [
            .moveSurfaceToPaneLeft: "←",
            .moveSurfaceToPaneRight: "→",
            .moveSurfaceToPaneUp: "↑",
            .moveSurfaceToPaneDown: "↓",
        ]
        for (action, key) in directionalDefaults {
            let shortcut = action.defaultShortcut
            #expect(shortcut.key == key)
            #expect(shortcut.command)
            #expect(shortcut.shift)
            #expect(shortcut.option)
            #expect(!shortcut.control)
        }
    }

    private func panelOrder(in workspace: Workspace, paneId: PaneID) -> [UUID] {
        workspace.bonsplitController.tabs(inPane: paneId).compactMap {
            workspace.panelIdFromSurfaceId($0.id)
        }
    }
}
