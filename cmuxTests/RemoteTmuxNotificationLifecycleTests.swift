import AppKit
import CmuxControlSocket
import CmuxRemoteSession
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct RemoteTmuxNotificationLifecycleTests {
    @MainActor
    private final class Harness {
        let windowID: UUID
        let controller: RemoteTmuxController
        let host: RemoteTmuxHost
        let connection: RemoteTmuxControlConnection
        let writer: RemoteTmuxControlPipeWriter
        let pipe: Pipe
        let manager: TabManager
        let workspace: Workspace

        init() throws {
            let appDelegate = try #require(AppDelegate.shared)
            windowID = appDelegate.createMainWindow()
            manager = try #require(appDelegate.tabManagerFor(windowId: windowID))
            controller = RemoteTmuxController()
            host = RemoteTmuxHost(destination: "user@notification")
            connection = RemoteTmuxControlConnection(host: host, sessionName: "notification")
            pipe = Pipe()
            writer = RemoteTmuxControlPipeWriter(
                handle: pipe.fileHandleForWriting,
                label: "remote-tmux-notification-lifecycle-test",
                maxPendingBytes: 1 << 16,
                onFailure: {}
            )
            connection.installStdinWriterForTesting(writer)
            connection.handleMessageForTesting(.enter)
            connection.handleMessageForTesting(
                .commandResult(commandNumber: 0, lines: [], isError: false)
            )
            controller.cacheConnection(connection)
            try controller.mirrorSession(host: host, sessionName: "notification", into: manager)
            let mirroredWorkspace = manager.tabs.first(where: \.isRemoteTmuxMirror)
            workspace = try #require(mirroredWorkspace)
        }

        func publishSinglePane() throws {
            connection.handleMessageForTesting(.commandResult(
                commandNumber: 1,
                lines: ["@2 beef,80x24,0,0,4 beef,80x24,0,0,4 [] editor"],
                isError: false
            ))
            while let kind = connection.pendingCommandKindsForTesting.first {
                let lines: [String]
                if case .paneRects = kind {
                    lines = ["%4 0 0 80 24 1 off :0 \"host\""]
                } else {
                    lines = []
                }
                connection.handleMessageForTesting(.commandResult(
                    commandNumber: 2,
                    lines: lines,
                    isError: false
                ))
            }
        }

        func tearDown() {
            TerminalNotificationStore.shared.clearAll()
            controller.detach(host: host, sessionName: "notification")
            writer.close()
            try? pipe.fileHandleForReading.close()
            let identifier = "cmux.main.\(windowID.uuidString)"
            NSApp.windows.first(where: { $0.identifier?.rawValue == identifier })?.performClose(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }

    @Test
    func projectedPaneNotificationStoresOpensAndUsesLiveReadiness() throws {
        TerminalNotificationStore.shared.clearAll()
        let harness = try Harness()
        defer { harness.tearDown() }
        try harness.publishSinglePane()

        let sessionMirror = try #require(harness.workspace.remoteTmuxSessionMirror)
        let containerPanelID = try #require(sessionMirror.panelIdByWindow[2])
        let mirror = try #require(
            harness.workspace.remoteTmuxWindowMirror(forPanelId: containerPanelID)
        )
        let panePanel = try #require(mirror.panel(forPane: 4))
        #expect(harness.manager.focusedSurfaceId(for: harness.workspace.id) == panePanel.id)
        #expect(AppDelegate.shared?.agentNotificationDeliveryTarget(
            claimedTabId: harness.workspace.id,
            surfaceId: containerPanelID
        )?.surfaceId == panePanel.id)
        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: harness.workspace.id,
            surfaceID: panePanel.id,
            paneID: nil
        )

        let result = TerminalController.shared.controlNotificationCreateForSurface(
            routing: routing,
            surfaceID: panePanel.id,
            title: "Projected pane",
            subtitle: "",
            body: "Body"
        )
        #expect(result == .delivered(
            workspaceID: harness.workspace.id,
            surfaceID: panePanel.id,
            windowID: harness.windowID
        ))

        let notification = try #require(
            TerminalNotificationStore.shared.notifications.first(where: {
                $0.tabId == harness.workspace.id && $0.surfaceId == panePanel.id
            }),
            "A delivered projected-pane notification must actually enter the store"
        )
        #expect(TerminalNotificationStore.shared.hasVisibleNotificationIndicator(
            forTabId: harness.workspace.id,
            surfaceId: panePanel.id
        ))
        #expect(
            harness.manager.panelId(forSurfaceOrPanelId: panePanel.id, in: harness.workspace)
                == containerPanelID
        )
        #expect(harness.workspace.hasLoadedTerminalSurface())

        let openResult = TerminalController.shared.controlNotificationOpen(id: notification.id)
        guard case .opened = openResult else {
            Issue.record("Expected the projected-pane notification to open, got \(openResult)")
            return
        }
        #expect(harness.workspace.focusedPanelId == containerPanelID)
        #expect(mirror.activePaneId == 4)
        #expect(TerminalNotificationStore.shared.notifications
            .first(where: { $0.id == notification.id })?.isRead == true)
    }
}
