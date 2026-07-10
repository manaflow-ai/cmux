import CmuxControlSocket
import Foundation
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
            #expect(send == .surfaceUnavailable(activeSurfaceID))
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

    @Test func advertisedProjectedTerminalsSupportTerminalCommands() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let firstTmuxPaneID = try #require(harness.mirror.paneIDsInOrder.first)
        let firstSurfaceID = try #require(harness.mirror.panel(forPane: firstTmuxPaneID)?.id)

        let refresh = TerminalController.shared.controlSurfaceRefresh(routing: harness.routing())
        guard case .refreshed(_, let workspaceID, let refreshedCount) = refresh else {
            Issue.record("Expected projected terminals to refresh")
            return
        }
        #expect(workspaceID == harness.workspace.id)
        #expect(refreshedCount == harness.mirror.paneIDsInOrder.count)

        let clear = TerminalController.shared.controlSurfaceClearHistory(
            routing: harness.routing(),
            surfaceID: firstSurfaceID,
            hasSurfaceIDParam: true
        )
        switch clear {
        case .cleared(_, let workspaceID, let surfaceID):
            #expect(workspaceID == harness.workspace.id)
            #expect(surfaceID == firstSurfaceID)
        case .bindingActionUnavailable:
            break
        default:
            Issue.record("Projected terminal was not resolved for clear_history")
        }

        let flash = TerminalController.shared.controlSurfaceTriggerFlash(
            routing: harness.routing(),
            surfaceID: firstSurfaceID
        )
        #expect(flash == .flashed(
            windowID: harness.windowID,
            workspaceID: harness.workspace.id,
            surfaceID: firstSurfaceID
        ))
    }

    @Test func treeAndIdentifyUseProjectedMirrorIdentities() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let expectedPaneIDs = harness.mirror.paneIDsInOrder.compactMap {
            harness.mirror.syntheticPaneID(forPane: $0)?.id
        }
        let expectedSurfaceIDs = harness.mirror.paneIDsInOrder.compactMap {
            harness.mirror.panel(forPane: $0)?.id
        }

        let tree = TerminalController.shared.controlSystemTreeWindows(
            requestedWindowID: harness.windowID,
            includeAllWindows: false,
            focusedWindowID: harness.windowID,
            workspaceFilter: harness.workspace.id
        )
        let workspaceNode = try #require(tree.windows.first?.workspaces.first)
        #expect(workspaceNode.panes.map(\.paneID) == expectedPaneIDs)
        #expect(workspaceNode.panes.flatMap(\.surfaceIDs) == expectedSurfaceIDs)

        let identify = TerminalController.shared.controlSystemIdentify(params: [:]).foundationObject
        let root = try #require(identify as? [String: Any])
        let focused = try #require(root["focused"] as? [String: Any])
        #expect(focused["pane_id"] as? String == expectedPaneIDs.last?.uuidString)
        #expect(focused["surface_id"] as? String == expectedSurfaceIDs.last?.uuidString)
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
