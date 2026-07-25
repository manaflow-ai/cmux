import AppKit
import CmuxControlSocket
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
    /// End-to-end regression for the control-plane liveness contract. The same
    /// live workspace must project independent true/false/null states through
    /// both the socket `system.tree` result and the Task Manager `system.top`
    /// payload, while preserving raw tty metadata inside the topology model.
    @Test func processLivenessFlowsThroughTreeAndTop() async throws {
        let app = try #require(AppDelegate.shared)
        let windowID = app.createMainWindow()
        let manager = try #require(app.tabManagerFor(windowId: windowID))
        let workspace = try #require(manager.selectedWorkspace)
        let aliveID = try #require(workspace.focusedPanelId)
        _ = try #require(workspace.panels[aliveID] as? TerminalPanel)
        let exitedPanel = try #require(workspace.newTerminalSplit(
            from: aliveID,
            orientation: .horizontal,
            focus: false
        ))
        let remotePlaceholderPanel = try #require(workspace.newTerminalSplit(
            from: exitedPanel.id,
            orientation: .vertical,
            focus: false
        ))

        workspace.surfaceTTYNames[aliveID] = "/dev/ttys901"
        workspace.surfaceTTYNames[exitedPanel.id] = "/dev/ttys902"
        workspace.surfaceTTYNames[remotePlaceholderPanel.id] = "/dev/ttys903"
        workspace.controlProcessAliveOverridesForTesting = [
            aliveID: true,
            exitedPanel.id: false,
            remotePlaceholderPanel.id: true,
        ]
        workspace.remoteDisconnectPlaceholderPanelIds.insert(remotePlaceholderPanel.id)
        defer {
            workspace.controlProcessAliveOverridesForTesting = [:]
            workspace.remoteDisconnectPlaceholderPanelIds.remove(remotePlaceholderPanel.id)
            let identifier = "cmux.main.\(windowID.uuidString)"
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == identifier }) {
                window.performClose(nil)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }
        }

        let rawTree = TerminalController.shared.controlSystemTreeWindows(
            requestedWindowID: windowID,
            includeAllWindows: false,
            focusedWindowID: nil,
            workspaceFilter: workspace.id
        )
        let rawSurfaces = try #require(rawTree.windows.first?.workspaces.first)
            .panes.flatMap(\.surfaces)
        let rawByID = Dictionary(uniqueKeysWithValues: rawSurfaces.map { ($0.surfaceID, $0) })
        #expect(rawByID[aliveID]?.processAlive == true)
        #expect(rawByID[exitedPanel.id]?.processAlive == false)
        #expect(rawByID[exitedPanel.id]?.tty == "/dev/ttys902")
        #expect(rawByID[remotePlaceholderPanel.id]?.processAlive == nil)

        let treeResult = try #require(ControlCommandCoordinator(context: TerminalController.shared).handle(
            ControlRequest(
                id: .int(1),
                method: "system.tree",
                params: [
                    "window_id": .string(windowID.uuidString),
                    "workspace_id": .string(workspace.id.uuidString),
                ]
            )
        ))
        let treeByID = try socketTreeSurfaceRows(treeResult)
        #expect(treeByID[aliveID]?["process_alive"] == .bool(true))
        #expect(treeByID[aliveID]?["tty"] == .string("/dev/ttys901"))
        #expect(treeByID[exitedPanel.id]?["process_alive"] == .bool(false))
        #expect(treeByID[exitedPanel.id]?["tty"] == .null)
        #expect(treeByID[remotePlaceholderPanel.id]?["process_alive"] == .null)
        #expect(treeByID[remotePlaceholderPanel.id]?["tty"] == .string("/dev/ttys903"))

        let top = try await TerminalController.shared.taskManagerTopPayload(includeProcesses: false)
        let topByID = try topSurfaceRows(top, windowID: windowID, workspaceID: workspace.id)
        #expect(topByID[aliveID]?["process_alive"] as? Bool == true)
        #expect(topByID[aliveID]?["tty"] as? String == "/dev/ttys901")
        #expect(topByID[exitedPanel.id]?["process_alive"] as? Bool == false)
        #expect(topByID[exitedPanel.id]?["tty"] is NSNull)
        #expect(topByID[remotePlaceholderPanel.id]?["process_alive"] is NSNull)
        #expect(topByID[remotePlaceholderPanel.id]?["tty"] as? String == "/dev/ttys903")
    }

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
                let expectedSurface = try #require(expectedPane.surfaces.first {
                    $0.surfaceID == surfaceID
                })
                let surfaceRef = try #require(surface["ref"] as? String)
                #expect(TerminalController.shared.v2ResolveHandleRef(surfaceRef) == surfaceID)

                let paneRef = try #require(surface["pane_ref"] as? String)
                #expect(TerminalController.shared.v2ResolveHandleRef(paneRef) == paneID)

                if let expectedProcessAlive = expectedSurface.processAlive {
                    #expect(surface["process_alive"] as? Bool == expectedProcessAlive)
                } else {
                    #expect(surface["process_alive"] is NSNull)
                }
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

    private func socketTreeSurfaceRows(
        _ result: ControlCallResult
    ) throws -> [UUID: [String: JSONValue]] {
        guard case .ok(.object(let root)) = result,
              case .array(let windows)? = root["windows"] else {
            Issue.record("Expected a successful system.tree payload")
            return [:]
        }
        let surfaces = windows.flatMap { window -> [JSONValue] in
            guard case .object(let fields) = window,
                  case .array(let workspaces)? = fields["workspaces"] else {
                return []
            }
            return workspaces.flatMap { workspace -> [JSONValue] in
                guard case .object(let workspaceFields) = workspace,
                      case .array(let panes)? = workspaceFields["panes"] else {
                    return []
                }
                return panes.flatMap { pane -> [JSONValue] in
                    guard case .object(let paneFields) = pane,
                          case .array(let paneSurfaces)? = paneFields["surfaces"] else {
                        return []
                    }
                    return paneSurfaces
                }
            }
        }
        return Dictionary(uniqueKeysWithValues: surfaces.compactMap { surface in
            guard case .object(let fields) = surface,
                  case .string(let rawID)? = fields["id"],
                  let id = UUID(uuidString: rawID) else {
                return nil
            }
            return (id, fields)
        })
    }

    private func topSurfaceRows(
        _ payload: [String: Any],
        windowID: UUID,
        workspaceID: UUID
    ) throws -> [UUID: [String: Any]] {
        let windows = try #require(payload["windows"] as? [[String: Any]])
        let window = try #require(windows.first { $0["id"] as? String == windowID.uuidString })
        let workspaces = try #require(window["workspaces"] as? [[String: Any]])
        let workspace = try #require(workspaces.first {
            $0["id"] as? String == workspaceID.uuidString
        })
        let panes = try #require(workspace["panes"] as? [[String: Any]])
        let surfaces = panes.flatMap { $0["surfaces"] as? [[String: Any]] ?? [] }
        return Dictionary(uniqueKeysWithValues: surfaces.compactMap { surface in
            guard let rawID = surface["id"] as? String,
                  let id = UUID(uuidString: rawID) else {
                return nil
            }
            return (id, surface)
        })
    }
}
