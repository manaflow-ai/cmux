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
        let secondPanel = try #require(workspace.newTerminalSurface(inPane: paneId, focus: false))
        let thirdPanel = try #require(workspace.newTerminalSurface(inPane: paneId, focus: false))
        workspace.focusPanel(firstPanelId)

        #expect(workspace.moveSelectedSurface(by: 1))
        #expect(panelOrder(in: workspace, paneId: paneId) == [secondPanel.id, firstPanelId, thirdPanel.id])
        #expect(workspace.focusedPanelId == firstPanelId)

        #expect(workspace.moveSelectedSurface(by: 1))
        let rightEdgeOrder = [secondPanel.id, thirdPanel.id, firstPanelId]
        #expect(panelOrder(in: workspace, paneId: paneId) == rightEdgeOrder)
        #expect(workspace.moveSelectedSurface(by: 1))
        #expect(panelOrder(in: workspace, paneId: paneId) == rightEdgeOrder)

        #expect(workspace.moveSelectedSurface(by: -1))
        #expect(panelOrder(in: workspace, paneId: paneId) == [secondPanel.id, firstPanelId, thirdPanel.id])
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
        let originalOrder = [firstPanelId, secondPanel.id, thirdPanel.id]

        workspace.canvasModel.syncPanes(panelIds: originalOrder, focusedPanelId: firstPanelId)
        #expect(workspace.canvasModel.joinPanel(secondPanel.id, withPaneContaining: firstPanelId))
        #expect(workspace.canvasModel.joinPanel(thirdPanel.id, withPaneContaining: firstPanelId))
        workspace.setLayoutMode(.canvas)
        workspace.focusPanel(firstPanelId)
        let canvasPaneId = try #require(workspace.canvasModel.paneID(containing: firstPanelId))
        let viewport = ReorderCanvasViewportSpy()
        workspace.canvasModel.viewport = viewport

        #expect(workspace.moveSelectedSurface(by: -1))
        #expect(viewport.modelDidChangeCount == 0)

        #expect(workspace.moveSelectedSurface(by: 1))
        #expect(viewport.modelDidChangeCount == 1)
        #expect(
            workspace.canvasModel.layout.panelIds(in: canvasPaneId)?.map(\.rawValue) ==
                [secondPanel.id, firstPanelId, thirdPanel.id]
        )
        #expect(workspace.focusedPanelId == firstPanelId)
        #expect(panelOrder(in: workspace, paneId: splitPaneId) == originalOrder)
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

    @Test func reorderActionsArePublicAndHaveAlignedCollisionFreeDefaults() throws {
        let actions: [KeyboardShortcutSettings.Action] = [
            .moveSurfaceLeft,
            .moveSurfaceRight,
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
    }

    private func panelOrder(in workspace: Workspace, paneId: PaneID) -> [UUID] {
        workspace.bonsplitController.tabs(inPane: paneId).compactMap {
            workspace.panelIdFromSurfaceId($0.id)
        }
    }
}
