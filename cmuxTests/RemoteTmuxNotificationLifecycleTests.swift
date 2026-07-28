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
            drainPendingCommands(paneRectLines: ["%4 0 0 80 24 1 off :0 \"host\""])
        }

        func splitMakingPaneFiveActive() {
            connection.handleMessageForTesting(.layoutChange(
                windowId: 2,
                layout: "beef,120x40,0,0{60x40,0,0,4,59x40,61,0,5}",
                visibleLayout: nil,
                zoomed: false
            ))
            drainPendingCommands(paneRectLines: [
                "%4 0 0 60 40 0 off :0 \"host\"",
                "%5 61 0 59 40 1 off :1 \"host\"",
            ])
            connection.handleMessageForTesting(.windowPaneChanged(windowId: 2, paneId: 5))
        }

        func removePaneFive() {
            connection.handleMessageForTesting(.layoutChange(
                windowId: 2,
                layout: "beef,80x24,0,0,4",
                visibleLayout: nil,
                zoomed: false
            ))
            drainPendingCommands(paneRectLines: ["%4 0 0 80 24 1 off :0 \"host\""])
            connection.handleMessageForTesting(.windowPaneChanged(windowId: 2, paneId: 4))
        }

        private func drainPendingCommands(paneRectLines: [String]) {
            while let kind = connection.pendingCommandKindsForTesting.first {
                let lines: [String]
                if case .paneRects = kind {
                    lines = paneRectLines
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
            AppDelegate.shared?.forgetRecoverableMainWindowRoute(windowId: windowID)
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
        #expect(mirror.surfaceIDsInLayoutOrder == [panePanel.id])
        #expect(
            harness.workspace.forkAgentConversationContextMenuAvailability(
                forPanelId: panePanel.id
            ) != .notTerminalPanel
        )
        let containerPanel = try #require(harness.workspace.panels[containerPanelID])
        let appDelegate = try #require(AppDelegate.shared)
        #expect(appDelegate.locateSurface(surfaceId: panePanel.id)?.workspaceId == harness.workspace.id)
        #expect(
            appDelegate.workspaceContainingPanel(
                panelId: panePanel.id,
                preferredWorkspaceId: harness.workspace.id
            )?.workspace === harness.workspace
        )
        #expect(
            WorkspaceSurfaceIdentifierClipboardText.makeSurfaceLink(
                workspace: harness.workspace,
                panelId: panePanel.id
            ) == WorkspaceSurfaceIdentifierClipboardText.makeSurfaceLink(
                workspaceId: harness.workspace.stableId,
                surfaceId: containerPanel.stableSurfaceId
            )
        )

        let defaultsName = "remote-tmux-projected-link-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.removePersistentDomain(forName: defaultsName)
        defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)
        defaults.set(true, forKey: BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey)
        var resolvedProjectedContainer = false
        var externallyOpenedURLs: [URL] = []
        let linkCoordinator = TerminalLinkOpenCoordinator(
            defaults: defaults,
            containerResolver: { preferredWorkspaceID, sourcePanelID in
                guard let sourcePanelID else { return nil }
                let owner = AppDelegate.shared?.workspaceContainingPanel(
                    panelId: sourcePanelID,
                    preferredWorkspaceId: preferredWorkspaceID
                )
                resolvedProjectedContainer = owner?.workspace === harness.workspace
                return owner?.workspace
            },
            externalOpen: {
                externallyOpenedURLs.append($0)
                return true
            },
            deferOperation: { $0() }
        )
        let projectedURL = try #require(URL(string: "https://example.com/projected-pane"))
        #expect(linkCoordinator.open(TerminalLinkOpenRequest(
            rawValue: projectedURL.absoluteString,
            sourceWorkspaceId: harness.workspace.id,
            sourcePanelId: panePanel.id,
            workingDirectory: nil
        )))
        #expect(resolvedProjectedContainer)
        #expect(externallyOpenedURLs == [projectedURL])

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
        #expect(notification.panelId == containerPanelID)
        #expect(TerminalNotificationStore.shared.hasVisibleNotificationIndicator(
            forTabId: harness.workspace.id,
            surfaceId: panePanel.id
        ))
        #expect(TerminalNotificationStore.shared.hasVisibleNotificationIndicator(
            forTabId: harness.workspace.id,
            surfaceId: containerPanelID
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

        appDelegate.unregisterMainWindowContextForTesting(windowId: harness.windowID)
        #expect(
            appDelegate.recoverableMainWindowRoute(windowId: harness.windowID)?.tabManager
                === harness.manager
        )
        appDelegate.retireRecoverableMainWindowRoutesWithoutRegisteredTerminalSurfaces(
            reason: "remote-tmux-notification-lifecycle-test"
        )
        #expect(
            appDelegate.recoverableMainWindowRoute(windowId: harness.windowID)?.tabManager
                === harness.manager
        )
    }

    @Test
    func removingProjectedPaneClearsItsNotifications() throws {
        let store = TerminalNotificationStore.shared
        store.clearAll()
        let harness = try Harness()
        defer { harness.tearDown() }
        try harness.publishSinglePane()
        harness.splitMakingPaneFiveActive()

        let sessionMirror = try #require(harness.workspace.remoteTmuxSessionMirror)
        let containerPanelID = try #require(sessionMirror.panelIdByWindow[2])
        let mirror = try #require(
            harness.workspace.remoteTmuxWindowMirror(forPanelId: containerPanelID)
        )
        let retainedPanel = try #require(mirror.panel(forPane: 4))
        let removedPanel = try #require(mirror.panel(forPane: 5))
        #expect(mirror.surfaceIDsInLayoutOrder == [
            retainedPanel.id,
            removedPanel.id,
        ])
        store.addNotification(
            tabId: harness.workspace.id,
            surfaceId: removedPanel.id,
            title: "Removed pane",
            subtitle: "",
            body: "Body",
            resolvedHooks: []
        )
        #expect(store.notifications.contains {
            $0.tabId == harness.workspace.id && $0.surfaceId == removedPanel.id
        })

        harness.removePaneFive()

        #expect(mirror.panel(forPane: 5) == nil)
        #expect(!store.notifications.contains {
            $0.tabId == harness.workspace.id && $0.surfaceId == removedPanel.id
        })
        #expect(!store.hasVisibleNotificationIndicator(
            forTabId: harness.workspace.id,
            surfaceId: removedPanel.id
        ))
    }
}
