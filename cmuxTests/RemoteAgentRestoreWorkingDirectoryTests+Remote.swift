import AppKit
import CMUXAgentLaunch
import CmuxControlSocket
import CmuxCore
import CmuxSidebar
import Darwin
import Foundation
import Testing
@testable import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif
@MainActor
extension RemoteAgentRestoreWorkingDirectoryTests {
    @Test func remoteAutoResumeUsesLatestAuthoritativeDirectoryReport() throws {
        let defaultsName = "cmux-remote-latest-cwd-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

        let localDirectory = "/Users/alice/development"
        let firstRemoteDirectory = "/repo-a"
        let latestRemoteDirectory = "/repo-b"
        let remoteCommand = "ssh cmux-remote"
        let sessionId = "codex-remote-latest-cwd-\(UUID().uuidString)"
        defer {
            AgentResumeLaunchGuard.shared.releaseResumeLaunch(
                kind: "codex",
                sessionId: sessionId
            )
        }
        let source = Workspace(
            workingDirectory: localDirectory,
            initialTerminalCommand: remoteCommand,
            agentSessionAutoResumeDefaults: defaults
        )
        defer { source.teardownAllPanels() }
        let sourcePanelId = try #require(source.focusedPanelId)
        source.configureRemoteConnection(
            remoteWorkspaceConfiguration(command: remoteCommand),
            autoConnect: false
        )
        #expect(source.updateRemotePanelDirectory(panelId: sourcePanelId, directory: firstRemoteDirectory))
        #expect(source.updateRemotePanelDirectory(panelId: sourcePanelId, directory: latestRemoteDirectory))
        source.updatePanelShellActivityState(panelId: sourcePanelId, state: .commandRunning)
        source.setRestoredAgentSnapshotForTesting(
            restorableCodexAgent(sessionId: sessionId, workingDirectory: firstRemoteDirectory),
            panelId: sourcePanelId
        )
        let firstBindingAgent = restorableCodexAgent(
            sessionId: sessionId,
            workingDirectory: firstRemoteDirectory
        )
        #expect(source.setSurfaceResumeBinding(
            SurfaceResumeBindingSnapshot(
                kind: "codex",
                command: "codex resume \(sessionId)",
                cwd: firstRemoteDirectory,
                checkpointId: sessionId,
                source: "agent-hook",
                launchCommand: firstBindingAgent.launchCommand,
                restoreWorkingDirectorySelection: .exact(firstRemoteDirectory),
                autoResume: true
            ),
            panelId: sourcePanelId
        ))

        let snapshot = source.sessionSnapshot(includeScrollback: false)
        #expect(snapshot.panels.first?.directoryIsTrustedRemoteReport == true)
        #expect(snapshot.panels.first?.terminal?.workingDirectory == latestRemoteDirectory)

        let restored = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { restored.teardownAllPanels() }
        let restoredPanelIds = restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try #require(restoredPanelIds[sourcePanelId])
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelId))
        let startupInput = try #require(restoredPanel.surface.initialInput)

        #expect(startupInput.contains(latestRemoteDirectory), Comment(rawValue: startupInput))
        #expect(!startupInput.contains(firstRemoteDirectory), Comment(rawValue: startupInput))
        #expect(!startupInput.contains(localDirectory), Comment(rawValue: startupInput))
        #expect(restoredPanel.requestedWorkingDirectory == latestRemoteDirectory)
        let restoredBinding = try #require(
            restored.surfaceResumeBinding(panelId: restoredPanelId)
        )
        #expect(restoredBinding.restoreWorkingDirectorySelection == .exact(latestRemoteDirectory))
        #expect(restoredBinding.cwd == latestRemoteDirectory)

        let newerRemoteDirectory = "/repo-c"
        restored.updatePanelShellActivityState(panelId: restoredPanelId, state: .commandRunning)
        #expect(restored.updateRemotePanelDirectory(
            panelId: restoredPanelId,
            directory: newerRemoteDirectory
        ))
        let secondSnapshot = restored.sessionSnapshot(includeScrollback: false)
        // The second snapshot models a relaunch after the first runtime has
        // exited. Release the in-process duplicate-launch claim that the first
        // restore intentionally held while its command was running.
        AgentResumeLaunchGuard.shared.releaseResumeLaunch(
            kind: "codex",
            sessionId: sessionId
        )
        let secondRestore = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { secondRestore.teardownAllPanels() }
        let secondPanelIds = secondRestore.restoreSessionSnapshot(secondSnapshot)
        let secondPanelId = try #require(secondPanelIds[restoredPanelId])
        let secondPanel = try #require(secondRestore.terminalPanel(for: secondPanelId))
        let secondStartupInput = try #require(secondPanel.surface.initialInput)
        let secondAgent = try #require(secondRestore.restoredAgentSnapshotsByPanelId[secondPanelId])

        #expect(secondAgent.restoreWorkingDirectorySelection == .exact(newerRemoteDirectory))
        #expect(secondStartupInput.contains(newerRemoteDirectory), Comment(rawValue: secondStartupInput))
        #expect(!secondStartupInput.contains(latestRemoteDirectory), Comment(rawValue: secondStartupInput))
        #expect(
            secondRestore.surfaceResumeBinding(panelId: secondPanelId)?.restoreWorkingDirectorySelection ==
                .exact(newerRemoteDirectory)
        )
    }

    @MainActor
    @Test func remoteDirectoryNamespacedAutoResumeSkipsWithoutTrustedLaunchDirectory() throws {
        let defaultsName = "cmux-remote-launch-cwd-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

        let localDirectory = "/Users/alice/development"
        let staleAgentDirectory = "/repo-a"
        let staleLaunchDirectory = "/repo-launch"
        let latestRemoteDirectory = "/repo-b"
        let savedScrollback = "last remote agent output\n"
        let remoteCommand = "ssh cmux-remote"
        let sessionId = "grok-remote-launch-cwd-\(UUID().uuidString)"
        let source = Workspace(
            workingDirectory: localDirectory,
            initialTerminalCommand: remoteCommand,
            agentSessionAutoResumeDefaults: defaults
        )
        defer { source.teardownAllPanels() }
        let sourcePanelId = try #require(source.focusedPanelId)
        source.configureRemoteConnection(
            remoteWorkspaceConfiguration(command: remoteCommand),
            autoConnect: false
        )
        #expect(source.updateRemotePanelDirectory(panelId: sourcePanelId, directory: staleAgentDirectory))
        #expect(source.updateRemotePanelDirectory(panelId: sourcePanelId, directory: latestRemoteDirectory))
        source.updatePanelShellActivityState(panelId: sourcePanelId, state: .commandRunning)
        source.setRestoredAgentSnapshotForTesting(
            SessionRestorableAgentSnapshot(
                kind: .grok,
                sessionId: sessionId,
                workingDirectory: staleAgentDirectory,
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: "grok",
                    executablePath: "grok",
                    arguments: ["grok", "--cwd", staleLaunchDirectory],
                    workingDirectory: staleLaunchDirectory,
                    environment: [:],
                    capturedAt: 1_777_777_777,
                    source: "process"
                ),
                registration: .builtInGrok
            ),
            panelId: sourcePanelId
        )
        #expect(source.setSurfaceResumeBinding(
            SurfaceResumeBindingSnapshot(
                kind: "grok",
                command: "grok --resume \(sessionId) --cwd '\(staleLaunchDirectory)'",
                cwd: staleLaunchDirectory,
                checkpointId: sessionId,
                source: "agent-hook",
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: "grok",
                    executablePath: "grok",
                    arguments: ["grok", "--cwd", staleLaunchDirectory],
                    workingDirectory: staleLaunchDirectory
                ),
                autoResume: true
            ),
            panelId: sourcePanelId
        ))

        var snapshot = source.sessionSnapshot(includeScrollback: false)
        #expect(snapshot.panels.first?.directoryIsTrustedRemoteReport == true)
        #expect(snapshot.panels.first?.terminal?.workingDirectory == latestRemoteDirectory)
        // The accepted hook binding promotes its captured launch cwd into the
        // snapshot; the independent agent-only cwd is not retained.
        #expect(snapshot.panels.first?.terminal?.agent?.workingDirectory == staleLaunchDirectory)
        #expect(snapshot.panels.first?.terminal?.agent?.launchCommand?.workingDirectory == staleLaunchDirectory)

        let panelIndex = try #require(snapshot.panels.firstIndex { $0.id == sourcePanelId })
        var terminalSnapshot = try #require(snapshot.panels[panelIndex].terminal)
        terminalSnapshot.scrollback = savedScrollback
        snapshot.panels[panelIndex].terminal = terminalSnapshot

        try withRestoredRemoteSurfaceSnapshot(
            snapshot,
            sourcePanelId: sourcePanelId,
            autoResumeAgentSessions: true
        ) { restored, restoredPanelId, restoredPanel, resumeSnapshot in
            let startupInput = restoredPanel.surface.initialInput
            #expect(startupInput == nil, Comment(rawValue: startupInput ?? "nil"))
            #expect(restoredPanel.requestedWorkingDirectory == nil)
            #expect(restored.restoredAgentSnapshotsByPanelId[restoredPanelId] == nil)
            #expect(restored.restoredAgentResumeStatesByPanelId[restoredPanelId] == nil)
            #expect(restored.restoredTerminalScrollbackByPanelId[restoredPanelId] == savedScrollback)
            #expect(restored.surfaceResumeBinding(panelId: restoredPanelId) == nil)
            #expect(resumeSnapshot.binding == nil)
            #expect(resumeSnapshot.restoreRecord == nil)
        }

        // A stale agent snapshot can coexist with an independent
        // process-detected SSH binding. Rejecting the agent recipe must not
        // erase that terminal-level binding.
        var plainSSHSnapshot = snapshot
        var plainSSHTerminal = try #require(plainSSHSnapshot.panels[panelIndex].terminal)
        var plainSSHBinding = try #require(plainSSHTerminal.resumeBinding)
        plainSSHBinding.source = "process-detected"
        plainSSHTerminal.resumeBinding = plainSSHBinding
        plainSSHSnapshot.panels[panelIndex].terminal = plainSSHTerminal
        try withRestoredRemoteSurfaceSnapshot(
            plainSSHSnapshot,
            sourcePanelId: sourcePanelId,
            autoResumeAgentSessions: true
        ) { restored, restoredPanelId, _, resumeSnapshot in
            #expect(restored.surfaceResumeBinding(panelId: restoredPanelId) != nil)
            #expect(resumeSnapshot.binding != nil)
        }
    }

    @MainActor
    @Test func remoteDirectoryNamespacedResumeKeepsAuthenticatedLaunchDirectory() throws {
        let defaultsName = "cmux-remote-authenticated-launch-cwd-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

        let localDirectory = "/Users/alice/development"
        let runtimeDirectory = "/repo-runtime"
        let launchDirectory = "/repo-launch"
        let remoteCommand = "ssh cmux-remote"
        let sessionId = "grok-authenticated-launch-cwd-\(UUID().uuidString)"
        let source = Workspace(
            workingDirectory: localDirectory,
            initialTerminalCommand: remoteCommand,
            agentSessionAutoResumeDefaults: defaults
        )
        defer { source.teardownAllPanels() }
        let sourcePanelId = try #require(source.focusedPanelId)
        source.configureRemoteConnection(
            remoteWorkspaceConfiguration(command: remoteCommand),
            autoConnect: false
        )
        #expect(source.updateRemotePanelDirectory(panelId: sourcePanelId, directory: runtimeDirectory))
        source.updatePanelShellActivityState(panelId: sourcePanelId, state: .commandRunning)
        source.setRestoredAgentSnapshotForTesting(
            SessionRestorableAgentSnapshot(
                kind: .grok,
                sessionId: sessionId,
                workingDirectory: runtimeDirectory,
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: "grok",
                    executablePath: "grok",
                    arguments: ["grok", "--cwd", launchDirectory],
                    workingDirectory: launchDirectory,
                    environment: [:],
                    capturedAt: 1_777_777_777,
                    source: "process"
                ),
                registration: .builtInGrok
            ),
            panelId: sourcePanelId
        )
        let authenticatedBinding = SurfaceResumeBindingSnapshot(
            kind: "grok",
            command: "grok --resume \(sessionId) --cwd '\(launchDirectory)'",
            cwd: launchDirectory,
            checkpointId: sessionId,
            source: "agent-hook",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "grok",
                executablePath: "grok",
                arguments: ["grok", "--cwd", launchDirectory],
                workingDirectory: launchDirectory
            ),
            restoreWorkingDirectorySelection: .exact(launchDirectory),
            autoResume: true,
            launchFlavor: .persistentSSH(SurfaceResumeRemoteContext(
                workspaceID: source.id,
                surfaceID: sourcePanelId,
                persistentPTYSessionID: "grok-authenticated-pty"
            ))
        )
        #expect(source.setSurfaceResumeBinding(authenticatedBinding, panelId: sourcePanelId))

        let snapshot = source.sessionSnapshot(includeScrollback: false)
        #expect(snapshot.panels.first?.directoryIsTrustedRemoteReport == true)
        #expect(snapshot.panels.first?.terminal?.workingDirectory == runtimeDirectory)
        #expect(
            snapshot.panels.first?.terminal?.resumeBinding?.restoreWorkingDirectorySelection ==
                .exact(launchDirectory)
        )

        try withRestoredRemoteSurfaceSnapshot(
            snapshot,
            sourcePanelId: sourcePanelId,
            autoResumeAgentSessions: true
        ) { restored, restoredPanelId, restoredPanel, resumeSnapshot in
            let restoredAgent = try #require(
                restored.restoredAgentSnapshotsByPanelId[restoredPanelId]
            )
            #expect(restoredAgent.restoreWorkingDirectorySelection == .exact(launchDirectory))
            #expect(restoredAgent.workingDirectory == launchDirectory)
            let restoredBinding = try #require(
                restored.surfaceResumeBinding(panelId: restoredPanelId)
            )
            #expect(
                restoredBinding.restoreWorkingDirectorySelection == .exact(launchDirectory)
            )
            #expect(restoredBinding.cwd == launchDirectory)
            #expect(resumeSnapshot.binding?.cwd == launchDirectory)
            let startupInput = try #require(restoredPanel.surface.initialInput)
            #expect(startupInput.contains(launchDirectory), Comment(rawValue: startupInput))
            #expect(!startupInput.contains(localDirectory), Comment(rawValue: startupInput))
        }
    }

    @MainActor
    @Test func remoteAutoResumeWithoutTrustedDirectoryRejectsRecordedLocalCwd() throws {
        let defaultsName = "cmux-remote-untrusted-cwd-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

        let localDirectory = "/Users/alice/development"
        let untrustedRecordedDirectory = "/Users/alice/recorded-agent-cwd"
        let remoteCommand = "ssh cmux-remote"
        let sessionId = "codex-remote-untrusted-cwd-\(UUID().uuidString)"
        defer {
            AgentResumeLaunchGuard.shared.releaseResumeLaunch(
                kind: "codex",
                sessionId: sessionId
            )
        }
        let source = Workspace(
            workingDirectory: localDirectory,
            initialTerminalCommand: remoteCommand,
            agentSessionAutoResumeDefaults: defaults
        )
        defer { source.teardownAllPanels() }
        let sourcePanelId = try #require(source.focusedPanelId)
        source.configureRemoteConnection(
            remoteWorkspaceConfiguration(command: remoteCommand),
            autoConnect: false
        )
        source.updatePanelShellActivityState(panelId: sourcePanelId, state: .commandRunning)
        source.setRestoredAgentSnapshotForTesting(
            restorableCodexAgent(sessionId: sessionId, workingDirectory: untrustedRecordedDirectory),
            panelId: sourcePanelId
        )

        var snapshot = source.sessionSnapshot(includeScrollback: false)
        let panelIndex = try #require(snapshot.panels.firstIndex { $0.id == sourcePanelId })
        snapshot.panels[panelIndex].directory = untrustedRecordedDirectory
        snapshot.panels[panelIndex].directoryIsTrustedRemoteReport = false
        snapshot.panels[panelIndex].directoryRequiresRemoteTrust = true
        var terminalSnapshot = try #require(snapshot.panels[panelIndex].terminal)
        terminalSnapshot.workingDirectory = untrustedRecordedDirectory
        terminalSnapshot.isRemoteTerminal = true
        terminalSnapshot.wasAgentRunning = true
        snapshot.panels[panelIndex].terminal = terminalSnapshot

        let restored = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { restored.teardownAllPanels() }
        let restoredPanelIds = restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try #require(restoredPanelIds[sourcePanelId])
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelId))
        let startupInput = try #require(restoredPanel.surface.initialInput)

        #expect(startupInput.contains(sessionId), Comment(rawValue: startupInput))
        #expect(!startupInput.contains(untrustedRecordedDirectory), Comment(rawValue: startupInput))
        #expect(!startupInput.contains(localDirectory), Comment(rawValue: startupInput))
        #expect(restoredPanel.requestedWorkingDirectory == nil)
        #expect(restored.remoteDirectoryTrustRequiredPanelIds.contains(restoredPanelId))

        let newlyReportedRemoteDirectory = "/repo-b"
        restored.updatePanelShellActivityState(panelId: restoredPanelId, state: .commandRunning)
        #expect(restored.updateRemotePanelDirectory(
            panelId: restoredPanelId,
            directory: newlyReportedRemoteDirectory
        ))
        let secondSnapshot = restored.sessionSnapshot(includeScrollback: false)
        AgentResumeLaunchGuard.shared.releaseResumeLaunch(
            kind: "codex",
            sessionId: sessionId
        )
        let secondRestore = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { secondRestore.teardownAllPanels() }
        let secondPanelIds = secondRestore.restoreSessionSnapshot(secondSnapshot)
        let secondPanelId = try #require(secondPanelIds[restoredPanelId])
        let secondPanel = try #require(secondRestore.terminalPanel(for: secondPanelId))
        let secondStartupInput = try #require(secondPanel.surface.initialInput)
        let secondAgent = try #require(secondRestore.restoredAgentSnapshotsByPanelId[secondPanelId])

        #expect(secondAgent.restoreWorkingDirectorySelection == .exact(newlyReportedRemoteDirectory))
        #expect(secondStartupInput.contains(newlyReportedRemoteDirectory), Comment(rawValue: secondStartupInput))
        #expect(!secondStartupInput.contains(untrustedRecordedDirectory), Comment(rawValue: secondStartupInput))
    }

}
