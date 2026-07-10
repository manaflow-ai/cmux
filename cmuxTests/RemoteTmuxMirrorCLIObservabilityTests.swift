import AppKit
import CmuxControlSocket
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for GitHub issue #7738: a multi-pane remote-tmux
/// window must expose its rendered pane surfaces through the same control-plane
/// seams that back `list-panes`, `list-pane-surfaces`, and `send`.
@MainActor
@Suite(.serialized)
struct RemoteTmuxMirrorCLIObservabilityTests {
    @Test func multiPaneMirrorPublishesInnerPanesAndRoutesInput() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: harness.workspace.id,
            surfaceID: nil,
            paneID: nil
        )
        let expectedPaneIDs = harness.mirror.paneIDsInOrder.compactMap {
            harness.mirror.syntheticPaneID(forPane: $0)?.id
        }
        let expectedSurfaceIDs = harness.mirror.paneIDsInOrder.compactMap {
            harness.mirror.panel(forPane: $0)?.id
        }

        let paneList = try #require(TerminalController.shared.controlPaneList(routing: routing))
        #expect(paneList.panes.map(\.paneID) == expectedPaneIDs)
        #expect(paneList.panes.compactMap(\.selectedSurfaceID) == expectedSurfaceIDs)
        #expect(paneList.panes.map(\.isFocused) == [false, true])

        let activePaneID = try #require(expectedPaneIDs.last)
        let activeSurfaceID = try #require(expectedSurfaceIDs.last)
        let paneSurfaces = try #require(TerminalController.shared.controlPaneSurfaces(
            routing: routing,
            paneID: activePaneID
        ))
        #expect(paneSurfaces.paneID == activePaneID)
        #expect(paneSurfaces.surfaces.compactMap(\.surfaceID) == [activeSurfaceID])

        let surfaceList = try #require(TerminalController.shared.controlSurfaceList(routing: routing))
        #expect(surfaceList.surfaces.map(\.surfaceID) == expectedSurfaceIDs)
        #expect(surfaceList.surfaces.map(\.paneID) == expectedPaneIDs)

        let explicitSend = TerminalController.shared.controlSurfaceSendText(
            routing: routing,
            surfaceID: activeSurfaceID,
            hasSurfaceIDParam: true,
            text: "explicit pane input"
        )
        #expect(explicitSend.sentSurfaceID == activeSurfaceID)

        let defaultSend = TerminalController.shared.controlSurfaceSendText(
            routing: routing,
            surfaceID: nil,
            hasSurfaceIDParam: false,
            text: "active pane input"
        )
        #expect(defaultSend.sentSurfaceID == activeSurfaceID)
    }

    @Test func unfocusedMirrorStillPublishesInnerPanes() throws {
        let harness = try Harness(focusAwayFromMirror: true)
        defer { harness.tearDown() }

        let nonMirrorPanelID = try #require(harness.nonMirrorPanelID)
        let nonMirrorPaneID = try #require(harness.workspace.paneId(forPanelId: nonMirrorPanelID))
        #expect(harness.workspace.focusedPanelId == nonMirrorPanelID)

        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: harness.workspace.id,
            surfaceID: nil,
            paneID: nil
        )
        let expectedRemotePaneIDs = harness.mirror.paneIDsInOrder.compactMap {
            harness.mirror.syntheticPaneID(forPane: $0)?.id
        }
        let expectedRemoteSurfaceIDs = harness.mirror.paneIDsInOrder.compactMap {
            harness.mirror.panel(forPane: $0)?.id
        }

        let paneList = try #require(TerminalController.shared.controlPaneList(routing: routing))
        let remotePanes = paneList.panes.filter { expectedRemotePaneIDs.contains($0.paneID) }
        #expect(remotePanes.map(\.paneID) == expectedRemotePaneIDs)
        #expect(remotePanes.compactMap(\.selectedSurfaceID) == expectedRemoteSurfaceIDs)
        #expect(remotePanes.allSatisfy { !$0.isFocused })
        #expect(!paneList.panes.flatMap(\.surfaceIDs).contains(harness.outerPanelID))

        let nonMirrorPane = try #require(paneList.panes.first {
            $0.paneID == nonMirrorPaneID.id
        })
        #expect(nonMirrorPane.surfaceIDs == [nonMirrorPanelID])
        #expect(nonMirrorPane.selectedSurfaceID == nonMirrorPanelID)
        #expect(nonMirrorPane.isFocused)
    }

    @Test func currentSurfaceProjectsTheActiveInnerPane() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        let routing = harness.routing()
        let activeTmuxPaneID = try #require(harness.mirror.paneIDsInOrder.last)
        let activePaneID = try #require(harness.mirror.syntheticPaneID(forPane: activeTmuxPaneID))
        let activeSurfaceID = try #require(harness.mirror.panel(forPane: activeTmuxPaneID)?.id)

        let current = try #require(TerminalController.shared.controlSurfaceCurrent(routing: routing))
        #expect(current.paneID == activePaneID.id)
        #expect(current.surfaceID == activeSurfaceID)
        #expect(current.surfaceTypeRawValue == PanelType.terminal.rawValue)
    }

    @Test func explicitOuterPaneCannotCrossIntoProjectedMirrorPane() throws {
        let harness = try Harness(addPeerSurface: true)
        defer { harness.tearDown() }

        let peerSurfaceID = try #require(harness.peerSurfaceID)
        let outerPaneID = try #require(harness.workspace.paneId(forPanelId: harness.outerPanelID))
        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: harness.workspace.id,
            surfaceID: nil,
            paneID: outerPaneID.id
        )

        let paneSurfaces = try #require(TerminalController.shared.controlPaneSurfaces(
            routing: routing,
            paneID: outerPaneID.id
        ))
        #expect(paneSurfaces.surfaces.compactMap(\.surfaceID) == [peerSurfaceID])
        #expect(paneSurfaces.surfaces.allSatisfy { !$0.isSelected })

        let send = TerminalController.shared.controlSurfaceSendText(
            routing: routing,
            surfaceID: nil,
            hasSurfaceIDParam: false,
            text: "must not reach a synthetic pane"
        )
        #expect(send == .noFocusedSurface)
    }

    @Test func unresolvedMirrorFocusFailsClosedWithoutHidingPanes() throws {
        let harness = try Harness(activeTmuxPaneID: nil)
        defer { harness.tearDown() }

        let routing = harness.routing()
        let expectedPaneIDs = harness.mirror.paneIDsInOrder.compactMap {
            harness.mirror.syntheticPaneID(forPane: $0)?.id
        }
        let paneList = try #require(TerminalController.shared.controlPaneList(routing: routing))
        #expect(paneList.panes.map(\.paneID) == expectedPaneIDs)
        #expect(paneList.panes.allSatisfy { !$0.isFocused })

        let defaultSend = TerminalController.shared.controlSurfaceSendText(
            routing: routing,
            surfaceID: nil,
            hasSurfaceIDParam: false,
            text: "must wait for authoritative focus"
        )
        #expect(defaultSend == .noFocusedSurface)
        #expect(TerminalController.shared.controlPaneSurfaces(routing: routing, paneID: nil) == nil)

        let current = try #require(TerminalController.shared.controlSurfaceCurrent(routing: routing))
        #expect(current.paneID == nil)
        #expect(current.surfaceID == nil)
        #expect(current.surfaceTypeRawValue == nil)
    }

    @Test func invalidExplicitPaneDoesNotFallBackToFocusedPane() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        #expect(TerminalController.shared.controlPaneSurfaces(
            routing: harness.routing(),
            paneID: UUID()
        ) == nil)
    }

    @Test func projectedMutationsResolveBeforeTransportFailure() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        let tmuxPaneID = try #require(harness.mirror.paneIDsInOrder.first)
        let paneID = try #require(harness.mirror.syntheticPaneID(forPane: tmuxPaneID)?.id)
        let surfaceID = try #require(harness.mirror.panel(forPane: tmuxPaneID)?.id)
        let routing = harness.routing()

        #expect(TerminalController.shared.controlPaneFocus(
            routing: routing,
            paneID: paneID
        ) == .paneNotFound(paneID))
        #expect(TerminalController.shared.controlSurfaceFocus(
            routing: routing,
            surfaceID: surfaceID
        ) == .surfaceNotFound(surfaceID))
        #expect(harness.mirror.activePaneId == 22)

        let split = TerminalController.shared.controlSurfaceSplit(
            routing: routing,
            inputs: ControlSurfaceSplitInputs(
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
        )
        #expect(split == .createFailed)

        let respawn = TerminalController.shared.controlSurfaceRespawn(
            routing: routing,
            inputs: ControlSurfaceRespawnInputs(
                command: "exec ${SHELL:-/bin/zsh} -l",
                tmuxStartCommand: "exec ${SHELL:-/bin/zsh} -l",
                workingDirectory: nil,
                hasSurfaceIDParam: true,
                requestedSurfaceID: surfaceID,
                hasFocusParam: false,
                requestedFocus: false
            )
        )
        #expect(respawn == .respawnFailed(surfaceID))
        #expect(TerminalController.shared.controlSurfaceClose(
            routing: routing,
            surfaceID: surfaceID
        ) == .closeFailed(surfaceID))
    }

    @Test func teardownRemovesProjectedPaneAndSurfaceHandles() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        let tmuxPaneID = try #require(harness.mirror.paneIDsInOrder.first)
        let paneID = try #require(harness.mirror.syntheticPaneID(forPane: tmuxPaneID)?.id)
        let surfaceID = try #require(harness.mirror.panel(forPane: tmuxPaneID)?.id)
        let paneRef = try #require(
            TerminalController.shared.v2Ref(kind: .pane, uuid: paneID) as? String
        )
        let surfaceRef = try #require(
            TerminalController.shared.v2Ref(kind: .surface, uuid: surfaceID) as? String
        )
        #expect(TerminalController.shared.v2ResolveHandleRef(paneRef) == paneID)
        #expect(TerminalController.shared.v2ResolveHandleRef(surfaceRef) == surfaceID)

        harness.mirror.teardown()

        #expect(TerminalController.shared.v2ResolveHandleRef(paneRef) == nil)
        #expect(TerminalController.shared.v2ResolveHandleRef(surfaceRef) == nil)
    }

    @MainActor
    private struct Harness {
        let appDelegate: AppDelegate
        let windowID: UUID
        let workspace: Workspace
        let outerPanelID: UUID
        let nonMirrorPanelID: UUID?
        let peerSurfaceID: UUID?
        let mirror: RemoteTmuxWindowMirror

        init(
            focusAwayFromMirror: Bool = false,
            addPeerSurface: Bool = false,
            activeTmuxPaneID: Int? = 22
        ) throws {
            appDelegate = try #require(AppDelegate.shared)
            windowID = appDelegate.createMainWindow()
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowID))
            workspace = try #require(manager.selectedWorkspace)
            outerPanelID = try #require(workspace.focusedPanelId)
            if focusAwayFromMirror {
                nonMirrorPanelID = try #require(workspace.newTerminalSplit(
                    from: outerPanelID,
                    orientation: .horizontal,
                    focus: true
                )?.id)
            } else {
                nonMirrorPanelID = nil
            }
            if addPeerSurface {
                let paneID = try #require(workspace.paneId(forPanelId: outerPanelID))
                peerSurfaceID = try #require(workspace.newTerminalSurface(
                    inPane: paneID,
                    focus: false
                )?.id)
            } else {
                peerSurfaceID = nil
            }

            let connection = RemoteTmuxControlConnection(
                host: RemoteTmuxHost(destination: "user@host"),
                sessionName: "work"
            )
            let layout = RemoteTmuxLayoutNode(
                width: 80,
                height: 24,
                x: 0,
                y: 0,
                content: .horizontal([
                    RemoteTmuxLayoutNode(width: 40, height: 24, x: 0, y: 0, content: .pane(11)),
                    RemoteTmuxLayoutNode(width: 39, height: 24, x: 41, y: 0, content: .pane(22)),
                ])
            )
            mirror = RemoteTmuxWindowMirror(
                windowId: 3,
                panelId: outerPanelID,
                connection: connection,
                layout: layout,
                onControlPaneRemoved: { paneID, surfaceID in
                    TerminalController.shared.cleanupSurfaceState(
                        surfaceIds: [surfaceID],
                        paneIds: [paneID.id]
                    )
                },
                makePanel: { [workspace] _ in
                    workspace.makeRemoteTmuxPanePanel(onInput: { _ in })
                }
            )
            if let activeTmuxPaneID {
                mirror.noteRemoteActivePane(activeTmuxPaneID)
            }
            workspace.isRemoteTmuxMirror = true
            workspace.setRemoteTmuxWindowMirror(mirror, forPanelId: outerPanelID)
        }

        func routing(paneID: UUID? = nil) -> ControlRoutingSelectors {
            ControlRoutingSelectors(
                hasWindowIDParam: false,
                windowID: nil,
                groupID: nil,
                workspaceID: workspace.id,
                surfaceID: nil,
                paneID: paneID
            )
        }

        func tearDown() {
            workspace.setRemoteTmuxWindowMirror(nil, forPanelId: outerPanelID)
            workspace.isRemoteTmuxMirror = false
            mirror.teardown()
            let identifier = "cmux.main.\(windowID.uuidString)"
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == identifier }) {
                window.performClose(nil)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }
        }
    }
}

private extension ControlSurfaceSendResolution {
    var sentSurfaceID: UUID? {
        guard case .sent(_, _, let surfaceID, _) = self else { return nil }
        return surfaceID
    }
}
