import CmuxCloud
import CmuxCore
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Switching a Claude pane's account respawns its surface with the account's
/// `CLAUDE_CONFIG_DIR`. The value must reach the child even when it is empty
/// (the default account) or the workspace sets the same key, a later plain
/// respawn must keep it, and a removed key must fall back to the workspace's
/// value or none.
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

    /// The seeded-workspace filter (#5995) must not mistake an override that
    /// differs from the workspace value for inherited workspace env.
    @Test
    func overrideOfWorkspaceValueSurvivesPlainRespawn() throws {
        let workspace = Workspace(workspaceEnvironment: [key: "/a"])
        let panelId = try #require(workspace.focusedPanelId)

        let first = try #require(workspace.respawnTerminalSurface(
            panelId: panelId,
            command: nil,
            environmentOverrides: [key: "/b"]
        ))
        #expect(first.surface.startupEnvironmentValue(key) == "/b")
        let second = try #require(workspace.respawnTerminalSurface(panelId: panelId, command: nil))

        #expect(second.surface.startupEnvironmentValue(key) == "/b")
    }

    /// The default account blanks a key the workspace sets; the blank must beat
    /// the workspace value now and after a plain respawn.
    @Test
    func emptyOverrideOfWorkspaceValueSurvivesPlainRespawn() throws {
        let workspace = Workspace(workspaceEnvironment: [key: "/a"])
        let panelId = try #require(workspace.focusedPanelId)

        let first = try #require(workspace.respawnTerminalSurface(
            panelId: panelId,
            command: nil,
            environmentOverrides: [key: ""]
        ))
        #expect(first.surface.startupEnvironmentValue(key) == "")
        let second = try #require(workspace.respawnTerminalSurface(panelId: panelId, command: nil))

        #expect(second.surface.respawnInitialEnvironmentOverrides[key] == "")
        #expect(second.surface.startupEnvironmentValue(key) == "")
    }

    @Test
    func removingEnvironmentKeysDropsInheritedOverride() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)

        try #require(workspace.respawnTerminalSurface(
            panelId: panelId,
            command: nil,
            environmentOverrides: [key: "/b"]
        ) != nil)
        let removed = try #require(workspace.respawnTerminalSurface(
            panelId: panelId,
            command: nil,
            removingEnvironmentKeys: [key]
        ))

        #expect(removed.surface.respawnInitialEnvironmentOverrides[key] == nil)
        #expect(removed.surface.startupEnvironmentValue(key) == nil)
        let later = try #require(workspace.respawnTerminalSurface(panelId: panelId, command: nil))
        #expect(later.surface.respawnInitialEnvironmentOverrides[key] == nil)
        #expect(later.surface.startupEnvironmentValue(key) == nil)
    }

    @Test
    func removingEnvironmentKeysFallsBackToWorkspaceValue() throws {
        let workspace = Workspace(workspaceEnvironment: [key: "/a"])
        let panelId = try #require(workspace.focusedPanelId)

        try #require(workspace.respawnTerminalSurface(
            panelId: panelId,
            command: nil,
            environmentOverrides: [key: "/b"]
        ) != nil)
        let removed = try #require(workspace.respawnTerminalSurface(
            panelId: panelId,
            command: nil,
            removingEnvironmentKeys: [key]
        ))

        #expect(removed.surface.respawnInitialEnvironmentOverrides[key] == nil)
        #expect(removed.surface.startupEnvironmentValue(key) == "/a")
        let later = try #require(workspace.respawnTerminalSurface(panelId: panelId, command: nil))
        #expect(later.surface.startupEnvironmentValue(key) == "/a")
    }

    /// A split's startup env rides the additional channel; removal drops it too.
    @Test
    func removingEnvironmentKeysDropsInheritedStartupEnvironment() throws {
        let workspace = Workspace()
        let sourcePanelId = try #require(workspace.focusedPanelId)
        let split = try #require(workspace.newTerminalSplit(
            from: sourcePanelId,
            orientation: .horizontal,
            focus: false,
            startupEnvironment: [key: "/split"]
        ))
        #expect(split.surface.startupEnvironmentValue(key) == "/split")

        let removed = try #require(workspace.respawnTerminalSurface(
            panelId: split.id,
            command: nil,
            removingEnvironmentKeys: [key]
        ))

        #expect(removed.surface.startupEnvironmentValue(key) == nil)
    }

    @Test
    func environmentOverrideWinsOverRemovalOfSameKey() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)

        try #require(workspace.respawnTerminalSurface(
            panelId: panelId,
            command: nil,
            environmentOverrides: [key: "/b"]
        ) != nil)
        let replaced = try #require(workspace.respawnTerminalSurface(
            panelId: panelId,
            command: nil,
            environmentOverrides: [key: "/c"],
            removingEnvironmentKeys: [key]
        ))

        #expect(replaced.surface.respawnInitialEnvironmentOverrides[key] == "/c")
        #expect(replaced.surface.startupEnvironmentValue(key) == "/c")
    }

    /// A native reservation hosts a remote terminal, so a local env change
    /// could not reach it. The respawn refuses and leaves the old surface in
    /// place instead of dropping it.
    @Test
    func nativeReservationRespawnRefusesLocalLaunchChanges() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)
        let oldPanel = try #require(workspace.terminalPanel(for: panelId))
        let reservation = CloudTerminalPaneReservation(
            workspaceID: workspace.id,
            panelID: panelId,
            machine: .cloud("respawn-account-\(UUID().uuidString)")
        )

        #expect(workspace.respawnTerminalSurface(
            panelId: panelId, command: nil, nativeReservation: reservation, environmentOverrides: [key: "/b"]
        ) == nil)
        #expect(workspace.respawnTerminalSurface(
            panelId: panelId, command: nil, nativeReservation: reservation, removingEnvironmentKeys: [key]
        ) == nil)
        #expect(workspace.terminalPanel(for: panelId) === oldPanel)
        #expect(workspace.cloudPendingCreations[panelId] == nil)
    }

    /// An SSH-owned surface respawns through its provider, which cannot carry a
    /// local env change; the respawn refuses before the
    /// provider closes the remote terminal.
    @Test
    func sshOwnedSurfaceRespawnRefusesLocalLaunchChanges() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let originalTabManager = appDelegate.tabManager
        let manager = originalTabManager ?? TabManager()
        appDelegate.tabManager = manager
        let workspace = try #require(manager.addWorkspaceIfActive(select: false))
        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace, recordHistory: false)
            }
            appDelegate.tabManager = originalTabManager
        }
        let panelId = try #require(workspace.focusedPanelId)
        let oldPanel = try #require(workspace.terminalPanel(for: panelId))
        let configuration = WorkspaceRemoteConfiguration(
            terminalProfile: .shell, destination: "alice@example.invalid", port: 2222, identityFile: nil,
            sshOptions: [], localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil,
            localSocketPath: nil, terminalStartupCommand: nil, configuredRemoteCommand: nil,
            preserveAfterTerminalExit: true
        )
        workspace.remoteConfiguration = configuration
        let catalog = SurfaceCatalog.shared
        let provider = CloudTerminalPlacementTestProvider(
            machine: .init(rawValue: SSHTuiConnection(configuration: configuration).id)
        )
        catalog.register(provider)
        defer {
            provider.release.resolve(true)
            catalog.endProjections(panelID: panelId, reason: .replaced)
            catalog.unregister(machine: provider.machine)
        }
        let original = provider.resource(key: "original")
        catalog.upsert(original, from: provider)
        catalog.record(SurfaceProjection(resource: original.id, workspaceID: workspace.id, panelID: panelId,
            remoteWorkspaceID: provider.remote.id, remoteTabID: "tab-original"))
        #expect(workspace.machineOwningSurface(panelId)?.isSSH == true)

        #expect(workspace.respawnTerminalSurface(
            panelId: panelId, command: nil, environmentOverrides: [key: "/b"]
        ) == nil)
        #expect(workspace.respawnTerminalSurface(
            panelId: panelId, command: nil, removingEnvironmentKeys: [key]
        ) == nil)
        #expect(workspace.terminalPanel(for: panelId) === oldPanel)
        #expect(provider.closedTerminals.isEmpty)
        #expect(provider.requestedCommands.isEmpty)
    }
}
