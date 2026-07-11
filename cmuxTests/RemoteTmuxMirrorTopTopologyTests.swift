import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension RemoteTmuxMirrorCLIObservabilityTests {
    /// Regression for #7910: process enrichment must not mint a second view of
    /// mirror topology. `system.top` and `system.tree` must expose the same
    /// actionable pane and surface identities.
    @Test func topUsesTreeTopologyForMirrorWorkspaces() async throws {
        let harness = try Harness()
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

        let topPaneIDs = topPanes.compactMap {
            ($0["id"] as? String).flatMap(UUID.init(uuidString:))
        }
        let topSurfaces = topPanes.flatMap {
            $0["surfaces"] as? [[String: Any]] ?? []
        }
        let topSurfaceIDs = topSurfaces.compactMap {
            ($0["id"] as? String).flatMap(UUID.init(uuidString:))
        }

        #expect(topPaneIDs == expectedPaneIDs)
        #expect(topSurfaceIDs == expectedSurfaceIDs)
        #expect(!topSurfaceIDs.contains(harness.outerPanelID))

        for (pane, paneID) in zip(topPanes, topPaneIDs) {
            let ref = try #require(pane["ref"] as? String)
            #expect(TerminalController.shared.v2ResolveHandleRef(ref) == paneID)
        }
        for (surface, surfaceID) in zip(topSurfaces, topSurfaceIDs) {
            let ref = try #require(surface["ref"] as? String)
            #expect(TerminalController.shared.v2ResolveHandleRef(ref) == surfaceID)
        }
    }
}
