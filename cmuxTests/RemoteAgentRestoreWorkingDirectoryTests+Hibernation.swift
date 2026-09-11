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
extension RemoteAgentRestoreWorkingDirectoryTests {
    @Test func exactRemoteRebuildSupportsRegistryOwnedKindWithoutSnapshot() throws {
        let sessionID = "snapshotless-grok-session"
        let trustedDirectory = "/srv/remote-grok"
        let binding = SurfaceResumeBindingSnapshot(
            kind: "grok",
            command: "grok -r \(sessionID)",
            cwd: trustedDirectory,
            checkpointId: sessionID,
            source: "agent-hook",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "grok",
                executablePath: "/usr/local/bin/grok",
                arguments: ["/usr/local/bin/grok"],
                workingDirectory: trustedDirectory
            ),
            restoreWorkingDirectorySelection: .exact(trustedDirectory),
            autoResume: true
        )

        let input = try #require(binding.remoteStartupInput())

        #expect(input.contains("grok"), Comment(rawValue: input))
        #expect(input.contains(sessionID), Comment(rawValue: input))
        #expect(input.contains(trustedDirectory), Comment(rawValue: input))
    }

    @MainActor
    @Test(arguments: [RestorableAgentKind.codex, .opencode])
    func remoteManualResumeRecordUsesOnlyTrustedReportedDirectory(
        kind: RestorableAgentKind
    ) throws {
        let localWorkspaceDirectory = "/Users/alice/development"
        let capturedAgentDirectory = "/Users/alice/captured-agent-cwd"
        let capturedLaunchDirectory = "/Users/alice/captured-launch-cwd"
        let capturedArgumentDirectory = "/Users/alice/captured-argument-cwd"
        let trustedRemoteDirectory = "/home/remote/current-project"
        let remoteCommand = "ssh cmux-remote"
        let sessionId = "\(kind.rawValue)-remote-manual-\(UUID().uuidString)"
        let executable = kind == .codex ? "codex" : "opencode"
        let cwdOption = kind == .codex ? "-C" : "--cwd"
        let source = Workspace(
            workingDirectory: localWorkspaceDirectory,
            initialTerminalCommand: remoteCommand
        )
        defer { source.teardownAllPanels() }
        let sourcePanelId = try #require(source.focusedPanelId)
        source.configureRemoteConnection(
            remoteWorkspaceConfiguration(command: remoteCommand),
            autoConnect: false
        )
        #expect(source.updateRemotePanelDirectory(
            panelId: sourcePanelId,
            directory: trustedRemoteDirectory
        ))
        source.updatePanelShellActivityState(panelId: sourcePanelId, state: .commandRunning)
        source.setRestoredAgentSnapshotForTesting(
            SessionRestorableAgentSnapshot(
                kind: kind,
                sessionId: sessionId,
                workingDirectory: capturedAgentDirectory,
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: executable,
                    executablePath: "/usr/local/bin/\(executable)",
                    arguments: [
                        "/usr/local/bin/\(executable)",
                        cwdOption,
                        capturedArgumentDirectory,
                        "--model",
                        "test-model",
                    ],
                    workingDirectory: capturedLaunchDirectory,
                    environment: [:],
                    capturedAt: 1_777_777_777,
                    source: "process"
                )
            ),
            panelId: sourcePanelId
        )
        #expect(source.setSurfaceResumeBinding(
            SurfaceResumeBindingSnapshot(
                kind: kind.rawValue,
                command: "\(executable) resume \(sessionId) \(cwdOption) '\(capturedArgumentDirectory)'",
                cwd: capturedAgentDirectory,
                checkpointId: sessionId,
                source: "agent-hook",
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: executable,
                    executablePath: "/usr/local/bin/\(executable)",
                    arguments: [
                        "/usr/local/bin/\(executable)",
                        cwdOption,
                        capturedArgumentDirectory,
                        "--model",
                        "test-model",
                    ],
                    workingDirectory: capturedLaunchDirectory
                ),
                autoResume: true
            ),
            panelId: sourcePanelId
        ))

        let snapshot = source.sessionSnapshot(includeScrollback: false)
        try withRestoredRemoteSurface(
            snapshot,
            sourcePanelId: sourcePanelId,
            autoResumeAgentSessions: false
        ) { workspace, panelId, panel, restoreRecord in
            #expect(panel.surface.initialInput == nil)
            #expect(workspace.restoredAgentResumeStatesByPanelId[panelId] == .manualResumeAvailable)
            #expect(restoreRecord.kind == kind.rawValue)
            #expect(restoreRecord.checkpointID == sessionId)
            #expect(restoreRecord.workingDirectory == trustedRemoteDirectory)
            #expect(restoreRecord.preparedArgumentsWorkingDirectory == trustedRemoteDirectory)

            let launchCommand = try #require(restoreRecord.launchCommand)
            #expect(launchCommand.workingDirectory == nil)
            let launchArguments = launchCommand.arguments.joined(separator: " ")
            #expect(!launchArguments.contains(capturedAgentDirectory))
            #expect(!launchArguments.contains(capturedLaunchDirectory))
            #expect(!launchArguments.contains(capturedArgumentDirectory))
            #expect(!launchCommand.arguments.contains(cwdOption))

            let preparedArguments = try #require(restoreRecord.preparedArguments)
                .joined(separator: " ")
            #expect(!preparedArguments.contains(capturedAgentDirectory))
            #expect(!preparedArguments.contains(capturedLaunchDirectory))
            #expect(!preparedArguments.contains(capturedArgumentDirectory))

            let continuation = try #require(
                workspace.restoredAgentSnapshotsByPanelId[panelId]
            )
            let resumeCommand = try #require(continuation.resumeCommand)
            #expect(resumeCommand.contains(trustedRemoteDirectory), Comment(rawValue: resumeCommand))
            #expect(!resumeCommand.contains(capturedAgentDirectory), Comment(rawValue: resumeCommand))
            #expect(!resumeCommand.contains(capturedLaunchDirectory), Comment(rawValue: resumeCommand))
            #expect(!resumeCommand.contains(capturedArgumentDirectory), Comment(rawValue: resumeCommand))

            workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
            #expect(workspace.restoredAgentSnapshotsByPanelId[panelId] == nil)
            let retainedBinding = try #require(
                workspace.sessionSnapshot(includeScrollback: false)
                    .panels.first(where: { $0.id == panelId })?
                    .terminal?.resumeBinding
            )
            let retainedInput = try #require(
                retainedBinding.inlineStartupInput(repairPortableAgentExecutable: false)
            )
            #expect(retainedBinding.restoreWorkingDirectorySelection == .exact(trustedRemoteDirectory))
            #expect(retainedBinding.autoResume == false)
            #expect(retainedInput.contains(trustedRemoteDirectory), Comment(rawValue: retainedInput))
            #expect(!retainedInput.contains(capturedAgentDirectory), Comment(rawValue: retainedInput))
            #expect(!retainedInput.contains(capturedLaunchDirectory), Comment(rawValue: retainedInput))
            #expect(!retainedInput.contains(capturedArgumentDirectory), Comment(rawValue: retainedInput))
        }
    }

    @MainActor
    @Test func hibernatedRemoteContinuationUsesOnlyTrustedReportedDirectory() throws {
        let localWorkspaceDirectory = "/Users/alice/development"
        let capturedAgentDirectory = "/Users/alice/hibernated-agent-cwd"
        let capturedLaunchDirectory = "/Users/alice/hibernated-launch-cwd"
        let capturedArgumentDirectory = "/Users/alice/hibernated-argument-cwd"
        let trustedRemoteDirectory = "/home/remote/hibernated-project"
        let remoteCommand = "ssh cmux-remote"
        let sessionId = "codex-remote-hibernated-\(UUID().uuidString)"
        let source = Workspace(
            workingDirectory: localWorkspaceDirectory,
            initialTerminalCommand: remoteCommand
        )
        defer { source.teardownAllPanels() }
        let sourcePanelId = try #require(source.focusedPanelId)
        source.configureRemoteConnection(
            remoteWorkspaceConfiguration(command: remoteCommand),
            autoConnect: false
        )
        #expect(source.updateRemotePanelDirectory(
            panelId: sourcePanelId,
            directory: trustedRemoteDirectory
        ))
        source.updatePanelShellActivityState(panelId: sourcePanelId, state: .commandRunning)
        source.setRestoredAgentSnapshotForTesting(
            SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: sessionId,
                workingDirectory: capturedAgentDirectory,
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: "codex",
                    executablePath: "/usr/local/bin/codex",
                    arguments: [
                        "/usr/local/bin/codex",
                        "-C\(capturedArgumentDirectory)",
                        "--model",
                        "test-model",
                    ],
                    workingDirectory: capturedLaunchDirectory,
                    environment: [:],
                    capturedAt: 1_777_777_777,
                    source: "process"
                )
            ),
            panelId: sourcePanelId
        )

        var snapshot = source.sessionSnapshot(includeScrollback: false)
        let panelIndex = try #require(snapshot.panels.firstIndex { $0.id == sourcePanelId })
        var terminalSnapshot = try #require(snapshot.panels[panelIndex].terminal)
        terminalSnapshot.hibernation = SessionAgentHibernationSnapshot(
            hibernatedAt: 1_777_777_777,
            lastActivityAt: 1_777_777_700
        )
        snapshot.panels[panelIndex].terminal = terminalSnapshot

        try withRestoredRemoteSurface(
            snapshot,
            sourcePanelId: sourcePanelId,
            autoResumeAgentSessions: true,
            agentHibernationPresentationVisible: false
        ) { workspace, panelId, panel, restoreRecord in
            #expect(panel.isAgentHibernated)
            #expect(restoreRecord.workingDirectory == trustedRemoteDirectory)
            #expect(restoreRecord.launchCommand?.workingDirectory == nil)

            let structuredArguments = [
                restoreRecord.launchCommand?.arguments.joined(separator: " "),
                restoreRecord.preparedArguments?.joined(separator: " "),
            ].compactMap { $0 }.joined(separator: " ")
            #expect(!structuredArguments.contains(capturedAgentDirectory))
            #expect(!structuredArguments.contains(capturedLaunchDirectory))
            #expect(!structuredArguments.contains(capturedArgumentDirectory))

            let hibernatedAgent = try #require(panel.agentHibernationState?.agent)
            let resumeCommand = try #require(hibernatedAgent.resumeCommand)
            #expect(resumeCommand.contains(trustedRemoteDirectory), Comment(rawValue: resumeCommand))
            #expect(!resumeCommand.contains(capturedAgentDirectory), Comment(rawValue: resumeCommand))
            #expect(!resumeCommand.contains(capturedLaunchDirectory), Comment(rawValue: resumeCommand))
            #expect(!resumeCommand.contains(capturedArgumentDirectory), Comment(rawValue: resumeCommand))

            #expect(workspace.resumeAgentHibernation(panelId: panelId, focus: false))
            let queuedInput = try #require(
                panel.surface.debugInitialInputForTesting()
                    ?? panel.surface.nextRuntimeInitialInput
            )
            #expect(queuedInput.contains(sessionId), Comment(rawValue: queuedInput))
            // Hibernation queues the local `cmux restore` verb; the persisted
            // restore record carries the trusted remote directory asserted above.
            #expect(!queuedInput.contains(capturedAgentDirectory), Comment(rawValue: queuedInput))
            #expect(!queuedInput.contains(capturedLaunchDirectory), Comment(rawValue: queuedInput))
            #expect(!queuedInput.contains(capturedArgumentDirectory), Comment(rawValue: queuedInput))
        }
    }

    @MainActor
    func withRestoredRemoteSurface<T>(
        _ snapshot: SessionWorkspaceSnapshot,
        sourcePanelId: UUID,
        autoResumeAgentSessions: Bool,
        agentHibernationPresentationVisible: Bool = true,
        body: (
            _ workspace: Workspace,
            _ panelId: UUID,
            _ panel: TerminalPanel,
            _ restoreRecord: ControlSurfaceRestoreRecord
        ) throws -> T
    ) throws -> T {
        try withRestoredRemoteSurfaceSnapshot(
            snapshot,
            sourcePanelId: sourcePanelId,
            autoResumeAgentSessions: autoResumeAgentSessions,
            agentHibernationPresentationVisible: agentHibernationPresentationVisible
        ) { workspace, panelId, panel, resumeSnapshot in
            let restoreRecord = try #require(resumeSnapshot.restoreRecord)
            return try body(workspace, panelId, panel, restoreRecord)
        }
    }

    @MainActor
    func withRestoredRemoteSurfaceSnapshot<T>(
        _ snapshot: SessionWorkspaceSnapshot,
        sourcePanelId: UUID,
        autoResumeAgentSessions: Bool,
        agentHibernationPresentationVisible: Bool = true,
        body: (
            _ workspace: Workspace,
            _ panelId: UUID,
            _ panel: TerminalPanel,
            _ resumeSnapshot: ControlSurfaceResumeSnapshot
        ) throws -> T
    ) throws -> T {
        let defaultsName = "cmux-remote-restore-helper-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(
            autoResumeAgentSessions,
            forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey
        )

        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let windowId = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            agentSessionAutoResumeDefaults: defaults
        )
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            for workspace in manager.tabs {
                workspace.teardownAllPanels()
            }
            window.orderOut(nil)
        }

        let workspace = try #require(manager.selectedWorkspace)
        workspace.setAgentHibernationAutoResumePresentationVisible(
            agentHibernationPresentationVisible
        )
        let restoredPanelIds = workspace.restoreSessionSnapshot(snapshot)
        let panelId = try #require(restoredPanelIds[sourcePanelId])
        let panel = try #require(workspace.terminalPanel(for: panelId))
        let routing = ControlRoutingSelectors(
            hasWindowIDParam: true,
            windowID: windowId,
            groupID: nil,
            workspaceID: workspace.id,
            surfaceID: panelId,
            paneID: nil
        )
        let resolution = TerminalController.shared.controlSurfaceResumeGet(
            routing: routing,
            explicitTargetID: panelId,
            hasResolvedWindowID: true,
            claimCheckpointID: nil,
            claimSource: nil,
            claimUpdatedAt: nil
        )
        guard case .result(let result) = resolution else {
            Issue.record("surface.resume.get failed: \(resolution)")
            throw RemoteSurfaceRestoreTestError.resumeRecordUnavailable
        }
        return try body(workspace, panelId, panel, result)
    }

    enum RemoteSurfaceRestoreTestError: Error {
        case resumeRecordUnavailable
    }

    func remoteWorkspaceConfiguration(
        command: String,
        preserveAfterTerminalExit: Bool = false,
        persistentDaemonSlot: String? = nil
    ) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "cmux-remote",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64_000,
            relayID: "relay-remote-cwd-\(UUID().uuidString)",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: "/tmp/cmux-remote-cwd-\(UUID().uuidString).sock",
            terminalStartupCommand: command,
            preserveAfterTerminalExit: preserveAfterTerminalExit,
            persistentDaemonSlot: persistentDaemonSlot
        )
    }

    func restorableCodexAgent(
        sessionId: String,
        workingDirectory: String
    ) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionId,
            workingDirectory: workingDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/usr/local/bin/codex",
                arguments: ["/usr/local/bin/codex"],
                workingDirectory: workingDirectory,
                environment: [:],
                capturedAt: 1_777_777_777,
                source: "process"
            )
        )
    }
}
