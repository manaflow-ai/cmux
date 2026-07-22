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
    @Test("Bundled Kimi wrapper captures launch metadata before exec")
    func bundledWrapperCapturesLaunchMetadata() throws {
        let fileManager = FileManager.default
        let bundledCLIURL = try BundledCLITestSupport.bundledCLIURL(
            for: CLINotifyProcessIntegrationRegressionTests.self
        )
        let wrapperURL = bundledCLIURL
            .deletingLastPathComponent()
            .appendingPathComponent("kimi", isDirectory: false)
        let executableWrapperURL = try #require(
            fileManager.isExecutableFile(atPath: wrapperURL.path) ? wrapperURL : nil
        )

        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-kimi-wrapper-\(UUID().uuidString)", isDirectory: true)
        let realBinURL = root.appendingPathComponent("real-bin", isDirectory: true)
        let launchDirectoryURL = root.appendingPathComponent("launch-repo", isDirectory: true)
        let captureURL = root.appendingPathComponent("capture.txt", isDirectory: false)
        let configURL = root.appendingPathComponent("kimi.toml", isDirectory: false)
        try fileManager.createDirectory(at: realBinURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: launchDirectoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let realKimiURL = realBinURL.appendingPathComponent("kimi", isDirectory: false)
        try """
        #!/bin/sh
        {
          printf 'kind=%s\n' "${CMUX_AGENT_LAUNCH_KIND-}"
          printf 'executable=%s\n' "${CMUX_AGENT_LAUNCH_EXECUTABLE-}"
          printf 'argv=%s\n' "${CMUX_AGENT_LAUNCH_ARGV_B64-}"
          printf 'cwd=%s\n' "${CMUX_AGENT_LAUNCH_CWD-}"
        } > "$CMUX_KIMI_TEST_CAPTURE"
        """.write(to: realKimiURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: realKimiURL.path)

        let process = Process()
        process.executableURL = executableWrapperURL
        process.arguments = [
            "--model", "kimi-k2",
            "--config-file", configURL.path,
        ]
        process.currentDirectoryURL = launchDirectoryURL
        process.environment = [
            "HOME": root.path,
            "PATH": "\(realBinURL.path):/usr/bin:/bin",
            "PWD": launchDirectoryURL.path,
            "CMUX_SURFACE_ID": UUID().uuidString,
            "CMUX_KIMI_TEST_CAPTURE": captureURL.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let capture = try String(contentsOf: captureURL, encoding: .utf8)
        let fields: [String: String] = Dictionary(uniqueKeysWithValues: capture.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]))
        })
        #expect(fields["kind"] == "kimi")
        #expect(fields["executable"] == realKimiURL.path)
        #expect(fields["cwd"] == launchDirectoryURL.path)

        let encodedArgv = try #require(fields["argv"])
        let argvData = try #require(Data(base64Encoded: encodedArgv))
        let capturedArgv = argvData
            .split(separator: 0)
            .map { String(decoding: $0, as: UTF8.self) }
        #expect(capturedArgv == [
            realKimiURL.path,
            "--model", "kimi-k2",
            "--config-file", configURL.path,
        ])
    }

    @Test("Value-identical user Kimi registration keeps runtime cwd ownership")
    func valueIdenticalCustomRegistrationKeepsRuntimeDirectory() throws {
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

        let userRegistration = try JSONDecoder().decode(
            CmuxVaultAgentRegistration.self,
            from: JSONEncoder().encode(CmuxVaultAgentRegistration.builtInKimi)
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

        let restored = Workspace(agentSessionAutoResumeDefaults: defaults)
        restored.restoreSessionSnapshot(persisted)
        let restoredPanelID = try #require(restored.focusedPanelId)
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))
        let launcherCommand = try #require(restoredPanel.surface.debugInitialCommand())
        let launcherWords = TerminalStartupWorkingDirectoryPrefix
            .shellWordRanges(launcherCommand)
            .map(\.value)
        #expect(launcherWords.first == "/bin/zsh", "\(launcherCommand)")
        let launcherPath = try #require(launcherWords.dropFirst().first)
        let launcher = try String(contentsOfFile: launcherPath, encoding: .utf8)
        #expect(launcher.contains("'custom-kimi' '--resume' '\(sessionID)'"), "\(launcher)")
        #expect(!launcher.contains("'kimi' '--resume' '\(sessionID)'"), "\(launcher)")
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
