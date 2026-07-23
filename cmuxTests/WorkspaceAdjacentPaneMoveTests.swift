import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Move surface between panes", .serialized)
struct WorkspaceAdjacentPaneMoveTests {
    @Test func previousAndNextWrapInSpatialPaneOrder() throws {
        let workspace = Workspace()
        let firstPanelId = try #require(workspace.focusedPanelId)
        let firstPaneId = try #require(workspace.paneId(forPanelId: firstPanelId))
        let topRightPanel = try #require(
            workspace.newTerminalSplit(
                from: firstPanelId,
                orientation: .horizontal,
                focus: false
            )
        )
        let bottomRightPanel = try #require(
            workspace.newTerminalSplit(
                from: topRightPanel.id,
                orientation: .vertical,
                focus: false
            )
        )
        let movedPanel = try #require(
            workspace.newTerminalSurface(inPane: firstPaneId, focus: false)
        )
        let orderedPaneIds = workspace.spatiallyOrderedPaneIds
        #expect(orderedPaneIds.count == 3)
        let lastPaneUUID = try #require(orderedPaneIds.last)
        let lastPaneId = PaneID(id: lastPaneUUID)

        workspace.focusPanel(movedPanel.id)
        #expect(workspace.moveFocusedSurface(to: .previous))
        #expect(workspace.paneId(forPanelId: movedPanel.id) == lastPaneId)

        #expect(workspace.moveFocusedSurface(to: .next))
        #expect(workspace.paneId(forPanelId: movedPanel.id) == firstPaneId)
        #expect(workspace.panels[topRightPanel.id] != nil)
        #expect(workspace.panels[bottomRightPanel.id] != nil)
    }

    @Test func directionalMovementUsesPaneAdjacency() throws {
        try expectDirectionalMovement(
            .right,
            orientation: .horizontal,
            fromSecondPane: false
        )
        try expectDirectionalMovement(
            .left,
            orientation: .horizontal,
            fromSecondPane: true
        )
        try expectDirectionalMovement(
            .down,
            orientation: .vertical,
            fromSecondPane: false
        )
        try expectDirectionalMovement(
            .up,
            orientation: .vertical,
            fromSecondPane: true
        )
    }

    @Test func insertsAfterDestinationSelectionAndFocusesMovedSurface() throws {
        let workspace = Workspace()
        let movedPanelId = try #require(workspace.focusedPanelId)
        let sourcePaneId = try #require(workspace.paneId(forPanelId: movedPanelId))
        let sourceRemainder = try #require(
            workspace.newTerminalSurface(inPane: sourcePaneId, focus: false)
        )
        let destinationFirst = try #require(
            workspace.newTerminalSplit(
                from: movedPanelId,
                orientation: .horizontal,
                focus: false
            )
        )
        let destinationPaneId = try #require(
            workspace.paneId(forPanelId: destinationFirst.id)
        )
        let destinationSelected = try #require(
            workspace.newTerminalSurface(inPane: destinationPaneId, focus: false)
        )
        let destinationLast = try #require(
            workspace.newTerminalSurface(inPane: destinationPaneId, focus: false)
        )
        workspace.focusPanel(destinationSelected.id)
        workspace.focusPanel(movedPanelId)

        #expect(workspace.moveFocusedSurface(to: .right))
        #expect(
            panelOrder(in: workspace, paneId: destinationPaneId) == [
                destinationFirst.id,
                destinationSelected.id,
                movedPanelId,
                destinationLast.id,
            ]
        )
        #expect(workspace.focusedPanelId == movedPanelId)
        let movedTabId = try #require(
            workspace.surfaceIdFromPanelId(movedPanelId)
        )
        #expect(
            workspace.bonsplitController.selectedTab(inPane: destinationPaneId)?.id ==
                movedTabId
        )
        #expect(workspace.paneId(forPanelId: sourceRemainder.id) == sourcePaneId)
    }

    @Test func movingSoleTerminalCollapsesSourceAndPreservesInstance() throws {
        let workspace = Workspace()
        let movedPanelId = try #require(workspace.focusedPanelId)
        let terminal = try #require(workspace.panels[movedPanelId] as? TerminalPanel)
        let sourcePaneId = try #require(workspace.paneId(forPanelId: movedPanelId))
        let destinationPanel = try #require(
            workspace.newTerminalSplit(
                from: movedPanelId,
                orientation: .horizontal,
                focus: false
            )
        )
        let destinationPaneId = try #require(
            workspace.paneId(forPanelId: destinationPanel.id)
        )
        workspace.focusPanel(movedPanelId)

        #expect(workspace.moveFocusedSurface(to: .right))
        #expect(workspace.bonsplitController.allPaneIds.count == 1)
        #expect(!workspace.bonsplitController.allPaneIds.contains(sourcePaneId))
        #expect(workspace.paneId(forPanelId: movedPanelId) == destinationPaneId)
        #expect((workspace.panels[movedPanelId] as? TerminalPanel) === terminal)
    }

    @Test func browserAndWebViewKeepIdentityAcrossPaneTransfer() throws {
        let workspace = Workspace()
        let terminalPanelId = try #require(workspace.focusedPanelId)
        let sourcePaneId = try #require(
            workspace.paneId(forPanelId: terminalPanelId)
        )
        let browser = try #require(
            workspace.newBrowserSurface(
                inPane: sourcePaneId,
                focus: false,
                creationPolicy: .restoration
            )
        )
        let webView = browser.webView
        let destinationPanel = try #require(
            workspace.newTerminalSplit(
                from: terminalPanelId,
                orientation: .horizontal,
                focus: false
            )
        )
        let destinationPaneId = try #require(
            workspace.paneId(forPanelId: destinationPanel.id)
        )
        workspace.focusPanel(browser.id)

        #expect(workspace.moveFocusedSurface(to: .right))
        #expect(workspace.paneId(forPanelId: browser.id) == destinationPaneId)
        #expect((workspace.panels[browser.id] as? BrowserPanel) === browser)
        #expect(browser.webView === webView)
    }

    @Test func allActionsAreNoOpsWithASinglePane() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: panelId))
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)

        for movement in SurfacePaneMovement.allCases {
            #expect(!workspace.moveFocusedSurface(to: movement))
        }

        #expect(workspace.bonsplitController.allPaneIds == [paneId])
        #expect(panelOrder(in: workspace, paneId: paneId) == [panelId])
        #expect((workspace.panels[panelId] as? TerminalPanel) === panel)
    }

    @Test func rejectsCanvasAndRemoteTmuxLayoutsWithoutMutation() throws {
        for unsupportedLayout in UnsupportedLayout.allCases {
            let workspace = Workspace()
            let movedPanelId = try #require(workspace.focusedPanelId)
            let sourcePaneId = try #require(
                workspace.paneId(forPanelId: movedPanelId)
            )
            let destinationPanel = try #require(
                workspace.newTerminalSplit(
                    from: movedPanelId,
                    orientation: .horizontal,
                    focus: false
                )
            )
            let destinationPaneId = try #require(
                workspace.paneId(forPanelId: destinationPanel.id)
            )
            workspace.focusPanel(movedPanelId)
            unsupportedLayout.apply(to: workspace)

            #expect(!workspace.moveFocusedSurface(to: .right))
            #expect(workspace.paneId(forPanelId: movedPanelId) == sourcePaneId)
            #expect(
                panelOrder(in: workspace, paneId: destinationPaneId) ==
                    [destinationPanel.id]
            )
            #expect(workspace.bonsplitController.allPaneIds.count == 2)
        }
    }

    @Test func tabContextActionsUseTheSharedTransferPath() throws {
        let workspace = Workspace()
        let leftPanelId = try #require(workspace.focusedPanelId)
        let leftPaneId = try #require(workspace.paneId(forPanelId: leftPanelId))
        let rightPanel = try #require(
            workspace.newTerminalSplit(
                from: leftPanelId,
                orientation: .horizontal,
                focus: false
            )
        )
        let rightPaneId = try #require(workspace.paneId(forPanelId: rightPanel.id))
        let leftTabId = try #require(workspace.surfaceIdFromPanelId(leftPanelId))
        let leftTab = try #require(workspace.bonsplitController.tab(leftTabId))

        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextAction: .moveToRightPane,
            for: leftTab,
            inPane: leftPaneId
        )

        #expect(workspace.paneId(forPanelId: leftPanelId) == rightPaneId)
    }

    private enum UnsupportedLayout: CaseIterable {
        case canvas
        case remoteTmuxMirror

        @MainActor
        func apply(to workspace: Workspace) {
            switch self {
            case .canvas:
                workspace.setLayoutMode(.canvas)
            case .remoteTmuxMirror:
                workspace.isRemoteTmuxMirror = true
            }
        }
    }

    private func expectDirectionalMovement(
        _ movement: SurfacePaneMovement,
        orientation: SplitOrientation,
        fromSecondPane: Bool
    ) throws {
        let workspace = Workspace()
        let firstPanelId = try #require(workspace.focusedPanelId)
        let firstPaneId = try #require(workspace.paneId(forPanelId: firstPanelId))
        let secondPanel = try #require(
            workspace.newTerminalSplit(
                from: firstPanelId,
                orientation: orientation,
                focus: false
            )
        )
        let secondPaneId = try #require(
            workspace.paneId(forPanelId: secondPanel.id)
        )
        let sourcePanelId = fromSecondPane ? secondPanel.id : firstPanelId
        let expectedPaneId = fromSecondPane ? firstPaneId : secondPaneId
        workspace.focusPanel(sourcePanelId)

        #expect(workspace.moveFocusedSurface(to: movement))
        #expect(workspace.paneId(forPanelId: sourcePanelId) == expectedPaneId)
        #expect(workspace.focusedPanelId == sourcePanelId)
    }

    private func panelOrder(in workspace: Workspace, paneId: PaneID) -> [UUID] {
        workspace.bonsplitController.tabs(inPane: paneId).compactMap {
            workspace.panelIdFromSurfaceId($0.id)
        }
    }
}
