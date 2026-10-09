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
            ProgramStatusReport(state: .blocked, kind: .permission, message: "Approve?", id: "deploy"),
            panelId: panelId
        )
        let entry = try #require(workspace.statusEntries[Workspace.programStatusKey])
        #expect(entry.icon == "bell.fill")
        #expect(entry.value.contains("Approve?"))
        #expect(workspace.programStatusStoresByPanelId[panelId]?.mostUrgentRecord()?.state == .blocked)
    }

    @Test func sanitizesInvisibleFormattingAndCapsDisplay() {
        let workspace = Workspace()
        let value = workspace.sanitizedProgramStatusText("hello\u{202E}world")
        #expect(value == "helloworld")
        #expect(workspace.sanitizedProgramStatusText(String(repeating: "x", count: 600))?.count == 512)
    }
}
