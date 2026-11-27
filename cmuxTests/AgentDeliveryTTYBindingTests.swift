import AppKit
import CmuxCore
import CmuxSidebar
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif
extension AgentNotificationRegressionTests {
    @Test("Local PID bindings use the live Ghostty TTY without a shell report")
    func localTTYBindingsUseLiveGhosttyTTYWithoutShellReport() async throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let terminal = try #require(fixture.source.panels[fixture.panelId] as? TerminalPanel)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let contentView = try #require(window.contentView)
        let hostedView = terminal.hostedView
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)
        window.orderFront(nil)
        window.displayIfNeeded()
        defer {
            hostedView.removeFromSuperview()
            window.orderOut(nil)
        }
        let liveTTYName = try await TerminalControllingTTYWaiter().wait(
            for: terminal,
            timeout: .seconds(15)
        )
        let liveTTYDevice = try #require(
            CmuxTopProcessSnapshot.deviceIdentifier(forTTYName: liveTTYName)
        )
        fixture.source.restorePersistedSurfaceTTYName(nil, panelId: fixture.panelId)
        #expect(fixture.source.surfaceTTYNames[fixture.panelId] == nil)
        #expect(
            fixture.source.localAgentDeliveryTTYDevices.contains {
                $0.surfaceId == fixture.panelId && $0.ttyDevice == liveTTYDevice
            },
            "A live terminal must remain PID-routable when shell integration is disabled"
        )
    }
    @Test("Generic TTY metadata changes do not become runtime reports")
    func genericTTYMetadataDoesNotBecomeRuntimeReport() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        workspace.remoteConfiguration = deliveryTargetRemoteConfiguration()
        workspace.trackRemoteTerminalSurface(panelID)
        workspace.registerReportedSurfaceTTYName("pts/0", panelId: panelID)
        #expect(workspace.agentDeliveryTarget(forReportedTTYName: "pts/0") != nil)
        workspace.surfaceTTYNames[panelID] = "pts/1"
        #expect(
            workspace.agentDeliveryTarget(forReportedTTYName: "pts/1") == nil,
            "Only an explicit report_tty call may establish runtime provenance"
        )
    }
    @Test("Relay TTY resolution follows a freshly reported surface into a Dock")
    func relayTTYResolutionFollowsFreshReportIntoDock() throws {
        let fixture = try makeFixture()
        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        defer {
            dock.closeAllPanels()
            fixture.restore()
        }
        fixture.source.remoteConfiguration = deliveryTargetRemoteConfiguration()
        let terminal = try #require(fixture.source.panels[fixture.panelId] as? TerminalPanel)
        let attemptID = UUID()
        fixture.source.trackRemoteTerminalSurface(fixture.panelId)
        #expect(fixture.source.markRemoteTerminalSessionLaunching(
            surfaceId: fixture.panelId,
            terminalLifecycleID: terminal.surface.terminalLifecycleId,
            attemptID: attemptID
        ))
        #expect(
            TerminalController.shared.controlSurfaceReportTTY(
                workspaceID: fixture.source.id,
                requestedSurfaceID: fixture.panelId,
                ttyName: "pts/2",
                authenticatedRemoteWorkspaceID: fixture.source.id,
                terminalLifecycleID: terminal.surface.terminalLifecycleId,
                attemptID: attemptID
            ) == .recorded(surfaceID: fixture.panelId)
        )
        try moveRemoteSurface(fixture, into: dock)
        assertRelayTTYTarget(
            authenticatedWorkspaceID: fixture.source.id,
            ttyName: "pts/2",
            expectedWorkspaceID: dock.workspaceId,
            expectedSurfaceID: fixture.panelId
        )
    }
    @Test("Relay TTY resolution does not disclose a surface moved from another owner")
    func relayTTYResolutionRejectsMovedSurfaceForNewOwner() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let configuration = deliveryTargetRemoteConfiguration(relayPort: 64_007)
        fixture.source.remoteConfiguration = configuration
        fixture.destination.remoteConfiguration = configuration
        fixture.source.trackRemoteTerminalSurface(fixture.panelId)
        fixture.source.registerReportedSurfaceTTYName("pts/4", panelId: fixture.panelId)
        try movePanel(fixture)
        assertNoRelayTTYTarget(
            authenticatedWorkspaceID: fixture.destination.id,
            ttyName: "pts/4",
        )
    }
    @Test("Relay TTY resolution follows a surface into a newly created ordinary workspace")
    func relayTTYResolutionFollowsSurfaceIntoNewOrdinaryWorkspace() throws {
        let fixture = try makeFixture()
        var destinationWorkspaceID: UUID?
        defer {
            if let destinationWorkspaceID,
               let destination = fixture.manager.tabs.first(where: { $0.id == destinationWorkspaceID }) {
                fixture.manager.closeWorkspace(destination)
            }
            fixture.restore()
        }
        fixture.source.remoteConfiguration = deliveryTargetRemoteConfiguration(relayPort: 64_007)
        fixture.source.trackRemoteTerminalSurface(fixture.panelId)
        fixture.source.registerReportedSurfaceTTYName("pts/7", panelId: fixture.panelId)
        let paneID = try #require(fixture.source.bonsplitController.allPaneIds.first)
        _ = try #require(fixture.source.newTerminalSurface(inPane: paneID, focus: false))

        let move = try #require(fixture.appDelegate.moveSurfaceToNewWorkspace(
            panelId: fixture.panelId,
            focus: false,
            focusWindow: false
        ))
        destinationWorkspaceID = move.destinationWorkspaceId
        let destination = try #require(
            fixture.manager.tabs.first(where: { $0.id == move.destinationWorkspaceId })
        )
        #expect(!destination.isRemoteWorkspace)

        assertRelayTTYTarget(
            authenticatedWorkspaceID: fixture.source.id,
            ttyName: "pts/7",
            expectedWorkspaceID: destination.id,
            expectedSurfaceID: fixture.panelId
        )
    }

    @Test("A runtime TTY report refreshes a remote surface already in a Dock")
    func runtimeTTYReportRefreshesRemoteSurfaceAlreadyInDock() throws {
        let fixture = try makeFixture()
        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        defer {
            dock.closeAllPanels()
            fixture.restore()
        }
        fixture.source.remoteConfiguration = deliveryTargetRemoteConfiguration()
        let terminal = try #require(fixture.source.panels[fixture.panelId] as? TerminalPanel)
        let attemptID = UUID()
        fixture.source.trackRemoteTerminalSurface(fixture.panelId)
        #expect(fixture.source.markRemoteTerminalSessionLaunching(
            surfaceId: fixture.panelId,
            terminalLifecycleID: terminal.surface.terminalLifecycleId,
            attemptID: attemptID
        ))
        try moveRemoteSurface(fixture, into: dock)

        #expect(
            TerminalController.shared.controlSurfaceReportTTY(
                workspaceID: fixture.source.id,
                requestedSurfaceID: fixture.panelId,
                ttyName: "pts/3",
                authenticatedRemoteWorkspaceID: fixture.source.id,
                terminalLifecycleID: terminal.surface.terminalLifecycleId,
                attemptID: attemptID
            ) == .recorded(surfaceID: fixture.panelId)
        )
        assertRelayTTYTarget(
            authenticatedWorkspaceID: fixture.source.id,
            ttyName: "pts/3",
            expectedWorkspaceID: dock.workspaceId,
            expectedSurfaceID: fixture.panelId
        )
    }

    @Test("An ended workspace remote terminal cannot resolve a reused TTY")
    func endedWorkspaceRemoteTerminalDoesNotResolveReportedTTY() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        workspace.remoteConfiguration = deliveryTargetRemoteConfiguration(relayPort: 64_007)
        workspace.trackRemoteTerminalSurface(panelID)
        workspace.registerReportedSurfaceTTYName("pts/0", panelId: panelID)
        #expect(workspace.agentDeliveryTarget(forReportedTTYName: "pts/0") != nil)

        #expect(
            workspace.markRemoteTerminalSessionEnded(
                surfaceId: panelID,
                relayPort: 64_007
            )
        )

        #expect(
            workspace.agentDeliveryTarget(forReportedTTYName: "pts/0") == nil,
            "A TTY report from an ended lifecycle must not identify a future remote process"
        )
    }

    @Test("An ended Dock remote terminal cannot resolve a reused TTY")
    func endedDockRemoteTerminalDoesNotResolveReportedTTY() throws {
        let fixture = try makeFixture()
        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        defer {
            dock.closeAllPanels()
            fixture.restore()
        }
        fixture.source.remoteConfiguration = deliveryTargetRemoteConfiguration(relayPort: 64_007)
        fixture.source.trackRemoteTerminalSurface(fixture.panelId)
        fixture.source.registerReportedSurfaceTTYName("pts/0", panelId: fixture.panelId)
        try moveRemoteSurface(fixture, into: dock)
        assertRelayTTYTarget(
            authenticatedWorkspaceID: fixture.source.id,
            ttyName: "pts/0",
            expectedWorkspaceID: dock.workspaceId,
            expectedSurfaceID: fixture.panelId
        )

        #expect(
            dock.markRemoteTerminalSessionEnded(
                panelId: fixture.panelId,
                relayPort: 64_007
            )
        )

        assertNoRelayTTYTarget(
            authenticatedWorkspaceID: fixture.source.id,
            ttyName: "pts/0"
        )
    }

    @Test("A workspace reconnect invalidates the previous attempt's TTY report")
    func workspaceReconnectInvalidatesReportedTTY() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let terminal = try #require(workspace.panels[panelID] as? TerminalPanel)
        workspace.remoteConfiguration = deliveryTargetRemoteConfiguration()
        workspace.trackRemoteTerminalSurface(panelID)
        #expect(
            workspace.markRemoteTerminalSessionLaunching(
                surfaceId: panelID,
                terminalLifecycleID: terminal.surface.terminalLifecycleId,
                attemptID: UUID()
            )
        )
        workspace.registerReportedSurfaceTTYName("pts/0", panelId: panelID)
        #expect(workspace.agentDeliveryTarget(forReportedTTYName: "pts/0") != nil)

        #expect(
            workspace.markRemoteTerminalSessionLaunching(
                surfaceId: panelID,
                terminalLifecycleID: terminal.surface.terminalLifecycleId,
                attemptID: UUID()
            )
        )

        #expect(
            workspace.agentDeliveryTarget(forReportedTTYName: "pts/0") == nil,
            "A new attach attempt must wait for its own report_tty before becoming routable"
        )
    }

    @Test("A persistent workspace bridge retry preserves the remote PTY's TTY report")
    func persistentWorkspaceRetryPreservesReportedTTY() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let terminal = try #require(workspace.panels[panelID] as? TerminalPanel)
        workspace.remoteConfiguration = deliveryTargetRemoteConfiguration(
            preserveAfterTerminalExit: true
        )
        workspace.trackRemoteTerminalSurface(panelID)
        #expect(
            workspace.markRemoteTerminalSessionLaunching(
                surfaceId: panelID,
                terminalLifecycleID: terminal.surface.terminalLifecycleId,
                attemptID: UUID()
            )
        )
        workspace.registerReportedSurfaceTTYName("pts/5", panelId: panelID)

        #expect(
            workspace.markRemoteTerminalSessionLaunching(
                surfaceId: panelID,
                terminalLifecycleID: terminal.surface.terminalLifecycleId,
                attemptID: UUID()
            )
        )

        #expect(
            workspace.agentDeliveryTarget(forReportedTTYName: "pts/5") != nil,
            "A bridge retry for the same persistent PTY must keep its report-once shell proof"
        )
    }

    @Test("A Dock reconnect invalidates the previous attempt's TTY report")
    func dockReconnectInvalidatesReportedTTY() throws {
        let fixture = try makeFixture()
        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        defer {
            dock.closeAllPanels()
            fixture.restore()
        }
        let terminal = try #require(fixture.source.panels[fixture.panelId] as? TerminalPanel)
        fixture.source.remoteConfiguration = deliveryTargetRemoteConfiguration()
        fixture.source.trackRemoteTerminalSurface(fixture.panelId)
        fixture.source.registerReportedSurfaceTTYName("pts/0", panelId: fixture.panelId)
        try moveRemoteSurface(fixture, into: dock)
        let attemptID = UUID()
        #expect(
            dock.markRemoteTerminalSessionLaunching(
                panelId: fixture.panelId,
                terminalLifecycleID: terminal.surface.terminalLifecycleId,
                attemptID: attemptID
            )
        )
        #expect(
            TerminalController.shared.controlSurfaceReportTTY(
                workspaceID: fixture.source.id,
                requestedSurfaceID: fixture.panelId,
                ttyName: "pts/0",
                authenticatedRemoteWorkspaceID: fixture.source.id,
                terminalLifecycleID: terminal.surface.terminalLifecycleId,
                attemptID: attemptID
            ) == .recorded(surfaceID: fixture.panelId)
        )
        assertRelayTTYTarget(
            authenticatedWorkspaceID: fixture.source.id,
            ttyName: "pts/0",
            expectedWorkspaceID: dock.workspaceId,
            expectedSurfaceID: fixture.panelId
        )

        #expect(
            dock.markRemoteTerminalSessionLaunching(
                panelId: fixture.panelId,
                terminalLifecycleID: terminal.surface.terminalLifecycleId,
                attemptID: UUID()
            )
        )

        assertNoRelayTTYTarget(
            authenticatedWorkspaceID: fixture.source.id,
            ttyName: "pts/0"
        )
    }

    @Test("A persistent Dock bridge retry preserves the remote PTY's TTY report")
    func persistentDockRetryPreservesReportedTTY() throws {
        let fixture = try makeFixture()
        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        defer {
            dock.closeAllPanels()
            fixture.restore()
        }
        let terminal = try #require(fixture.source.panels[fixture.panelId] as? TerminalPanel)
        fixture.source.remoteConfiguration = deliveryTargetRemoteConfiguration(
            preserveAfterTerminalExit: true
        )
        fixture.source.trackRemoteTerminalSurface(fixture.panelId)
        #expect(
            fixture.source.markRemoteTerminalSessionLaunching(
                surfaceId: fixture.panelId,
                terminalLifecycleID: terminal.surface.terminalLifecycleId,
                attemptID: UUID()
            )
        )
        fixture.source.registerReportedSurfaceTTYName("pts/6", panelId: fixture.panelId)
        try moveRemoteSurface(fixture, into: dock)

        #expect(
            dock.markRemoteTerminalSessionLaunching(
                panelId: fixture.panelId,
                terminalLifecycleID: terminal.surface.terminalLifecycleId,
                attemptID: UUID()
            )
        )

        assertRelayTTYTarget(
            authenticatedWorkspaceID: fixture.source.id,
            ttyName: "pts/6",
            expectedWorkspaceID: dock.workspaceId,
            expectedSurfaceID: fixture.panelId
        )
    }

    private func moveRemoteSurface(_ fixture: Fixture, into dock: DockSplitStore) throws {
        let transfer = try #require(fixture.source.detachSurface(panelId: fixture.panelId))
        let rootPane = try #require(dock.bonsplitController.allPaneIds.first)
        #expect(
            dock.attachDetachedSurface(transfer, inPane: rootPane, focus: false)
                == fixture.panelId
        )
    }

    private func assertRelayTTYTarget(
        authenticatedWorkspaceID: UUID,
        ttyName: String,
        expectedWorkspaceID: UUID,
        expectedSurfaceID: UUID
    ) {
        var params: [String: Any] = [
            "tty_name": ttyName,
            "tty_resolution": "reported_tty",
            "_cmux_remote_workspace_id": authenticatedWorkspaceID.uuidString,
        ]
        let result: TerminalController.V2CallResult
        if let workspace = AppDelegate.shared?.workspaceFor(tabId: authenticatedWorkspaceID) {
            let previousConnectionID = workspace.activeRemoteSessionControllerID
            let connectionID = previousConnectionID ?? UUID()
            workspace.activeRemoteSessionControllerID = connectionID
            params[WorkspaceRemoteRelayCommandRewriter.connectionIDKey] = connectionID.uuidString
            result = TerminalController.shared.v2AgentResolveDeliveryTarget(params: params)
            workspace.activeRemoteSessionControllerID = previousConnectionID
        } else {
            result = TerminalController.shared.v2AgentResolveDeliveryTarget(params: params)
        }
        guard case .ok(let payload) = result,
              let target = payload as? [String: Any] else {
            Issue.record("Expected authenticated relay TTY resolution, got \(result)")
            return
        }
        #expect(target["workspace_id"] as? String == expectedWorkspaceID.uuidString)
        #expect(target["surface_id"] as? String == expectedSurfaceID.uuidString)
    }

    private func assertNoRelayTTYTarget(
        authenticatedWorkspaceID: UUID,
        ttyName: String
    ) {
        var params: [String: Any] = [
            "tty_name": ttyName,
            "tty_resolution": "reported_tty",
            "_cmux_remote_workspace_id": authenticatedWorkspaceID.uuidString,
        ]
        let result: TerminalController.V2CallResult
        if let workspace = AppDelegate.shared?.workspaceFor(tabId: authenticatedWorkspaceID) {
            let previousConnectionID = workspace.activeRemoteSessionControllerID
            let connectionID = previousConnectionID ?? UUID()
            workspace.activeRemoteSessionControllerID = connectionID
            params[WorkspaceRemoteRelayCommandRewriter.connectionIDKey] = connectionID.uuidString
            result = TerminalController.shared.v2AgentResolveDeliveryTarget(params: params)
            workspace.activeRemoteSessionControllerID = previousConnectionID
        } else {
            result = TerminalController.shared.v2AgentResolveDeliveryTarget(params: params)
        }
        guard case .err(let code, _, _) = result else {
            Issue.record("Expected ended relay TTY resolution to fail, got \(result)")
            return
        }
        #expect(code == "not_found")
    }

    /// Relay-host agent status shows without a local agent PID, but only on a
    /// relay-backed workspace and only while a live panel owns the agent.
    @Test("Relay-host agent status needs a relay and a live owning panel")
    func relayHostAgentStatusNeedsRelayAndLiveOwningPanel() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let workspace = fixture.source
        workspace.statusEntries["claude_code"] = SidebarStatusEntry(key: "claude_code", value: "Running")
        workspace.setAgentLifecycle(key: "claude_code", panelId: fixture.panelId, lifecycle: .running)
        #expect(!workspace.sidebarStatusEntriesVisibleForDisplay().contains { $0.key == "claude_code" })

        workspace.remoteConfiguration = deliveryTargetRemoteConfiguration()
        #expect(!workspace.sidebarStatusEntriesVisibleForDisplay().contains { $0.key == "claude_code" })

        workspace.remoteConfiguration = deliveryTargetRemoteConfiguration(relayPort: 64_011)
        #expect(workspace.sidebarStatusEntriesVisibleForDisplay().contains { $0.key == "claude_code" })

        _ = workspace.clearAgentLifecycle(key: "claude_code", panelId: fixture.panelId)
        #expect(!workspace.sidebarStatusEntriesVisibleForDisplay().contains { $0.key == "claude_code" })

        workspace.agentLifecycleStatesByPanelId[UUID()] = ["claude_code": .running]
        #expect(
            !workspace.sidebarStatusEntriesVisibleForDisplay().contains { $0.key == "claude_code" },
            "A closed panel's lifecycle must not keep relay status visible"
        )
    }

    /// Two relay-host agents on one pane show only the newer status, as local agents do.
    @Test("Relay-host agent status keeps only the newest agent per panel")
    func relayHostAgentStatusKeepsNewestAgentPerPanel() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let workspace = fixture.source
        workspace.remoteConfiguration = deliveryTargetRemoteConfiguration(relayPort: 64_012)
        workspace.statusEntries["claude_code"] = SidebarStatusEntry(
            key: "claude_code",
            value: "Idle",
            timestamp: Date(timeIntervalSince1970: 1_000)
        )
        workspace.statusEntries["codex"] = SidebarStatusEntry(
            key: "codex",
            value: "Running",
            timestamp: Date(timeIntervalSince1970: 2_000)
        )
        workspace.setAgentLifecycle(key: "claude_code", panelId: fixture.panelId, lifecycle: .idle)
        workspace.setAgentLifecycle(key: "codex", panelId: fixture.panelId, lifecycle: .running)

        let visibleKeys = Set(workspace.sidebarStatusEntriesVisibleForDisplay().map(\.key))
        #expect(visibleKeys.contains("codex"))
        #expect(!visibleKeys.contains("claude_code"))
    }

    /// A dropped relay clears relay-host agent status and lifecycle; other status stays.
    @Test("Relay-host agent status clears when the relay connection drops")
    func relayHostAgentStatusClearsWhenRelayDrops() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let workspace = fixture.source
        workspace.remoteConfiguration = deliveryTargetRemoteConfiguration(relayPort: 64_013)
        workspace.statusEntries["claude_code"] = SidebarStatusEntry(key: "claude_code", value: "Needs input")
        workspace.statusEntries["build"] = SidebarStatusEntry(key: "build", value: "green")
        workspace.setAgentLifecycle(key: "claude_code", panelId: fixture.panelId, lifecycle: .needsInput)

        #expect(workspace.sidebarStatusEntriesVisibleForDisplay().contains { $0.key == "claude_code" })

        workspace.applyRemoteConnectionStateUpdate(.reconnecting, detail: nil, target: "example.invalid")
        #expect(workspace.statusEntries["claude_code"] == nil)
        #expect(workspace.agentLifecycleStatesByPanelId[fixture.panelId]?["claude_code"] == nil)
        #expect(workspace.statusEntries["build"] != nil, "Non-agent status is not relay-owned")
    }

    /// Agent status saved in a snapshot does not come back on restore, so a relay
    /// workspace starts without status until the next relayed hook.
    @Test("Restored relay workspaces drop agent status from the snapshot")
    func restoredRelayWorkspaceDropsAgentStatus() throws {
        let source = Workspace()
        defer { source.teardownAllPanels() }
        source.statusEntries["claude_code"] = SidebarStatusEntry(key: "claude_code", value: "Running")
        let snapshot = source.sessionSnapshot(includeScrollback: false)
        #expect(snapshot.statusEntries.contains { $0.key == "claude_code" })

        let restored = Workspace()
        defer { restored.teardownAllPanels() }
        _ = restored.restoreSessionSnapshot(snapshot)
        restored.remoteConfiguration = deliveryTargetRemoteConfiguration(relayPort: 64_014)
        #expect(restored.statusEntries["claude_code"] == nil)
        #expect(!restored.sidebarStatusEntriesVisibleForDisplay().contains { $0.key == "claude_code" })
    }

    private func deliveryTargetRemoteConfiguration(
        relayPort: Int? = nil,
        preserveAfterTerminalExit: Bool = false
    ) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "example.invalid",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: relayPort,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: preserveAfterTerminalExit,
            persistentDaemonSlot: preserveAfterTerminalExit ? "delivery-target-test" : nil
        )
    }
}
