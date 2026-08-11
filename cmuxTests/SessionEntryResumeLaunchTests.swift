import CMUXAgentLaunch
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

    @Test("Restore responder resolves a Vault startup snapshot without restored-panel state")
    func responderResolvesVaultStartupSnapshot() throws {
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
        let workspace = Workspace(
            workingDirectory: launch.workingDirectory,
            initialTerminalInput: launch.initialInput,
            initialTerminalStartupRestoreAgent: snapshot
        )
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        #expect(workspace.restoredAgentSnapshotsByPanelId[panelID] == nil)

        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        defer { tabManager.tabs.forEach { $0.teardownAllPanels() } }
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
        #expect(record.source == "vault")
        #expect(record.workingDirectory == "/tmp")
        #expect(record.permissionMode == "acceptEdits")
        #expect(record.environment.isEmpty)
        #expect(record.launchCommand?.environment?["CLAUDE_CONFIG_DIR"] == "/tmp/claude-config")
        #expect(record.preparedArguments?.contains("--resume") == true)
        #expect(record.preparedArguments?.contains("vault-claude-session") == true)
        #expect(record.legacyCommand == nil)
    }
}
