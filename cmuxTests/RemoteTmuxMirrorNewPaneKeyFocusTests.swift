import AppKit
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
        let connection: RemoteTmuxControlConnection
        let writer: RemoteTmuxControlPipeWriter
        let pipe: Pipe

        init() throws {
            let manager = TabManager()
            let workspace = try #require(manager.selectedWorkspace)
            let containerPanelId = try #require(workspace.focusedPanelId)
            let connection = RemoteTmuxControlConnection(
                host: RemoteTmuxHost(destination: "user@newpanefocus"),
                sessionName: "focus-map"
            )
            let pipe = Pipe()
            let writer = RemoteTmuxControlPipeWriter(
                handle: pipe.fileHandleForWriting,
                label: "remote-tmux-created-pane-focus-test",
                maxPendingBytes: 1 << 16,
                onFailure: {}
            )
            connection.installStdinWriterForTesting(writer)
            connection.handleMessageForTesting(.enter)
            connection.handleMessageForTesting(
                .commandResult(commandNumber: 0, lines: [], isError: false)
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
            self.connection = connection
            self.writer = writer
            self.pipe = pipe
        }

        func splitMakingPaneFiveActive() {
            mirror.reconcile(
                layout: RemoteTmuxMirrorNewPaneKeyFocusTests.twoPaneLayout(left: 4, right: 5)
            )
            mirror.noteRemoteActivePane(5)
        }

        func tearDown() {
            workspace.setRemoteTmuxWindowMirror(nil, forPanelId: containerPanelId)
            mirror.teardown()
            writer.close()
            try? pipe.fileHandleForReading.close()
        }
    }

    @Test
    func freshlySplitPaneBecomesFocusedTerminalInputTarget() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.splitMakingPaneFiveActive()

        #expect(harness.workspace.focusedPanelId == harness.containerPanelId)
        let paneFive = try #require(harness.mirror.panel(forPane: 5))
        let inputTarget = try #require(harness.workspace.focusedTerminalInputTarget())

        #expect(harness.mirror.activePaneId == 5)
        #expect(inputTarget.surfaceID == paneFive.id)
        #expect(inputTarget.panel === paneFive)
        #expect(harness.workspace.focusedTerminalPanel?.id == harness.containerPanelId)
        #expect(
            harness.workspace.terminalInputTarget(
                forPanelID: harness.containerPanelId
            )?.panel === paneFive
        )
        #expect(
            AppDelegate.resolveTerminalPanelForTextSend(
                in: harness.workspace,
                preferredPanelId: harness.containerPanelId
            ) === paneFive
        )
    }

    @Test
    func locallyRequestedFocusedSplitTransfersFirstResponderWhenNewPaneMounts() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let paneFour = try #require(harness.mirror.panel(forPane: 4))
        let mountedPortal = try RemoteTmuxPanePortalTestHarness()
        defer { mountedPortal.tearDown() }
        mountedPortal.mount(paneFour, frame: NSRect(x: 0, y: 0, width: 395, height: 500))
        paneFour.hostedView.setVisibleInUI(true)
        paneFour.hostedView.setActive(true)
        paneFour.hostedView.moveFocus()
        #expect(paneFour.hostedView.isSurfaceViewFirstResponder())

        #expect(harness.mirror.requestSplit(
            fromPane: 4,
            vertical: false,
            focusIntent: .focusCreatedPane
        ))
        harness.splitMakingPaneFiveActive()

        let paneFive = try #require(harness.mirror.panel(forPane: 5))
        #expect(paneFour.hostedView.isSurfaceViewFirstResponder())
        paneFour.hostedView.setActive(false)
        mountedPortal.mount(paneFive, frame: NSRect(x: 405, y: 0, width: 395, height: 500))
        paneFive.hostedView.setVisibleInUI(true)
        paneFive.hostedView.setActive(true)
        paneFive.surface.onRuntimeReady?()

        #expect(
            paneFive.hostedView.isSurfaceViewFirstResponder(),
            "The authoritative created pane must receive key input as soon as it mounts"
        )
    }

    @Test
    func locallyRequestedFocusedSplitDoesNotOverrideLaterPaneFocus() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let paneFour = try #require(harness.mirror.panel(forPane: 4))
        let mountedPortal = try RemoteTmuxPanePortalTestHarness()
        defer { mountedPortal.tearDown() }
        mountedPortal.mount(paneFour, frame: NSRect(x: 0, y: 0, width: 395, height: 500))
        paneFour.hostedView.setVisibleInUI(true)
        paneFour.hostedView.setActive(true)
        paneFour.hostedView.moveFocus()
        #expect(paneFour.hostedView.isSurfaceViewFirstResponder())

        #expect(harness.mirror.requestSplit(
            fromPane: 4,
            vertical: false,
            focusIntent: .focusCreatedPane
        ))
        harness.splitMakingPaneFiveActive()
        let paneFive = try #require(harness.mirror.panel(forPane: 5))

        harness.mirror.focus(pane: 4)
        #expect(harness.mirror.activePaneId == 4)
        mountedPortal.mount(paneFive, frame: NSRect(x: 405, y: 0, width: 395, height: 500))
        paneFive.hostedView.setVisibleInUI(true)
        paneFive.hostedView.setActive(false)
        paneFive.surface.onRuntimeReady?()

        #expect(
            paneFour.hostedView.isSurfaceViewFirstResponder(),
            "Mounting a stale split candidate must not override newer user focus"
        )
        #expect(harness.mirror.activePaneId == 4)
        #expect(harness.workspace.focusedTerminalInputTarget()?.surfaceID == paneFour.id)
    }

    @Test
    func activePaneChangesUpdateFocusedTerminalInputTarget() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.splitMakingPaneFiveActive()

        #expect(harness.workspace.focusedPanelId == harness.containerPanelId)
        let paneFour = try #require(harness.mirror.panel(forPane: 4))
        let paneFive = try #require(harness.mirror.panel(forPane: 5))

        harness.mirror.noteRemoteActivePane(4)
        #expect(harness.workspace.focusedPanelId == harness.containerPanelId)
        #expect(harness.workspace.focusedTerminalInputTarget()?.surfaceID == paneFour.id)
        #expect(harness.workspace.focusedTerminalPanel?.id == harness.containerPanelId)

        harness.mirror.noteRemoteActivePane(5)
        #expect(harness.workspace.focusedPanelId == harness.containerPanelId)
        #expect(harness.workspace.focusedTerminalInputTarget()?.surfaceID == paneFive.id)
        #expect(harness.workspace.focusedTerminalPanel?.id == harness.containerPanelId)
    }

    @Test
    func unresolvedDirectMirrorActivePaneFailsClosed() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.splitMakingPaneFiveActive()

        let paneFive = try #require(harness.mirror.panel(forPane: 5))
        harness.mirror.panelsByPaneId[5] = nil
        defer { harness.mirror.panelsByPaneId[5] = paneFive }

        #expect(
            harness.workspace.activeRemoteTmuxControlPane(
                containerPanelID: harness.containerPanelId
            ) == nil
        )
        #expect(harness.workspace.focusedTerminalInputTarget() == nil)
        #expect(harness.workspace.focusedTerminalPanel?.id == harness.containerPanelId)
    }
}
