import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// loop reports itself with `set_status loop … --pid=<pid>`, the same way the
/// hook integrations do, so its tab must pick up loop's mark from that key.
@MainActor
@Suite("loop agent icon")
struct LoopAgentIconTests {
    @Test("A tab running loop shows loop's mark")
    func tabRunningLoopShowsMark() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)

        workspace.recordAgentPID(key: "loop", pid: getpid(), panelId: panelId)

        #expect(workspace.terminalTabAgentIconAsset(forPanelId: panelId) == "AgentIcons/Loop")
    }

    @Test("The loop mark ships in the asset catalog")
    func markShipsInAssetCatalog() {
        #expect(NSImage(named: "AgentIcons/Loop") != nil)
    }
}
