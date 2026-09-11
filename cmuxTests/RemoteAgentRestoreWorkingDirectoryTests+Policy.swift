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
    @Test func unavailableRemoteAgentRetainsOnlyPersistentSSHReattach() throws {
        let defaultsName = "cmux-remote-persistent-cwd-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

        let capturedDirectory = "/Users/alice/persistent-agent-cwd"
        let trustedRuntimeDirectory = "/home/remote/persistent-project"
        let source = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { source.teardownAllPanels() }
        source.configureRemoteConnection(
            remoteWorkspaceConfiguration(
                command: SSHPTYAttachStartupCommandBuilder.command(),
                preserveAfterTerminalExit: true,
                persistentDaemonSlot: "remote-cwd-policy"
            ),
            autoConnect: false
        )
        let sourcePanelId = try #require(source.focusedPanelId)
        let persistentSessionID = Workspace.defaultSSHPTYSessionID(
            workspaceId: source.id,
            panelId: sourcePanelId
        )
        #expect(source.updateRemotePanelDirectory(
            panelId: sourcePanelId,
            directory: trustedRuntimeDirectory
        ))
        source.updatePanelShellActivityState(panelId: sourcePanelId, state: .commandRunning)
        source.setRestoredAgentSnapshotForTesting(
            SessionRestorableAgentSnapshot(
                kind: .grok,
                sessionId: "persistent-grok-session",
                workingDirectory: capturedDirectory,
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: "grok",
                    executablePath: "grok",
                    arguments: ["grok", "--cwd", capturedDirectory],
                    workingDirectory: capturedDirectory
                ),
                registration: .builtInGrok
            ),
            panelId: sourcePanelId
        )
        let binding = SurfaceResumeBindingSnapshot(
            kind: "grok",
            command: "grok --resume persistent-grok-session --cwd '\(capturedDirectory)'",
            cwd: capturedDirectory,
            checkpointId: "persistent-grok-session",
            source: "agent-hook",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "grok",
                executablePath: "grok",
                arguments: ["grok", "--cwd", capturedDirectory],
                workingDirectory: capturedDirectory
            ),
            autoResume: true,
            launchFlavor: .persistentSSH(SurfaceResumeRemoteContext(
                workspaceID: source.id,
                surfaceID: sourcePanelId,
                persistentPTYSessionID: persistentSessionID
            ))
        )
        #expect(source.setSurfaceResumeBinding(binding, panelId: sourcePanelId))

        let snapshot = source.sessionSnapshot(includeScrollback: false)
        let restored = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { restored.teardownAllPanels() }
        let restoredPanelIds = restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try #require(restoredPanelIds[sourcePanelId])
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelId))
        let retained = try #require(restored.restoredAgentSnapshotsByPanelId[restoredPanelId])

        #expect(retained.restoreWorkingDirectorySelection == .unavailable)
        #expect(retained.resumeCommand == nil)
        #expect(retained.forkCommand == nil)
        #expect(
            restored.restoredAgentResumeStatesByPanelId[restoredPanelId] == .manualResumeAvailable
        )
        #expect(restored.surfaceResumeBinding(panelId: restoredPanelId)?.launchFlavor.remoteContext != nil)

        let attachCommand = try #require(restoredPanel.surface.debugInitialCommand())
        #expect(attachCommand.contains("ssh-pty-attach"), Comment(rawValue: attachCommand))
        #expect(attachCommand.contains("--require-existing"), Comment(rawValue: attachCommand))
        #expect(!attachCommand.contains(capturedDirectory), Comment(rawValue: attachCommand))

        // The attach launcher is itself `/bin/sh -c '<script>'`; unwrap that
        // script before inspecting its nested `ssh-pty-attach` argv.
        let outerWords = TerminalStartupWorkingDirectoryPrefix.shellWordRanges(attachCommand)
        let script = if let shellIndex = outerWords.firstIndex(where: { $0.value == "-c" }),
                        outerWords.indices.contains(outerWords.index(after: shellIndex)) {
            outerWords[outerWords.index(after: shellIndex)].value
        } else {
            attachCommand
        }
        let words = TerminalStartupWorkingDirectoryPrefix.shellWordRanges(script).map(\.value)
        let commandIndex = try #require(words.firstIndex(of: "--command-b64"))
        let commandPayloadIndex = words.index(after: commandIndex)
        try #require(words.indices.contains(commandPayloadIndex))
        let commandPayload = words[commandPayloadIndex]
            .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
        let remoteCommandData = try #require(Data(base64Encoded: commandPayload))
        let remoteCommand = try #require(String(data: remoteCommandData, encoding: .utf8))
        let unsafeStartupInput = try #require(binding.remoteStartupInput())
        let unsafeStartupPayload = Data(unsafeStartupInput.utf8).base64EncodedString()
        #expect(!remoteCommand.contains(unsafeStartupPayload), Comment(rawValue: remoteCommand))
        #expect(!remoteCommand.contains(capturedDirectory), Comment(rawValue: remoteCommand))
    }

    @MainActor
    @Test func persistentSSHExactBindingDoesNotReplayWhenAutoResumeIsDisabled() throws {
        let defaultsName = "cmux-remote-disabled-auto-resume-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(false, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

        let capturedDirectory = "/Users/alice/persistent-agent-cwd"
        let trustedRemoteDirectory = "/home/remote/persistent-project"
        let agentSessionID = "persistent-codex-disabled-auto-resume"
        let remoteCommand = SSHPTYAttachStartupCommandBuilder.command()
        let source = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { source.teardownAllPanels() }
        source.configureRemoteConnection(
            remoteWorkspaceConfiguration(
                command: remoteCommand,
                preserveAfterTerminalExit: true,
                persistentDaemonSlot: "remote-disabled-auto-resume"
            ),
            autoConnect: false
        )
        let sourcePanelID = try #require(source.focusedPanelId)
        let persistentSessionID = Workspace.defaultSSHPTYSessionID(
            workspaceId: source.id,
            panelId: sourcePanelID
        )
        #expect(source.updateRemotePanelDirectory(
            panelId: sourcePanelID,
            directory: trustedRemoteDirectory
        ))
        source.updatePanelShellActivityState(panelId: sourcePanelID, state: .commandRunning)

        let launchCommand = AgentLaunchCommandSnapshot(
            launcher: "codex",
            executablePath: "codex",
            arguments: ["codex", "-C", capturedDirectory],
            workingDirectory: capturedDirectory
        )
        source.setRestoredAgentSnapshotForTesting(
            SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: agentSessionID,
                workingDirectory: capturedDirectory,
                launchCommand: launchCommand
            ),
            panelId: sourcePanelID
        )
        #expect(source.setSurfaceResumeBinding(
            SurfaceResumeBindingSnapshot(
                kind: "codex",
                command: "codex resume \(agentSessionID) -C '\(capturedDirectory)'",
                cwd: capturedDirectory,
                checkpointId: agentSessionID,
                source: "agent-hook",
                launchCommand: launchCommand,
                restoreWorkingDirectorySelection: .exact(trustedRemoteDirectory),
                autoResume: true,
                launchFlavor: .persistentSSH(SurfaceResumeRemoteContext(
                    workspaceID: source.id,
                    surfaceID: sourcePanelID,
                    persistentPTYSessionID: persistentSessionID
                ))
            ),
            panelId: sourcePanelID
        ))

        var snapshot = source.sessionSnapshot(includeScrollback: false)
        let panelIndex = try #require(snapshot.panels.firstIndex { $0.id == sourcePanelID })
        var terminalSnapshot = try #require(snapshot.panels[panelIndex].terminal)
        // Simulate a clean shell at quit while keeping the exact binding and
        // retained agent available for a later explicit manual restore.
        terminalSnapshot.wasAgentRunning = false
        snapshot.panels[panelIndex].terminal = terminalSnapshot

        try withRestoredRemoteSurfaceSnapshot(
            snapshot,
            sourcePanelId: sourcePanelID,
            autoResumeAgentSessions: false
        ) { restored, _, panel, _ in
            let attachCommand = try #require(panel.surface.debugInitialCommand())
            #expect(attachCommand.contains("--require-existing"), Comment(rawValue: attachCommand))

            let outerWords = TerminalStartupWorkingDirectoryPrefix.shellWordRanges(attachCommand)
            let script = if let shellIndex = outerWords.firstIndex(where: { $0.value == "-c" }),
                            outerWords.indices.contains(outerWords.index(after: shellIndex)) {
                outerWords[outerWords.index(after: shellIndex)].value
            } else {
                attachCommand
            }
            let words = TerminalStartupWorkingDirectoryPrefix.shellWordRanges(script).map(\.value)
            // Reattach the authenticated PTY, but do not resurrect the agent
            // command after the auto-resume decision explicitly denied it.
            if let commandIndex = words.firstIndex(of: "--command-b64") {
                let commandPayloadIndex = words.index(after: commandIndex)
                try #require(words.indices.contains(commandPayloadIndex))
                let commandPayload = words[commandPayloadIndex]
                    .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
                let remoteCommandData = try #require(Data(base64Encoded: commandPayload))
                let decodedRemoteCommand = try #require(String(data: remoteCommandData, encoding: .utf8))
                #expect(!decodedRemoteCommand.contains(agentSessionID), Comment(rawValue: decodedRemoteCommand))
                #expect(!decodedRemoteCommand.contains(capturedDirectory), Comment(rawValue: decodedRemoteCommand))
                #expect(!decodedRemoteCommand.contains(trustedRemoteDirectory), Comment(rawValue: decodedRemoteCommand))
            }
            #expect(restored.restoredAgentSnapshotsByPanelId.values.contains { $0.sessionId == agentSessionID })
        }
    }

    @MainActor
    @Test func persistentSSHExactSelectionEmbedsOnlyConstrainedAgentStartupInput() throws {
        let capturedDirectory = "/Users/alice/persistent-agent-cwd"
        let trustedRemoteDirectory = "/home/remote/persistent-project"
        let sessionId = "persistent-codex-session"
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        workspace.configureRemoteConnection(
            remoteWorkspaceConfiguration(
                command: SSHPTYAttachStartupCommandBuilder.command(),
                preserveAfterTerminalExit: true,
                persistentDaemonSlot: "remote-exact-cwd-policy"
            ),
            autoConnect: false
        )
        let panelId = try #require(workspace.focusedPanelId)
        let persistentSessionID = Workspace.defaultSSHPTYSessionID(
            workspaceId: workspace.id,
            panelId: panelId
        )
        let agent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionId,
            workingDirectory: capturedDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "codex",
                arguments: ["codex", "-C", capturedDirectory],
                workingDirectory: capturedDirectory
            )
        )
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume \(sessionId) -C '\(capturedDirectory)'",
            cwd: capturedDirectory,
            checkpointId: sessionId,
            source: "agent-hook",
            environment: ["CODEX_HOME": "/tmp/remote-codex-home"],
            launchCommand: agent.launchCommand,
            autoResume: true,
            launchFlavor: .persistentSSH(SurfaceResumeRemoteContext(
                workspaceID: workspace.id,
                surfaceID: panelId,
                persistentPTYSessionID: persistentSessionID
            ))
        )
        let constrainedBinding = binding.applyingRestoreWorkingDirectorySelection(
            .exact(trustedRemoteDirectory),
            from: agent
        )
        let constrainedStartupInput = try #require(constrainedBinding.remoteStartupInput())
        let remoteCommand = try #require(workspace.persistentSSHResumeCommand(
            for: constrainedBinding,
            expectedWorkspaceID: workspace.id,
            expectedSurfaceID: panelId,
            persistentPTYSessionID: persistentSessionID
        ))
        let constrainedPayload = Data(constrainedStartupInput.utf8).base64EncodedString()
        let unsafeStartupInput = try #require(binding.remoteStartupInput())
        let unsafePayload = Data(unsafeStartupInput.utf8).base64EncodedString()

        #expect(constrainedStartupInput.contains(trustedRemoteDirectory))
        #expect(!constrainedStartupInput.contains(capturedDirectory))
        #expect(constrainedStartupInput.contains("CODEX_HOME=/tmp/remote-codex-home"), Comment(rawValue: constrainedStartupInput))
        #expect(remoteCommand.contains(constrainedPayload), Comment(rawValue: remoteCommand))
        #expect(!remoteCommand.contains(unsafePayload), Comment(rawValue: remoteCommand))

        var staleExactNilBinding = binding
        staleExactNilBinding.restoreWorkingDirectorySelection = .exact(nil)
        let exactNilRemoteCommand = try #require(workspace.persistentSSHResumeCommand(
            for: staleExactNilBinding,
            expectedWorkspaceID: workspace.id,
            expectedSurfaceID: panelId,
            persistentPTYSessionID: persistentSessionID
        ))
        #expect(!exactNilRemoteCommand.contains(capturedDirectory), Comment(rawValue: exactNilRemoteCommand))

        var exactWithoutLaunchBinding = binding
        exactWithoutLaunchBinding.launchCommand = nil
        exactWithoutLaunchBinding.restoreWorkingDirectorySelection = .exact(trustedRemoteDirectory)
        #expect(workspace.setSurfaceResumeBinding(exactWithoutLaunchBinding, panelId: panelId))
        let exactWithoutLaunchRemoteCommand = try #require(workspace.persistentSSHResumeCommand(
            for: exactWithoutLaunchBinding,
            expectedWorkspaceID: workspace.id,
            expectedSurfaceID: panelId,
            persistentPTYSessionID: persistentSessionID
        ))
        #expect(!exactWithoutLaunchRemoteCommand.contains(capturedDirectory))
        // `persistentSSHResumeCommand` is the remote shell bootstrap; the
        // local attach wrapper is the layer that owns `--require-existing`.
        let exactWithoutLaunchAttach = SSHPTYAttachStartupCommandBuilder.command(
            sessionID: persistentSessionID,
            remoteCommand: exactWithoutLaunchRemoteCommand,
            requireExisting: true
        )
        #expect(exactWithoutLaunchAttach.contains("--require-existing"))
    }

    @Test func persistentSSHRegistrationWithoutCwdFailsClosedForDirectoryKeyedAgent() {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let context = SurfaceResumeRemoteContext(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            persistentPTYSessionID: "persistent-grok-session"
        )
        let binding = SurfaceResumeBindingSnapshot(
            kind: "grok",
            command: "grok resume persistent-grok-session",
            checkpointId: "persistent-grok-session",
            source: "agent-hook",
            autoResume: true
        )

        let staleAgent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "persistent-grok-session",
            workingDirectory: "/repo/stale"
        )
        let registered = binding.registeredForPersistentSSH(
            context,
            restorableAgent: staleAgent
        )

        #expect(registered.restoreWorkingDirectorySelection == .unavailable)
    }

    @Test func persistentSSHRegistrationTrustsReportedCwdForUnmatchedSnapshot() {
        let reportedRemoteDirectory = "/srv/projects/current"
        let binding = SurfaceResumeBindingSnapshot(
            kind: "grok",
            command: "grok resume persistent-unmatched-session",
            cwd: reportedRemoteDirectory,
            checkpointId: "persistent-unmatched-session",
            source: "agent-hook",
            autoResume: true
        )
        let staleAgent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "different-session",
            workingDirectory: "/repo/stale"
        )
        let registered = binding.registeredForPersistentSSH(
            SurfaceResumeRemoteContext(
                workspaceID: UUID(), surfaceID: UUID(),
                persistentPTYSessionID: "persistent-unmatched-pty"
            ),
            restorableAgent: staleAgent
        )
        #expect(registered.restoreWorkingDirectorySelection == .exact(reportedRemoteDirectory))
    }

    @Test func persistentSSHRegistrationHonorsCwdIgnoreWithReportedCwd() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let sessionID = "persistent-ignore-session"
        let capturedDirectory = "/Users/alice/captured-project"
        let context = SurfaceResumeRemoteContext(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            persistentPTYSessionID: "persistent-ignore-pty"
        )
        let registration = CmuxVaultAgentRegistration(
            id: "acme-ignore",
            name: "Acme Ignore",
            detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "acme-agent --session {{sessionId}}",
            forkCommand: "acme-agent --session {{sessionId}} --fork",
            cwd: .ignore
        )
        let launchCommand = AgentLaunchCommandSnapshot(
            processDetectedLauncher: registration.id,
            executablePath: "/usr/local/bin/acme-agent",
            arguments: ["/usr/local/bin/acme-agent", "--session", sessionID],
            workingDirectory: capturedDirectory,
            environment: [:]
        )
        let binding = SurfaceResumeBindingSnapshot(
            kind: registration.id,
            command: "acme-agent --session \(sessionID)",
            cwd: capturedDirectory,
            checkpointId: sessionID,
            source: "agent-hook",
            launchCommand: launchCommand,
            autoResume: true
        )
        let matchingAgent = SessionRestorableAgentSnapshot(
            kind: .custom(registration.id),
            sessionId: sessionID,
            workingDirectory: capturedDirectory,
            launchCommand: launchCommand,
            registration: registration
        )

        let registered = binding.registeredForPersistentSSH(
            context,
            restorableAgent: matchingAgent
        )

        #expect(
            registered.restoreWorkingDirectorySelection ==
                AgentRestoreWorkingDirectorySelection.exact(nil)
        )
    }

    @Test func persistentSSHRegistrationDoesNotTrustCapturedCwdWithoutRemoteSelection() {
        let sessionID = "persistent-captured-cwd-session"
        let context = SurfaceResumeRemoteContext(
            workspaceID: UUID(),
            surfaceID: UUID(),
            persistentPTYSessionID: "persistent-captured-cwd-pty"
        )
        let registration = CmuxVaultAgentRegistration(
            id: "captured-cwd-agent",
            name: "Captured CWD Agent",
            detect: CmuxVaultAgentDetectRule(processName: "captured-cwd-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "captured-cwd-agent --session {{sessionId}}",
            cwd: .preserve
        )
        let binding = SurfaceResumeBindingSnapshot(
            kind: registration.id,
            command: "captured-cwd-agent --session \(sessionID)",
            cwd: "/Users/alice/local-project",
            checkpointId: sessionID,
            source: "agent-hook",
            autoResume: true
        )
        let capturedAgent = SessionRestorableAgentSnapshot(
            kind: .custom(registration.id),
            sessionId: sessionID,
            workingDirectory: "/Users/alice/local-project",
            registration: registration
        )

        let registered = binding.registeredForPersistentSSH(
            context,
            restorableAgent: capturedAgent
        )

        #expect(registered.restoreWorkingDirectorySelection == .unavailable)
    }

    @Test func unavailableRestorePolicyDoesNotAdvertiseForkSupport() async {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "unavailable-fork-session",
            workingDirectory: "/Users/alice/captured-project",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/opt/homebrew/bin/claude",
                arguments: ["/opt/homebrew/bin/claude"],
                workingDirectory: "/Users/alice/captured-project"
            ),
            restoreWorkingDirectorySelection: .unavailable
        )

        #expect(snapshot.forkCommand == nil)
        #expect(AgentForkSupport.forkValidationIdentity(snapshot: snapshot) == nil)
        #expect(!(await AgentForkSupport.supportsFork(snapshot: snapshot)))
    }

}
