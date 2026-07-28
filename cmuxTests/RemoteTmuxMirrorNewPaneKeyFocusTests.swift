import CmuxRemoteSession
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Focus ownership coverage for tmux panes nested inside a workspace tab.
/// The workspace's focused panel remains the outer container; input focus is
/// projected to the mirror's authoritative active inner pane.
@MainActor
@Suite(.serialized)
struct RemoteTmuxMirrorNewPaneKeyFocusTests {
    private static func singlePaneLayout(_ pane: Int) -> RemoteTmuxLayoutNode {
        RemoteTmuxLayoutNode(width: 80, height: 24, x: 0, y: 0, content: .pane(pane))
    }

    private static func twoPaneLayout(left: Int, right: Int) -> RemoteTmuxLayoutNode {
        RemoteTmuxLayoutNode(
            width: 80,
            height: 24,
            x: 0,
            y: 0,
            content: .horizontal([
                RemoteTmuxLayoutNode(width: 39, height: 24, x: 0, y: 0, content: .pane(left)),
                RemoteTmuxLayoutNode(width: 40, height: 24, x: 40, y: 0, content: .pane(right)),
            ])
        )
    }

    @MainActor
    private final class Harness {
        let workspace: Workspace
        let mirror: RemoteTmuxWindowMirror
        let containerPanelId: UUID

        init() throws {
            let manager = TabManager()
            let workspace = try #require(manager.selectedWorkspace)
            let containerPanelId = try #require(workspace.focusedPanelId)
            let connection = RemoteTmuxControlConnection(
                host: RemoteTmuxHost(destination: "user@newpanefocus"),
                sessionName: "focus-map"
            )
            let mirror = RemoteTmuxWindowMirror(
                windowId: 2,
                panelId: containerPanelId,
                connection: connection,
                layout: RemoteTmuxMirrorNewPaneKeyFocusTests.singlePaneLayout(4),
                makePanel: { _ in workspace.makeRemoteTmuxPanePanel(onInput: { _ in }) }
            )
            workspace.setRemoteTmuxWindowMirror(mirror, forPanelId: containerPanelId)
            self.workspace = workspace
            self.mirror = mirror
            self.containerPanelId = containerPanelId
        }

        func splitMakingPaneFiveActive() {
            mirror.reconcile(
                layout: RemoteTmuxMirrorNewPaneKeyFocusTests.twoPaneLayout(left: 4, right: 5)
            )
            mirror.noteRemoteActivePane(5)
        }

        func tearDown() {
            workspace.setRemoteTmuxWindowMirror(nil, forPanelId: containerPanelId)
            mirror.tearDown()
        }
    }

    @Test
    func freshlySplitPaneBecomesFocusedTerminalInputTarget() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.splitMakingPaneFiveActive()

        let paneFive = try #require(harness.mirror.panel(forPane: 5))
        let inputTarget = try #require(harness.workspace.focusedTerminalInputTarget())

        #expect(harness.mirror.activePaneId == 5)
        #expect(inputTarget.surfaceID == paneFive.id)
        #expect(inputTarget.panel === paneFive)
    }

    @Test
    func activePaneChangesUpdateFocusedTerminalInputTarget() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.splitMakingPaneFiveActive()

        let paneFour = try #require(harness.mirror.panel(forPane: 4))
        let paneFive = try #require(harness.mirror.panel(forPane: 5))

        harness.mirror.noteRemoteActivePane(4)
        #expect(harness.workspace.focusedTerminalInputTarget()?.surfaceID == paneFour.id)

        harness.mirror.noteRemoteActivePane(5)
        #expect(harness.workspace.focusedTerminalInputTarget()?.surfaceID == paneFive.id)
    }
}
