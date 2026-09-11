import AppKit
import CMUXAgentLaunch
import CmuxControlSocket
import CmuxCore
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension RemoteResumeBindingTests {
    @Test
    func persistentSSHRecordedFallbackIsTransportOnly() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let surfaceID = try #require(workspace.focusedPanelId)
        workspace.configureRemoteConnection(remoteConfiguration(), autoConnect: false)
        let persistentPTYSessionID = "recorded-fallback-pty"
        let context = SurfaceResumeRemoteContext(
            workspaceID: workspace.id,
            surfaceID: surfaceID,
            persistentPTYSessionID: persistentPTYSessionID
        )
        let capturedLocalDirectory = "/Users/alice/local-project"
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "cd '\(capturedLocalDirectory)' && codex resume remote-session",
            cwd: capturedLocalDirectory,
            checkpointId: "remote-session",
            source: "agent-hook",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "codex",
                arguments: ["codex", "resume", "remote-session"],
                workingDirectory: capturedLocalDirectory
            ),
            restoreWorkingDirectorySelection: .recordedFallback(
                preferred: capturedLocalDirectory
            ),
            launchFlavor: .persistentSSH(context)
        )

        let attachCommand = try #require(
            workspace.persistentSSHResumeCommand(
                for: binding,
                expectedWorkspaceID: workspace.id,
                expectedSurfaceID: surfaceID,
                persistentPTYSessionID: persistentPTYSessionID
            )
        )
        #expect(!attachCommand.contains(capturedLocalDirectory), Comment(rawValue: attachCommand))
        #expect(!attachCommand.contains("codex resume remote-session"), Comment(rawValue: attachCommand))
    }

    @Test
    func surfaceRestoreRecordExactNilCwdDoesNotUseCapturedFallbacks() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        let windowID = UUID()
        let window = makeMainWindow(id: windowID)
        let manager = TabManager(autoWelcomeIfNeeded: false)
        app.registerMainWindow(
            window,
            windowId: windowID,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: windowID)
            AppDelegate.shared = previousAppDelegate
            for workspace in manager.tabs {
                workspace.teardownAllPanels()
            }
            window.orderOut(nil)
        }

        let workspace = try #require(manager.selectedWorkspace)
        let surfaceID = try #require(workspace.focusedPanelId)
        let sessionID = UUID().uuidString.lowercased()
        let capturedDirectory = "/Users/alice/captured-local-project"
        let restoredFallbackDirectory = "/Users/alice/restored-local-project"
        #expect(workspace.setSurfaceResumeBinding(
            SurfaceResumeBindingSnapshot(
                kind: "codex",
                command: "codex resume \(sessionID)",
                cwd: capturedDirectory,
                checkpointId: sessionID,
                source: "agent-hook",
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: "codex",
                    executablePath: "/usr/local/bin/codex",
                    arguments: ["/usr/local/bin/codex", "resume", sessionID],
                    workingDirectory: capturedDirectory
                ),
                restoreWorkingDirectorySelection: .exact(nil),
                autoResume: true
            ),
            panelId: surfaceID
        ))
        workspace.restoredResumeSessionWorkingDirectoriesByPanelId[surfaceID] =
            restoredFallbackDirectory

        let result = try v2Result(request: [
            "id": "exact-nil-cwd-resume-get",
            "method": "surface.resume.get",
            "params": [
                "window_id": windowID.uuidString,
                "workspace_id": workspace.id.uuidString,
                "surface_id": surfaceID.uuidString,
            ],
        ])
        let restoreRecord = try #require(result["restore_record"] as? [String: Any])
        #expect(restoreRecord["working_directory"] as? String == nil)
        let launchCommand = try #require(restoreRecord["launch_command"] as? [String: Any])
        #expect(launchCommand["working_directory"] as? String == nil)
        #expect(restoreRecord["legacy_command"] as? String == nil)

        workspace.setRestoredAgentSnapshotForTesting(SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionID,
            workingDirectory: capturedDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/usr/local/bin/codex",
                arguments: ["/usr/local/bin/codex", "-C", capturedDirectory, "resume", sessionID],
                workingDirectory: capturedDirectory
            ),
            restoreWorkingDirectorySelection: .exact(capturedDirectory)
        ), panelId: surfaceID)
        let staleAgentResult = try v2Result(request: [
            "id": "exact-nil-cwd-with-stale-agent-resume-get",
            "method": "surface.resume.get",
            "params": [
                "window_id": windowID.uuidString,
                "workspace_id": workspace.id.uuidString,
                "surface_id": surfaceID.uuidString,
            ],
        ])
        let staleAgentRecord = try #require(staleAgentResult["restore_record"] as? [String: Any])
        #expect(staleAgentRecord["working_directory"] as? String == nil)
        #expect(staleAgentRecord["legacy_command"] as? String == nil)
        let staleAgentLaunch = try #require(staleAgentRecord["launch_command"] as? [String: Any])
        #expect(staleAgentLaunch["working_directory"] as? String == nil)

        // A pre-policy persistent-SSH hook binding can arrive directly from
        // an older persisted snapshot.  Without an explicit trust selection,
        // control restore must not revive its captured local cwd or command.
        let unscopedRemoteBinding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "cd '\(capturedDirectory)' && codex resume \(sessionID)",
            cwd: capturedDirectory,
            checkpointId: sessionID,
            source: "agent-hook",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/usr/local/bin/codex",
                arguments: ["/usr/local/bin/codex", "resume", sessionID],
                workingDirectory: capturedDirectory
            ),
            autoResume: true,
            launchFlavor: .persistentSSH(SurfaceResumeRemoteContext(
                workspaceID: workspace.id,
                surfaceID: surfaceID,
                persistentPTYSessionID: Workspace.defaultSSHPTYSessionID(
                    workspaceId: workspace.id,
                    panelId: surfaceID
                )
            ))
        )
        workspace.surfaceResumeBindingsByPanelId[surfaceID] = unscopedRemoteBinding
        workspace.restoredAgentLifecycle.setSnapshot(nil, panelId: surfaceID)
        let unscopedResult = try v2Result(request: [
            "id": "unscoped-remote-agent-hook-resume-get",
            "method": "surface.resume.get",
            "params": [
                "window_id": windowID.uuidString,
                "workspace_id": workspace.id.uuidString,
                "surface_id": surfaceID.uuidString,
            ],
        ])
        #expect(unscopedResult["restore_record"] as? [String: Any] == nil)

        let directBinding = SurfaceResumeBindingSnapshot(
            kind: "command",
            command: "printf direct-cli-restore",
            source: "cli",
            autoResume: true
        )
        #expect(workspace.setSurfaceResumeBinding(directBinding, panelId: surfaceID))
        #expect(workspace.surfaceResumeBinding(panelId: surfaceID)?.command == directBinding.command)
        let directResult = try v2Result(request: [
            "id": "direct-cli-binding-with-stale-agent",
            "method": "surface.resume.get",
            "params": [
                "window_id": windowID.uuidString,
                "workspace_id": workspace.id.uuidString,
                "surface_id": surfaceID.uuidString,
            ],
        ])
        let directRecord = try #require(directResult["restore_record"] as? [String: Any])
        #expect((directRecord["legacy_command"] as? String)?.contains("direct-cli-restore") == true)

        let customAgentBinding = SurfaceResumeBindingSnapshot(
            kind: "acme-ignore",
            command: "cd '/Users/alice/captured-custom-cwd' && acme-agent --session custom-session",
            cwd: "/Users/alice/captured-custom-cwd",
            checkpointId: "custom-session",
            source: "agent-hook",
            autoResume: true
        )
        #expect(workspace.setSurfaceResumeBinding(customAgentBinding, panelId: surfaceID))
        workspace.restoredAgentLifecycle.setSnapshot(nil, panelId: surfaceID)
        let customResult = try v2Result(request: [
            "id": "custom-agent-without-restore-snapshot",
            "method": "surface.resume.get",
            "params": [
                "window_id": windowID.uuidString,
                "workspace_id": workspace.id.uuidString,
                "surface_id": surfaceID.uuidString,
            ],
        ])
        #expect(customResult["restore_record"] as? [String: Any] == nil)
    }

    @Test
    func customAgentHookRestoreRecordRequiresTypedPlanForExactCwd() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        let windowID = UUID()
        let window = makeMainWindow(id: windowID)
        let manager = TabManager(autoWelcomeIfNeeded: false)
        app.registerMainWindow(
            window,
            windowId: windowID,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: windowID)
            AppDelegate.shared = previousAppDelegate
            for workspace in manager.tabs {
                workspace.teardownAllPanels()
            }
            window.orderOut(nil)
        }

        let workspace = try #require(manager.selectedWorkspace)
        let surfaceID = try #require(workspace.focusedPanelId)
        let sessionID = "custom-session-" + UUID().uuidString
        let capturedDirectory = "/Users/alice/captured-custom-cwd"
        let launchCommand = AgentLaunchCommandSnapshot(
            executablePath: "/usr/local/bin/acme-agent",
            arguments: ["/usr/local/bin/acme-agent", "--session", sessionID],
            workingDirectory: capturedDirectory
        )
        let exactBinding = SurfaceResumeBindingSnapshot(
            kind: "acme-agent",
            command: "acme-agent --session " + sessionID,
            cwd: capturedDirectory,
            checkpointId: sessionID,
            source: "agent-hook",
            launchCommand: launchCommand,
            restoreWorkingDirectorySelection: .exact(nil),
            autoResume: true
        )

        // This is a persisted binding shape that cannot be installed through
        // the normal mutation API without the custom registration. It must not
        // advertise a restore record that the CLI planner cannot execute.
        workspace.surfaceResumeBindingsByPanelId[surfaceID] = exactBinding
        let noSnapshotResult = try v2Result(request: [
            "id": "custom-exact-no-snapshot",
            "method": "surface.resume.get",
            "params": [
                "window_id": windowID.uuidString,
                "workspace_id": workspace.id.uuidString,
                "surface_id": surfaceID.uuidString,
            ],
        ])
        #expect(noSnapshotResult["restore_record"] as? [String: Any] == nil)

        // A matching snapshot without its registry metadata reaches the
        // snapshot branch, so cover that branch separately from the fallback.
        workspace.setRestoredAgentSnapshotForTesting(SessionRestorableAgentSnapshot(
            kind: .custom("acme-agent"),
            sessionId: sessionID,
            workingDirectory: capturedDirectory,
            launchCommand: launchCommand
        ), panelId: surfaceID)
        let missingRegistrationResult = try v2Result(request: [
            "id": "custom-exact-missing-registration",
            "method": "surface.resume.get",
            "params": [
                "window_id": windowID.uuidString,
                "workspace_id": workspace.id.uuidString,
                "surface_id": surfaceID.uuidString,
            ],
        ])
        #expect(missingRegistrationResult["restore_record"] as? [String: Any] == nil)

        // A registry-backed snapshot supplies the typed argv required by both
        // the control-surface record and AgentRestorePlanner.
        let registration = CmuxVaultAgentRegistration(
            id: "acme-agent",
            name: "Acme Agent",
            detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "{{executable}} --session {{sessionId}}",
            cwd: .preserve
        )
        let trustedDirectory = "/Users/alice/trusted-custom-cwd"
        workspace.surfaceResumeBindingsByPanelId[surfaceID] = SurfaceResumeBindingSnapshot(
            kind: "acme-agent",
            command: "acme-agent --session " + sessionID,
            cwd: trustedDirectory,
            checkpointId: sessionID,
            source: "agent-hook",
            launchCommand: launchCommand,
            restoreWorkingDirectorySelection: .exact(trustedDirectory),
            autoResume: true
        )
        workspace.setRestoredAgentSnapshotForTesting(SessionRestorableAgentSnapshot(
            kind: .custom(registration.id),
            sessionId: sessionID,
            workingDirectory: capturedDirectory,
            launchCommand: launchCommand,
            registration: registration
        ), panelId: surfaceID)
        let validResult = try v2Result(request: [
            "id": "custom-exact-registered",
            "method": "surface.resume.get",
            "params": [
                "window_id": windowID.uuidString,
                "workspace_id": workspace.id.uuidString,
                "surface_id": surfaceID.uuidString,
            ],
        ])
        let restoreRecord = try #require(validResult["restore_record"] as? [String: Any])
        let preparedArguments = try #require(
            restoreRecord["prepared_arguments"] as? [String]
        )
        #expect(preparedArguments == [
            "/usr/local/bin/acme-agent",
            "--session",
            sessionID,
        ])
        let restoreKind = try #require(restoreRecord["kind"] as? String)
        let restoreCheckpointID = try #require(restoreRecord["checkpoint_id"] as? String)
        let restoreLaunchCommand = AgentLaunchCommand(
            launcher: launchCommand.launcher,
            executablePath: launchCommand.executablePath,
            arguments: launchCommand.arguments,
            workingDirectory: nil,
            environment: launchCommand.environment,
            verificationHome: launchCommand.verificationHome,
            capturedAt: launchCommand.capturedAt,
            source: launchCommand.source
        )
        let restoreRequest = AgentRestoreRequest(
            mode: .resumeAgent,
            kind: restoreKind,
            checkpointID: restoreCheckpointID,
            source: restoreRecord["source"] as? String,
            workingDirectory: restoreRecord["working_directory"] as? String,
            environment: restoreRecord["environment"] as? [String: String] ?? [:],
            launchCommand: restoreLaunchCommand,
            preparedArguments: preparedArguments,
            preparedArgumentsWorkingDirectory: restoreRecord[
                "prepared_arguments_working_directory"
            ] as? String,
            observedPermissionMode: restoreRecord["permission_mode"] as? String
        )
        let invocation = try #require(AgentRestorePlanner(
            isExecutableFile: { _ in false }
        ).invocation(
            for: restoreRequest,
            ambientEnvironment: ["PATH": "/usr/bin:/bin"]
        ))
        #expect(invocation.arguments == preparedArguments)
    }

}
