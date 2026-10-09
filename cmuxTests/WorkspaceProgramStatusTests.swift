import Foundation
import Testing
import CmuxSidebar

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct WorkspaceProgramStatusTests {
    @Test func projectsMostUrgentPanelRecord() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.applyProgramStatus(
            ProgramStatusReport(state: .working, app: "cargo", message: "Building"),
            panelId: panelId
        )
        workspace.applyProgramStatus(
            ProgramStatusReport(state: .blocked, kind: .permission, id: "deploy", message: "Approve?"),
            panelId: panelId
        )
        let entry = try #require(workspace.statusEntries[Workspace.programStatusKey])
        #expect(entry.icon == "bell.fill")
        #expect(entry.value.contains("Approve?"))
        #expect(workspace.programStatusStoresByPanelId[panelId]?.mostUrgentRecord()?.state == .blocked)
    }

    @Test func programStatusIsNotAgentLifecycleState() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.applyProgramStatus(
            ProgramStatusReport(state: .blocked, kind: .auth, app: "brew"),
            panelId: panelId
        )
        #expect(workspace.agentLifecycleStatesByPanelId[panelId] == nil)
        #expect(workspace.agentRuntimeState(forPanelId: panelId) == nil)
        #expect(workspace.statusEntries[Workspace.programStatusKey]?.value == "brew · Needs sign-in")
    }

    @Test func workingShowsPercentAndPromptDropsTransientRecords() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.applyProgramStatus(
            ProgramStatusReport(state: .done, id: "lint", app: "cargo", message: "Lint clean"),
            panelId: panelId
        )
        workspace.applyProgramStatus(
            ProgramStatusReport(state: .working, progress: 40, app: "cargo", message: "Building"),
            panelId: panelId
        )
        #expect(workspace.statusEntries[Workspace.programStatusKey]?.value == "cargo · Building · 40%")

        workspace.applyProgramStatus(ProgramStatusReport(event: .promptStart, state: .idle), panelId: panelId)
        let entry = try #require(workspace.statusEntries[Workspace.programStatusKey])
        #expect(entry.icon == "checkmark.circle.fill")
        #expect(entry.value == "cargo · Lint clean")

        workspace.dismissCompletedProgramStatus(panelId: panelId)
        #expect(workspace.statusEntries[Workspace.programStatusKey] == nil)
    }

    @Test func sanitizesInvisibleFormattingAndCapsDisplay() {
        let workspace = Workspace()
        let value = workspace.sanitizedProgramStatusText("hello\u{202E}world")
        #expect(value == "helloworld")
        #expect(workspace.sanitizedProgramStatusText(String(repeating: "x", count: 600))?.count == 512)
    }
}
