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
    func reportedCloseSurfaceLeaderKeepsTheWorkspace() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let harness = try GhosttyWorkspaceActionTestHarness()
            defer { harness.close() }
            let surface = try await harness.startTerminal()
            let workspace = try #require(harness.manager.selectedWorkspace)
            _ = try #require(workspace.newTerminalSplit(from: surface.id, orientation: .horizontal))
            harness.manager.confirmCloseHandler = { _, _, _ in true }
            try harness.configure(surface, contents: Self.reportedConfig)
            #expect(workspace.panels.count == 2)

            #expect(harness.press("b", keyCode: 11, control: true, on: surface))
            #expect(harness.press("q", keyCode: 12, on: surface))

            #expect(await AppKitTestEventPump().waitUntil { workspace.panels.count == 1 })
            #expect(harness.manager.tabs.contains(where: { $0.id == workspace.id }))
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

    @Test
    func navigationUsesTheSourceWindowAndNeverCreatesAnOutOfRangeWorkspace() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let source = try GhosttyWorkspaceActionTestHarness()
            defer { source.close() }
            for _ in 1..<10 {
                _ = source.manager.addWorkspaceIfActive(
                    select: false, placementOverride: .end,
                    autoWelcomeIfNeeded: false, autoRefreshMetadata: false
                )
            }
            let surface = try await source.startTerminal()
            let other = try GhosttyWorkspaceActionTestHarness()
            defer { other.close() }
            let ids = source.manager.tabs.map(\.id)
            let otherSelection = other.manager.selectedTabId
            let windowCount = NSApp.windows.count

            #expect(surface.performBindingAction("goto_tab:9"))
            #expect(source.manager.selectedTabId == ids[8])
            #expect(surface.performBindingAction("last_tab"))
            #expect(source.manager.selectedTabId == ids.last)
            #expect(surface.performBindingAction("next_tab"))
            #expect(source.manager.selectedTabId == ids.first)
            #expect(surface.performBindingAction("previous_tab"))
            #expect(source.manager.selectedTabId == ids.last)
            #expect(!surface.performBindingAction("goto_tab:9999"))
            #expect(!surface.performBindingAction("goto_tab:0"))
            #expect(source.manager.tabs.map(\.id) == ids)
            #expect(other.manager.selectedTabId == otherSelection)
            #expect(NSApp.windows.count == windowCount)
        }
    }

    @Test
    func keyTablesAndBindingFlagsUseGhosttysEngine() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let harness = try GhosttyWorkspaceActionTestHarness()
            defer { harness.close() }
            let second = try #require(harness.manager.addWorkspaceIfActive(
                select: false, placementOverride: .end,
                autoWelcomeIfNeeded: false, autoRefreshMetadata: false
            ))
            let surface = try await harness.startTerminal()
            try harness.configure(surface, contents: """
                keybind = ctrl+y=activate_key_table:workspaces
                keybind = workspaces/2=goto_tab:2
                keybind = performable:ctrl+g=goto_tab:9999
                keybind = unconsumed:ctrl+j=next_tab
                keybind = ctrl+page_down=next_tab
                """)
            #expect(harness.press("y", keyCode: 16, control: true, on: surface))
            #expect(harness.press("2", keyCode: 19, on: surface))
            #expect(harness.manager.selectedTabId == second.id)
            #expect(surface.performBindingAction("deactivate_all_key_tables"))
            #expect(!harness.press("g", keyCode: 5, control: true, on: surface))
            #expect(harness.manager.selectedTabId == second.id)
            #expect(!harness.press("j", keyCode: 38, control: true, on: surface))
            #expect(harness.manager.selectedTabId == harness.sourceWorkspaceID)
            #expect(harness.press("", keyCode: 121, control: true, on: surface))
            #expect(harness.manager.selectedTabId == second.id)
        }
    }

    @Test
    func closeTabUsesWorkspaceConfirmationAndHonorsCancellation() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let harness = try GhosttyWorkspaceActionTestHarness()
            defer { harness.close() }
            let workspace = try #require(harness.manager.selectedWorkspace)
            _ = harness.manager.addWorkspaceIfActive(
                select: false, autoWelcomeIfNeeded: false, autoRefreshMetadata: false
            )
            let surface = try await harness.startTerminal()
            // Pinned workspaces always enter the existing confirmation path.
            harness.manager.setPinned(workspace, pinned: true)
            var prompts = 0
            var acceptsClose = false
            harness.manager.confirmCloseHandler = { _, _, _ in
                prompts += 1
                return acceptsClose
            }
            #expect(surface.performBindingAction("close_tab"))
            #expect(await AppKitTestEventPump().waitUntil {
                prompts == 1 && !harness.manager.isCloseConfirmationInFlight
            })
            #expect(harness.manager.tabs.contains(where: { $0.id == workspace.id }))
            acceptsClose = true
            #expect(surface.performBindingAction("close_tab"))
            #expect(await AppKitTestEventPump().waitUntil {
                !harness.manager.tabs.contains(where: { $0.id == workspace.id })
            })
            #expect(prompts == 2)
        }
    }

    @Test
    func moveTabPreservesWorkspaceIdentity() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let harness = try GhosttyWorkspaceActionTestHarness()
            defer { harness.close() }
            for _ in 1..<3 {
                _ = harness.manager.addWorkspaceIfActive(
                    select: false, placementOverride: .end,
                    autoWelcomeIfNeeded: false, autoRefreshMetadata: false
                )
            }
            let surface = try await harness.startTerminal()
            let ids = harness.manager.tabs.map(\.id)
            #expect(surface.performBindingAction("move_tab:1"))
            #expect(harness.manager.tabs.map(\.id) == [ids[1], ids[0], ids[2]])
            #expect(harness.manager.selectedTabId == ids[0])
            #expect(surface.performBindingAction("move_tab:-1"))
            #expect(harness.manager.tabs.map(\.id) == ids)
            #expect(surface.performBindingAction("move_tab:-1"))
            #expect(harness.manager.tabs.map(\.id) == [ids[1], ids[2], ids[0]])
            let workspace = try #require(harness.manager.tabs.first(where: { $0.id == ids[0] }))
            harness.manager.setPinned(workspace, pinned: true)
            _ = surface.performBindingAction("move_tab:\(Int.max)")
            #expect(harness.manager.tabs.first?.id == ids[0])
            #expect(harness.manager.selectedTabId == ids[0])
        }
    }

    @Test
    func closeWindowUsesTheSourceWindowConfirmation() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let source = try GhosttyWorkspaceActionTestHarness()
            defer { source.close() }
            let surface = try await source.startTerminal()
            let other = try GhosttyWorkspaceActionTestHarness()
            defer { other.close() }
            let originalHandler = source.app.debugCloseMainWindowConfirmationHandler
            defer { source.app.debugCloseMainWindowConfirmationHandler = originalHandler }
            var confirmedWindow: NSWindow?
            source.app.debugCloseMainWindowConfirmationHandler = { window in
                confirmedWindow = window
                return false
            }
            #expect(surface.performBindingAction("close_window"))
            #expect(await AppKitTestEventPump().waitUntil { confirmedWindow != nil })
            #expect(confirmedWindow === source.window)
            #expect(source.app.tabManagerFor(windowId: source.windowID) === source.manager)
            #expect(source.app.tabManagerFor(windowId: other.windowID) === other.manager)
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
