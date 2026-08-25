import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Workspace outer pane split", .serialized)
struct WorkspaceOuterPaneSplitTests {
    @Test(arguments: PaneOuterSplitMovement.allCases)
    func movesPaneWithoutRecreatingSurfaces(
        movement: PaneOuterSplitMovement
    ) throws {
        let workspace = Workspace()
        let leftPanel = try #require(workspace.focusedPanelId)
        let rightTop = try #require(
            workspace.newTerminalSplit(
                from: leftPanel,
                orientation: .horizontal,
                focus: false
            )
        )
        let sourcePanel = try #require(
            workspace.newTerminalSplit(
                from: rightTop.id,
                orientation: .vertical,
                focus: false
            )
        )
        let sourcePane = try #require(
            workspace.paneId(forPanelId: sourcePanel.id)
        )
        let sourceSecondPanel = try #require(
            workspace.newTerminalSurface(inPane: sourcePane, focus: false)
        )
        workspace.focusPanel(sourceSecondPanel.id)

        let panelsBefore = workspace.panels
        let treeBefore = workspace.bonsplitController.treeSnapshot()
        let sourcePanelObjects = sourcePanel.id
        let sourceSecondObject = sourceSecondPanel.id

        #expect(workspace.moveFocusedPane(to: movement))
        guard case .split(let root) = workspace.bonsplitController.treeSnapshot() else {
            Issue.record("The workspace must retain a split root")
            return
        }

        let expectedOrientation: String = movement.orientation == .horizontal
            ? "horizontal"
            : "vertical"
        #expect(root.orientation == expectedOrientation)
        let sourceEdge = movement.insertFirst ? root.first : root.second
        guard case .pane(let sourceNode) = sourceEdge else {
            Issue.record("The moved workspace pane must be a root child")
            return
        }
        #expect(sourceNode.id == sourcePane.id.uuidString)
        #expect(workspace.bonsplitController.allPaneIds.count == 3)
        #expect(Set(workspace.panels.keys) == Set(panelsBefore.keys))
        #expect(workspace.panels[sourcePanelObjects] === panelsBefore[sourcePanelObjects])
        #expect(workspace.panels[sourceSecondObject] === panelsBefore[sourceSecondObject])
        #expect(workspace.paneId(forPanelId: sourcePanelObjects) == sourcePane)
        #expect(workspace.paneId(forPanelId: sourceSecondObject) == sourcePane)
        #expect(workspace.focusedPanelId == sourceSecondObject)

        let remainingEdge = movement.insertFirst ? root.second : root.first
        guard case .split(let remainingRoot) = remainingEdge else {
            Issue.record("The remaining workspace branch must retain its split")
            return
        }
        #expect(remainingRoot.orientation == "horizontal")

        // A second invocation at the same root edge is the documented no-op.
        let treeAfterMove = workspace.bonsplitController.treeSnapshot()
        #expect(!workspace.moveFocusedPane(to: movement))
        #expect(workspace.bonsplitController.treeSnapshot() == treeAfterMove)
        #expect(treeBefore != treeAfterMove)
    }

    @Test func rejectsCanvasAndRemoteTmuxMirror() throws {
        for unsupported in [UnsupportedLayout.canvas, .remoteTmuxMirror] {
            let workspace = Workspace()
            let firstPanel = try #require(workspace.focusedPanelId)
            _ = try #require(
                workspace.newTerminalSplit(
                    from: firstPanel,
                    orientation: .horizontal,
                    focus: false
                )
            )
            workspace.focusPanel(firstPanel)
            let before = workspace.bonsplitController.treeSnapshot()
            unsupported.apply(to: workspace)

            #expect(!workspace.moveFocusedPane(to: .right))
            #expect(workspace.bonsplitController.treeSnapshot() == before)
        }
    }

    private enum UnsupportedLayout {
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
}
