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

    @Test func promptIdleFallbackTrackedDirectoryBeatsLiveWorkingDirectory() throws {
        let workspace = Workspace()
        let sourcePanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let trackedDirectory = "/tmp/cmux-tracked-\(UUID().uuidString)"
        let liveDirectory = "/tmp/cmux-live-\(UUID().uuidString)"

        #expect(workspace.updatePanelDirectory(panelId: sourcePanelId, directory: trackedDirectory))
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

        #expect(panel.requestedWorkingDirectory == trackedDirectory)
    }

    @Test func promptIdleFallbackLiveWorkingDirectoryFillsMissingTrackedDirectory() throws {
        let workspace = Workspace()
        let sourcePanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let liveDirectory = "/tmp/cmux-live-missing-tracked-\(UUID().uuidString)"

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

    @Test func promptIdleSplitTrackedDirectoryBeatsLiveWorkingDirectory() throws {
        let workspace = Workspace()
        let sourcePanelId = try #require(workspace.focusedPanelId)
        let trackedDirectory = "/tmp/cmux-tracked-split-\(UUID().uuidString)"
        let liveDirectory = "/tmp/cmux-live-split-\(UUID().uuidString)"

        #expect(workspace.updatePanelDirectory(panelId: sourcePanelId, directory: trackedDirectory))
        workspace.panelShellActivityStates[sourcePanelId] = .promptIdle
        workspace.foregroundProcessWorkingDirectoryProvider = { panelId in
            panelId == sourcePanelId ? liveDirectory : nil
        }

        let panel = try #require(workspace.newTerminalSplit(
            from: sourcePanelId,
            orientation: .horizontal,
            focus: false
        ))

        #expect(panel.requestedWorkingDirectory == trackedDirectory)
    }

    @Test func promptIdleSplitLiveWorkingDirectoryFillsMissingTrackedDirectory() throws {
        let workspace = Workspace()
        let sourcePanelId = try #require(workspace.focusedPanelId)
        let liveDirectory = "/tmp/cmux-live-split-missing-tracked-\(UUID().uuidString)"

        workspace.panelShellActivityStates[sourcePanelId] = .promptIdle
        workspace.foregroundProcessWorkingDirectoryProvider = { panelId in
            panelId == sourcePanelId ? liveDirectory : nil
        }

        let panel = try #require(workspace.newTerminalSplit(
            from: sourcePanelId,
            orientation: .horizontal,
            focus: false
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

        #expect(panel.requestedWorkingDirectory == Workspace.safeLocalTerminalStartupWorkingDirectory())
        #expect(panel.surface.debugInitialCommand() != nil)
    }

    @Test func remoteStartupCommandSuppressesSplitFallbackWorkingDirectoryInheritance() throws {
        let workspace = Workspace()
        let sourcePanelId = try #require(workspace.focusedPanelId)
        let remoteDirectory = "/home/seepine/cmux-remote-\(UUID().uuidString)"
        let remoteCommand = "ssh seepine@192.168.5.20"

        workspace.configureRemoteConnection(sshRemoteConfiguration(command: remoteCommand), autoConnect: false)
        #expect(workspace.updatePanelDirectory(panelId: sourcePanelId, directory: remoteDirectory))
        workspace.panelShellActivityStates[sourcePanelId] = .promptIdle

        let panel = try #require(workspace.newTerminalSplit(
            from: sourcePanelId,
            orientation: .horizontal,
            focus: false
        ))

        #expect(panel.requestedWorkingDirectory == Workspace.safeLocalTerminalStartupWorkingDirectory())
        #expect(panel.surface.debugInitialCommand() != nil)
    }

    @Test func explicitInitialCommandDoesNotUseRemotePanelDirectoryAsLocalFallback() throws {
        let workspace = Workspace()
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let remoteDirectory = "/home/seepine/cmux-remote-explicit-\(UUID().uuidString)"
        let remoteCommand = "ssh seepine@192.168.5.20"
        let explicitCommand = "/tmp/cmux-local-command-\(UUID().uuidString).sh"

        workspace.configureRemoteConnection(sshRemoteConfiguration(command: remoteCommand), autoConnect: false)
        let remotePanel = try #require(workspace.newTerminalSurface(inPane: paneId, focus: true))
        #expect(workspace.isRemoteTerminalSurface(remotePanel.id))
        #expect(workspace.updatePanelDirectory(panelId: remotePanel.id, directory: remoteDirectory))

        let panel = try #require(workspace.newTerminalSurface(
            inPane: paneId,
            focus: false,
            initialCommand: explicitCommand,
            inheritWorkingDirectoryFallback: true,
            workingDirectoryFallbackSourcePanelId: remotePanel.id
        ))

        #expect(panel.requestedWorkingDirectory == Workspace.safeLocalTerminalStartupWorkingDirectory())
        #expect(panel.surface.debugInitialCommand() == explicitCommand)
    }

    @Test func explicitSplitCommandDoesNotUseRemotePanelDirectoryAsLocalFallback() throws {
        let workspace = Workspace()
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let remoteDirectory = "/home/seepine/cmux-remote-split-explicit-\(UUID().uuidString)"
        let remoteCommand = "ssh seepine@192.168.5.20"
        let explicitCommand = "/tmp/cmux-local-split-command-\(UUID().uuidString).sh"

        workspace.configureRemoteConnection(sshRemoteConfiguration(command: remoteCommand), autoConnect: false)
        let remotePanel = try #require(workspace.newTerminalSurface(inPane: paneId, focus: true))
        #expect(workspace.isRemoteTerminalSurface(remotePanel.id))
        #expect(workspace.updatePanelDirectory(panelId: remotePanel.id, directory: remoteDirectory))

        let panel = try #require(workspace.newTerminalSplit(
            from: remotePanel.id,
            orientation: .horizontal,
            focus: false,
            initialCommand: explicitCommand
        ))

        #expect(panel.requestedWorkingDirectory == Workspace.safeLocalTerminalStartupWorkingDirectory())
        #expect(panel.surface.debugInitialCommand() == explicitCommand)
    }

    @Test func explicitWorkingDirectoryWinsOverRemoteStartupSplitFallback() throws {
        let workspace = Workspace()
        let sourcePanelId = try #require(workspace.focusedPanelId)
        let remoteDirectory = "/home/seepine/cmux-remote-\(UUID().uuidString)"
        let explicitDirectory = "/tmp/cmux-explicit-split-\(UUID().uuidString)"
        let remoteCommand = "ssh seepine@192.168.5.20"

        workspace.configureRemoteConnection(sshRemoteConfiguration(command: remoteCommand), autoConnect: false)
        #expect(workspace.updatePanelDirectory(panelId: sourcePanelId, directory: remoteDirectory))

        let panel = try #require(workspace.newTerminalSplit(
            from: sourcePanelId,
            orientation: .horizontal,
            focus: false,
            workingDirectory: explicitDirectory
        ))

        #expect(panel.requestedWorkingDirectory == explicitDirectory)
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

    @Test func inheritedRuntimeWorkingDirectoryRequiresPromptIdleSource() {
        let inheritedDirectory = "/tmp/cmux-inherited-runtime-\(UUID().uuidString)"

        #expect(Workspace.terminalStartupInheritedWorkingDirectoryCandidate(
            inheritedDirectory,
            shellActivityState: .promptIdle,
            isRemoteTerminalSurface: false,
            isRestoreGuarded: false,
            isAgentResumePendingOrRunning: false
        ) == inheritedDirectory)
        #expect(Workspace.terminalStartupInheritedWorkingDirectoryCandidate(
            inheritedDirectory,
            shellActivityState: .commandRunning,
            isRemoteTerminalSurface: false,
            isRestoreGuarded: false,
            isAgentResumePendingOrRunning: false
        ) == nil)
        #expect(Workspace.terminalStartupInheritedWorkingDirectoryCandidate(
            inheritedDirectory,
            shellActivityState: .unknown,
            isRemoteTerminalSurface: false,
            isRestoreGuarded: false,
            isAgentResumePendingOrRunning: false
        ) == nil)
        #expect(Workspace.terminalStartupInheritedWorkingDirectoryCandidate(
            inheritedDirectory,
            shellActivityState: nil,
            isRemoteTerminalSurface: false,
            isRestoreGuarded: false,
            isAgentResumePendingOrRunning: false
        ) == nil)
    }

    @Test func inheritedRuntimeWorkingDirectorySkipsRemoteRestoreAndAutoResumeSources() {
        let inheritedDirectory = "/tmp/cmux-inherited-runtime-\(UUID().uuidString)"

        #expect(Workspace.terminalStartupInheritedWorkingDirectoryCandidate(
            inheritedDirectory,
            shellActivityState: .promptIdle,
            isRemoteTerminalSurface: true,
            isRestoreGuarded: false,
            isAgentResumePendingOrRunning: false
        ) == nil)
        #expect(Workspace.terminalStartupInheritedWorkingDirectoryCandidate(
            inheritedDirectory,
            shellActivityState: .promptIdle,
            isRemoteTerminalSurface: false,
            isRestoreGuarded: true,
            isAgentResumePendingOrRunning: false
        ) == nil)
        #expect(Workspace.terminalStartupInheritedWorkingDirectoryCandidate(
            inheritedDirectory,
            shellActivityState: .promptIdle,
            isRemoteTerminalSurface: false,
            isRestoreGuarded: false,
            isAgentResumePendingOrRunning: true
        ) == nil)
        #expect(Workspace.terminalStartupInheritedWorkingDirectoryCandidate(
            " \n\t",
            shellActivityState: .promptIdle,
            isRemoteTerminalSurface: false,
            isRestoreGuarded: false,
            isAgentResumePendingOrRunning: false
        ) == nil)
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
