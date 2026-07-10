import CmuxControlSocket
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
extension RemoteTmuxMirrorCLIObservabilityTests {
    @Test func unresolvedMirrorMutationsFailClosed() throws {
        do {
            let harness = try Harness(addPeerSurface: true, activeTmuxPaneID: nil)
            defer { harness.tearDown() }

            let result = TerminalController.shared.controlSurfaceRespawn(
                routing: harness.routing(),
                inputs: respawnInputs(surfaceID: nil)
            )

            #expect(result == .noFocusedSurface)
            #expect(harness.workspace.panels[harness.outerPanelID] != nil)
        }

        do {
            let harness = try Harness(addPeerSurface: true, activeTmuxPaneID: nil)
            defer { harness.tearDown() }

            let result = TerminalController.shared.controlSurfaceClose(
                routing: harness.routing(),
                surfaceID: nil
            )

            #expect(result == .noFocusedSurface)
            #expect(harness.workspace.panels[harness.outerPanelID] != nil)
        }
    }

    @Test func hiddenMirrorContainerRoutesThroughActiveProjection() throws {
        do {
            let harness = try Harness()
            defer { harness.tearDown() }
            let activeSurfaceID = try activeSurfaceID(in: harness)

            let send = TerminalController.shared.controlSurfaceSendText(
                routing: harness.routing(),
                surfaceID: harness.outerPanelID,
                hasSurfaceIDParam: true,
                text: "route through active pane"
            )
            #expect(send.sentSurfaceID == activeSurfaceID)
            #expect(TerminalController.shared.controlSurfaceFocus(
                routing: harness.routing(),
                surfaceID: harness.outerPanelID
            ) == .surfaceNotFound(harness.outerPanelID))
        }

        do {
            let harness = try Harness()
            defer { harness.tearDown() }

            let result = TerminalController.shared.controlSurfaceSplit(
                routing: harness.routing(),
                inputs: splitInputs(surfaceID: harness.outerPanelID)
            )

            #expect(result == .createFailed)
        }

        do {
            let harness = try Harness()
            defer { harness.tearDown() }
            let activeSurfaceID = try activeSurfaceID(in: harness)

            let result = TerminalController.shared.controlSurfaceRespawn(
                routing: harness.routing(),
                inputs: respawnInputs(surfaceID: harness.outerPanelID)
            )

            #expect(result == .respawnFailed(activeSurfaceID))
        }

        do {
            let harness = try Harness(addPeerSurface: true)
            defer { harness.tearDown() }
            let activeSurfaceID = try activeSurfaceID(in: harness)

            let result = TerminalController.shared.controlSurfaceClose(
                routing: harness.routing(),
                surfaceID: harness.outerPanelID
            )

            #expect(result == .closeFailed(activeSurfaceID))
            #expect(harness.workspace.panels[harness.outerPanelID] != nil)
        }
    }

    @Test func paneScopedMutationsTargetTheRequestedProjectedPane() throws {
        do {
            let harness = try Harness()
            defer { harness.tearDown() }
            let firstTmuxPaneID = try #require(harness.mirror.paneIDsInOrder.first)
            let firstPaneID = try #require(harness.mirror.syntheticPaneID(forPane: firstTmuxPaneID)?.id)
            let firstSurfaceID = try #require(harness.mirror.panel(forPane: firstTmuxPaneID)?.id)

            let result = TerminalController.shared.controlSurfaceRespawn(
                routing: harness.routing(paneID: firstPaneID),
                inputs: respawnInputs(surfaceID: nil)
            )

            #expect(result == .respawnFailed(firstSurfaceID))
        }

        do {
            let harness = try Harness(addPeerSurface: true)
            defer { harness.tearDown() }
            let firstTmuxPaneID = try #require(harness.mirror.paneIDsInOrder.first)
            let firstPaneID = try #require(harness.mirror.syntheticPaneID(forPane: firstTmuxPaneID)?.id)
            let firstSurfaceID = try #require(harness.mirror.panel(forPane: firstTmuxPaneID)?.id)

            let result = TerminalController.shared.controlSurfaceClose(
                routing: harness.routing(paneID: firstPaneID),
                surfaceID: nil
            )

            #expect(result == .closeFailed(firstSurfaceID))
            #expect(harness.workspace.panels[harness.outerPanelID] != nil)
        }
    }

    private func activeSurfaceID(in harness: Harness) throws -> UUID {
        let paneID = try #require(harness.mirror.activePaneId)
        return try #require(harness.mirror.panel(forPane: paneID)?.id)
    }

    private func respawnInputs(surfaceID: UUID?) -> ControlSurfaceRespawnInputs {
        ControlSurfaceRespawnInputs(
            command: "exec ${SHELL:-/bin/zsh} -l",
            tmuxStartCommand: "exec ${SHELL:-/bin/zsh} -l",
            workingDirectory: nil,
            hasSurfaceIDParam: surfaceID != nil,
            requestedSurfaceID: surfaceID,
            hasFocusParam: false,
            requestedFocus: false
        )
    }

    private func splitInputs(surfaceID: UUID) -> ControlSurfaceSplitInputs {
        ControlSurfaceSplitInputs(
            directionRaw: "right",
            typeRaw: nil,
            urlRaw: nil,
            requestedSourceSurfaceID: surfaceID,
            workingDirectory: nil,
            initialCommand: nil,
            tmuxStartCommand: nil,
            remotePTYSessionID: nil,
            remoteContextRaw: nil,
            startupEnvironment: [:],
            clientUnsupportedRemoteTmuxOptions: [],
            requestedFocus: false,
            initialDividerPosition: nil
        )
    }
}
