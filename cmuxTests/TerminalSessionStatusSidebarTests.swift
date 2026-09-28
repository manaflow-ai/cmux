import Foundation
import Testing

import CmuxSidebar
import CmuxTerminalCore

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// OSC 21337 output from a terminal becomes one sidebar status entry per
/// surface, owned by the workspace status store.
@MainActor
struct TerminalSessionStatusSidebarTests {
    private func feed(_ output: String, into status: inout TerminalSessionStatus) {
        var scanner = TerminalSessionStatusOSCScanner()
        for update in scanner.consume(Data(output.utf8)) {
            status.apply(update)
        }
    }

    private func entry(_ workspace: Workspace, panelId: UUID) -> SidebarStatusEntry? {
        let key = Workspace.terminalSessionStatusKey(panelId: panelId)
        return workspace.sidebarStatusEntriesInDisplayOrder().first { $0.key == key }
    }

    @Test func sessionStatusShowsOneEntryPerSurfaceAndClearsOnEmptyStatus() throws {
        let workspace = Workspace()
        let paneId = try #require(workspace.bonsplitController.allPaneIds.first)
        let firstId = try #require(workspace.focusedPanelId)
        let secondId = try #require(workspace.newTerminalSurface(inPane: paneId, focus: false)?.id)

        var first = TerminalSessionStatus()
        feed("\u{1B}]21337;status=Working;indicator=#ffa500;detail=cargo test\u{07}", into: &first)
        workspace.applyTerminalSessionStatus(first, panelId: firstId)
        var second = TerminalSessionStatus()
        feed("\u{1B}]21337;status=Waiting;status-color=rgb:33/66/99\u{1B}\\", into: &second)
        workspace.applyTerminalSessionStatus(second, panelId: secondId)

        let firstEntry = try #require(entry(workspace, panelId: firstId))
        #expect(firstEntry.value == "Working · cargo test")
        #expect(firstEntry.color == "#ffa500")
        #expect(firstEntry.icon == "circle.fill")
        #expect(firstEntry.url == nil)
        #expect(firstEntry.format == .plain)
        let secondEntry = try #require(entry(workspace, panelId: secondId))
        #expect(secondEntry.value == "Waiting")
        #expect(secondEntry.color == "#336699")
        #expect(secondEntry.icon == nil)

        feed("\u{1B}]21337;status=;detail=\u{07}", into: &first)
        workspace.applyTerminalSessionStatus(first, panelId: firstId)

        #expect(entry(workspace, panelId: firstId) == nil)
        #expect(entry(workspace, panelId: secondId)?.value == "Waiting")
    }

    @Test func sessionStatusIsRemovedWhenItsSurfaceClosesAndIsNotRevived() throws {
        let workspace = Workspace()
        let paneId = try #require(workspace.bonsplitController.allPaneIds.first)
        let keptId = try #require(workspace.focusedPanelId)
        let closedId = try #require(workspace.newTerminalSurface(inPane: paneId, focus: true)?.id)

        var status = TerminalSessionStatus()
        feed("\u{1B}]21337;status=Building\u{07}", into: &status)
        workspace.applyTerminalSessionStatus(status, panelId: closedId)
        workspace.applyTerminalSessionStatus(status, panelId: keptId)
        #expect(entry(workspace, panelId: closedId)?.value == "Building")

        #expect(workspace.closePanel(closedId, force: true))
        #expect(workspace.panels[closedId] == nil)
        #expect(entry(workspace, panelId: closedId) == nil)
        #expect(entry(workspace, panelId: keptId)?.value == "Building")

        // A publish that was already in flight when the surface closed.
        workspace.applyTerminalSessionStatus(status, panelId: closedId)
        #expect(entry(workspace, panelId: closedId) == nil)
    }

    @Test func sessionStatusIsNotPersistedInSessionSnapshots() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.statusEntries["build"] = SidebarStatusEntry(key: "build", value: "ok")
        var status = TerminalSessionStatus()
        feed("\u{1B}]21337;status=Working\u{07}", into: &status)
        workspace.applyTerminalSessionStatus(status, panelId: panelId)

        let keys = workspace.sessionSnapshot(includeScrollback: false).statusEntries.map(\.key)

        #expect(keys == ["build"])
    }
}
