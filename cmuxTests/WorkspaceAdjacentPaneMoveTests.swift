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

    @Test(arguments: [
        SurfacePaneMovement.left,
        .right,
        .up,
        .down,
    ])
    func missingDirectionalDestinationCreatesEqualSplit(
        _ movement: SurfacePaneMovement
    ) throws {
        let workspace = Workspace()
        let movedPanelId = try #require(workspace.focusedPanelId)
        let sourcePaneId = try #require(
            workspace.paneId(forPanelId: movedPanelId)
        )
        let movedTerminal = try #require(
            workspace.panels[movedPanelId] as? TerminalPanel
        )
        let expectation = try #require(
            directionalSplitExpectation(for: movement)
        )

        #expect(workspace.moveFocusedSurface(to: movement))
        #expect(workspace.bonsplitController.allPaneIds.count == 2)

        let destinationPaneId = try #require(
            workspace.paneId(forPanelId: movedPanelId)
        )
        #expect(destinationPaneId != sourcePaneId)
        #expect((workspace.panels[movedPanelId] as? TerminalPanel) === movedTerminal)
        #expect(workspace.focusedPanelId == movedPanelId)
        #expect(workspace.bonsplitController.focusedPaneId == destinationPaneId)

        let replacementPanelIds = panelOrder(in: workspace, paneId: sourcePaneId)
        #expect(replacementPanelIds.count == 1)
        let replacementPanelId = try #require(replacementPanelIds.first)
        #expect(replacementPanelId != movedPanelId)
        #expect(workspace.panels[replacementPanelId] is TerminalPanel)

        guard case .split(let split) = workspace.bonsplitController.treeSnapshot() else {
            Issue.record("Expected a split for \(movement)")
            return
        }
        #expect(split.orientation == expectation.orientation)
        #expect(abs(split.dividerPosition - 0.5) < 0.000_1)
        #expect(
            paneId(in: split.first) ==
                (expectation.insertFirst ? destinationPaneId.id : sourcePaneId.id)
        )
        #expect(
            paneId(in: split.second) ==
                (expectation.insertFirst ? sourcePaneId.id : destinationPaneId.id)
        )
    }

    @Test(arguments: [
        SurfacePaneMovement.left,
        .right,
        .up,
        .down,
    ])
    func missingDirectionalDestinationPreservesParentExtent(
        _ movement: SurfacePaneMovement
    ) throws {
        let workspace = Workspace()
        let movedPanelId = try #require(workspace.focusedPanelId)
        let sourcePaneId = try #require(
            workspace.paneId(forPanelId: movedPanelId)
        )
        let expectation = try #require(
            directionalSplitExpectation(for: movement)
        )
        let parentOrientation: SplitOrientation =
            expectation.orientation == "horizontal" ? .vertical : .horizontal
        let untouchedPanel = try #require(
            workspace.newTerminalSplit(
                from: movedPanelId,
                orientation: parentOrientation,
                focus: false,
                initialDividerPosition: 0.3
            )
        )
        let untouchedPaneId = try #require(
            workspace.paneId(forPanelId: untouchedPanel.id)
        )
        workspace.focusPanel(movedPanelId)

        #expect(workspace.moveFocusedSurface(to: movement))
        let destinationPaneId = try #require(
            workspace.paneId(forPanelId: movedPanelId)
        )

        guard case .split(let root) = workspace.bonsplitController.treeSnapshot() else {
            Issue.record("Expected the parent split for \(movement)")
            return
        }
        #expect(
            root.orientation ==
                (parentOrientation == .horizontal ? "horizontal" : "vertical")
        )
        #expect(abs(root.dividerPosition - 0.3) < 0.000_1)

        guard case .split(let sourceRegion) = root.first,
              case .pane(let untouchedPane) = root.second else {
            Issue.record("Expected only the source region to split for \(movement)")
            return
        }
        #expect(sourceRegion.orientation == expectation.orientation)
        #expect(abs(sourceRegion.dividerPosition - 0.5) < 0.000_1)
        #expect(UUID(uuidString: untouchedPane.id) == untouchedPaneId.id)
        #expect(
            paneId(in: sourceRegion.first) ==
                (expectation.insertFirst ? destinationPaneId.id : sourcePaneId.id)
        )
        #expect(
            paneId(in: sourceRegion.second) ==
                (expectation.insertFirst ? sourcePaneId.id : destinationPaneId.id)
        )
    }

    @Test func missingDestinationPreservesBrowserAndWebViewIdentity() throws {
        let workspace = Workspace()
        let terminalPanelId = try #require(workspace.focusedPanelId)
        let sourcePaneId = try #require(
            workspace.paneId(forPanelId: terminalPanelId)
        )
        let browser = try #require(
            workspace.newBrowserSurface(
                inPane: sourcePaneId,
                focus: true,
                creationPolicy: .restoration
            )
        )
        let webView = browser.webView
        #expect(workspace.closePanel(terminalPanelId, force: true))

        #expect(workspace.moveFocusedSurface(to: .right))
        let destinationPaneId = try #require(
            workspace.paneId(forPanelId: browser.id)
        )

        #expect(destinationPaneId != sourcePaneId)
        #expect((workspace.panels[browser.id] as? BrowserPanel) === browser)
        #expect(browser.webView === webView)
        #expect(workspace.focusedPanelId == browser.id)
        #expect(workspace.bonsplitController.focusedPaneId == destinationPaneId)

        let replacementPanelIds = panelOrder(in: workspace, paneId: sourcePaneId)
        #expect(replacementPanelIds.count == 1)
        let replacementPanelId = try #require(replacementPanelIds.first)
        #expect(replacementPanelId != browser.id)
        #expect(workspace.panels[replacementPanelId] is TerminalPanel)
    }

    @Test func previousAndNextAreNoOpsWithASinglePane() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: panelId))
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)

        for movement in [SurfacePaneMovement.previous, .next] {
            #expect(!workspace.moveFocusedSurface(to: movement))
        }

        #expect(workspace.bonsplitController.allPaneIds == [paneId])
        #expect(panelOrder(in: workspace, paneId: paneId) == [panelId])
        #expect((workspace.panels[panelId] as? TerminalPanel) === panel)
    }

    @Test func failedTransferRestoresSplitZoom() throws {
        let workspace = Workspace()
        let movedPanelId = try #require(workspace.focusedPanelId)
        let sourcePaneId = try #require(
            workspace.paneId(forPanelId: movedPanelId)
        )
        _ = try #require(
            workspace.newTerminalSplit(
                from: movedPanelId,
                orientation: .horizontal,
                focus: false
            )
        )
        workspace.focusPanel(movedPanelId)
        #expect(workspace.toggleSplitZoom(panelId: movedPanelId))

        var configuration = workspace.bonsplitController.configuration
        configuration.allowCrossPaneTabMove = false
        workspace.bonsplitController.configuration = configuration

        #expect(!workspace.moveFocusedSurface(to: .right))
        #expect(workspace.bonsplitController.zoomedPaneId == sourcePaneId)
        #expect(workspace.paneId(forPanelId: movedPanelId) == sourcePaneId)
        #expect(workspace.focusedPanelId == movedPanelId)
    }

    @Test func failedDirectionalSplitRestoresZoomAndLayout() throws {
        let workspace = Workspace()
        let movedPanelId = try #require(workspace.focusedPanelId)
        let sourcePaneId = try #require(
            workspace.paneId(forPanelId: movedPanelId)
        )
        _ = try #require(
            workspace.newTerminalSplit(
                from: movedPanelId,
                orientation: .vertical,
                focus: false
            )
        )
        workspace.focusPanel(movedPanelId)
        #expect(workspace.toggleSplitZoom(panelId: movedPanelId))
        let treeBeforeMove = workspace.bonsplitController.treeSnapshot()

        var configuration = workspace.bonsplitController.configuration
        configuration.allowCrossPaneTabMove = false
        workspace.bonsplitController.configuration = configuration

        #expect(!workspace.moveFocusedSurface(to: .right))
        #expect(workspace.bonsplitController.treeSnapshot() == treeBeforeMove)
        #expect(workspace.bonsplitController.zoomedPaneId == sourcePaneId)
        #expect(workspace.paneId(forPanelId: movedPanelId) == sourcePaneId)
        #expect(workspace.focusedPanelId == movedPanelId)
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

    private func directionalSplitExpectation(
        for movement: SurfacePaneMovement
    ) -> (orientation: String, insertFirst: Bool)? {
        switch movement {
        case .left: ("horizontal", true)
        case .right: ("horizontal", false)
        case .up: ("vertical", true)
        case .down: ("vertical", false)
        case .previous, .next: nil
        }
    }

    private func paneId(in node: ExternalTreeNode) -> UUID? {
        guard case .pane(let pane) = node else { return nil }
        return UUID(uuidString: pane.id)
    }
}
