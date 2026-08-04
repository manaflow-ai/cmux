import AppKit
import CmuxControlSocket
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
        let terminal = try #require(fixture.source.panels[fixture.panelId] as? TerminalPanel)
        let attemptID = UUID()
        fixture.source.trackRemoteTerminalSurface(fixture.panelId)
        #expect(fixture.source.markRemoteTerminalSessionLaunching(
            surfaceId: fixture.panelId,
            terminalLifecycleID: terminal.surface.terminalLifecycleId,
            attemptID: attemptID
        ))
        fixture.source.registerReportedSurfaceTTYName("pts/21", panelId: fixture.panelId)
        let paneID = try #require(fixture.source.bonsplitController.allPaneIds.first)
        _ = try #require(fixture.source.newTerminalSurface(inPane: paneID, focus: false))

        try movePanel(fixture)

        #expect(
            TerminalController.shared.controlSurfaceReportTTY(
                workspaceID: fixture.source.id,
                requestedSurfaceID: fixture.panelId,
                ttyName: "pts/22",
                authenticatedRemoteWorkspaceID: fixture.source.id,
                terminalLifecycleID: terminal.surface.terminalLifecycleId,
                attemptID: attemptID
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

    @Test("A disconnected remote terminal cannot resolve or register another TTY")
    func disconnectedRemoteTerminalCannotResolveOrRegisterTTY() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        fixture.source.remoteConfiguration = relayConfiguration(
            destination: "source.example.invalid",
            relayPort: 64_007
        )
        let terminal = try #require(fixture.source.panels[fixture.panelId] as? TerminalPanel)
        let attemptID = UUID()
        fixture.source.trackRemoteTerminalSurface(fixture.panelId)
        #expect(fixture.source.markRemoteTerminalSessionLaunching(
            surfaceId: fixture.panelId,
            terminalLifecycleID: terminal.surface.terminalLifecycleId,
            attemptID: attemptID
        ))
        fixture.source.registerReportedSurfaceTTYName("pts/23", panelId: fixture.panelId)

        fixture.source.disconnectRemoteConnection()

        assertNoRelayTTYTarget(
            authenticatedWorkspaceID: fixture.source.id,
            ttyName: "pts/23"
        )
        #expect(
            TerminalController.shared.controlSurfaceReportTTY(
                workspaceID: fixture.source.id,
                requestedSurfaceID: fixture.panelId,
                ttyName: "pts/24",
                authenticatedRemoteWorkspaceID: fixture.source.id,
                terminalLifecycleID: terminal.surface.terminalLifecycleId,
                attemptID: attemptID
            ) == .surfaceNotFound
        )
        assertNoRelayTTYTarget(
            authenticatedWorkspaceID: fixture.source.id,
            ttyName: "pts/24"
        )
    }

    @Test("A delayed TTY report cannot revive an ended remote terminal")
    func delayedTTYReportCannotReviveEndedRemoteTerminal() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        fixture.source.remoteConfiguration = relayConfiguration(
            destination: "source.example.invalid",
            relayPort: 64_007
        )
        let terminal = try #require(fixture.source.panels[fixture.panelId] as? TerminalPanel)
        let attemptID = UUID()
        fixture.source.trackRemoteTerminalSurface(fixture.panelId)
        #expect(fixture.source.markRemoteTerminalSessionLaunching(
            surfaceId: fixture.panelId,
            terminalLifecycleID: terminal.surface.terminalLifecycleId,
            attemptID: attemptID
        ))
        fixture.source.registerReportedSurfaceTTYName("pts/25", panelId: fixture.panelId)
        #expect(
            fixture.source.markRemoteTerminalSessionEnded(
                surfaceId: fixture.panelId,
                relayPort: 64_007
            )
        )

        #expect(
            TerminalController.shared.controlSurfaceReportTTY(
                workspaceID: fixture.source.id,
                requestedSurfaceID: fixture.panelId,
                ttyName: "pts/26",
                authenticatedRemoteWorkspaceID: fixture.source.id,
                terminalLifecycleID: terminal.surface.terminalLifecycleId,
                attemptID: attemptID
            ) == .surfaceNotFound
        )
        assertNoRelayTTYTarget(
            authenticatedWorkspaceID: fixture.source.id,
            ttyName: "pts/26"
        )
    }

    @Test("Relay provenance survives repeated ordinary workspace moves")
    func relayTTYProvenanceSurvivesRepeatedOrdinaryWorkspaceMoves() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        fixture.source.remoteConfiguration = relayConfiguration(
            destination: "source.example.invalid",
            relayPort: 64_007
        )
        fixture.source.trackRemoteTerminalSurface(fixture.panelId)
        fixture.source.registerReportedSurfaceTTYName("pts/27", panelId: fixture.panelId)

        try movePanel(fixture)
        let secondDestination = fixture.manager.addWorkspace(select: false)
        defer {
            if fixture.manager.tabs.contains(where: { $0.id == secondDestination.id }) {
                fixture.manager.closeWorkspace(secondDestination)
            }
        }
        let transfer = try #require(
            fixture.destination.detachSurface(panelId: fixture.panelId)
        )
        let destinationPaneID = try #require(
            secondDestination.bonsplitController.allPaneIds.first
        )
        #expect(
            secondDestination.attachDetachedSurface(
                transfer,
                inPane: destinationPaneID,
                focus: false
            ) == fixture.panelId
        )

        assertRelayTTYTarget(
            authenticatedWorkspaceID: fixture.source.id,
            ttyName: "pts/27",
            expectedWorkspaceID: secondDestination.id,
            expectedSurfaceID: fixture.panelId
        )
    }

    @Test("A persistent retry after an ordinary workspace move preserves TTY proof")
    func persistentRetryAfterOrdinaryWorkspaceMovePreservesTTYProof() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let terminal = try #require(
            fixture.source.panels[fixture.panelId] as? TerminalPanel
        )
        fixture.source.remoteConfiguration = relayConfiguration(
            destination: "source.example.invalid",
            relayPort: 64_007,
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
        fixture.source.registerReportedSurfaceTTYName("pts/28", panelId: fixture.panelId)

        try movePanel(fixture)
        #expect(
            fixture.destination.markRemoteTerminalSessionLaunching(
                surfaceId: fixture.panelId,
                terminalLifecycleID: terminal.surface.terminalLifecycleId,
                attemptID: UUID()
            )
        )

        assertRelayTTYTarget(
            authenticatedWorkspaceID: fixture.source.id,
            ttyName: "pts/28",
            expectedWorkspaceID: fixture.destination.id,
            expectedSurfaceID: fixture.panelId
        )
    }

    @Test("The relay stamps its owner onto TTY reports")
    func relayTTYReportProvenanceOverridesSpoofedWorkspace() throws {
        let authenticatedWorkspaceID = UUID()
        let spoofedWorkspaceID = UUID()
        let request: [String: Any] = [
            "id": "relay-tty-report",
            "method": "surface.report_tty",
            "params": [
                "workspace_id": spoofedWorkspaceID.uuidString,
                "surface_id": UUID().uuidString,
                "tty_name": "pts/29",
                "_cmux_remote_workspace_id": spoofedWorkspaceID.uuidString,
            ],
        ]
        let commandLine = try JSONSerialization.data(withJSONObject: request)

        let rewritten = WorkspaceRemoteRelayCommandRewriter(
            remoteWorkspaceID: authenticatedWorkspaceID,
            remoteRelayTokenHex: String(repeating: "a", count: 64)
        ).rewriteRemoteRelayCommandLine(
            commandLine,
            workspaceAliases: [:],
            surfaceAliases: [:]
        )
        let rewrittenRequest = try #require(
            JSONSerialization.jsonObject(with: rewritten) as? [String: Any]
        )
        let params = try #require(rewrittenRequest["params"] as? [String: Any])

        #expect(
            params["_cmux_remote_workspace_id"] as? String
                == authenticatedWorkspaceID.uuidString
        )
    }

    @Test("Relay TTY reports require the authenticated owner and current attempt")
    func relayTTYReportsRejectSpoofedOwnerAndStaleAttempt() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        fixture.source.remoteConfiguration = relayConfiguration(
            destination: "source.example.invalid",
            relayPort: 64_007
        )
        fixture.destination.remoteConfiguration = relayConfiguration(
            destination: "destination.example.invalid",
            relayPort: 64_008
        )
        let sourceTerminal = try #require(
            fixture.source.panels[fixture.panelId] as? TerminalPanel
        )
        let destinationPanelID = try #require(fixture.destination.focusedPanelId)
        let destinationTerminal = try #require(
            fixture.destination.panels[destinationPanelID] as? TerminalPanel
        )
        let sourceAttemptID = UUID()
        let destinationAttemptID = UUID()
        fixture.source.trackRemoteTerminalSurface(fixture.panelId)
        fixture.destination.trackRemoteTerminalSurface(destinationPanelID)
        #expect(
            fixture.source.markRemoteTerminalSessionLaunching(
                surfaceId: fixture.panelId,
                terminalLifecycleID: sourceTerminal.surface.terminalLifecycleId,
                attemptID: sourceAttemptID
            )
        )
        #expect(
            fixture.destination.markRemoteTerminalSessionLaunching(
                surfaceId: destinationPanelID,
                terminalLifecycleID: destinationTerminal.surface.terminalLifecycleId,
                attemptID: destinationAttemptID
            )
        )
        let coordinator = ControlCommandCoordinator(context: TerminalController.shared)

        assertTTYReportRejected(coordinator.handle(ControlRequest(
            id: .string("spoofed-owner"),
            method: "surface.report_tty",
            params: [
                "workspace_id": .string(fixture.destination.id.uuidString),
                "surface_id": .string(destinationPanelID.uuidString),
                "tty_name": .string("pts/30"),
                "_cmux_remote_workspace_id": .string(fixture.source.id.uuidString),
                "terminal_lifecycle_id": .string(
                    destinationTerminal.surface.terminalLifecycleId.uuidString
                ),
                "attempt_id": .string(destinationAttemptID.uuidString),
            ]
        )))
        #expect(
            !fixture.destination.surfaceRegistry.runtimeReportedTTYSurfaceIDs
                .contains(destinationPanelID)
        )

        assertTTYReportRejected(coordinator.handle(ControlRequest(
            id: .string("stale-attempt"),
            method: "surface.report_tty",
            params: [
                "workspace_id": .string(fixture.source.id.uuidString),
                "surface_id": .string(fixture.panelId.uuidString),
                "tty_name": .string("pts/31"),
                "_cmux_remote_workspace_id": .string(fixture.source.id.uuidString),
                "terminal_lifecycle_id": .string(
                    sourceTerminal.surface.terminalLifecycleId.uuidString
                ),
                "attempt_id": .string(UUID().uuidString),
            ]
        )))
        #expect(
            !fixture.source.surfaceRegistry.runtimeReportedTTYSurfaceIDs
                .contains(fixture.panelId)
        )
    }

    @Test("A local TTY report expires when its runtime generation changes")
    func localTTYReportExpiresAfterRuntimeGenerationChanges() async throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let terminal = try #require(
            fixture.source.panels[fixture.panelId] as? TerminalPanel
        )
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
        let ttyName = try #require(await waitForControllingTTYName(for: terminal))
        fixture.source.registerReportedSurfaceTTYName(
            ttyName,
            panelId: fixture.panelId
        )
        #expect(!fixture.source.localAgentDeliveryTTYDevices.isEmpty)
        let reportedGeneration = terminal.surface.runtimeSurfaceGeneration

        terminal.surface.releaseSurfaceForTesting()

        #expect(terminal.surface.runtimeSurfaceGeneration != reportedGeneration)
        #expect(fixture.source.localAgentDeliveryTTYDevices.isEmpty)
    }

    private func relayConfiguration(
        destination: String,
        relayPort: Int,
        preserveAfterTerminalExit: Bool = false
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
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: preserveAfterTerminalExit,
            persistentDaemonSlot: preserveAfterTerminalExit ? "relay-tty-test" : nil
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

    private func assertTTYReportRejected(_ result: ControlCallResult?) {
        guard case .err(let code, _, _) = result else {
            Issue.record("Expected relay TTY report rejection, got \(String(describing: result))")
            return
        }
        #expect(code == "not_found")
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
}
