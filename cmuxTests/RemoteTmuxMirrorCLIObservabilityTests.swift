import CmuxRemoteSession
import AppKit
import Bonsplit
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
        #expect(explicitSend == .surfaceUnavailable(activeSurfaceID))

        let defaultSend = TerminalController.shared.controlSurfaceSendText(
            routing: routing,
            surfaceID: nil,
            hasSurfaceIDParam: false,
            text: "active pane input"
        )
        #expect(defaultSend == .surfaceUnavailable(activeSurfaceID))
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

    @Test func defaultTriggerFlashProjectsTheActiveInnerPane() throws {
        do {
            let harness = try Harness()
            defer { harness.tearDown() }
            let activeTmuxPaneID = try #require(harness.mirror.paneIDsInOrder.last)
            let activeSurfaceID = try #require(harness.mirror.panel(forPane: activeTmuxPaneID)?.id)

            let flash = TerminalController.shared.controlSurfaceTriggerFlash(
                routing: harness.routing(),
                surfaceID: nil
            )
            switch flash {
            case .flashed(_, let workspaceID, let surfaceID):
                #expect(workspaceID == harness.workspace.id)
                #expect(surfaceID == activeSurfaceID)
            default:
                Issue.record("Default flash did not project the focused mirror: \(flash)")
            }
        }

        do {
            // Without a published active pane the mirror seeds its first live
            // pane (the native chrome always has a selection), and the default
            // flash projects that seed — never the wrapper panel.
            let harness = try Harness(activeTmuxPaneID: nil)
            defer { harness.tearDown() }
            let seededTmuxPaneID = try #require(harness.mirror.paneIDsInOrder.first)
            let seededSurfaceID = try #require(harness.mirror.panel(forPane: seededTmuxPaneID)?.id)

            let flash = TerminalController.shared.controlSurfaceTriggerFlash(
                routing: harness.routing(),
                surfaceID: nil
            )
            switch flash {
            case .flashed(_, let workspaceID, let surfaceID):
                #expect(workspaceID == harness.workspace.id)
                #expect(surfaceID == seededSurfaceID)
            default:
                Issue.record("Default flash did not project the seeded mirror pane: \(flash)")
            }
        }
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

    @Test func mirrorWithoutPublishedActivePaneSeedsFirstPaneProjection() throws {
        // Since the native-chrome rearchitecture a mirror can never be
        // "unresolved": with no tmux-published active pane it seeds its first
        // live pane, so defaults project that seed while mutations still fail
        // closed at the dead transport instead of leaking into the wrapper.
        let harness = try Harness(activeTmuxPaneID: nil)
        defer { harness.tearDown() }

        let routing = harness.routing()
        let seededTmuxPaneID = try #require(harness.mirror.paneIDsInOrder.first)
        let seededPaneID = try #require(harness.mirror.syntheticPaneID(forPane: seededTmuxPaneID)?.id)
        let seededSurfaceID = try #require(harness.mirror.panel(forPane: seededTmuxPaneID)?.id)
        let expectedPaneIDs = harness.mirror.paneIDsInOrder.compactMap {
            harness.mirror.syntheticPaneID(forPane: $0)?.id
        }
        let paneList = try #require(TerminalController.shared.controlPaneList(routing: routing))
        #expect(paneList.panes.map(\.paneID) == expectedPaneIDs)
        #expect(paneList.panes.first(where: \.isFocused)?.paneID == seededPaneID)

        let defaultSend = TerminalController.shared.controlSurfaceSendText(
            routing: routing,
            surfaceID: nil,
            hasSurfaceIDParam: false,
            text: "must fail closed at the dead transport"
        )
        #expect(defaultSend == .surfaceUnavailable(seededSurfaceID))

        let paneSurfaces = try #require(TerminalController.shared.controlPaneSurfaces(
            routing: routing,
            paneID: nil
        ))
        #expect(paneSurfaces.paneID == seededPaneID)
        #expect(paneSurfaces.surfaces.compactMap(\.surfaceID) == [seededSurfaceID])

        let current = try #require(TerminalController.shared.controlSurfaceCurrent(routing: routing))
        #expect(current.paneID == seededPaneID)
        #expect(current.surfaceID == seededSurfaceID)
        #expect(current.surfaceTypeRawValue == PanelType.terminal.rawValue)
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

        harness.teardownMirror()

        #expect(TerminalController.shared.v2ResolveHandleRef(paneRef) == nil)
        #expect(TerminalController.shared.v2ResolveHandleRef(surfaceRef) == nil)
    }

    @MainActor
    struct Harness {
        let appDelegate: AppDelegate
        let windowID: UUID
        let workspace: Workspace
        let outerPanelID: UUID
        let nonMirrorPanelID: UUID?
        let peerSurfaceID: UUID?
        let controlPaneIDs: [Int: PaneID]
        let connection: RemoteTmuxControlConnection
        let controlWriter: RemoteTmuxControlPipeWriter?
        let controlPipe: Pipe?
        let mirror: RemoteTmuxWindowMirror

        init(
            focusAwayFromMirror: Bool = false,
            addPeerSurface: Bool = false,
            activeTmuxPaneID: Int? = 22,
            connectedTransport: Bool = false,
            geometryScale: CGFloat = 2,
            mirrorLayout: RemoteTmuxLayoutNode? = nil
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

            connection = RemoteTmuxControlConnection(
                host: RemoteTmuxHost(destination: "user@host"),
                sessionName: "work"
            )
            if connectedTransport {
                let pipe = Pipe()
                let writer = RemoteTmuxControlPipeWriter(
                    handle: pipe.fileHandleForWriting,
                    label: "remote-tmux-mirror-control-command-test",
                    maxPendingBytes: 1 << 20,
                    onFailure: {}
                )
                controlPipe = pipe
                controlWriter = writer
                connection.installStdinWriterForTesting(writer)
                connection.handleMessageForTesting(.enter)
                connection.handleMessageForTesting(
                    .commandResult(commandNumber: 0, lines: [], isError: false)
                )
            } else {
                controlPipe = nil
                controlWriter = nil
            }
            let layout = mirrorLayout ?? RemoteTmuxLayoutNode(
                width: 80,
                height: 24,
                x: 0,
                y: 0,
                content: .horizontal([
                    RemoteTmuxLayoutNode(width: 40, height: 24, x: 0, y: 0, content: .pane(11)),
                    RemoteTmuxLayoutNode(width: 39, height: 24, x: 41, y: 0, content: .pane(22)),
                ])
            )
            let paneIDs = [11: PaneID(), 22: PaneID()]
            controlPaneIDs = paneIDs
            let geometry = RemoteTmuxMirrorGeometry(
                cellWidthPx: Int(8 * geometryScale),
                cellHeightPx: Int(17 * geometryScale),
                surfacePadWidthPx: Int(4 * geometryScale),
                surfacePadHeightPx: Int(4 * geometryScale),
                scale: geometryScale
            )
            mirror = RemoteTmuxWindowMirror(
                windowId: 3,
                panelId: outerPanelID,
                connection: connection,
                layout: layout,
                geometrySource: { geometry },
                controlPaneID: { [paneIDs] in paneIDs[$0] },
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
            teardownMirror()
            controlWriter?.close()
            try? controlPipe?.fileHandleForReading.close()
            let identifier = "cmux.main.\(windowID.uuidString)"
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == identifier }) {
                window.performClose(nil)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }
        }

        func teardownMirror() {
            TerminalController.shared.cleanupSurfaceState(
                surfaceIds: mirror.controlPanes().map(\.panel.id),
                paneIds: controlPaneIDs.values.map(\.id)
            )
            mirror.teardown()
        }
    }
}

private extension ControlSurfaceSendResolution {
    var sentSurfaceID: UUID? {
        guard case .sent(_, _, let surfaceID, _) = self else { return nil }
        return surfaceID
    }
}
