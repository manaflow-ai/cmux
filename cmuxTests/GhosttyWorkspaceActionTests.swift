import AppKit
import CmuxTerminal
import GhosttyKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct GhosttyWorkspaceActionTests {
    @Test
    func reportedLeaderCreatesWorkspace() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let harness = try GhosttyWorkspaceActionTestHarness()
            defer { harness.close() }
            let surface = try await harness.startTerminal()
            try harness.configure(surface, contents: Self.reportedConfig)
            let count = harness.manager.tabs.count

            #expect(harness.press("b", keyCode: 11, control: true, on: surface))
            #expect(harness.press("c", keyCode: 8, on: surface))

            #expect(harness.manager.tabs.count == count + 1)
            #expect(harness.manager.selectedTabId != harness.sourceWorkspaceID)
        }
    }

    @Test
    func reportedLeaderSelectsWorkspacesOneThroughSix() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let harness = try GhosttyWorkspaceActionTestHarness()
            defer { harness.close() }
            for _ in 1..<6 {
                _ = harness.manager.addWorkspaceIfActive(
                    select: false, placementOverride: .end,
                    autoWelcomeIfNeeded: false, autoRefreshMetadata: false
                )
            }
            let expectedIDs = harness.manager.tabs.map(\.id)
            let surface = try await harness.startTerminal()
            try harness.configure(surface, contents: Self.reportedConfig)
            // Start at the last workspace so selecting 1 cannot pass as a no-op.
            harness.manager.selectTab(at: 5)
            let keyCodes: [UInt32] = [18, 19, 20, 21, 23, 22]
            for digit in 1...6 {
                #expect(harness.press("b", keyCode: 11, control: true, on: surface))
                #expect(harness.press(String(digit), keyCode: keyCodes[digit - 1], on: surface))
                #expect(harness.manager.selectedTabId == expectedIDs[digit - 1])
            }
            #expect(harness.manager.tabs.map(\.id) == expectedIDs)
        }
    }

    // Verbatim reproduction from https://github.com/manaflow-ai/cmux/issues/14462.
    static let reportedConfig = """
    keybind = ctrl+b>c=new_tab
    keybind = ctrl+b>q=close_surface
    keybind = ctrl+b>1=goto_tab:1
    keybind = ctrl+b>2=goto_tab:2
    keybind = ctrl+b>3=goto_tab:3
    keybind = ctrl+b>4=goto_tab:4
    keybind = ctrl+b>5=goto_tab:5
    keybind = ctrl+b>6=goto_tab:6
    """
}
