import AppKit
import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the invariant that a Vault launch has a structured
/// restore record before its startup selector is admitted to a terminal.
@MainActor
@Suite(.serialized)
struct VaultRestorePathGuaranteeTests {
    @Test(arguments: ["claude", "codex", "grok", "opencode", "rovodev", "hermes-agent"])
    func everyBuiltInEntryUsesRestoreVerb(_ rawKind: String) throws {
        let entry = Self.entry(for: rawKind)
        let launch = try #require(entry.resumeLaunch)

        #expect(launch.strategy == .restoreVerb)
        #expect(launch.initialInput.hasPrefix(" \(AgentRestoreLaunch.cliStartupExecutableToken) restore"))
        #expect(launch.startupRestoreAgent?.sessionId == entry.sessionId)
        #expect(launch.startupRestoreAgent?.workingDirectory == entry.cwd)
    }

    @Test
    func rovodevRestoreRecordKeepsTheProviderRestoreSelector() throws {
        let entry = Self.entry(for: "rovodev")
        let launch = try #require(entry.resumeLaunch)
        let snapshot = try #require(launch.startupRestoreAgent)
        let arguments = try #require(snapshot.preparedResumeArguments(
            launchCommand: snapshot.launchCommand,
            workingDirectory: snapshot.workingDirectory,
            observedPermissionMode: snapshot.permissionMode
        ))

        #expect(arguments == ["acli", "rovodev", "run", "--restore", entry.sessionId])
        #expect(launch.initialInput == " cmux restore rovodev \(entry.sessionId)\n")
        #expect(launch.startupInput(for: .remoteHost) == launch.initialInput)
    }

    @Test
    func registeredGrokProfileKeepsGrokHomeInRestoreRecord() throws {
        let grokHome = "/tmp/グロク profile"
        var registration = CmuxVaultAgentRegistration.builtInGrok
        registration.resumeCommand = "env GROK_HOME=\(SessionEntry.shellQuote(grokHome)) \(registration.resumeCommand)"
        let entry = SessionEntry(
            id: "grok:grok-session",
            agent: .registered(RegisteredSessionAgent(registration: registration)),
            sessionId: "grok-session",
            title: "Grok profile session",
            cwd: "/tmp/grok-project",
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_800_000_100),
            fileURL: nil,
            specifics: .registered(registration)
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
        let target = ControlSurfaceResumeTarget.workspace(
            tabManager: tabManager,
            workspace: workspace,
            surfaceID: panelID
        )
        let record = try #require(TerminalController.shared.controlSurfaceRestoreRecord(
            target: target,
            binding: nil
        ))

        #expect(launch.strategy == .restoreVerb)
        #expect(record.kind == "grok")
        #expect(record.workingDirectory == "/tmp/grok-project")
        #expect(record.launchCommand?.environment?["GROK_HOME"] == grokHome)
        #expect(record.preparedArguments == ["grok", "-r", "grok-session"])
        #expect(record.legacyCommand == nil)
    }

    @Test
    func oversizedInvalidRegistrationDoesNotUseUnboundedLegacyFallback() throws {
        let registration = CmuxVaultAgentRegistration(
            id: "legacy agent",
            name: "Legacy agent",
            detect: CmuxVaultAgentDetectRule(processName: "legacy-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "{{executable}} --session {{sessionId}} "
                + String(repeating: "--profile-value ", count: 160),
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
            modified: Date(timeIntervalSince1970: 1_800_000_101),
            fileURL: nil,
            specifics: .registered(registration)
        )

        #expect(entry.copyResumeCommand?.utf8.count ?? 0 > 900)
        #expect(entry.resumeLaunch == nil)
    }

    @Test
    func unsafeEnvironmentPrefixUsesTheBoundedCompatibilityClassification() throws {
        let registration = CmuxVaultAgentRegistration(
            id: "dynamic-env-agent",
            name: "Dynamic env agent",
            detect: CmuxVaultAgentDetectRule(processName: "dynamic-env-agent"),
            sessionIdSource: .argvOption("--session"),
            // Command substitutions are intentionally not copied into a
            // structured environment record. They must remain an explicit
            // compatibility case (or be rejected by the byte bound).
            resumeCommand: "env GROK_HOME=$(runtime-home) dynamic-env-agent --session {{sessionId}}",
            cwd: .preserve
        )
        let entry = SessionEntry(
            id: "dynamic-env-agent:dynamic-session",
            agent: .registered(RegisteredSessionAgent(registration: registration)),
            sessionId: "dynamic-session",
            title: "Dynamic env session",
            cwd: "/tmp/dynamic-env-project",
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_800_000_104),
            fileURL: nil,
            specifics: .registered(registration)
        )
        let launch = try #require(entry.resumeLaunch)

        #expect(launch.strategy == .legacyCommand)
        #expect(launch.legacyFallbackReason == .missingStructuredSnapshot)
        #expect(launch.startupRestoreAgent == nil)
    }

    @Test
    func legacyFallbackRejectsControlCharactersBeforeTyping() throws {
        let registration = CmuxVaultAgentRegistration(
            id: "control agent",
            name: "Control agent",
            detect: CmuxVaultAgentDetectRule(processName: "control-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "control-agent --session {{sessionId}}\u{1B}[31m",
            cwd: .preserve
        )
        let entry = SessionEntry(
            id: "control agent:control-session",
            agent: .registered(RegisteredSessionAgent(registration: registration)),
            sessionId: "control-session",
            title: "Control session",
            cwd: "/tmp/control-project",
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_800_000_105),
            fileURL: nil,
            specifics: .registered(registration)
        )

        #expect(entry.resumeLaunch == nil)
    }

    @Test
    func resumeFromRemoteTmuxSelectionCreatesLocalRestoreWorkspace() throws {
        let workingDirectory = "/tmp/vault-remote-tmux"
        let manager = TabManager(
            initialWorkingDirectory: workingDirectory,
            autoWelcomeIfNeeded: false
        )
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let mirrorWorkspace = try #require(manager.selectedWorkspace)
        mirrorWorkspace.isRemoteTmuxMirror = true

        let entry = Self.entry(for: "codex", cwd: workingDirectory)
        SessionEntryResumeCoordinator.resume(entry, tabManager: manager)

        #expect(manager.tabs.count == 2)
        let restoredWorkspace = try #require(manager.selectedWorkspace)
        #expect(restoredWorkspace !== mirrorWorkspace)
        let panelID = try #require(restoredWorkspace.focusedPanelId)
        #expect(
            restoredWorkspace.restoredAgentSnapshotsByPanelId[panelID]?.sessionId
                == entry.sessionId
        )
        #expect(
            restoredWorkspace.terminalPanel(for: panelID)?.surface.debugInitialInputForTesting()
                == entry.resumeLaunch?.initialInput
        )
    }

    @Test
    func localPaneDropSeedsTheSameRestoreRecordAsResume() throws {
        let workingDirectory = "/tmp/vault-drop-restore"
        let manager = TabManager(
            initialWorkingDirectory: workingDirectory,
            autoWelcomeIfNeeded: false
        )
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(manager.selectedWorkspace)
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let entry = Self.entry(for: "codex", cwd: workingDirectory)
        let baselinePanelIDs = Set(workspace.panels.keys)
        let handled = workspace.handleSessionDrop(
            entry: entry,
            destination: .insert(paneID, 0)
        )

        #expect(handled)
        let panelID = try #require(workspace.panels.keys.first { !baselinePanelIDs.contains($0) })
        let launch = try #require(entry.resumeLaunch)
        #expect(workspace.terminalPanel(for: panelID)?.surface.debugInitialInputForTesting() == launch.initialInput)
        #expect(workspace.restoredAgentSnapshotsByPanelId[panelID]?.sessionId == entry.sessionId)
        let target = ControlSurfaceResumeTarget.workspace(
            tabManager: manager,
            workspace: workspace,
            surfaceID: panelID
        )
        let record = try #require(TerminalController.shared.controlSurfaceRestoreRecord(
            target: target,
            binding: nil
        ))
        #expect(record.kind == "codex")
        #expect(record.checkpointID == entry.sessionId)
        #expect(record.workingDirectory == workingDirectory)
        #expect(record.legacyCommand == nil)
    }

    @Test
    func legacyFallbackUsesRemoteHostDialectWithoutLocalShellEnvelope() throws {
        let registration = CmuxVaultAgentRegistration(
            id: "legacy agent",
            name: "Legacy agent",
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
            modified: Date(timeIntervalSince1970: 1_800_000_103),
            fileURL: nil,
            specifics: .registered(registration)
        )
        let launch = try #require(entry.resumeLaunch)

        #expect(launch.strategy == .legacyCommand)
        #expect(launch.legacyFallbackReason == .missingStructuredSnapshot)
        #expect(
            launch.startupInput(for: .remoteHost)
                == (entry.copyResumeCommand ?? "") + "\n"
        )
    }

    private static func entry(for rawKind: String, cwd: String = "/tmp/vault-project") -> SessionEntry {
        let sessionID = "vault-\(rawKind)-session"
        let specifics: AgentSpecifics
        let agent: SessionAgent
        switch rawKind {
        case "claude":
            agent = .claude
            specifics = .claude(model: "sonnet", permissionMode: "acceptEdits", configDirectoryForResume: nil)
        case "codex":
            agent = .codex
            specifics = .codex(model: "gpt-5.5", approvalPolicy: "never", sandboxMode: "disabled", effort: "high")
        case "grok":
            agent = .grok
            specifics = .grok(model: "grok-4", permissionMode: "auto", sandboxMode: "danger-full-access", grokHome: nil)
        case "opencode":
            agent = .opencode
            specifics = .opencode(providerModel: "anthropic/claude-sonnet", agentName: "build")
        case "rovodev":
            agent = .rovodev
            specifics = .rovodev
        default:
            agent = .hermesAgent
            specifics = .hermesAgent(source: "tui", model: "gpt-5.5", hermesHome: nil)
        }
        return SessionEntry(
            id: "\(rawKind):\(sessionID)",
            agent: agent,
            sessionId: sessionID,
            title: "Vault \(rawKind)",
            cwd: cwd,
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_800_000_102),
            fileURL: nil,
            specifics: specifics
        )
    }
}
