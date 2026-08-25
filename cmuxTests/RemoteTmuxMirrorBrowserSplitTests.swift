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

        #expect(harness.workspace.closePanel(browser.id, force: true))
        #expect(harness.waitUntil { harness.workspace.remoteTmuxSessionBrowserPanelId == nil })

        let replacement = try #require(harness.workspace.openRemoteTmuxSessionBrowser(focus: false))
        #expect(replacement.id != browser.id)
        #expect(harness.workspace.remoteTmuxSessionBrowserPanelId == replacement.id)
        let replacementPaneId = try #require(harness.workspace.paneId(forPanelId: replacement.id))
        #expect(harness.workspace.remoteTmuxWindowsTargetPaneId() != replacementPaneId)
    }

    @Test func closingTrackedBrowserKeepsSiblingAsSessionBrowser() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        let first = try #require(harness.workspace.openRemoteTmuxSessionBrowser(focus: false))
        let browserPaneId = try #require(harness.workspace.paneId(forPanelId: first.id))
        let sibling = try #require(
            harness.workspace.newBrowserSurface(inPane: browserPaneId, focus: false)
        )
        let panelCount = harness.workspace.panels.count

        #expect(harness.workspace.closePanel(first.id, force: true))
        #expect(harness.waitUntil {
            harness.workspace.remoteTmuxSessionBrowserPanelId == sibling.id
        })

        let reused = try #require(harness.workspace.openRemoteTmuxSessionBrowser(focus: false))
        #expect(reused.id == sibling.id)
        #expect(harness.workspace.panels.count == panelCount - 1)
    }

    @MainActor
    private struct Harness {
        let appDelegate: AppDelegate
        let windowId: UUID
        let workspace: Workspace
        let sourcePanelId: UUID
        let wasBrowserDisabled: Bool

        init() throws {
            let previousBrowserDisabled = BrowserAvailabilitySettings.isDisabled()
            let app = try #require(AppDelegate.shared)
            let createdWindowId = app.createMainWindow()
            let createdWorkspace: Workspace
            let createdSourcePanelId: UUID
            do {
                let manager = try #require(app.tabManagerFor(windowId: createdWindowId))
                createdWorkspace = try #require(manager.selectedWorkspace)
                createdSourcePanelId = try #require(createdWorkspace.focusedPanelId)
            } catch {
                Self.closeWindow(createdWindowId)
                throw error
            }
            wasBrowserDisabled = previousBrowserDisabled
            appDelegate = app
            windowId = createdWindowId
            workspace = createdWorkspace
            sourcePanelId = createdSourcePanelId
            BrowserAvailabilitySettings.setDisabled(false)
            workspace.isRemoteTmuxMirror = true
            workspace.authenticateRemoteTmuxWindowsPane()
        }

        func tearDown() {
            workspace.isRemoteTmuxMirror = false
            Self.closeWindow(windowId)
            BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled)
        }

        func waitUntil(
            timeout: TimeInterval = 2,
            _ predicate: () -> Bool
        ) -> Bool {
            let deadline = Date(timeIntervalSinceNow: timeout)
            while !predicate(), Date() < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            }
            return predicate()
        }

        private static func closeWindow(_ windowId: UUID) {
            let identifier = "cmux.main.\(windowId.uuidString)"
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == identifier }) else { return }
            window.performClose(nil)
            let deadline = Date(timeIntervalSinceNow: 2)
            while NSApp.windows.contains(where: { $0.identifier?.rawValue == identifier }),
                  Date() < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            }
        }
    }
}
