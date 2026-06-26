import AppKit
import Bonsplit
import CmuxCanvas
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Canvas layout mode behavior")
struct CanvasLayoutModeBehaviorTests {
    @Test func toggleCanvasLayoutCyclesThroughLayoutModes() {
        let workspace = Workspace()

        #expect(workspace.layoutMode == .splits)
        workspace.toggleCanvasLayout()
        #expect(workspace.layoutMode == .canvas)
        workspace.toggleCanvasLayout()
        #expect(workspace.layoutMode == .niri)
        workspace.toggleCanvasLayout()
        #expect(workspace.layoutMode == .splits)
    }

    @Test func switchingToNiriPreservesCanvasViewport() throws {
        let workspace = Workspace()
        workspace.setLayoutMode(.canvas)
        workspace.canvasModel.savedViewport = (
            canvasCenter: CGPoint(x: 123, y: 456),
            magnification: 1.25
        )

        workspace.setLayoutMode(.niri)

        let savedViewport = try #require(workspace.canvasModel.savedViewport)
        #expect(abs(savedViewport.canvasCenter.x - 123) < 0.001)
        #expect(abs(savedViewport.canvasCenter.y - 456) < 0.001)
        #expect(abs(savedViewport.magnification - 1.25) < 0.001)
    }

    @Test func zoomAndOverviewActionsDoNotApplyInNiriMode() {
        let workspace = Workspace()
        workspace.setLayoutMode(.niri)
        let executor = CanvasActionExecutor(workspace: workspace)

        #expect(!executor.perform(.toggleOverview))
        #expect(!executor.perform(.zoomIn))
        #expect(!executor.perform(.zoomOut))
        #expect(!executor.perform(.zoomReset))
    }

    @Test func freeformAlignmentDoesNotApplyInNiriMode() {
        let workspace = Workspace()
        workspace.setLayoutMode(.niri)
        let executor = CanvasActionExecutor(workspace: workspace)

        #expect(!executor.perform(.alignment(.tidy)))
    }

    @Test func freeformArrangePaletteCommandsAreHiddenInNiriMode() {
        var pagesContext = ContentView.CommandPaletteContextSnapshot()
        pagesContext.setBool(ContentView.CommandPaletteContextKeys.hasWorkspace, true)
        pagesContext.setBool(ContentView.CommandPaletteContextKeys.workspaceCanvasLayout, true)
        pagesContext.setBool(ContentView.CommandPaletteContextKeys.workspaceFreeformCanvasLayout, false)

        var freeformContext = ContentView.CommandPaletteContextSnapshot()
        freeformContext.setBool(ContentView.CommandPaletteContextKeys.hasWorkspace, true)
        freeformContext.setBool(ContentView.CommandPaletteContextKeys.workspaceCanvasLayout, true)
        freeformContext.setBool(ContentView.CommandPaletteContextKeys.workspaceFreeformCanvasLayout, true)

        let contributions = ContentView.commandPaletteCanvasCommandContributions()
        let pagesCommandIds = Set(contributions.filter { $0.when(pagesContext) }.map(\.commandId))
        let freeformCommandIds = Set(contributions.filter { $0.when(freeformContext) }.map(\.commandId))
        let freeformOnlyArrangeCommandIds: Set<String> = [
            "palette.canvas.tidy",
            "palette.canvas.alignLeft",
            "palette.canvas.alignRight",
            "palette.canvas.alignTop",
            "palette.canvas.alignBottom",
            "palette.canvas.equalizeWidths",
            "palette.canvas.equalizeHeights",
            "palette.canvas.distributeHorizontally",
            "palette.canvas.distributeVertically",
        ]

        #expect(pagesCommandIds.contains("palette.canvas.toggleLayout"))
        #expect(pagesCommandIds.contains("palette.canvas.revealFocusedPane"))
        #expect(freeformOnlyArrangeCommandIds.isDisjoint(with: pagesCommandIds))
        #expect(freeformOnlyArrangeCommandIds.isSubset(of: freeformCommandIds))
    }

    @Test func niriRenderedVisiblePanelsComeFromViewport() throws {
        let workspace = Workspace()
        let firstPanelId = try #require(workspace.orderedPanelIds.first)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let secondPanel = try #require(
            workspace.splitPaneWithNewTerminal(
                targetPane: paneId,
                orientation: .horizontal,
                insertFirst: false,
                workingDirectory: nil,
                initialInput: nil
            )
        )
        workspace.setLayoutMode(.niri)
        let viewport = TestCanvasViewport(renderedPanelIds: [secondPanel.id])
        workspace.canvasModel.viewport = viewport

        #expect(workspace.renderedVisiblePanelIdsForTesting() == [secondPanel.id])
        #expect(workspace.renderedVisiblePanelIdsForTesting() != [firstPanelId, secondPanel.id])
        withExtendedLifetime(viewport) {}
    }

    @Test func niriDoesNotRunFreeformBrowserPortalZOrder() throws {
        let workspace = Workspace()
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        _ = try #require(workspace.newBrowserSurface(inPane: paneId, focus: false))
        workspace.setLayoutMode(.niri)

        #expect(!workspace.syncCanvasBrowserPortalZOrder())
    }

#if DEBUG
    @Test func niriTerminalVisibilityReconcileTracksViewportRenderedPanels() throws {
        let workspace = Workspace()
        let firstPanelId = try #require(workspace.orderedPanelIds.first)
        let firstPanel = try #require(workspace.terminalPanel(for: firstPanelId))
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let secondPanel = try #require(
            workspace.splitPaneWithNewTerminal(
                targetPane: paneId,
                orientation: .horizontal,
                insertFirst: false,
                workingDirectory: nil,
                initialInput: nil
            )
        )
        workspace.setLayoutMode(.niri)
        let viewport = TestCanvasViewport(renderedPanelIds: [secondPanel.id])
        workspace.canvasModel.viewport = viewport
        firstPanel.hostedView.setVisibleInUI(true)
        secondPanel.hostedView.setVisibleInUI(true)

        workspace.debugReconcileTerminalPortalVisibilityForTesting()

        #expect(!firstPanel.hostedView.debugPortalVisibleInUI)
        #expect(secondPanel.hostedView.debugPortalVisibleInUI)

        viewport.renderedPanelIds = [firstPanel.id]
        workspace.debugReconcileTerminalPortalVisibilityForTesting()

        #expect(firstPanel.hostedView.debugPortalVisibleInUI)
        #expect(!secondPanel.hostedView.debugPortalVisibleInUI)
        withExtendedLifetime(viewport) {}
    }
#endif
}
