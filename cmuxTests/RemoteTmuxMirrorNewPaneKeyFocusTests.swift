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

    private static func threePaneLayout(
        left: Int,
        middle: Int,
        right: Int
    ) -> RemoteTmuxLayoutNode {
        RemoteTmuxLayoutNode(
            width: 120,
            height: 24,
            x: 0,
            y: 0,
            content: .horizontal([
                RemoteTmuxLayoutNode(width: 39, height: 24, x: 0, y: 0, content: .pane(left)),
                RemoteTmuxLayoutNode(width: 39, height: 24, x: 40, y: 0, content: .pane(middle)),
                RemoteTmuxLayoutNode(width: 40, height: 24, x: 80, y: 0, content: .pane(right)),
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

        func drainPendingCommands() {
            while !connection.pendingCommandKindsForTesting.isEmpty {
                connection.handleMessageForTesting(
                    .commandResult(commandNumber: 1, lines: [], isError: false)
                )
            }
        }

        func resolveFocusedSplit(createdPaneID: Int) {
            let pendingSplitIsNext = connection.pendingCommandKindsForTesting.first.map { kind in
                if case .newPane = kind {
                    return true
                }
                return false
            } ?? false
            #expect(
                pendingSplitIsNext,
                "The focused split result must remain next in the command FIFO"
            )
            guard pendingSplitIsNext else { return }
            connection.handleMessageForTesting(
                .commandResult(
                    commandNumber: 2,
                    lines: ["%\(createdPaneID)"],
                    isError: false
                )
            )
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

        harness.drainPendingCommands()
        #expect(harness.mirror.requestSplit(
            fromPane: 4,
            vertical: false,
            focusIntent: .focusCreatedPane
        ))
        harness.resolveFocusedSplit(createdPaneID: 5)
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

        harness.drainPendingCommands()
        #expect(harness.mirror.requestSplit(
            fromPane: 4,
            vertical: false,
            focusIntent: .focusCreatedPane
        ))
        harness.resolveFocusedSplit(createdPaneID: 5)
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
    func focusedSplitWaitsForThePaneIDReturnedByTmux() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let paneFour = try #require(harness.mirror.panel(forPane: 4))
        let mountedPortal = try RemoteTmuxPanePortalTestHarness()
        defer { mountedPortal.tearDown() }
        mountedPortal.mount(paneFour, frame: NSRect(x: 0, y: 0, width: 390, height: 500))
        paneFour.hostedView.setVisibleInUI(true)
        paneFour.hostedView.setActive(true)
        paneFour.hostedView.moveFocus()
        #expect(paneFour.hostedView.isSurfaceViewFirstResponder())

        harness.drainPendingCommands()
        #expect(harness.mirror.requestSplit(
            fromPane: 4,
            vertical: false,
            focusIntent: .focusCreatedPane
        ))

        // A second attached tmux client creates and activates %6 while cmux's
        // own split command is still awaiting its result block.
        harness.mirror.reconcile(
            layout: RemoteTmuxMirrorNewPaneKeyFocusTests.twoPaneLayout(left: 4, right: 6)
        )
        let paneSix = try #require(harness.mirror.panel(forPane: 6))
        mountedPortal.mount(paneSix, frame: NSRect(x: 400, y: 0, width: 390, height: 500))
        paneSix.hostedView.setVisibleInUI(true)
        paneSix.hostedView.setActive(true)
        harness.mirror.noteRemoteActivePane(6)

        #expect(
            paneFour.hostedView.isSurfaceViewFirstResponder(),
            "An unrelated pane must not consume the pending local split-focus request"
        )

        // The command reply identifies cmux's pane exactly. Only that pane may
        // complete the focus handoff when its authoritative topology arrives.
        harness.resolveFocusedSplit(createdPaneID: 5)
        harness.mirror.reconcile(
            layout: RemoteTmuxMirrorNewPaneKeyFocusTests.threePaneLayout(
                left: 4,
                middle: 6,
                right: 5
            )
        )
        let paneFive = try #require(harness.mirror.panel(forPane: 5))
        mountedPortal.mount(paneFive, frame: NSRect(x: 800, y: 0, width: 390, height: 500))
        paneFour.hostedView.setActive(false)
        paneSix.hostedView.setActive(false)
        paneFive.hostedView.setVisibleInUI(true)
        paneFive.hostedView.setActive(true)
        harness.mirror.noteRemoteActivePane(5)

        #expect(
            paneFive.hostedView.isSurfaceViewFirstResponder(),
            "The pane ID returned by split-window must own the focus handoff"
        )
    }

    @Test
    func rejectedProjectedPaneSelectionPreservesCurrentWorkspaceFocus() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let containerPaneID = try #require(
            harness.workspace.paneId(forPanelId: harness.containerPanelId)
        )
        let outerNeighbor = try #require(harness.workspace.splitPaneWithNewTerminal(
            targetPane: containerPaneID,
            orientation: .horizontal,
            insertFirst: false,
            workingDirectory: nil,
            initialInput: nil
        ))
        harness.workspace.focusPanel(outerNeighbor.id)
        #expect(harness.workspace.focusedPanelId == outerNeighbor.id)

        let projectedPane = try #require(harness.mirror.panel(forPane: 4))
        harness.writer.close()
        harness.workspace.focusPanel(projectedPane.id)

        #expect(
            harness.workspace.focusedPanelId == outerNeighbor.id,
            "A rejected select-pane must not activate the mirror container's stale active pane"
        )
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
