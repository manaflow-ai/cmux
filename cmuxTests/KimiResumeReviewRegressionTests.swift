import CMUXAgentLaunch
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
    @Test("Kimi process discovery captures launch metadata for resume")
    func processDiscoveryCapturesLaunchMetadata() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-kimi-process-capture-\(UUID().uuidString)", isDirectory: true)
        let launchDirectory = root.appendingPathComponent("launch-repo", isDirectory: true)
        try fileManager.createDirectory(at: launchDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let executable = root.appendingPathComponent("bin/kimi").path
        let configPath = root.appendingPathComponent("kimi.toml").path
        let workspaceID = UUID()
        let panelID = UUID()
        let sessionID = "kimi-captured-session"
        let arguments = [
            executable,
            "--resume", sessionID,
            "--model", "kimi-k2",
            "--config-file", configPath,
        ]
        let process = CmuxTopProcessInfo(
            pid: 4_321,
            parentPID: 1,
            name: "kimi",
            path: executable,
            ttyDevice: nil,
            cmuxWorkspaceID: workspaceID,
            cmuxSurfaceID: panelID,
            cmuxAttributionReason: "cmux-test",
            processGroupID: nil,
            terminalProcessGroupID: nil,
            cpuPercent: 0,
            residentBytes: 0,
            virtualBytes: 0,
            threadCount: 1
        )
        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: [.builtInKimi]),
            fileManager: fileManager,
            processSnapshot: CmuxTopProcessSnapshot(
                processes: [process],
                sampledAt: Date(timeIntervalSince1970: 123),
                includesProcessDetails: true
            ),
            capturedAt: 123,
            processArgumentsProvider: { pid in
                guard pid == process.pid else { return nil }
                return CmuxTopProcessArguments(
                    arguments: arguments,
                    environment: ["PWD": launchDirectory.path]
                )
            }
        )
        let snapshot = try #require(detected[
            .init(workspaceId: workspaceID, panelId: panelID)
        ]?.snapshot)
        let launch = try #require(snapshot.launchCommand)
        #expect(snapshot.kind == .custom("kimi"))
        #expect(snapshot.sessionId == sessionID)
        #expect(snapshot.workingDirectory == launchDirectory.path)
        #expect(launch.launcher == "kimi")
        #expect(launch.executablePath == executable)
        #expect(launch.arguments == arguments)
        #expect(launch.workingDirectory == launchDirectory.path)
        #expect(launch.source == "process")
        let resumeCommand = try #require(snapshot.resumeCommand)
        #expect(Array(TerminalStartupWorkingDirectoryPrefix.shellWordRanges(resumeCommand).map(\.value).suffix(7)) == [
            executable, "--resume", sessionID, "--model", "kimi-k2", "--config-file", configPath,
        ])
    }

    @Test("Customized Kimi registration keeps runtime cwd ownership")
    func customizedRegistrationKeepsRuntimeDirectory() throws {
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

        var userRegistration = try JSONDecoder().decode(
            CmuxVaultAgentRegistration.self,
            from: JSONEncoder().encode(CmuxVaultAgentRegistration.builtInKimi)
        )
        userRegistration.name = "Custom Kimi"
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
        let source = Workspace(agentSessionAutoResumeDefaults: defaults, restorableAgentIndexProvider: { .empty })
        defer { source.teardownAllPanels() }
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
        source.recordAgentPID(
            key: "kimi.\(sessionID)",
            pid: getpid(),
            panelId: sourcePanelID,
            refreshPorts: false
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
            restorableAgentIndex: .empty,
            surfaceResumeBindingIndex: bindingIndex
        )
        #expect(persisted.panels.first?.terminal?.agent?.kind == .custom("kimi"))
        #expect(persisted.panels.first?.terminal?.resumeBinding?.kind == "kimi")
        #expect(persisted.panels.first?.terminal?.wasAgentRunning == true)

        let restored = Workspace(agentSessionAutoResumeDefaults: defaults, restorableAgentIndexProvider: { .empty })
        defer { restored.teardownAllPanels() }
        restored.restoreSessionSnapshot(persisted)
        let restoredPanelID = try #require(restored.focusedPanelId)
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))
        #expect(restoredPanel.surface.debugInitialCommand() == nil)
        #expect(
            restoredPanel.surface.debugInitialInputForTesting()
                == " \(AgentRestoreLaunch.cliStartupExecutableToken) restore kimi \(sessionID)\n"
        )
        let restoredAgent = try #require(restored.restoredAgentSnapshotForTesting(panelId: restoredPanelID))
        #expect(restoredAgent.registration == customRegistration)
        #expect(restoredAgent.workingDirectory == runtimeWorkingDirectory.path)
        #expect(restoredAgent.preparedResumeArguments(
            launchCommand: restoredAgent.launchCommand,
            workingDirectory: restoredAgent.workingDirectory,
            observedPermissionMode: restoredAgent.permissionMode
        ) == ["custom-kimi", "--resume", sessionID])
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
