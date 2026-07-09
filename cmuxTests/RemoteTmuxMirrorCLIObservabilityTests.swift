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

    @MainActor
    private struct Harness {
        let appDelegate: AppDelegate
        let windowID: UUID
        let workspace: Workspace
        let outerPanelID: UUID
        let mirror: RemoteTmuxWindowMirror

        init() throws {
            appDelegate = try #require(AppDelegate.shared)
            windowID = appDelegate.createMainWindow()
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowID))
            workspace = try #require(manager.selectedWorkspace)
            outerPanelID = try #require(workspace.focusedPanelId)

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
                makePanel: { [workspace] _ in
                    workspace.makeRemoteTmuxPanePanel(onInput: { _ in })
                }
            )
            mirror.noteRemoteActivePane(22)
            workspace.isRemoteTmuxMirror = true
            workspace.setRemoteTmuxWindowMirror(mirror, forPanelId: outerPanelID)
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
