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

    private func parsedRequest(_ link: String) throws -> CmuxNavigationURLRequest {
        let url = try #require(URL(string: link))
        switch CmuxNavigationURLRequest.parse(url) {
        case .success(let request):
            return try #require(request)
        case .failure(let error):
            throw error
        }
    }

    @Test
    func projectedPaneNotificationStoresOpensAndPreservesRecoverableRoute() throws {
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
        let appDelegate = try #require(AppDelegate.shared)
        #expect(appDelegate.locateSurface(surfaceId: panePanel.id)?.workspaceId == harness.workspace.id)
        #expect(
            appDelegate.workspaceContainingPanel(
                panelId: panePanel.id,
                preferredWorkspaceId: harness.workspace.id
            )?.workspace === harness.workspace
        )
        let containerPanel = try #require(harness.workspace.panels[containerPanelID])
        let copiedSurfaceLink = try #require(
            WorkspaceSurfaceIdentifierClipboardText.makeSurfaceLink(
                workspace: harness.workspace,
                panelId: panePanel.id
            )
        )
        #expect(
            copiedSurfaceLink == WorkspaceSurfaceIdentifierClipboardText.makeSurfaceLink(
                workspaceId: harness.workspace.id,
                surfaceId: panePanel.id,
                stableWorkspaceId: harness.workspace.stableId,
                stableSurfaceId: containerPanel.stableSurfaceId
            )
        )
        let copiedSurfaceRequest = try parsedRequest(copiedSurfaceLink)
        #expect(
            copiedSurfaceRequest.target ==
                .surface(workspaceId: harness.workspace.id, surfaceId: panePanel.id)
        )
        #expect(copiedSurfaceRequest.stableFallbackWorkspaceId == harness.workspace.stableId)
        #expect(copiedSurfaceRequest.stableFallbackSurfaceId == containerPanel.stableSurfaceId)
        let resolver = CmuxNavigationTargetResolver(
            workspaces: [harness.workspace.cmuxNavigationDescriptor]
        )
        #expect(
            resolver.resolve(copiedSurfaceRequest) ==
                .surface(workspaceId: harness.workspace.id, panelId: containerPanelID)
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
        #expect(
            harness.workspace.terminalLinkIsRemoteTerminal(panePanel.id),
            "A projected SSH-tmux pane must remain remote at the terminal-link policy boundary"
        )
        let localOnlyPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("projected-link-\(UUID().uuidString).swift")
        try "local-only".write(to: localOnlyPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: localOnlyPath) }
        #expect(linkCoordinator.open(TerminalLinkOpenRequest(
            rawValue: localOnlyPath.path,
            sourceWorkspaceId: harness.workspace.id,
            sourcePanelId: panePanel.id,
            workingDirectory: nil
        )))
        #expect(
            externallyOpenedURLs.last == localOnlyPath,
            "Remote transcript paths must fall back externally instead of opening the Mac-local file in cmux"
        )

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
        guard case .delivered(
            let workspaceID,
            let surfaceID,
            let windowID,
            let notificationID
        ) = result else {
            Issue.record("Expected a delivered notification, got \(result)")
            return
        }
        #expect(workspaceID == harness.workspace.id)
        #expect(surfaceID == panePanel.id)
        #expect(windowID == harness.windowID)
        #expect(notificationID != nil)

        let notification = try #require(
            TerminalNotificationStore.shared.notifications.first(where: {
                $0.tabId == harness.workspace.id && $0.surfaceId == panePanel.id
            }),
            "A delivered projected-pane notification must actually enter the store"
        )
        #expect(notification.id == notificationID)
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
        harness.splitMakingPaneFiveActive()
        #expect(mirror.activePaneId == 5)

        let openResult = TerminalController.shared.controlNotificationOpen(id: notification.id)
        guard case .opened = openResult else {
            Issue.record("Expected the projected-pane notification to open, got \(openResult)")
            return
        }
        #expect(harness.workspace.focusedPanelId == containerPanelID)
        #expect(
            TerminalNotificationStore.shared.notifications
                .first(where: { $0.id == notification.id })?.isRead == false,
            "Projected-pane notifications must remain unread until tmux confirms the requested pane"
        )
        harness.writer.close()
        let commands = try #require(String(
            bytes: try harness.pipe.fileHandleForReading.readToEnd() ?? Data(),
            encoding: .utf8
        ))
        let selectCommands = commands.split(separator: "\n").filter {
            $0.hasPrefix("select-pane ")
        }
        #expect(selectCommands.last?.contains("-t @2.%4") == true)
        harness.connection.handleMessageForTesting(
            .commandResult(commandNumber: 3, lines: [], isError: false)
        )
        harness.connection.handleMessageForTesting(
            .windowPaneChanged(windowId: 2, paneId: 4)
        )
        #expect(mirror.activePaneId == 4)
        #expect(TerminalNotificationStore.shared.notifications
            .first(where: { $0.id == notification.id })?.isRead == true)

        appDelegate.unregisterMainWindowContextForTesting(windowId: harness.windowID)
        #expect(
            appDelegate.recoverableMainWindowRoute(windowId: harness.windowID)?.tabManager
                === harness.manager
        )
        appDelegate.retireInactiveRecoverableMainWindowRoutes(
            reason: "remote-tmux-notification-lifecycle-test"
        )
        #expect(
            appDelegate.recoverableMainWindowRoute(windowId: harness.windowID)?.tabManager
                === harness.manager
        )
    }

    @Test
    func rejectedProjectedNotificationFocusRollsBackAndStaysUnread() throws {
        TerminalNotificationStore.shared.clearAll()
        let harness = try Harness()
        defer { harness.tearDown() }
        try harness.publishSinglePane()
        harness.splitMakingPaneFiveActive()

        let sessionMirror = try #require(harness.workspace.remoteTmuxSessionMirror)
        let containerPanelID = try #require(sessionMirror.panelIdByWindow[2])
        let mirror = try #require(
            harness.workspace.remoteTmuxWindowMirror(forPanelId: containerPanelID)
        )
        let paneFour = try #require(mirror.panel(forPane: 4))
        #expect(mirror.activePaneId == 5)

        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: harness.workspace.id,
            surfaceID: paneFour.id,
            paneID: nil
        )
        let result = TerminalController.shared.controlNotificationCreateForSurface(
            routing: routing,
            surfaceID: paneFour.id,
            title: "Rejected focus",
            subtitle: "",
            body: "Body"
        )
        guard case .delivered = result else {
            Issue.record("Expected projected notification delivery, got \(result)")
            return
        }
        let notification = try #require(
            TerminalNotificationStore.shared.notifications.first(where: {
                $0.tabId == harness.workspace.id && $0.surfaceId == paneFour.id
            })
        )

        let openResult = TerminalController.shared.controlNotificationOpen(id: notification.id)
        guard case .opened = openResult else {
            Issue.record("Expected projected notification open, got \(openResult)")
            return
        }
        #expect(mirror.activePaneId == 4, "The accepted request should route input optimistically")
        #expect(TerminalNotificationStore.shared.notifications
            .first(where: { $0.id == notification.id })?.isRead == false)

        harness.connection.handleMessageForTesting(
            .commandResult(
                commandNumber: 3,
                lines: ["can't find pane: %4"],
                isError: true
            )
        )

        #expect(mirror.activePaneId == 5, "A rejected request must restore the previous pane")
        #expect(TerminalNotificationStore.shared.notifications
            .first(where: { $0.id == notification.id })?.isRead == false)
    }

    @Test
    func projectedPaneForkRoutesCommandThroughRemoteTmuxOwner() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        try harness.publishSinglePane()

        let sessionMirror = try #require(harness.workspace.remoteTmuxSessionMirror)
        let containerPanelID = try #require(sessionMirror.panelIdByWindow[2])
        let mirror = try #require(
            harness.workspace.remoteTmuxWindowMirror(forPanelId: containerPanelID)
        )
        let panePanel = try #require(mirror.panel(forPane: 4))
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: "/tmp/remote fork",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/opt/homebrew/bin/claude",
                arguments: ["/opt/homebrew/bin/claude"],
                workingDirectory: "/tmp/remote fork",
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )
        harness.workspace.setRestoredAgentSnapshotForTesting(
            snapshot,
            panelId: panePanel.id
        )

        #expect(await harness.workspace.forkAgentConversationFromContextMenu(
            fromPanelId: panePanel.id,
            destination: .newTab
        ))

        harness.writer.close()
        let commands = try #require(String(
            bytes: try harness.pipe.fileHandleForReading.readToEnd() ?? Data(),
            encoding: .utf8
        ))
        let forkCommand = try #require(
            commands.split(separator: "\n").last(where: { $0.hasPrefix("new-window ") })
        )
        #expect(forkCommand.contains("claude"))
        #expect(forkCommand.contains("--fork-session"))
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

    @Test
    func projectedPaneNotificationFlashTargetsWorkspaceContainer() throws {
        let defaults = UserDefaults.standard
        let originalExperimentEnabled = defaults.object(
            forKey: TmuxOverlayExperimentSettings.enabledKey
        )
        let originalExperimentTarget = defaults.object(
            forKey: TmuxOverlayExperimentSettings.targetKey
        )
        let originalPaneFlashEnabled = defaults.object(
            forKey: NotificationPaneFlashSettings.enabledKey
        )
        defer {
            restoreDefault(
                originalExperimentEnabled,
                key: TmuxOverlayExperimentSettings.enabledKey
            )
            restoreDefault(
                originalExperimentTarget,
                key: TmuxOverlayExperimentSettings.targetKey
            )
            restoreDefault(
                originalPaneFlashEnabled,
                key: NotificationPaneFlashSettings.enabledKey
            )
        }
        defaults.set(true, forKey: TmuxOverlayExperimentSettings.enabledKey)
        defaults.set(
            TmuxOverlayExperimentTarget.bonsplitPane.rawValue,
            forKey: TmuxOverlayExperimentSettings.targetKey
        )
        defaults.set(true, forKey: NotificationPaneFlashSettings.enabledKey)

        let harness = try Harness()
        defer { harness.tearDown() }
        try harness.publishSinglePane()

        let sessionMirror = try #require(harness.workspace.remoteTmuxSessionMirror)
        let containerPanelID = try #require(sessionMirror.panelIdByWindow[2])
        let mirror = try #require(
            harness.workspace.remoteTmuxWindowMirror(forPanelId: containerPanelID)
        )
        let panePanel = try #require(mirror.panel(forPane: 4))
        let appDelegate = try #require(AppDelegate.shared)
        let previousToken = harness.workspace.tmuxWorkspaceFlashToken

        #expect(appDelegate.routeNotificationAttentionFlash(
            workspaceID: harness.workspace.id,
            panelID: panePanel.id,
            reason: .notificationArrival
        ))
        #expect(harness.workspace.tmuxWorkspaceFlashToken == previousToken + 1)
        #expect(harness.workspace.tmuxWorkspaceFlashPanelId == containerPanelID)
        #expect(harness.workspace.tmuxWorkspaceFlashReason == .notificationArrival)
    }

    private func restoreDefault(_ value: Any?, key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
