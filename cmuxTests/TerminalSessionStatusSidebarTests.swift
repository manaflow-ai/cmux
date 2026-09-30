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

    @Test func sessionStatusMovesWithItsSurfaceToAnotherWorkspace() throws {
        let source = Workspace()
        let sourcePane = try #require(source.bonsplitController.allPaneIds.first)
        let movedId = try #require(source.newTerminalSurface(inPane: sourcePane, focus: false)?.id)
        var status = TerminalSessionStatus()
        feed("\u{1B}]21337;status=Reviewing;indicator=#00aa00\u{07}", into: &status)
        source.applyTerminalSessionStatus(status, panelId: movedId)
        let original = try #require(entry(source, panelId: movedId))

        let transfer = try #require(source.detachSurface(panelId: movedId))
        #expect(entry(source, panelId: movedId) == nil)

        let destination = Workspace()
        let destinationPane = try #require(destination.bonsplitController.allPaneIds.first)
        #expect(destination.attachDetachedSurface(transfer, inPane: destinationPane, focus: false) == movedId)

        // The program does not re-send an unchanged status after the move.
        #expect(entry(destination, panelId: movedId) == original)
    }

    @Test func repeatedUnchangedStatusKeepsItsTimestamp() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        var status = TerminalSessionStatus()
        feed("\u{1B}]21337;status=Working;indicator=#ffa500\u{07}", into: &status)
        workspace.applyTerminalSessionStatus(status, panelId: panelId)
        let first = try #require(entry(workspace, panelId: panelId))

        feed("\u{1B}]21337;status=Working;indicator=#ffa500\u{07}", into: &status)
        workspace.applyTerminalSessionStatus(status, panelId: panelId)

        #expect(entry(workspace, panelId: panelId)?.timestamp == first.timestamp)
    }

    // MARK: PTY tee publishing

    @MainActor
    private final class PublishedStatuses {
        var values: [TerminalSessionStatus] = []
    }

    private func consume(_ output: String, in context: TerminalOutputTeeContext) {
        Data(output.utf8).withUnsafeBytes { raw in
            context.consume(raw.bindMemory(to: UInt8.self))
        }
    }

    private func scheduler(clock: SidebarTestManualClock) -> TerminalOutputTeeContext.SessionStatusScheduler {
        { operation in
            Task { @MainActor in
                do {
                    try await clock.sleep(for: .milliseconds(250))
                    operation()
                } catch {
                    // Test teardown can cancel a scheduled publication.
                }
            }
        }
    }

    private func advancePublication(clock: SidebarTestManualClock) async {
        await clock.waitUntilSleeping(for: .milliseconds(250))
        clock.advance(by: .milliseconds(250))
        for _ in 0..<10 { await Task.yield() }
    }

    @Test func setThenClearInOnePublishWindowEndsCleared() async throws {
        let published = PublishedStatuses()
        let clock = SidebarTestManualClock()
        let context = TerminalOutputTeeContext(
            workspaceID: UUID(),
            surfaceID: UUID(),
            agentDefinitions: [],
            sessionStatusSink: { published.values.append($0) },
            sessionStatusScheduler: scheduler(clock: clock)
        )

        consume("\u{1B}]21337;status=Working;indicator=#ffa500\u{07}", in: context)
        consume("\u{1B}]21337;status=;indicator=\u{07}", in: context)
        await advancePublication(clock: clock)
        #expect(published.values.count >= 1)
        // A later status is the fence: any second, wrongly scheduled publish
        // of the first window would land before it.
        consume("\u{1B}]21337;status=Done\u{07}", in: context)
        await advancePublication(clock: clock)
        #expect(published.values.count >= 2)

        #expect(published.values.first == TerminalSessionStatus())
        #expect(published.values.count == 2)
        #expect(published.values.last?.status == "Done")
    }

    @Test func resentUnchangedStatusRestoresAClearedEntry() async throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let published = PublishedStatuses()
        let clock = SidebarTestManualClock()
        let context = TerminalOutputTeeContext(
            workspaceID: workspace.id,
            surfaceID: panelId,
            agentDefinitions: [],
            sessionStatusSink: { status in
                published.values.append(status)
                workspace.applyTerminalSessionStatus(status, panelId: panelId)
            },
            sessionStatusScheduler: scheduler(clock: clock)
        )

        consume("\u{1B}]21337;status=Working\u{07}", in: context)
        await advancePublication(clock: clock)
        #expect(published.values.count >= 1)
        #expect(entry(workspace, panelId: panelId)?.value == "Working")

        // e.g. `cmux clear-status` or a sidebar context reset.
        workspace.clearStatusEntry(key: Workspace.terminalSessionStatusKey(panelId: panelId), panelId: nil)
        #expect(entry(workspace, panelId: panelId) == nil)

        consume("\u{1B}]21337;status=Working\u{07}", in: context)
        await advancePublication(clock: clock)
        #expect(published.values.count >= 2)
        #expect(entry(workspace, panelId: panelId)?.value == "Working")
    }
}
