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

    @Test func hiddenMirrorContainerHandlesFailClosedWhileDefaultsProject() throws {
        do {
            let harness = try Harness()
            defer { harness.tearDown() }
            let activeSurfaceID = try activeSurfaceID(in: harness)

            let implicitSend = TerminalController.shared.controlSurfaceSendText(
                routing: harness.routing(),
                surfaceID: nil,
                hasSurfaceIDParam: false,
                text: "route through active pane"
            )
            #expect(implicitSend == .surfaceUnavailable(activeSurfaceID))

            let explicitSend = TerminalController.shared.controlSurfaceSendText(
                routing: harness.routing(),
                surfaceID: harness.outerPanelID,
                hasSurfaceIDParam: true,
                text: "do not alias a cached wrapper"
            )
            #expect(explicitSend == .surfaceNotTerminal(harness.outerPanelID))
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

            #expect(result == .requestedSurfaceNotFound(harness.outerPanelID))
        }

        do {
            let harness = try Harness()
            defer { harness.tearDown() }
            let result = TerminalController.shared.controlSurfaceRespawn(
                routing: harness.routing(),
                inputs: respawnInputs(surfaceID: harness.outerPanelID)
            )

            #expect(result == .surfaceNotFoundForID(harness.outerPanelID))
        }

        do {
            let harness = try Harness(addPeerSurface: true)
            defer { harness.tearDown() }
            let result = TerminalController.shared.controlSurfaceClose(
                routing: harness.routing(),
                surfaceID: harness.outerPanelID
            )

            #expect(result == .surfaceNotFound(harness.outerPanelID))
            #expect(harness.workspace.panels[harness.outerPanelID] != nil)
        }

        do {
            let harness = try Harness(addPeerSurface: true)
            defer { harness.tearDown() }
            let notFound = ControlCallResult.err(
                code: "not_found",
                message: "Surface not found",
                data: .object(["surface_id": .string(harness.outerPanelID.uuidString)])
            )

            #expect(TerminalController.shared.controlSurfaceMove(params: [
                "surface_id": .string(harness.outerPanelID.uuidString),
            ]) == notFound)
            #expect(TerminalController.shared.controlSurfaceReorder(
                surfaceID: harness.outerPanelID,
                inputs: ControlSurfaceReorderInputs(
                    index: 0,
                    beforeSurfaceID: nil,
                    afterSurfaceID: nil
                ),
                requestedFocus: false
            ) == .surfaceNotFound(harness.outerPanelID))
            #expect(TerminalController.shared.controlPaneJoin(
                targetPaneID: try #require(harness.workspace.bonsplitController.focusedPaneId?.id),
                surfaceID: harness.outerPanelID,
                sourcePaneID: nil,
                hasFocusParam: false,
                focus: false
            ) == .moved(notFound))
            #expect(harness.workspace.panels[harness.outerPanelID] != nil)
        }
    }

    /// `system.tree` advertises the inner pane surface, while tab order lives on
    /// the pane's outer tmux-window container. Reorder must accept that advertised
    /// identity and mutate the container without exposing the hidden wrapper
    /// handle (#7734).
    @Test func advertisedMirrorSurfaceReordersItsOwningWindowTab() throws {
        let harness = try Harness(addPeerSurface: true)
        defer {
            harness.workspace.remoteTmuxWindowOrderSync = nil
            harness.tearDown()
        }
        let tmuxPaneID = try #require(harness.mirror.paneIDsInOrder.first)
        let advertisedSurfaceID = try #require(harness.mirror.panel(forPane: tmuxPaneID)?.id)
        let peerSurfaceID = try #require(harness.peerSurfaceID)
        let sourcePane = try #require(harness.workspace.paneId(forPanelId: harness.outerPanelID))
        var synchronizedPanelOrder: [UUID] = []
        harness.workspace.remoteTmuxWindowOrderSync = { panelOrder, verification in
            synchronizedPanelOrder = panelOrder
            verification?(true)
            return true
        }

        let result = TerminalController.shared.controlSurfaceReorder(
            surfaceID: advertisedSurfaceID,
            inputs: ControlSurfaceReorderInputs(
                index: 1,
                beforeSurfaceID: nil,
                afterSurfaceID: nil
            ),
            requestedFocus: false
        )

        #expect(result == .reordered(
            windowID: harness.windowID,
            workspaceID: harness.workspace.id,
            paneID: sourcePane.id,
            surfaceID: advertisedSurfaceID
        ))
        let reorderedPanelIDs = harness.workspace.bonsplitController.tabs(inPane: sourcePane)
            .compactMap { harness.workspace.panelIdFromSurfaceId($0.id) }
        #expect(reorderedPanelIDs == [peerSurfaceID, harness.outerPanelID])
        #expect(synchronizedPanelOrder == reorderedPanelIDs)
    }

    @Test func unsupportedBonsplitOnlyPaneMutationsRejectProjectedPaneIDs() throws {
        let harness = try Harness(focusAwayFromMirror: true)
        defer { harness.tearDown() }
        let tmuxPaneID = try #require(harness.mirror.paneIDsInOrder.first)
        let paneID = try #require(harness.mirror.syntheticPaneID(forPane: tmuxPaneID)?.id)
        let surfaceID = try #require(harness.mirror.panel(forPane: tmuxPaneID)?.id)
        let focusedBefore = harness.workspace.bonsplitController.focusedPaneId?.id
        let treeBefore = harness.workspace.bonsplitController.treeSnapshot()

        let resize = ControlCommandCoordinator(context: TerminalController.shared).handle(
            ControlRequest(
                id: .int(1),
                method: "pane.resize",
                params: [
                    "workspace_id": .string(harness.workspace.id.uuidString),
                    "pane_id": .string(paneID.uuidString),
                    "direction": .string("right"),
                    "amount": .int(10),
                ]
            )
        )
        guard case .err(let code, _, let data)? = resize else {
            Issue.record("Disconnected mirror pane resize did not fail: \(String(describing: resize))")
            return
        }
        #expect(code == "unavailable")
        #expect(data == .object(["pane_id": .string(paneID.uuidString)]))
        #expect(harness.workspace.bonsplitController.treeSnapshot() == treeBefore)

        let breakResult = TerminalController.shared.controlPaneBreak(
            routing: harness.routing(paneID: paneID),
            paneID: paneID,
            surfaceID: nil,
            requestedFocus: false
        )
        #expect(breakResult == .surfaceNotFound(surfaceID))

        let join = TerminalController.shared.controlPaneJoin(
            targetPaneID: paneID,
            surfaceID: nil,
            sourcePaneID: paneID,
            hasFocusParam: false,
            focus: false
        )
        #expect(join == .sourceSurfaceUnresolved(sourcePaneID: paneID))

        let last = TerminalController.shared.controlPaneLast(
            routing: harness.routing(paneID: paneID)
        )
        #expect(last == .noAlternatePane)
        #expect(harness.workspace.bonsplitController.focusedPaneId?.id == focusedBefore)
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

    @Test func createPathsHonorProjectedPaneIdentities() throws {
        do {
            let harness = try Harness()
            defer { harness.tearDown() }
            let firstTmuxPaneID = try #require(harness.mirror.paneIDsInOrder.first)
            let firstPaneID = try #require(harness.mirror.syntheticPaneID(forPane: firstTmuxPaneID)?.id)

            let result = TerminalController.shared.controlSurfaceCreate(
                routing: harness.routing(),
                inputs: ControlSurfaceCreateInputs(
                    typeRaw: nil,
                    providerRaw: nil,
                    rendererRaw: nil,
                    urlRaw: nil,
                    workingDirectory: nil,
                    initialCommand: nil,
                    tmuxStartCommand: nil,
                    remotePTYSessionID: nil,
                    remoteContextRaw: nil,
                    startupEnvironment: [:],
                    requestedPaneID: firstPaneID,
                    requestedFocus: false
                )
            )

            // A projected pane is a valid target. `new-surface` maps to a tmux
            // window in a mirror, so the disconnected transport fails only
            // after the handle has resolved and routing has been attempted.
            #expect(result == .createFailed)
        }

        do {
            let harness = try Harness()
            defer { harness.tearDown() }
            let firstTmuxPaneID = try #require(harness.mirror.paneIDsInOrder.first)
            let firstSurfaceID = try #require(harness.mirror.panel(forPane: firstTmuxPaneID)?.id)

            let result = TerminalController.shared.controlPaneCreate(
                routing: harness.routing(),
                inputs: ControlPaneCreateInputs(
                    directionRaw: "right",
                    typeRaw: nil,
                    urlRaw: nil,
                    workingDirectory: nil,
                    initialCommand: nil,
                    tmuxStartCommand: nil,
                    startupEnvironment: [:],
                    requestedSourceSurfaceID: firstSurfaceID,
                    requestedFocus: false,
                    hasInitialDividerPosition: false,
                    initialDividerPositionRaw: nil
                )
            )

            // The projected source surface resolves to its tmux pane and the
            // split routes to tmux; the never-connected transport then fails
            // closed instead of splitting the local Bonsplit wrapper.
            #expect(result == .createFailed)
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
