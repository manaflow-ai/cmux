import AppKit
import CmuxCore
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
        let liveTTYName = try #require(await waitForControllingTTYName(for: terminal))
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
        fixture.source.trackRemoteTerminalSurface(fixture.panelId)
        #expect(
            TerminalController.shared.controlSurfaceReportTTY(
                workspaceID: fixture.source.id,
                requestedSurfaceID: fixture.panelId,
                ttyName: "pts/2"
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

    @Test("A runtime TTY report refreshes a remote surface already in a Dock")
    func runtimeTTYReportRefreshesRemoteSurfaceAlreadyInDock() throws {
        let fixture = try makeFixture()
        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        defer {
            dock.closeAllPanels()
            fixture.restore()
        }
        fixture.source.remoteConfiguration = deliveryTargetRemoteConfiguration()
        fixture.source.trackRemoteTerminalSurface(fixture.panelId)
        try moveRemoteSurface(fixture, into: dock)

        #expect(
            TerminalController.shared.controlSurfaceReportTTY(
                workspaceID: fixture.source.id,
                requestedSurfaceID: fixture.panelId,
                ttyName: "pts/3"
            ) == .recorded(surfaceID: fixture.panelId)
        )
        assertRelayTTYTarget(
            authenticatedWorkspaceID: fixture.source.id,
            ttyName: "pts/3",
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

    private func waitForControllingTTYName(for terminal: TerminalPanel) async -> String? {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if let ttyName = terminal.surface.controllingTTYName() {
                return ttyName
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return terminal.surface.controllingTTYName()
    }

    private func assertRelayTTYTarget(
        authenticatedWorkspaceID: UUID,
        ttyName: String,
        expectedWorkspaceID: UUID,
        expectedSurfaceID: UUID
    ) {
        let result = TerminalController.shared.v2AgentResolveDeliveryTarget(params: [
            "tty_name": ttyName,
            "tty_resolution": "reported_tty",
            "_cmux_remote_workspace_id": authenticatedWorkspaceID.uuidString,
        ])
        guard case .ok(let payload) = result,
              let target = payload as? [String: Any] else {
            Issue.record("Expected authenticated relay TTY resolution, got \(result)")
            return
        }
        #expect(target["workspace_id"] as? String == expectedWorkspaceID.uuidString)
        #expect(target["surface_id"] as? String == expectedSurfaceID.uuidString)
    }

    private func deliveryTargetRemoteConfiguration() -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "example.invalid",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil
        )
    }
}
