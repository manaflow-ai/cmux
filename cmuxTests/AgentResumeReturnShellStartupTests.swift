import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@Suite("Agent resume return shell startup")
struct AgentResumeReturnShellStartupTests {
    @Test("local resume input is one short readable CLI command")
    func localResumeInputUsesRestoreVerb() {
        let sessionID = "019dad34-d218-7943-b81a-eddac5c87951"
        let agentBinding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume \(sessionID) \(String(repeating: "--config x=y ", count: 200))",
            checkpointId: sessionID,
            source: "agent-hook",
            autoResume: true
        )
        let manualBinding = SurfaceResumeBindingSnapshot(
            name: "CLI binding",
            command: "printf done >/dev/null # \(String(repeating: "x", count: 4_000))",
            source: "cli",
            autoResume: true
        )
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionID,
            workingDirectory: "/tmp/项目 with spaces",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: [
                    "/Users/example/.bun/bin/codex",
                    "--add-dir",
                    "quote' and 日本語",
                    String(repeating: "nested-path-", count: 200),
                ],
                workingDirectory: "/tmp/项目 with spaces"
            )
        )

        #expect(
            agentBinding.restoreStartupInput(
                repairPortableAgentExecutable: true
            )
                == " cmux restore codex \(sessionID)\n"
        )
        #expect(
            manualBinding.restoreStartupInput(
                repairPortableAgentExecutable: true
            )
                == " cmux restore --surface\n"
        )
        #expect(
            snapshot.resumeStartupInput()
                == " cmux restore codex \(sessionID)\n"
        )
    }

    @Test("unsafe identifiers use the ASCII-only surface selector")
    func unsafeIdentifiersUseSurfaceSelector() {
        let snapshots = [
            SessionRestorableAgentSnapshot(
                kind: .custom("代理 agent"),
                sessionId: "会話 'one'"
            ),
            SessionRestorableAgentSnapshot(
                kind: .custom("-beta"),
                sessionId: "checkpoint"
            ),
            SessionRestorableAgentSnapshot(
                kind: .custom("agent"),
                sessionId: "--checkpoint"
            ),
        ]

        for snapshot in snapshots {
            #expect(
                snapshot.resumeStartupInput()
                    == " \(AgentRestoreLaunch.cliStartupExecutableToken) restore --surface\n"
            )
        }
    }

    @MainActor
    @Test("cwd-less restorable agents keep the owning shell in the session directory")
    func cwdlessRestorableAgentUsesSessionDirectory() throws {
        for recordedWorkingDirectory in [nil, "", "  \n"] as [String?] {
            let fixture = try makeAutoResumeFixture(prefix: "cwdless-agent")
            defer { fixture.cleanUp() }
            let source = Workspace(agentSessionAutoResumeDefaults: fixture.defaults)
            source.currentDirectory = fixture.projectDirectory.path
            let sourcePanelID = try #require(source.focusedPanelId)
            source.updatePanelShellActivityState(panelId: sourcePanelID, state: .commandRunning)
            let sessionID = UUID().uuidString.lowercased()
            source.setRestoredAgentSnapshotForTesting(
                SessionRestorableAgentSnapshot(
                    kind: .custom("cwdless-agent"),
                    sessionId: sessionID,
                    workingDirectory: recordedWorkingDirectory,
                    launchCommand: AgentLaunchCommandSnapshot(
                        launcher: "cwdless-agent",
                        executablePath: "/usr/local/bin/cwdless-agent",
                        arguments: ["/usr/local/bin/cwdless-agent", "--session", sessionID],
                        workingDirectory: recordedWorkingDirectory,
                        environment: [:]
                    )
                ),
                panelId: sourcePanelID
            )

            let restored = Workspace(agentSessionAutoResumeDefaults: fixture.defaults)
            restored.restoreSessionSnapshot(source.sessionSnapshot(includeScrollback: false))
            let restoredPanelID = try #require(restored.focusedPanelId)
            let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))

            #expect(
                restoredPanel.surface.debugInitialInputForTesting()
                    == " cmux restore cwdless-agent \(sessionID)\n"
            )
            #expect(restoredPanel.requestedWorkingDirectory == fixture.projectDirectory.path)
        }
    }

    @MainActor
    @Test("cwd-less surface bindings keep the owning shell in the session directory")
    func cwdlessSurfaceBindingUsesSessionDirectory() throws {
        for recordedWorkingDirectory in [nil, "", "  \n"] as [String?] {
            let fixture = try makeAutoResumeFixture(prefix: "cwdless-binding")
            defer { fixture.cleanUp() }
            let source = Workspace(agentSessionAutoResumeDefaults: fixture.defaults)
            source.currentDirectory = fixture.projectDirectory.path
            let sourcePanelID = try #require(source.focusedPanelId)
            let binding = SurfaceResumeBindingSnapshot(
                name: "CWD-less binding",
                kind: "command",
                command: "/usr/bin/true",
                cwd: recordedWorkingDirectory,
                source: "process-detected",
                autoResume: true
            )
            let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
                .init(workspaceId: source.id, panelId: sourcePanelID): binding,
            ])

            let restored = Workspace(agentSessionAutoResumeDefaults: fixture.defaults)
            restored.restoreSessionSnapshot(source.sessionSnapshot(
                includeScrollback: false,
                surfaceResumeBindingIndex: bindingIndex
            ))
            let restoredPanelID = try #require(restored.focusedPanelId)
            let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))

            #expect(
                restoredPanel.surface.debugInitialInputForTesting()
                    == " cmux restore --surface\n"
            )
            #expect(restoredPanel.requestedWorkingDirectory == fixture.projectDirectory.path)
        }
    }

    @MainActor
    @Test("cwd-ignore auto-resume gives the owning shell a safe home fallback")
    func cwdIgnoreAutoResumeUsesHomeFallback() throws {
        let fixture = try makeAutoResumeFixture(prefix: "cwd-ignore")
        defer { fixture.cleanUp() }
        let source = Workspace(agentSessionAutoResumeDefaults: fixture.defaults)
        source.currentDirectory = fixture.projectDirectory.path
        let sourcePanelID = try #require(source.focusedPanelId)
        source.updatePanelShellActivityState(panelId: sourcePanelID, state: .commandRunning)
        let sessionID = UUID().uuidString.lowercased()
        let registration = CmuxVaultAgentRegistration(
            id: "cwd-ignore-agent",
            name: "CWD Ignore Agent",
            detect: CmuxVaultAgentDetectRule(processName: "cwd-ignore-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "cwd-ignore-agent --session {{sessionId}}",
            cwd: .ignore
        )
        source.setRestoredAgentSnapshotForTesting(
            SessionRestorableAgentSnapshot(
                kind: .custom(registration.id),
                sessionId: sessionID,
                workingDirectory: nil,
                launchCommand: AgentLaunchCommandSnapshot(
                    processDetectedLauncher: registration.id,
                    executablePath: "/usr/local/bin/cwd-ignore-agent",
                    arguments: ["/usr/local/bin/cwd-ignore-agent", "--session", sessionID],
                    workingDirectory: fixture.projectDirectory.path,
                    environment: [:]
                ),
                registration: registration
            ),
            panelId: sourcePanelID
        )

        let restored = Workspace(agentSessionAutoResumeDefaults: fixture.defaults)
        restored.restoreSessionSnapshot(source.sessionSnapshot(includeScrollback: false))
        let restoredPanelID = try #require(restored.focusedPanelId)
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))

        #expect(
            restoredPanel.surface.debugInitialInputForTesting()
                == " cmux restore cwd-ignore-agent \(sessionID)\n"
        )
        #expect(restored.restoredResumeSessionWorkingDirectoriesByPanelId[restoredPanelID] == nil)
        #expect(
            restoredPanel.requestedWorkingDirectory == FileManager.default.homeDirectoryForCurrentUser.path,
            "The outer host shell needs an explicit safe cwd even though the agent's cwd policy remains ignored"
        )
    }

    @Test("non-restore one-shot launchers retain their storage policy")
    func nonRestoreOneShotLauncherStoragePolicy() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-9258-store-\(UUID().uuidString)", isDirectory: true)
        let launcherDirectory = root.appendingPathComponent("cmux-r", isDirectory: true)
        let staleLauncher = launcherDirectory.appendingPathComponent("stale.zsh", isDirectory: false)
        let currentLauncher = launcherDirectory.appendingPathComponent("current.zsh", isDirectory: false)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try fileManager.createDirectory(at: launcherDirectory, withIntermediateDirectories: true)
        try "#!/bin/zsh\n:\n".write(to: staleLauncher, atomically: true, encoding: .utf8)
        try "#!/bin/zsh\n:\n".write(to: currentLauncher, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-(25 * 60 * 60))],
            ofItemAtPath: staleLauncher.path
        )
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-(23 * 60 * 60))],
            ofItemAtPath: currentLauncher.path
        )
        defer { try? fileManager.removeItem(at: root) }

        let launcher = try #require(OneShotTerminalLauncherStore(
            fileManager: fileManager,
            temporaryDirectory: root,
            currentDate: now
        ).writeLauncherScript(
            command: ":",
            workingDirectory: nil
        ))

        #expect(!fileManager.fileExists(atPath: staleLauncher.path))
        #expect(fileManager.fileExists(atPath: currentLauncher.path))
        let directoryMode = try #require(
            fileManager.attributesOfItem(atPath: launcherDirectory.path)[.posixPermissions] as? NSNumber
        ).intValue & 0o777
        let launcherMode = try #require(
            fileManager.attributesOfItem(atPath: launcher.path)[.posixPermissions] as? NSNumber
        ).intValue & 0o777
        #expect(directoryMode == 0o700)
        #expect(launcherMode == 0o600)
    }

    private struct AutoResumeFixture {
        let defaults: UserDefaults
        let defaultsSuiteName: String
        let projectDirectory: URL

        func cleanUp() {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: projectDirectory)
        }
    }

    private func makeAutoResumeFixture(prefix: String) throws -> AutoResumeFixture {
        let defaultsSuiteName = "cmux-5391-\(prefix)-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        let projectDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-5391-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        return AutoResumeFixture(
            defaults: defaults,
            defaultsSuiteName: defaultsSuiteName,
            projectDirectory: projectDirectory
        )
    }
}
