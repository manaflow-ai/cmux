import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct RemoteTmuxMirrorTopTopologyTests {
    /// Regression for #7910: process enrichment must not mint a second view of
    /// mirror topology. `system.top` and `system.tree` must expose the same
    /// actionable pane and surface identities.
    @Test func topUsesTreeTopologyForMirrorWorkspaces() async throws {
        let harness = try RemoteTmuxMirrorCLIObservabilityTests.Harness()
        defer { harness.tearDown() }

        let tree = TerminalController.shared.controlSystemTreeWindows(
            requestedWindowID: harness.windowID,
            includeAllWindows: false,
            focusedWindowID: nil,
            workspaceFilter: harness.workspace.id
        )
        let treeWorkspace = try #require(tree.windows.first?.workspaces.first)
        let expectedPaneIDs = treeWorkspace.panes.map(\.paneID)
        let expectedSurfaceIDs = treeWorkspace.panes.flatMap(\.surfaceIDs)

        let top = try await TerminalController.shared.taskManagerTopPayload(
            includeProcesses: false
        )
        let windows = try #require(top["windows"] as? [[String: Any]])
        let topWindow = try #require(windows.first {
            $0["id"] as? String == harness.windowID.uuidString
        })
        let workspaces = try #require(topWindow["workspaces"] as? [[String: Any]])
        let topWorkspace = try #require(workspaces.first {
            $0["id"] as? String == harness.workspace.id.uuidString
        })
        let topPanes = try #require(topWorkspace["panes"] as? [[String: Any]])

        let workspaceRef = try #require(topWorkspace["ref"] as? String)
        #expect(TerminalController.shared.v2ResolveHandleRef(workspaceRef) == harness.workspace.id)

        let topPaneIDs = try topPanes.map { pane in
            let id = try #require(pane["id"] as? String)
            return try #require(UUID(uuidString: id))
        }
        let topSurfacesByPane = try topPanes.map { pane in
            try #require(pane["surfaces"] as? [[String: Any]])
        }
        let topSurfaceIDsByPane = try topSurfacesByPane.map { surfaces in
            try surfaces.map { surface in
                let id = try #require(surface["id"] as? String)
                return try #require(UUID(uuidString: id))
            }
        }
        let topSurfaceIDs = topSurfaceIDsByPane.flatMap { $0 }

        #expect(topPaneIDs == expectedPaneIDs)
        #expect(topSurfaceIDs == expectedSurfaceIDs)
        #expect(!topSurfaceIDs.contains(harness.outerPanelID))

        let expectedPanesByID = Dictionary(uniqueKeysWithValues: treeWorkspace.panes.map {
            ($0.paneID, $0)
        })
        for (index, pane) in topPanes.enumerated() {
            let paneID = topPaneIDs[index]
            let surfaces = topSurfacesByPane[index]
            let surfaceIDs = topSurfaceIDsByPane[index]
            let expectedPane = try #require(expectedPanesByID[paneID])

            let ref = try #require(pane["ref"] as? String)
            #expect(TerminalController.shared.v2ResolveHandleRef(ref) == paneID)

            #expect(surfaceIDs == expectedPane.surfaceIDs)
            let surfaceRefs = try #require(pane["surface_refs"] as? [String])
            let resolvedSurfaceRefs = surfaceRefs.map {
                TerminalController.shared.v2ResolveHandleRef($0)
            }
            #expect(resolvedSurfaceRefs == expectedPane.surfaceIDs.map { Optional($0) })

            let selectedSurfaceID = try #require(expectedPane.selectedSurfaceID)
            let selectedSurfaceRef = try #require(pane["selected_surface_ref"] as? String)
            #expect(TerminalController.shared.v2ResolveHandleRef(selectedSurfaceRef) == selectedSurfaceID)

            for (surfaceIndex, surface) in surfaces.enumerated() {
                let surfaceID = surfaceIDs[surfaceIndex]
                let surfaceRef = try #require(surface["ref"] as? String)
                #expect(TerminalController.shared.v2ResolveHandleRef(surfaceRef) == surfaceID)

                let paneRef = try #require(surface["pane_ref"] as? String)
                #expect(TerminalController.shared.v2ResolveHandleRef(paneRef) == paneID)
            }
        }
    }

    /// Task Manager navigation must consume the same projected surface IDs
    /// that its top snapshot displays.
    @Test func taskManagerViewsProjectedMirrorSurface() async throws {
        let harness = try RemoteTmuxMirrorCLIObservabilityTests.Harness(
            activeTmuxPaneID: 11,
            connectedTransport: true
        )
        defer { harness.tearDown() }

        let targetTmuxPaneID = 22
        #expect(harness.mirror.paneIDsInOrder.contains(targetTmuxPaneID))
        let targetSurfaceID = try #require(harness.mirror.panel(forPane: targetTmuxPaneID)?.id)
        let payload = try await TerminalController.shared.taskManagerTopPayload(
            includeProcesses: false
        )
        let snapshot = CmuxTaskManagerSnapshot(payload: payload)
        let row = try #require(snapshot.rows.first {
            $0.kind == .terminalSurface && $0.surfaceId == targetSurfaceID
        })

        harness.mirror.noteRemoteActivePane(11)
        #expect(harness.mirror.activePaneId == 11)
        let baselinePendingCount = harness.connection.pendingCommandKindsForTesting.count
        CmuxTaskManagerModel().viewTerminal(for: row)
        #expect(harness.connection.pendingCommandKindsForTesting.count == baselinePendingCount + 1)

        let writer = try #require(harness.controlWriter)
        let pipe = try #require(harness.controlPipe)
        writer.close()
        let commands = try #require(String(
            bytes: try pipe.fileHandleForReading.readToEnd() ?? Data(),
            encoding: .utf8
        ))
        let commandLines = commands.split(separator: "\n").map(String.init)
        #expect(commandLines.last == "select-pane -t @3.%\(targetTmuxPaneID)")
    }

    /// A single-pane session window has no window mirror, so its control pane
    /// projection reuses the display panel as both container and surface.
    /// Focusing that panel must take the ordinary workspace focus path: the
    /// mirror intercept re-entering itself with the same identity would
    /// recurse without bound, and it must not mint a select-pane command that
    /// the pre-projection focus path never sent.
    @Test func singlePaneSessionWindowFocusUsesTheNormalPath() throws {
        let harness = try RemoteTmuxSessionMirrorLayoutHarness()
        defer { harness.tearDown() }

        let panel = try #require(harness.singlePanePanel(tmuxPaneID: 11))
        let location = try #require(harness.workspace.remoteTmuxControlPane(surfaceID: panel.id))
        #expect(location.containerPanelID == panel.id)

        let baselinePendingCount = harness.connection.pendingCommandKindsForTesting.count
        harness.workspace.focusPanel(panel.id)
        #expect(harness.workspace.focusedPanelId == panel.id)
        #expect(harness.connection.pendingCommandKindsForTesting.count == baselinePendingCount)
    }
}
