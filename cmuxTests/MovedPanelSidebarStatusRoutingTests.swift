import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct MovedPanelSidebarStatusRoutingTests {
    @Test func panelScopedMutationsRouteMovedSurfaceToCurrentWorkspace() throws {
        try withMovedPanelTestContext { moved in
            let staleTab = moved.source.id.uuidString
            let panel = moved.panelID.uuidString

            #expect(
                TerminalController.shared.handleSocketLine(
                    "set_status codex Running --icon=bolt.fill --color=#4C8DFF --tab=\(staleTab) --panel=\(panel) --pid=111"
                ) == "OK"
            )
            TerminalMutationBus.shared.drainForTesting()
            #expect(moved.source.statusEntries["codex"] == nil)
            #expect(moved.destination.statusEntries["codex"]?.value == "Running")
            #expect(moved.destination.agentPIDs["codex"].map(Int.init) == 111)

            #expect(
                TerminalController.shared.handleSocketLine(
                    "report_meta build compiling --tab=\(staleTab) --panel=\(panel)"
                ) == "OK"
            )
            TerminalMutationBus.shared.drainForTesting()
            #expect(moved.source.statusEntries["build"] == nil)
            #expect(moved.destination.statusEntries["build"]?.value == "compiling")

            #expect(
                TerminalController.shared.handleSocketLine(
                    "set_agent_pid codex.session 222 --tab=\(staleTab) --panel=\(panel)"
                ) == "OK"
            )
            TerminalMutationBus.shared.drainForTesting()
            #expect(moved.source.agentPIDs["codex.session"] == nil)
            #expect(moved.destination.agentPIDs["codex.session"].map(Int.init) == 222)

            #expect(
                TerminalController.shared.handleSocketLine(
                    "set_agent_lifecycle codex running --tab=\(staleTab) --panel=\(panel)"
                ) == "OK"
            )
            TerminalMutationBus.shared.drainForTesting()
            #expect(moved.source.agentLifecycleStatesByPanelId[moved.panelID]?["codex"] == nil)
            #expect(moved.destination.agentLifecycleStatesByPanelId[moved.panelID]?["codex"] == .running)

            let customAgentRoot = try makeCustomAgentConfigRoot(agentID: "local-agent")
            defer { try? FileManager.default.removeItem(at: customAgentRoot) }
            moved.destination.panelDirectories[moved.panelID] = customAgentRoot.path

            #expect(
                TerminalController.shared.handleSocketLine(
                    "set_agent_lifecycle local-agent idle --tab=\(staleTab) --panel=\(panel)"
                ) == "OK"
            )
            TerminalMutationBus.shared.drainForTesting()
            #expect(moved.source.agentLifecycleStatesByPanelId[moved.panelID]?["local-agent"] == nil)
            #expect(moved.destination.agentLifecycleStatesByPanelId[moved.panelID]?["local-agent"] == .idle)

            #expect(
                TerminalController.shared.handleSocketLine(
                    "clear_agent_pid codex.session --tab=\(staleTab) --panel=\(panel)"
                ) == "OK"
            )
            TerminalMutationBus.shared.drainForTesting()
            #expect(moved.destination.agentPIDs["codex.session"] == nil)

            #expect(
                TerminalController.shared.handleSocketLine(
                    "clear_status build --tab=\(staleTab) --panel=\(panel)"
                ) == "OK"
            )
            TerminalMutationBus.shared.drainForTesting()
            #expect(moved.destination.statusEntries["build"] == nil)
        }
    }

    @Test func panelScopedMutationsDoNotFallbackForImplicitOrNonWorkspaceTargets() throws {
        try withMovedPanelTestContext { moved in
            let unrelated = moved.manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
            let panel = moved.panelID.uuidString

            #expect(
                TerminalController.shared.handleSocketLine(
                    "set_status selected Running --panel=\(panel)"
                ) == "OK"
            )
            TerminalMutationBus.shared.drainForTesting()
            #expect(moved.source.statusEntries["selected"] == nil)
            #expect(moved.destination.statusEntries["selected"] == nil)

            #expect(
                TerminalController.shared.handleSocketLine(
                    "set_status indexed Running --tab=0 --panel=\(panel)"
                ) == "OK"
            )
            TerminalMutationBus.shared.drainForTesting()
            #expect(moved.source.statusEntries["indexed"] == nil)
            #expect(moved.destination.statusEntries["indexed"] == nil)

            #expect(
                TerminalController.shared.handleSocketLine(
                    "set_status unrelated Running --tab=\(unrelated.id.uuidString) --panel=\(panel)"
                ) == "OK"
            )
            TerminalMutationBus.shared.drainForTesting()
            #expect(moved.source.statusEntries["unrelated"] == nil)
            #expect(moved.destination.statusEntries["unrelated"] == nil)
            #expect(unrelated.statusEntries["unrelated"] == nil)

            #expect(
                TerminalController.shared.handleSocketLine(
                    "set_status unknown Running --tab=\(UUID().uuidString) --panel=\(panel)"
                ) == "OK"
            )
            TerminalMutationBus.shared.drainForTesting()
            #expect(moved.source.statusEntries["unknown"] == nil)
            #expect(moved.destination.statusEntries["unknown"] == nil)
        }
    }

    @Test func panelScopedMutationsRouteMovedSurfaceAfterSourceWorkspaceCloses() throws {
        try withMovedPanelTestContext { moved in
            let staleTab = moved.source.id.uuidString
            let panel = moved.panelID.uuidString
            moved.manager.closeWorkspace(moved.source, recordHistory: false)
            #expect(!moved.manager.tabs.contains { $0.id == moved.source.id })

            #expect(
                TerminalController.shared.handleSocketLine(
                    "set_status closed-source Running --tab=\(staleTab) --panel=\(panel)"
                ) == "OK"
            )
            TerminalMutationBus.shared.drainForTesting()
            #expect(moved.destination.statusEntries["closed-source"]?.value == "Running")
        }
    }

    private struct MovedPanelTestContext {
        let manager: TabManager
        let source: Workspace
        let destination: Workspace
        let panelID: UUID
    }

    private func withMovedPanelTestContext(
        _ body: (_ moved: MovedPanelTestContext) throws -> Void
    ) throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let moved = try makeMovedTerminalSurface(in: manager)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
            TerminalMutationBus.shared.drainForTesting()
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
        }
        TerminalController.shared.setActiveTabManager(manager)

        try body(
            MovedPanelTestContext(
                manager: manager,
                source: moved.source,
                destination: moved.destination,
                panelID: moved.panelID
            )
        )
    }

    private func makeMovedTerminalSurface(
        in manager: TabManager
    ) throws -> (source: Workspace, destination: Workspace, panelID: UUID) {
        let source = manager.addWorkspace(select: true, autoWelcomeIfNeeded: false)
        let destination = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        let sourcePanelID = try #require(source.focusedTerminalPanel?.id)
        let panel = try #require(
            source.newTerminalSplit(
                from: sourcePanelID,
                orientation: .horizontal,
                initialCommand: nil
            )
        )
        let detached = try #require(source.detachSurface(panelId: panel.id))
        let destinationPaneID = try #require(destination.bonsplitController.allPaneIds.first)
        #expect(destination.attachDetachedSurface(detached, inPane: destinationPaneID, focus: false) == panel.id)
        return (source, destination, panel.id)
    }

    private func makeCustomAgentConfigRoot(agentID: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-moved-panel-agent-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = root.appendingPathComponent(".cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try """
        {
          "vault": {
            "agents": [
              {
                "id": "\(agentID)",
                "name": "Local Agent",
                "detect": { "processName": "\(agentID)" },
                "sessionIdSource": { "type": "argvOption", "argvOption": "--session" },
                "resumeCommand": "\(agentID) --session {{sessionId}}",
                "cwd": "preserve"
              }
            ]
          }
        }
        """.write(to: configDirectory.appendingPathComponent("cmux.json"), atomically: true, encoding: .utf8)
        return root
    }
}
