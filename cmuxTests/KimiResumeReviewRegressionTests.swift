import Foundation
import Testing
@_implementationOnly import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Kimi resume review regressions")
struct KimiResumeReviewRegressionTests {
    @Test("User Kimi registration keeps runtime cwd ownership")
    func customRegistrationKeepsRuntimeDirectory() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-custom-kimi-equal-\(UUID().uuidString)", isDirectory: true)
        let launchWorkingDirectory = root.appendingPathComponent("launch-repo", isDirectory: true)
        let runtimeWorkingDirectory = root.appendingPathComponent("runtime-worktree", isDirectory: true)
        let stateDirectory = root.appendingPathComponent(".cmuxterm", isDirectory: true)
        try fileManager.createDirectory(at: launchWorkingDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: runtimeWorkingDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let userRegistration = CmuxVaultAgentRegistration(
            id: "kimi",
            name: "Custom Kimi",
            detect: CmuxVaultAgentDetectRule(processName: "custom-kimi"),
            sessionIdSource: .argvOption("--resume"),
            resumeCommand: "custom-kimi --resume {{sessionId}}"
        )
        let registry = CmuxVaultAgentRegistry(registrations: [
            .builtInKimi,
            userRegistration,
        ])
        let workspaceID = UUID()
        let panelID = UUID()
        let sessionID = "user-kimi-session"
        let store = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "sessions": [
                    sessionID: [
                        "sessionId": sessionID,
                        "workspaceId": workspaceID.uuidString,
                        "surfaceId": panelID.uuidString,
                        "cwd": runtimeWorkingDirectory.path,
                        "launchCommand": [
                            "launcher": "kimi",
                            "executablePath": "/Users/example/.local/bin/kimi",
                            "arguments": ["/Users/example/.local/bin/kimi"],
                            "workingDirectory": launchWorkingDirectory.path,
                            "capturedAt": 1_750_000_000.0,
                            "source": "test",
                        ],
                        "isRestorable": true,
                        "updatedAt": 1_750_000_000.0,
                    ],
                ],
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        try store.write(
            to: stateDirectory.appendingPathComponent("kimi-hook-sessions.json", isDirectory: false),
            options: .atomic
        )

        let snapshot = try #require(
            RestorableAgentSessionIndex.load(
                homeDirectory: root.path,
                fileManager: fileManager,
                registry: registry,
                detectedSnapshots: [:],
                processArgumentsProvider: { _ in nil }
            ).snapshot(workspaceId: workspaceID, panelId: panelID)
        )
        #expect(snapshot.registration == userRegistration)
        #expect(snapshot.workingDirectory == runtimeWorkingDirectory.path)
        #expect(snapshot.resumeCommand?.hasPrefix("cd -- '\(runtimeWorkingDirectory.path)'") == true)
    }

    @Test("Custom Kimi snapshot owns restore over generic hook binding")
    @MainActor
    func customSnapshotOwnsRestoreOverHookBinding() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-custom-kimi-binding-\(UUID().uuidString)", isDirectory: true)
        let runtimeWorkingDirectory = root.appendingPathComponent("runtime-worktree", isDirectory: true)
        try fileManager.createDirectory(at: runtimeWorkingDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let defaultsName = "cmux-custom-kimi-binding-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

        let sessionID = "custom-kimi-binding-session"
        let customRegistration = CmuxVaultAgentRegistration(
            id: "kimi",
            name: "Custom Kimi",
            detect: CmuxVaultAgentDetectRule(processName: "custom-kimi"),
            sessionIdSource: .argvOption("--resume"),
            resumeCommand: "custom-kimi --resume {{sessionId}}"
        )
        let source = Workspace(agentSessionAutoResumeDefaults: defaults)
        let sourcePanelID = try #require(source.focusedPanelId)
        source.updatePanelDirectory(panelId: sourcePanelID, directory: runtimeWorkingDirectory.path)
        source.updatePanelShellActivityState(panelId: sourcePanelID, state: .commandRunning)
        source.setRestoredAgentSnapshotForTesting(
            SessionRestorableAgentSnapshot(
                kind: .custom("kimi"),
                sessionId: sessionID,
                workingDirectory: runtimeWorkingDirectory.path,
                launchCommand: nil,
                registration: customRegistration
            ),
            panelId: sourcePanelID
        )
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(
                workspaceId: source.id,
                panelId: sourcePanelID
            ): SurfaceResumeBindingSnapshot(
                name: "Kimi Code",
                kind: "kimi",
                command: "'kimi' '--resume' '\(sessionID)'",
                cwd: runtimeWorkingDirectory.path,
                checkpointId: sessionID,
                source: "agent-hook",
                autoResume: true,
                updatedAt: 1_750_000_000
            ),
        ])

        let persisted = source.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )
        #expect(persisted.panels.first?.terminal?.agent?.kind == .custom("kimi"))
        #expect(persisted.panels.first?.terminal?.resumeBinding?.kind == "kimi")

        let restored = Workspace(
            agentSessionAutoResumeDefaults: defaults,
            restorableAgentIndexProvider: { .empty }
        )
        restored.restoreSessionSnapshot(persisted)
        let restoredPanelID = try #require(restored.focusedPanelId)
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))
        #expect(restoredPanel.surface.debugInitialCommand() == nil)
        let launcherInput = try #require(restoredPanel.surface.debugInitialInputForTesting())
        let launcherWords = TerminalStartupWorkingDirectoryPrefix
            .shellWordRanges(launcherInput)
            .map(\.value)
        let launcherIndex = try #require(launcherWords.lastIndex(of: "/bin/zsh"))
        let launcherPath = try #require(launcherWords.dropFirst(launcherIndex + 1).first)
        let launcher = try String(contentsOfFile: launcherPath, encoding: .utf8)
        #expect(launcher.contains("'custom-kimi' '--resume' '\(sessionID)'"), "\(launcher)")
        #expect(!launcher.contains("'kimi' '--resume' '\(sessionID)'"), "\(launcher)")
    }

    @Test("Custom Kimi registrations preserve profile -w options during exact restore")
    func customKimiExactRestorePreservesProfileWorkingDirectoryOption() throws {
        let workingDirectory = "/remote/project"
        let profile = "profile-a"
        let registration = CmuxVaultAgentRegistration(
            id: "kimi",
            name: "Custom Kimi",
            detect: CmuxVaultAgentDetectRule(processName: "custom-kimi"),
            sessionIdSource: .argvOption("--resume"),
            resumeCommand: "custom-kimi --resume {{sessionId}}"
        )
        let launchCommand = AgentLaunchCommandSnapshot(
            launcher: "kimi",
            executablePath: "/Users/example/.local/bin/custom-kimi",
            arguments: [
                "/Users/example/.local/bin/custom-kimi",
                "-w", profile,
                "--model", "custom-model",
            ],
            workingDirectory: "/Users/example/local-project",
            capturedAt: 1_750_000_000,
            source: "test"
        )
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .custom("kimi"),
            sessionId: "custom-kimi-session",
            workingDirectory: workingDirectory,
            launchCommand: launchCommand,
            registration: registration,
            restoreWorkingDirectorySelection: .exact(workingDirectory)
        )

        let constrained = try #require(
            snapshot.constrainedLaunchCommand(
                launchCommand,
                selection: .exact(workingDirectory)
            )
        )
        #expect(constrained.arguments == launchCommand.arguments)
        #expect(constrained.arguments.dropFirst().contains("-w"))
        #expect(constrained.arguments.contains(profile))
    }

    @MainActor
    @Test("Control restore strips native Kimi cwd flags without consuming custom profiles")
    func controlRestoreUsesOnlyMatchingNativeKimiPolicy() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(manager.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelId)
        let target = ControlSurfaceResumeTarget.workspace(
            tabManager: manager,
            workspace: workspace,
            surfaceID: panelID
        )

        let nativeSessionID = "native-kimi-session"
        let capturedDirectory = "/Users/example/local-kimi-project"
        let trustedDirectory = "/remote/kimi-project"
        let nativeLaunch = AgentLaunchCommandSnapshot(
            launcher: "kimi",
            executablePath: "kimi",
            arguments: ["kimi", "--resume", nativeSessionID, "-w", capturedDirectory],
            workingDirectory: capturedDirectory
        )
        workspace.setRestoredAgentSnapshotForTesting(
            SessionRestorableAgentSnapshot(
                kind: .kimi,
                sessionId: nativeSessionID,
                workingDirectory: capturedDirectory,
                launchCommand: nativeLaunch,
                registration: .builtInKimi
            ),
            panelId: panelID
        )
        let nativeBinding = SurfaceResumeBindingSnapshot(
            kind: "kimi",
            command: "kimi --resume \(nativeSessionID) -w '\(capturedDirectory)'",
            cwd: capturedDirectory,
            checkpointId: nativeSessionID,
            source: "manual",
            launchCommand: nativeLaunch,
            restoreWorkingDirectorySelection: .exact(trustedDirectory)
        )

        let nativeRecord = try #require(
            TerminalController.shared.controlSurfaceRestoreRecord(
                target: target,
                binding: nativeBinding
            )
        )
        let nativeArguments = try #require(nativeRecord.launchCommand?.arguments)
        #expect(!nativeArguments.contains("-w"))
        #expect(!nativeArguments.contains(capturedDirectory))
        #expect(nativeRecord.preparedArguments == nativeArguments)

        let profile = "profile-a"
        let customSessionID = "custom-kimi-profile-session"
        let customRegistration = CmuxVaultAgentRegistration(
            id: "kimi",
            name: "Custom Kimi",
            detect: CmuxVaultAgentDetectRule(processName: "custom-kimi"),
            sessionIdSource: .argvOption("--resume"),
            resumeCommand: "custom-kimi --resume {{sessionId}}"
        )
        let customLaunch = AgentLaunchCommandSnapshot(
            launcher: "kimi",
            executablePath: "custom-kimi",
            arguments: ["custom-kimi", "--resume", customSessionID, "-w", profile]
        )
        let customBinding = SurfaceResumeBindingSnapshot(
            kind: "kimi",
            command: "custom-kimi --resume \(customSessionID) -w \(profile)",
            checkpointId: customSessionID,
            source: "manual",
            launchCommand: customLaunch,
            restoreWorkingDirectorySelection: .exact(trustedDirectory)
        )
        workspace.setRestoredAgentSnapshotForTesting(
            SessionRestorableAgentSnapshot(
                kind: .custom("kimi"),
                sessionId: customSessionID,
                workingDirectory: trustedDirectory,
                launchCommand: customLaunch,
                registration: customRegistration
            ),
            panelId: panelID
        )

        let customRecord = try #require(
            TerminalController.shared.controlSurfaceRestoreRecord(
                target: target,
                binding: customBinding
            )
        )
        #expect(customRecord.launchCommand?.arguments == customLaunch.arguments)

        // A native snapshot from another conversation is stale evidence and
        // must not reinterpret the binding's custom profile as a cwd.
        workspace.setRestoredAgentSnapshotForTesting(
            SessionRestorableAgentSnapshot(
                kind: .kimi,
                sessionId: nativeSessionID,
                workingDirectory: capturedDirectory,
                launchCommand: nativeLaunch,
                registration: .builtInKimi
            ),
            panelId: panelID
        )
        let staleSnapshotRecord = try #require(
            TerminalController.shared.controlSurfaceRestoreRecord(
                target: target,
                binding: customBinding
            )
        )
        #expect(staleSnapshotRecord.launchCommand?.arguments == customLaunch.arguments)
    }
}

extension CLINotifyProcessIntegrationRegressionTests {
    func testKimiHookAcceptsAndSanitizesWrapperLaunchCapture() throws {
        try runGenericHookPersistenceScenario(
            GenericHookPersistenceScenario(
                agent: "kimi",
                subcommand: "session-start",
                sessionId: "kimi-wrapper-session",
                executable: "/Users/example/.local/bin/kimi",
                launchArguments: [
                    "/Users/example/.local/bin/kimi",
                    "--resume", "stale-session",
                    "--model", "kimi-k2",
                    "--config-file", "/tmp/kimi.toml",
                    "-c", "stale prompt",
                    "--plan",
                ],
                extraEnvironment: [
                    "KIMI_SHARE_DIR": "/tmp/kimi-share",
                    "MOONSHOT_API_KEY": "secret",
                ],
                expectedArguments: [
                    "/Users/example/.local/bin/kimi",
                    "--model", "kimi-k2",
                    "--config-file", "/tmp/kimi.toml",
                ],
                expectedEnvironment: ["KIMI_SHARE_DIR": "/tmp/kimi-share"]
            )
        )
    }
}
