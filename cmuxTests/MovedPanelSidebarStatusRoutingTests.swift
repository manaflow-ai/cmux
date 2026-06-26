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
}
