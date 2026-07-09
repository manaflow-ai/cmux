import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct RemoteTmuxWindowMirrorFocusSeedTests {
    @Test func activePaneSeedsFromTmuxOnMirrorCreation() {
        let connection = RemoteTmuxControlConnection(host: RemoteTmuxHost(destination: "user@host"), sessionName: "work")
        connection.handleMessageForTesting(.windowPaneChanged(windowId: 1, paneId: 5))

        let mirror = RemoteTmuxWindowMirror(
            windowId: 1,
            panelId: UUID(),
            connection: connection,
            layout: Self.twoPaneLayout(left: 4, right: 5),
            appearance: .default,
            makePanel: { _ in nil }
        )

        #expect(mirror.activePaneId == 5)
    }

    @Test func activePaneUpdatesFromTmuxAndReseedsOnReconcile() {
        let connection = RemoteTmuxControlConnection(host: RemoteTmuxHost(destination: "user@host"), sessionName: "work")
        let mirror = RemoteTmuxWindowMirror(
            windowId: 1,
            panelId: UUID(),
            connection: connection,
            layout: Self.twoPaneLayout(left: 4, right: 5),
            appearance: .default,
            makePanel: { _ in nil }
        )
        #expect(mirror.activePaneId == 4)

        connection.handleMessageForTesting(.windowPaneChanged(windowId: 1, paneId: 5))
        mirror.setActivePane(5, fromTmux: true)
        #expect(mirror.activePaneId == 5)

        connection.handleMessageForTesting(.windowPaneChanged(windowId: 1, paneId: 8))
        mirror.reconcile(layout: Self.twoPaneLayout(left: 7, right: 8))
        #expect(mirror.activePaneId == 8)
    }

    @Test func liveWindowPaneChangedUpdatesMirrorBeforeAnotherReconcile() throws {
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        workspace.isRemoteTmuxMirror = true
        let host = RemoteTmuxHost(destination: "user@host")
        let connection = RemoteTmuxControlConnection(host: host, sessionName: "work")
        let layout = Self.twoPaneLayout(left: 4, right: 5)
        connection.windowsByID[1] = RemoteTmuxWindow(
            id: 1,
            name: "main",
            width: layout.width,
            height: layout.height,
            layout: layout
        )
        connection.windowOrder = [1]
        connection.activePaneByWindow[1] = 4

        let sessionMirror = RemoteTmuxSessionMirror(
            host: host,
            sessionName: "work",
            connection: connection,
            tabManager: manager,
            workspace: workspace
        )
        defer { sessionMirror.detachObserver() }
        let windowMirror = try #require(
            workspace.panels.keys.lazy.compactMap {
                workspace.remoteTmuxWindowMirror(forPanelId: $0)
            }.first
        )
        #expect(windowMirror.activePaneId == 4)

        connection.handleMessageForTesting(.windowPaneChanged(windowId: 1, paneId: 5))

        #expect(windowMirror.activePaneId == 5)
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
}
