import AppKit
import Bonsplit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the per-session browser on remote tmux mirror
/// workspaces (https://github.com/manaflow-ai/cmux/pull/9861).
///
/// A tmux session maps 1:1 to a ``Workspace``, so it hosts at most one browser
/// as a top-level split beside the mirrored tmux area (never inside the mirror's
/// nested pane tree, which the mirror's `rebuild()` would reconcile away). Generic
/// browser-split / browser-surface requests on a mirror must route to that single
/// browser rather than returning nil or creating a local orphan, and the tmux
/// windows target pane must never resolve to the browser pane (else a newly
/// mirrored window would land as a tab inside the browser split).
@MainActor
@Suite(.serialized) struct RemoteTmuxMirrorBrowserSplitTests {
    @Test func openReturnsBrowserAndTracksPanelId() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        let panelsBefore = harness.workspace.panels.count
        let browser = try #require(harness.workspace.openRemoteTmuxSessionBrowser(focus: false))

        #expect(harness.workspace.panels.count == panelsBefore + 1)
        #expect(harness.workspace.remoteTmuxSessionBrowserPanelId == browser.id)
        #expect(harness.workspace.panels[browser.id] is BrowserPanel)
    }

    @Test func openIsSinglePerSession() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        let panelsBefore = harness.workspace.panels.count
        let first = try #require(harness.workspace.openRemoteTmuxSessionBrowser(focus: false))
        let countAfterFirst = harness.workspace.panels.count
        #expect(countAfterFirst == panelsBefore + 1)

        let second = try #require(harness.workspace.openRemoteTmuxSessionBrowser(focus: false))
        #expect(second.id == first.id)
        #expect(harness.workspace.panels.count == countAfterFirst)
        #expect(harness.workspace.remoteTmuxSessionBrowserPanelId == first.id)
    }

    @Test func newBrowserSurfaceRoutesToSessionBrowser() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        let paneId = try #require(harness.workspace.remoteTmuxWindowsTargetPaneId())
        let panelsBefore = harness.workspace.panels.count

        let first = try #require(harness.workspace.newBrowserSurface(inPane: paneId, focus: true))
        #expect(harness.workspace.remoteTmuxSessionBrowserPanelId == first.id)
        #expect(harness.workspace.panels.count == panelsBefore + 1)

        // A second surface request routes to the same browser, never a second one.
        let second = try #require(harness.workspace.newBrowserSurface(inPane: paneId, focus: true))
        #expect(second.id == first.id)
        #expect(harness.workspace.panels.count == panelsBefore + 1)
    }

    @Test func newBrowserSplitRoutesToSessionBrowser() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        let panelsBefore = harness.workspace.panels.count

        let first = try #require(
            harness.workspace.newBrowserSplit(
                from: harness.sourcePanelId,
                orientation: .horizontal,
                focus: false
            )
        )
        #expect(harness.workspace.remoteTmuxSessionBrowserPanelId == first.id)
        #expect(harness.workspace.panels.count == panelsBefore + 1)

        // A second split request routes to the same browser, never a second one.
        let second = try #require(
            harness.workspace.newBrowserSplit(
                from: harness.sourcePanelId,
                orientation: .horizontal,
                focus: false
            )
        )
        #expect(second.id == first.id)
        #expect(harness.workspace.panels.count == panelsBefore + 1)
    }

    @Test func windowsTargetPaneAvoidsBrowserPane() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        let browser = try #require(harness.workspace.openRemoteTmuxSessionBrowser(focus: false))
        let browserPaneId = try #require(harness.workspace.paneId(forPanelId: browser.id))
        let targetPaneId = try #require(harness.workspace.remoteTmuxWindowsTargetPaneId())

        #expect(targetPaneId != browserPaneId)
    }

    @MainActor
    private struct Harness {
        let appDelegate: AppDelegate
        let windowId: UUID
        let workspace: Workspace
        let sourcePanelId: UUID
        let wasBrowserDisabled: Bool

        init() throws {
            wasBrowserDisabled = BrowserAvailabilitySettings.isDisabled()
            BrowserAvailabilitySettings.setDisabled(false)
            appDelegate = try #require(AppDelegate.shared)
            windowId = appDelegate.createMainWindow()
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            workspace = try #require(manager.selectedWorkspace)
            sourcePanelId = try #require(workspace.focusedPanelId)
            workspace.isRemoteTmuxMirror = true
        }

        func tearDown() {
            workspace.isRemoteTmuxMirror = false
            let identifier = "cmux.main.\(windowId.uuidString)"
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == identifier }) {
                window.performClose(nil)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }
            BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled)
        }
    }
}
