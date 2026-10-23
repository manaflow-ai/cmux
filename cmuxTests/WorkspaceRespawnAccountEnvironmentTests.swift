import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Switching a Claude pane's account respawns its surface with the account's
/// `CLAUDE_CONFIG_DIR`. The value must reach the child even when it is empty
/// (the default account) or the workspace sets the same key, and a later plain
/// respawn must keep it.
@MainActor
@Suite(.serialized)
struct WorkspaceRespawnAccountEnvironmentTests {
    private let key = "CLAUDE_CONFIG_DIR"

    @Test
    func respawnAppliesEnvironmentOverridesIncludingEmpty() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)

        let newPanel = try #require(workspace.respawnTerminalSurface(
            panelId: panelId,
            command: nil,
            environmentOverrides: [key: ""]
        ))

        #expect(newPanel.surface.respawnInitialEnvironmentOverrides[key] == "")
        #expect(newPanel.surface.startupEnvironmentValue(key) == "")
    }

    @Test
    func overridesBeatWorkspaceEnvironment() throws {
        let workspace = Workspace(workspaceEnvironment: [key: "/a"])
        let panelId = try #require(workspace.focusedPanelId)

        let newPanel = try #require(workspace.respawnTerminalSurface(
            panelId: panelId,
            command: nil,
            environmentOverrides: [key: "/b"]
        ))

        #expect(newPanel.surface.respawnInitialEnvironmentOverrides[key] == "/b")
        #expect(newPanel.surface.startupEnvironmentValue(key) == "/b")
    }

    @Test
    func respawnForwardsInitialInput() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let input = "echo cmux-respawn-startup-input\n"

        let newPanel = try #require(workspace.respawnTerminalSurface(
            panelId: panelId,
            command: nil,
            initialInput: input
        ))

        #expect(newPanel.surface.initialInput == input)
    }

    @Test
    func secondRespawnKeepsAccountOverride() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)

        try #require(workspace.respawnTerminalSurface(
            panelId: panelId,
            command: nil,
            environmentOverrides: [key: "/b"]
        ) != nil)
        let second = try #require(workspace.respawnTerminalSurface(panelId: panelId, command: nil))

        #expect(second.surface.respawnInitialEnvironmentOverrides[key] == "/b")
        #expect(second.surface.startupEnvironmentValue(key) == "/b")
    }
}
