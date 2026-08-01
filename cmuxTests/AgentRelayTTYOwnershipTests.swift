import CmuxCore
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension AgentNotificationRegressionTests {
    @Test("Relay provenance does not cross remote hosts sharing a port")
    func relayTTYProvenanceDoesNotCrossRemoteHostsSharingPort() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        fixture.source.remoteConfiguration = relayConfiguration(
            destination: "source.example.invalid",
            relayPort: 64_007
        )
        fixture.destination.remoteConfiguration = relayConfiguration(
            destination: "destination.example.invalid",
            relayPort: 64_007
        )
        fixture.source.trackRemoteTerminalSurface(fixture.panelId)
        fixture.source.registerReportedSurfaceTTYName("pts/20", panelId: fixture.panelId)

        try movePanel(fixture)

        assertRelayTTYTarget(
            authenticatedWorkspaceID: fixture.source.id,
            ttyName: "pts/20",
            expectedWorkspaceID: fixture.destination.id,
            expectedSurfaceID: fixture.panelId
        )
        assertNoRelayTTYTarget(
            authenticatedWorkspaceID: fixture.destination.id,
            ttyName: "pts/20"
        )
    }

    @Test("A fresh TTY report follows a remote surface into an ordinary workspace")
    func freshRelayTTYReportFollowsSurfaceIntoOrdinaryWorkspace() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        fixture.source.remoteConfiguration = relayConfiguration(
            destination: "source.example.invalid",
            relayPort: 64_007
        )
        fixture.source.trackRemoteTerminalSurface(fixture.panelId)
        fixture.source.registerReportedSurfaceTTYName("pts/21", panelId: fixture.panelId)
        let paneID = try #require(fixture.source.bonsplitController.allPaneIds.first)
        _ = try #require(fixture.source.newTerminalSurface(inPane: paneID, focus: false))

        try movePanel(fixture)

        #expect(
            TerminalController.shared.controlSurfaceReportTTY(
                workspaceID: fixture.source.id,
                requestedSurfaceID: fixture.panelId,
                ttyName: "pts/22"
            ) == .recorded(surfaceID: fixture.panelId)
        )
        assertRelayTTYTarget(
            authenticatedWorkspaceID: fixture.source.id,
            ttyName: "pts/22",
            expectedWorkspaceID: fixture.destination.id,
            expectedSurfaceID: fixture.panelId
        )
        assertNoRelayTTYTarget(
            authenticatedWorkspaceID: fixture.source.id,
            ttyName: "pts/21"
        )
    }

    private func relayConfiguration(
        destination: String,
        relayPort: Int
    ) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: destination,
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: relayPort,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil
        )
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

    private func assertNoRelayTTYTarget(
        authenticatedWorkspaceID: UUID,
        ttyName: String
    ) {
        let result = TerminalController.shared.v2AgentResolveDeliveryTarget(params: [
            "tty_name": ttyName,
            "tty_resolution": "reported_tty",
            "_cmux_remote_workspace_id": authenticatedWorkspaceID.uuidString,
        ])
        guard case .err(let code, _, _) = result else {
            Issue.record("Expected relay TTY resolution to fail, got \(result)")
            return
        }
        #expect(code == "not_found")
    }
}
