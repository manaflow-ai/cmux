import Foundation
import CmuxCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct WorkspaceTerminalWorkingDirectoryFallbackTests {
    @Test func newTerminalSurfaceFallsBackToRequestedWorkingDirectoryWhenReportedDirectoryIsStale() throws {
        let workspace = Workspace()
        let sourcePaneId = try #require(
            workspace.bonsplitController.focusedPaneId,
            "Expected focused pane in new workspace"
        )

        let staleCurrentDirectory = workspace.currentDirectory
        let requestedDirectory = "/tmp/cmux-requested-tab-cwd-\(UUID().uuidString)"
        let sourcePanel = try #require(
            workspace.newTerminalSurface(
                inPane: sourcePaneId,
                focus: true,
                workingDirectory: requestedDirectory
            ),
            "Expected source terminal panel to be created"
        )

        #expect(sourcePanel.requestedWorkingDirectory == requestedDirectory)
        #expect(
            workspace.panelDirectories[sourcePanel.id] == nil,
            "Expected requested cwd to exist before shell integration reports a live cwd"
        )
        #expect(
            workspace.currentDirectory == staleCurrentDirectory,
            "Expected focused workspace cwd to remain stale before panel directory updates"
        )

        let newTabPanel = try #require(
            workspace.newTerminalSurfaceInFocusedPane(focus: false),
            "Expected new terminal tab panel to be created"
        )

        #expect(
            newTabPanel.requestedWorkingDirectory == requestedDirectory,
            "Expected new terminal tab to inherit the selected source terminal's requested cwd when no reported cwd exists yet"
        )
    }

    @Test func promptIdleFallbackLiveWorkingDirectoryBeatsTrackedDirectory() throws {
        let workspace = Workspace()
        let sourcePanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let staleDirectory = "/tmp/cmux-stale-\(UUID().uuidString)"
        let liveDirectory = "/tmp/cmux-live-\(UUID().uuidString)"

        #expect(workspace.updatePanelDirectory(panelId: sourcePanelId, directory: staleDirectory))
        workspace.panelShellActivityStates[sourcePanelId] = .promptIdle
        workspace.foregroundProcessWorkingDirectoryProvider = { panelId in
            panelId == sourcePanelId ? liveDirectory : nil
        }

        let panel = try #require(workspace.newTerminalSurface(
            inPane: paneId,
            focus: false,
            inheritWorkingDirectoryFallback: true,
            workingDirectoryFallbackSourcePanelId: sourcePanelId
        ))

        #expect(panel.requestedWorkingDirectory == liveDirectory)
    }

    @Test func commandRunningFallbackLiveWorkingDirectoryDoesNotBeatTrackedDirectory() throws {
        let workspace = Workspace()
        let sourcePanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let trackedDirectory = "/tmp/cmux-tracked-\(UUID().uuidString)"
        let foregroundDirectory = "/tmp/cmux-child-process-\(UUID().uuidString)"

        #expect(workspace.updatePanelDirectory(panelId: sourcePanelId, directory: trackedDirectory))
        workspace.panelShellActivityStates[sourcePanelId] = .commandRunning
        workspace.foregroundProcessWorkingDirectoryProvider = { panelId in
            panelId == sourcePanelId ? foregroundDirectory : nil
        }

        let panel = try #require(workspace.newTerminalSurface(
            inPane: paneId,
            focus: false,
            inheritWorkingDirectoryFallback: true,
            workingDirectoryFallbackSourcePanelId: sourcePanelId
        ))

        #expect(panel.requestedWorkingDirectory == trackedDirectory)
    }

    @Test func unknownShellStateFallbackLiveWorkingDirectoryDoesNotBeatTrackedDirectory() throws {
        let workspace = Workspace()
        let sourcePanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let trackedDirectory = "/tmp/cmux-tracked-\(UUID().uuidString)"
        let foregroundDirectory = "/tmp/cmux-unknown-foreground-\(UUID().uuidString)"

        #expect(workspace.updatePanelDirectory(panelId: sourcePanelId, directory: trackedDirectory))
        workspace.foregroundProcessWorkingDirectoryProvider = { panelId in
            panelId == sourcePanelId ? foregroundDirectory : nil
        }

        let panel = try #require(workspace.newTerminalSurface(
            inPane: paneId,
            focus: false,
            inheritWorkingDirectoryFallback: true,
            workingDirectoryFallbackSourcePanelId: sourcePanelId
        ))

        #expect(panel.requestedWorkingDirectory == trackedDirectory)
    }

    @Test func explicitWorkingDirectoryWinsOverFallbackLiveWorkingDirectory() throws {
        let workspace = Workspace()
        let sourcePanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let explicitDirectory = "/tmp/cmux-explicit-\(UUID().uuidString)"
        let liveDirectory = "/tmp/cmux-live-\(UUID().uuidString)"

        workspace.panelShellActivityStates[sourcePanelId] = .promptIdle
        workspace.foregroundProcessWorkingDirectoryProvider = { panelId in
            panelId == sourcePanelId ? liveDirectory : nil
        }

        let panel = try #require(workspace.newTerminalSurface(
            inPane: paneId,
            focus: false,
            workingDirectory: explicitDirectory,
            inheritWorkingDirectoryFallback: true,
            workingDirectoryFallbackSourcePanelId: sourcePanelId
        ))

        #expect(panel.requestedWorkingDirectory == explicitDirectory)
    }

    @Test func explicitInitialCommandInheritsFallbackWorkingDirectory() throws {
        let workspace = Workspace()
        let sourcePanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let liveDirectory = "/tmp/cmux-live-\(UUID().uuidString)"
        let initialCommand = "/tmp/cmux-command-\(UUID().uuidString).sh"

        workspace.panelShellActivityStates[sourcePanelId] = .promptIdle
        workspace.foregroundProcessWorkingDirectoryProvider = { panelId in
            panelId == sourcePanelId ? liveDirectory : nil
        }

        let panel = try #require(workspace.newTerminalSurface(
            inPane: paneId,
            focus: false,
            initialCommand: initialCommand,
            inheritWorkingDirectoryFallback: true,
            workingDirectoryFallbackSourcePanelId: sourcePanelId
        ))

        #expect(panel.requestedWorkingDirectory == liveDirectory)
        #expect(panel.surface.debugInitialCommand() == initialCommand)
    }

    @Test func remoteStartupCommandSuppressesFallbackWorkingDirectoryInheritance() throws {
        let workspace = Workspace()
        let sourcePanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let liveDirectory = "/tmp/cmux-live-\(UUID().uuidString)"
        let remoteCommand = "ssh seepine@192.168.5.20"

        workspace.configureRemoteConnection(sshRemoteConfiguration(command: remoteCommand), autoConnect: false)
        workspace.panelShellActivityStates[sourcePanelId] = .promptIdle
        workspace.foregroundProcessWorkingDirectoryProvider = { panelId in
            panelId == sourcePanelId ? liveDirectory : nil
        }

        let panel = try #require(workspace.newTerminalSurface(
            inPane: paneId,
            focus: false,
            inheritWorkingDirectoryFallback: true,
            workingDirectoryFallbackSourcePanelId: sourcePanelId
        ))

        #expect(panel.requestedWorkingDirectory == nil)
        #expect(panel.surface.debugInitialCommand() != nil)
    }

    @Test func startupCommandConfigTemplateClearsInheritedWorkingDirectory() throws {
        var inheritedConfig = CmuxSurfaceConfigTemplate()
        inheritedConfig.fontSize = 17
        inheritedConfig.workingDirectory = "/tmp/cmux-inherited-\(UUID().uuidString)"
        inheritedConfig.environmentVariables = ["CMUX_TEST_ENV": "1"]

        let sanitized = try #require(Workspace.terminalStartupConfigTemplate(
            inheritedConfig,
            waitAfterCommand: true,
            clearWorkingDirectory: true
        ))

        #expect(sanitized.waitAfterCommand)
        #expect(sanitized.workingDirectory == nil)
        #expect(sanitized.fontSize == inheritedConfig.fontSize)
        #expect(sanitized.environmentVariables == inheritedConfig.environmentVariables)
    }

    private func sshRemoteConfiguration(command: String) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "seepine@192.168.5.20",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64007,
            relayID: "relay-\(UUID().uuidString)",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: "/tmp/cmux-cwd-inheritance-\(UUID().uuidString).sock",
            terminalStartupCommand: command
        )
    }
}
