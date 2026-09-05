import CMUXAgentLaunch
import CmuxAgentChat
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SessionEntryResumeLaunchTests {
    @Test("Vault resume plans the short restore verb with structured Codex settings")
    func vaultResumeUsesShortRestoreVerb() throws {
        let entry = SessionEntry(
            id: "codex:vault-session",
            agent: .codex,
            sessionId: "vault-session",
            title: "Resume me",
            cwd: "/tmp/vault-project",
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_800_000_000),
            fileURL: nil,
            specifics: .codex(
                model: "gpt-5.5",
                approvalPolicy: "never",
                sandboxMode: "disabled",
                effort: "high"
            )
        )

        let launch = try #require(entry.resumeLaunch)
        #expect(launch.strategy == .restoreVerb)
        #expect(
            launch.initialInput
                == " \(AgentRestoreLaunch.cliStartupExecutableToken) restore codex vault-session\n"
        )
        #expect(launch.workingDirectory == "/tmp/vault-project")
        #expect(!launch.initialInput.contains("cd --"))
        #expect(!launch.initialInput.contains("codex resume"))

        let snapshot = try #require(launch.startupRestoreAgent)
        let arguments = try #require(snapshot.preparedResumeArguments(
            launchCommand: snapshot.launchCommand,
            workingDirectory: snapshot.workingDirectory,
            observedPermissionMode: snapshot.permissionMode
        ))
        #expect(Array(arguments.prefix(3)) == ["codex", "resume", "vault-session"])
        #expect(arguments.contains("gpt-5.5"))
        #expect(arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
        #expect(arguments.contains("model_reasoning_effort=high"))
    }

    @Test("Vault Codex restore keeps the transcript's effective Codex home")
    func vaultCodexRestorePreservesEffectiveCodexHome() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vault-codex-home-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-account", isDirectory: true)
        let transcript = codexHome
            .appendingPathComponent("sessions/2026/09/04/rollout-session.jsonl", isDirectory: false)
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let entry = SessionEntry(
            id: "codex:\(transcript.path)",
            agent: .codex,
            sessionId: "vault-session-home",
            title: "Account-scoped Codex session",
            cwd: root.path,
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_800_000_000),
            fileURL: transcript,
            specifics: .codex(
                model: "gpt-5.5",
                approvalPolicy: nil,
                sandboxMode: nil,
                effort: nil
            )
        )

        let launch = try #require(entry.resumeLaunch)
        let snapshot = try #require(launch.startupRestoreAgent)
        #expect(
            snapshot.launchCommand?.environment?["CODEX_HOME"] == codexHome.path,
            "Vault restore must probe and resume the account that owns the transcript"
        )
    }

    @Test("Registered Vault agents use structured restore argv")
    func registeredAgentUsesStructuredRestore() throws {
        let registration = CmuxVaultAgentRegistration(
            id: "my-agent",
            name: "My Agent",
            detect: CmuxVaultAgentDetectRule(processName: "my-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "{{executable}} --session {{sessionId}} --profile fast",
            cwd: .preserve
        )
        let entry = SessionEntry(
            id: "my-agent:custom-session",
            agent: .registered(RegisteredSessionAgent(registration: registration)),
            sessionId: "custom-session",
            title: "Custom session",
            cwd: "/tmp/custom-project",
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_800_000_001),
            fileURL: nil,
            specifics: .registered(registration)
        )

        let launch = try #require(entry.resumeLaunch)
        #expect(launch.strategy == .restoreVerb)
        #expect(launch.workingDirectory == "/tmp/custom-project")
        #expect(
            launch.initialInput
                == " \(AgentRestoreLaunch.cliStartupExecutableToken) restore my-agent custom-session\n"
        )
        let snapshot = try #require(launch.startupRestoreAgent)
        #expect(
            snapshot.preparedResumeArguments(
                launchCommand: snapshot.launchCommand,
                workingDirectory: snapshot.workingDirectory,
                observedPermissionMode: snapshot.permissionMode
            ) == ["my-agent", "--session", "custom-session", "--profile", "fast"]
        )
    }

    @Test("Unencodable custom Vault kinds use the explicit legacy strategy")
    func unencodableCustomKindUsesLegacyFallback() throws {
        let registration = CmuxVaultAgentRegistration(
            id: "legacy agent",
            name: "Legacy Agent",
            detect: CmuxVaultAgentDetectRule(processName: "legacy-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "{{executable}} --session {{sessionId}}",
            cwd: .preserve
        )
        let entry = SessionEntry(
            id: "legacy agent:legacy-session",
            agent: .registered(RegisteredSessionAgent(registration: registration)),
            sessionId: "legacy-session",
            title: "Legacy session",
            cwd: "/tmp/legacy-project",
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_800_000_002),
            fileURL: nil,
            specifics: .registered(registration)
        )

        let copiedCommand = try #require(entry.copyResumeCommand)
        let launch = try #require(entry.resumeLaunch)
        #expect(launch.strategy == .legacyCommand)
        #expect(launch.initialInput == copiedCommand + "\n")
        #expect(launch.workingDirectory == "/tmp/legacy-project")
        #expect(launch.startupRestoreAgent == nil)
        #expect(!launch.initialInput.contains(" restore legacy agent "))
    }

    @Test("Restore responder resolves a Vault snapshot through lifecycle state")
    func responderResolvesVaultLifecycleSnapshot() throws {
        let entry = SessionEntry(
            id: "claude:vault-claude-session",
            agent: .claude,
            sessionId: "vault-claude-session",
            title: "Claude session",
            cwd: "/tmp",
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_800_000_002),
            fileURL: nil,
            specifics: .claude(
                model: "sonnet",
                permissionMode: "acceptEdits",
                configDirectoryForResume: "/tmp/claude-config"
            )
        )
        let launch = try #require(entry.resumeLaunch)
        let snapshot = try #require(launch.startupRestoreAgent)
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        defer { tabManager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = tabManager.addWorkspace(
            workingDirectory: launch.workingDirectory,
            initialTerminalInput: launch.initialInput,
            initialTerminalStartupRestoreAgent: snapshot,
            autoWelcomeIfNeeded: false
        )
        let panelID = try #require(workspace.focusedPanelId)
        #expect(
            workspace.restoredAgentSnapshotsByPanelId[panelID]?.sessionId
                == "vault-claude-session"
        )

        let target = ControlSurfaceResumeTarget.workspace(
            tabManager: tabManager,
            workspace: workspace,
            surfaceID: panelID
        )
        let record = try #require(TerminalController.shared.controlSurfaceRestoreRecord(
            target: target,
            binding: nil
        ))

        #expect(record.modeRawValue == AgentRestoreRequestMode.resumeAgent.rawValue)
        #expect(record.kind == "claude")
        #expect(record.checkpointID == "vault-claude-session")
        #expect(record.source == "session-snapshot")
        #expect(record.workingDirectory == "/tmp")
        #expect(record.permissionMode == "acceptEdits")
        #expect(record.environment.isEmpty)
        #expect(record.launchCommand?.environment?["CLAUDE_CONFIG_DIR"] == "/tmp/claude-config")
        #expect(record.preparedArguments?.contains("--resume") == true)
        #expect(record.preparedArguments?.contains("vault-claude-session") == true)
        #expect(record.legacyCommand == nil)

        workspace.clearRestoredAgentSnapshot(panelId: panelID)
        #expect(TerminalController.shared.controlSurfaceRestoreRecord(
            target: target,
            binding: nil
        ) == nil)
        #expect(
            workspace.sessionSnapshot(includeScrollback: false)
                .panels.first { $0.id == panelID }?.terminal?.agent == nil
        )
    }

    @Test("Vault-restored chats persist and resume after a session round trip")
    func vaultRestorePersistsAcrossRelaunch() throws {
        let sessionID = "vault-persisted-session"
        let entry = SessionEntry(
            id: "codex:\(sessionID)",
            agent: .codex,
            sessionId: sessionID,
            title: "Persisted Vault session",
            cwd: "/tmp/vault-persisted-project",
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_800_000_003),
            fileURL: nil,
            specifics: .codex(
                model: "gpt-5.5",
                approvalPolicy: "never",
                sandboxMode: "disabled",
                effort: "high"
            )
        )
        let launch = try #require(entry.resumeLaunch)
        let restorableAgent = try #require(launch.startupRestoreAgent)
        var resumeIntents: [AgentChatResumeIntent] = []
        let resumeIntentRecorder = AgentChatResumeIntentRecorder {
            resumeIntents.append($0)
        }

        let defaultsName = "cmux-vault-restore-persistence-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

        let source = Workspace(
            workingDirectory: launch.workingDirectory,
            initialTerminalInput: launch.initialInput,
            initialTerminalStartupRestoreAgent: restorableAgent,
            agentSessionAutoResumeDefaults: defaults,
            agentChatResumeIntentRecorder: resumeIntentRecorder
        )
        defer { source.teardownAllPanels() }
        let sourcePanelID = try #require(source.focusedPanelId)
        #expect(
            source.restoredResumeSessionWorkingDirectoriesByPanelId[sourcePanelID]
                == launch.workingDirectory
        )
        let persisted = source.sessionSnapshot(includeScrollback: false)
        #expect(
            persisted.panels.first { $0.id == sourcePanelID }?.terminal?.agent?.sessionId
                == sessionID
        )

        let encoded = try JSONEncoder().encode(persisted)
        let decoded = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: encoded)
        let restored = Workspace(
            agentSessionAutoResumeDefaults: defaults,
            agentChatResumeIntentRecorder: resumeIntentRecorder
        )
        defer { restored.teardownAllPanels() }
        let restoredPanelIDs = restored.restoreSessionSnapshot(decoded)
        let restoredPanelID = try #require(restoredPanelIDs[sourcePanelID])
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))

        #expect(restoredPanel.surface.debugInitialInputForTesting() == launch.initialInput)
        #expect(
            restored.restoredResumeSessionWorkingDirectoriesByPanelId[restoredPanelID]
                == launch.workingDirectory
        )
        #expect(
            restored.sessionSnapshot(includeScrollback: false)
                .panels.first { $0.id == restoredPanelID }?.terminal?.agent?.sessionId
                == sessionID
        )
        let restoredIntent = try #require(resumeIntents.last)
        #expect(restoredIntent.sessionID == sessionID)
        #expect(restoredIntent.surfaceID == restoredPanelID.uuidString)
        #expect(restoredIntent.workspaceID == restored.id.uuidString)
        #expect(restoredIntent.workingDirectory == launch.workingDirectory)
    }

    @Test("Vault terminal creation authoritatively rebinds the resumed chat")
    func vaultCreationRebindsResumedChat() throws {
        let sessionID = "vault-chat-rebind-\(UUID().uuidString)"
        let workingDirectory = "/tmp/vault-chat-rebind"
        let entry = SessionEntry(
            id: "codex:\(sessionID)",
            agent: .codex,
            sessionId: sessionID,
            title: "Rebound Vault session",
            cwd: workingDirectory,
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_800_000_004),
            fileURL: nil,
            specifics: .codex(
                model: nil,
                approvalPolicy: nil,
                sandboxMode: nil,
                effort: nil
            )
        )
        let launch = try #require(entry.resumeLaunch)
        let restorableAgent = try #require(launch.startupRestoreAgent)
        var resumeIntents: [AgentChatResumeIntent] = []
        let resumeIntentRecorder = AgentChatResumeIntentRecorder {
            resumeIntents.append($0)
        }

        let tabManager = TabManager(
            autoWelcomeIfNeeded: false,
            agentChatResumeIntentRecorder: resumeIntentRecorder
        )
        defer { tabManager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = tabManager.addWorkspace(
            workingDirectory: launch.workingDirectory,
            initialTerminalInput: launch.initialInput,
            initialTerminalStartupRestoreAgent: restorableAgent,
            autoWelcomeIfNeeded: false
        )
        let panelID = try #require(workspace.focusedPanelId)
        let intent = try #require(resumeIntents.last)

        #expect(intent.sessionID == sessionID)
        #expect(intent.source == "codex")
        #expect(intent.surfaceID == panelID.uuidString)
        #expect(intent.workspaceID == workspace.id.uuidString)
        #expect(intent.workingDirectory == workingDirectory)
    }

    @Test("Vault tab and split placements seed persistent lifecycle state")
    func vaultPlacementPathsSeedLifecycleState() throws {
        let sessionID = "vault-placement-session"
        let workingDirectory = FileManager.default.temporaryDirectory
            .appending(path: "cmux-vault-placement-\(UUID().uuidString)", directoryHint: .isDirectory)
            .path
        try FileManager.default.createDirectory(
            atPath: workingDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: workingDirectory) }
        let entry = SessionEntry(
            id: "codex:\(sessionID)",
            agent: .codex,
            sessionId: sessionID,
            title: "Placed Vault session",
            cwd: workingDirectory,
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_800_000_004),
            fileURL: nil,
            specifics: .codex(
                model: nil,
                approvalPolicy: nil,
                sandboxMode: nil,
                effort: nil
            )
        )
        let launch = try #require(entry.resumeLaunch)
        let restorableAgent = try #require(launch.startupRestoreAgent)
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let initialPanelID = try #require(workspace.focusedPanelId)
        let paneID = try #require(workspace.paneId(forPanelId: initialPanelID))

        let tabPanel = try #require(workspace.newTerminalSurface(
            inPane: paneID,
            focus: true,
            workingDirectory: launch.workingDirectory,
            initialInput: launch.initialInput,
            startupRestoreAgent: restorableAgent
        ))
        let splitPanel = try #require(workspace.splitPaneWithNewTerminal(
            targetPane: paneID,
            orientation: .horizontal,
            insertFirst: false,
            workingDirectory: launch.workingDirectory,
            initialInput: launch.initialInput,
            startupRestoreAgent: restorableAgent
        ))
        let persisted = workspace.sessionSnapshot(includeScrollback: false)

        for panelID in [tabPanel.id, splitPanel.id] {
            #expect(workspace.restoredAgentSnapshotsByPanelId[panelID]?.sessionId == sessionID)
            #expect(
                workspace.restoredResumeSessionWorkingDirectoriesByPanelId[panelID]
                    == workingDirectory
            )
            #expect(
                persisted.panels.first { $0.id == panelID }?.terminal?.agent?.sessionId
                    == sessionID
            )
        }

        workspace.restoredAgentLifecycle.setResumeState(
            .autoResumeCommandRunning,
            panelId: tabPanel.id
        )
        workspace.panelDirectories[tabPanel.id] = FileManager.default.homeDirectoryForCurrentUser.path
        workspace.foregroundProcessWorkingDirectoryProvider = { _ in nil }
        let inheritedSplit = try #require(workspace.newTerminalSplit(
            from: tabPanel.id,
            orientation: .vertical,
            focus: false
        ))
        #expect(inheritedSplit.requestedWorkingDirectory == workingDirectory)
    }

}
