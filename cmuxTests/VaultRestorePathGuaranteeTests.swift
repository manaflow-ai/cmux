import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxCore
import CmuxSettings
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

    @Test(arguments: ["claude", "codex", "grok", "opencode", "rovodev", "hermes-agent"])
    func everyBuiltInEntryUsesTheSameSelectorForRemoteHost(_ rawKind: String) throws {
        let launch = try #require(Self.entry(for: rawKind).resumeLaunch)

        #expect(launch.startupInput(for: .loginShell) == launch.initialInput)
        #expect(launch.startupInput(for: .remoteHost) == launch.initialInput)
        #expect(launch.initialInput.contains(" restore \(rawKind) "))
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
        #expect(launch.legacyFallbackReason == .unrepresentableRegistration)
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
    func compatibilityInputIsBoundedWhenItIsAdmitted() throws {
        let registration = CmuxVaultAgentRegistration(
            id: "legacy boundary agent",
            name: "Legacy boundary agent",
            detect: CmuxVaultAgentDetectRule(processName: "legacy-boundary-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "legacy-boundary-agent --session {{sessionId}}",
            cwd: .preserve
        )
        let entry = SessionEntry(
            id: "legacy boundary agent:boundary-session",
            agent: .registered(RegisteredSessionAgent(registration: registration)),
            sessionId: "boundary-session",
            title: "Legacy boundary session",
            cwd: "/tmp/legacy-boundary-project",
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_800_000_106),
            fileURL: nil,
            specifics: .registered(registration)
        )
        let launch = try #require(entry.resumeLaunch)

        #expect(launch.strategy == .legacyCommand)
        #expect(launch.legacyFallbackReason == .unrepresentableRegistration)
        #expect(launch.initialInput.utf8.count <= SessionEntryResumeLaunch.maximumLegacyResumeInputBytes)
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
        SessionEntryResumeCoordinator().resume(entry, tabManager: manager)

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
    func remoteSelectionWithoutEntryCwdUsesLocalDefaultDirectory() throws {
        let remoteDirectory = "/tmp/vault-remote-inherited"
        let localDefaultDirectory = "/tmp/vault-local-default"
        let defaultsName = "cmux-vault-remote-cwd-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let settings = UserDefaultsSettingsClient(defaults: defaults)
        settings.set(true, for: SettingCatalog().app.workspaceInheritWorkingDirectory)
        let manager = TabManager(
            initialWorkingDirectory: remoteDirectory,
            autoWelcomeIfNeeded: false,
            settings: settings,
            defaultWorkspaceWorkingDirectoryProvider: { localDefaultDirectory }
        )
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let remoteWorkspace = try #require(manager.selectedWorkspace)
        remoteWorkspace.remoteConfiguration = WorkspaceRemoteConfiguration(
            destination: "vault-review.example.com",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: "ssh vault-review.example.com"
        )

        let entry = Self.entry(for: "codex", cwd: nil)
        #expect(SessionEntryResumeCoordinator().resume(entry, tabManager: manager))

        let restoredWorkspace = try #require(manager.selectedWorkspace)
        #expect(restoredWorkspace !== remoteWorkspace)
        #expect(restoredWorkspace.currentDirectory == localDefaultDirectory)
        #expect(restoredWorkspace.focusedTerminalPanel?.requestedWorkingDirectory == localDefaultDirectory)
    }

    @Test(arguments: [false, true])
    func remoteDropWithoutStartupCommandFailsClosed(isSplit: Bool) throws {
        let workspace = Workspace(workingDirectory: "/tmp/vault-remote-drop", initialTerminalInput: nil)
        defer { workspace.teardownAllPanels() }
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        workspace.remoteConfiguration = WorkspaceRemoteConfiguration(
            destination: "vault-drop.example.com",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil
        )
        let baselinePanelIDs = Set(workspace.panels.keys)
        let destination: BonsplitController.ExternalTabDropRequest.Destination = isSplit
            ? .split(targetPane: paneID, orientation: .horizontal, insertFirst: false)
            : .insert(targetPane: paneID, targetIndex: 0)

        #expect(!workspace.handleSessionDrop(
            entry: Self.entry(for: "codex", cwd: "/tmp/vault-remote-drop"),
            destination: destination
        ))
        #expect(Set(workspace.panels.keys) == baselinePanelIDs)
    }

    @Test
    func remoteVaultDirectoryUpdateBypassesLiveReportTrustGate() throws {
        let workspace = Workspace(workingDirectory: "/tmp/vault-remote-directory")
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        workspace.trackRemoteTerminalSurface(panelID)

        #expect(!workspace.updatePanelDirectory(panelId: panelID, directory: "/remote/project"))
        #expect(workspace.updateRemotePanelDirectory(panelId: panelID, directory: "/remote/project"))
        #expect(workspace.panelDirectories[panelID] == "/remote/project")
    }

    @Test
    func remoteVaultDropRecordsTheEntryWorkingDirectory() throws {
        let workspace = Workspace(workingDirectory: "/tmp/vault-remote-drop")
        defer { workspace.teardownAllPanels() }
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        workspace.remoteConfiguration = WorkspaceRemoteConfiguration(
            destination: "vault-drop.example.com",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64_089,
            relayID: "vault-remote-drop",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: "/tmp/vault-remote-drop.sock",
            terminalStartupCommand: "ssh vault-drop.example.com"
        )
        let baselinePanelIDs = Set(workspace.panels.keys)
        let entry = Self.entry(for: "codex", cwd: "/remote/project")

        #expect(workspace.handleSessionDrop(
            entry: entry,
            destination: .insert(targetPane: paneID, targetIndex: nil)
        ))
        let createdPanelID = try #require(workspace.panels.keys.first {
            !baselinePanelIDs.contains($0)
        })
        #expect(workspace.panelDirectories[createdPanelID] == "/remote/project")
        #expect(workspace.restoredAgentSnapshotsByPanelId[createdPanelID]?.workingDirectory == "/remote/project")
        #expect(workspace.remoteDirectoryTrustRequiredPanelIds.contains(createdPanelID))
        #expect(!workspace.remoteDirectoryReportPanelIds.contains(createdPanelID))
        #expect(workspace.reportedPanelDirectory(panelId: createdPanelID) == nil)
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
            destination: .insert(targetPane: paneID, targetIndex: 0)
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
    func localPaneDropPreservesTheRequestedTabIndex() throws {
        let manager = TabManager(
            initialWorkingDirectory: "/tmp/vault-drop-index",
            autoWelcomeIfNeeded: false
        )
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(manager.selectedWorkspace)
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        _ = try #require(workspace.newTerminalSurface(inPane: paneID, focus: true))
        let baselinePanelIDs = Set(workspace.panels.keys)

        let handled = workspace.handleSessionDrop(
            entry: Self.entry(for: "codex", cwd: "/tmp/vault-drop-index"),
            destination: .insert(targetPane: paneID, targetIndex: 0)
        )

        #expect(handled)
        let droppedPanelID = try #require(workspace.panels.keys.first {
            !baselinePanelIDs.contains($0)
        })
        let orderedPanelIDs = workspace.bonsplitController.tabs(inPane: paneID).compactMap {
            workspace.panelIdFromSurfaceId($0.id)
        }
        #expect(orderedPanelIDs.first == droppedPanelID)
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
        #expect(launch.legacyFallbackReason == .unrepresentableRegistration)
        #expect(
            launch.startupInput(for: .remoteHost)
                == (entry.copyResumeCommand ?? "") + "\n"
        )
    }

    private static func entry(for rawKind: String, cwd: String? = "/tmp/vault-project") -> SessionEntry {
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
