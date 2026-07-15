import CmuxRemoteSession
import AppKit
import Bonsplit
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Reproduces the reported "new split pane shows selected (blue) but I can't type
/// anywhere until I click it" bug for a mirrored multi-pane tmux window.
///
/// A ``RemoteTmuxWindowMirror`` renders each tmux pane as a ``TerminalPanel`` in
/// its OWN Bonsplit tree — those pane panels are never inserted into the
/// workspace's Bonsplit, so the workspace-level focus machinery
/// (`Workspace.focusPanel` → `applyFirstResponderIfNeeded`, gated on
/// `matchesCurrentTerminalFocusTarget`) cannot resolve them. The only thing that
/// makes such a pane the window's first responder is a click (AppKit `mouseDown`
/// → `becomeFirstResponder`) or the equivalent `GhosttySurfaceScrollView.moveFocus()`.
///
/// When tmux splits a window, the mirror creates the new pane's panel and marks
/// it active/selected — but it never drives the first-responder path, so the new
/// pane is highlighted yet untypeable until the user clicks it. The fix drives
/// key focus for a freshly created pane the moment it becomes active, on the
/// creation event edge.
///
/// These are mirror-layer contract tests: they spy the mirror's key-focus
/// establishment seam (`onEstablishPaneKeyFocus`), which production wires to the
/// pane's `moveFocus()`. They assert the mirror DROVE key focus onto the NEW
/// pane's panel at creation — not merely that `activePaneId` moved. That makes
/// them timing-independent (no live surface, window, or run loop) and RED on the
/// buggy build, where creation only updates selection.
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

    /// A mirror wired with a key-focus spy and a real-panel factory, driving the
    /// exact 1→2 split the user hit: a window mirrored as a single zsh pane (%4),
    /// then split so %5 is created and made active.
    @MainActor
    private final class Harness {
        let manager: TabManager
        let workspace: Workspace
        let connection: RemoteTmuxControlConnection
        let mirror: RemoteTmuxWindowMirror
        /// Every pane the mirror drove key focus onto, in order.
        private(set) var focusRequests: [(paneId: Int, panelId: UUID)] = []

        init() {
            let manager = TabManager()
            let workspace = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
            workspace.isRemoteTmuxMirror = true
            let host = RemoteTmuxHost(destination: "user@newpanefocus")
            let connection = RemoteTmuxControlConnection(host: host, sessionName: "focus-map")
            let mirror = RemoteTmuxWindowMirror(
                windowId: 2,
                panelId: UUID(),
                connection: connection,
                layout: RemoteTmuxMirrorNewPaneKeyFocusTests.singlePaneLayout(4),
                makePanel: { _ in workspace.makeRemoteTmuxPanePanel(onInput: { _ in }) }
            )
            self.manager = manager
            self.workspace = workspace
            self.connection = connection
            self.mirror = mirror
            // Installed after the mirror's own init reconcile (which creates the
            // initial pane %4), so only the split's %5 — driven later — is
            // recorded, matching the repro.
            mirror.onEstablishPaneKeyFocus = { [weak self] paneId, panel in
                self?.focusRequests.append((paneId, panel.id))
            }
        }

        /// tmux splits window @2: pane %5 is created and becomes active.
        func splitMakingPaneFiveActive() {
            mirror.reconcile(layout: RemoteTmuxMirrorNewPaneKeyFocusTests.twoPaneLayout(left: 4, right: 5))
            // `%window-pane-changed`: tmux reports the freshly split pane active.
            mirror.noteRemoteActivePane(5)
        }
    }

    /// The freshly split, active pane must have key focus driven onto its own
    /// panel at creation — the mirror-layer equivalent of "typeable without a
    /// click." RED on the buggy build: creation sets `activePaneId`/selection but
    /// never touches the first-responder path.
    @Test
    func freshlySplitActivePaneDrivesKeyFocusOntoItsOwnPanel() throws {
        let harness = Harness()
        harness.splitMakingPaneFiveActive()

        #expect(harness.mirror.activePaneId == 5, "The split pane must be the active pane")
        let newPane = try #require(harness.mirror.panel(forPane: 5), "Expected the new pane's panel")

        let requestedForFive = harness.focusRequests.filter { $0.paneId == 5 }
        #expect(
            !requestedForFive.isEmpty,
            "A newly created active mirror pane must have key focus driven onto it without a click"
        )
        #expect(
            harness.focusRequests.last?.paneId == 5,
            "The newly split pane must be the final key-focus target, got \(String(describing: harness.focusRequests.last?.paneId))"
        )
        #expect(
            requestedForFive.last?.panelId == newPane.id,
            "Key focus must be pointed at the NEW pane's own panel, not another pane's"
        )
    }

    /// The fix must act on the CREATION edge only. A routine active-pane change to
    /// a pane that already exists (a co-attached client switching panes, or an
    /// echoed `%window-pane-changed`) must not re-drive key focus, or a background
    /// client's pane switch would yank the local first responder around.
    @Test
    func routineActivePaneSwitchDoesNotRedriveKeyFocus() throws {
        let harness = Harness()
        harness.splitMakingPaneFiveActive()
        let requestsAfterSplit = harness.focusRequests.count

        // Both panes already exist; switching back and forth must add no focus
        // drives (each pane's creation edge was already consumed).
        harness.mirror.noteRemoteActivePane(4)
        harness.mirror.noteRemoteActivePane(5)
        harness.mirror.setActivePane(4, fromTmux: true)

        #expect(
            harness.focusRequests.count == requestsAfterSplit,
            "Only pane creation may drive key focus; a plain active-pane switch must not"
        )
    }
}
