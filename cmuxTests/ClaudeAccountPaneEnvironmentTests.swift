import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A pane switched to another Claude account keeps that account across an app relaunch (spec D9):
/// its session snapshot carries the account keys, the restored shell gets them back even where the
/// workspace or the app environment sets `CLAUDE_CONFIG_DIR`, and the restored resume unsets the
/// keys the pane cleared so a shell rc that exports one again cannot move Claude back.
@MainActor
@Suite(.serialized)
struct ClaudeAccountPaneEnvironmentTests {
    private let configKey = "CLAUDE_CONFIG_DIR"
    private let secureStorageKey = "CLAUDE_SECURESTORAGE_CONFIG_DIR"
    private let sessionID = "5b0d1c52-6f0e-4d6c-9a43-3f9e2b8c7d11"

    /// What a switch to the default account leaves on a pane whose workspace sets no account key.
    private var defaultAccount: ClaudeAccountPaneEnvironment {
        ClaudeAccountPaneEnvironment(overrides: [:], removedKeys: [configKey, secureStorageKey])
    }

    // MARK: Snapshot

    @Test
    func snapshotRoundTripsTheAccountEnvironment() throws {
        var terminal = SessionTerminalPanelSnapshot(workingDirectory: "/tmp")
        terminal.claudeAccountEnvironment = ClaudeAccountPaneEnvironment(
            overrides: [configKey: "", secureStorageKey: ""],
            removedKeys: []
        )

        let decoded = try JSONDecoder().decode(
            SessionTerminalPanelSnapshot.self,
            from: JSONEncoder().encode(terminal)
        )

        #expect(decoded.claudeAccountEnvironment == terminal.claudeAccountEnvironment)
        #expect(decoded.claudeAccountEnvironment?.overrides[configKey] == "")
    }

    @Test
    func snapshotsWithoutTheFieldStillDecode() throws {
        let plain = SessionTerminalPanelSnapshot(workingDirectory: "/tmp")
        let encoded = try JSONEncoder().encode(plain)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(!json.contains("claudeAccountEnvironment"))

        // A snapshot written before the field existed.
        let legacy = Data(#"{"workingDirectory":"/tmp","scrollback":"x"}"#.utf8)
        let decoded = try JSONDecoder().decode(SessionTerminalPanelSnapshot.self, from: legacy)
        #expect(decoded.claudeAccountEnvironment == nil)
        #expect(decoded.workingDirectory == "/tmp")
    }

    /// Only the two account keys are ever kept or replayed. A snapshot naming anything else (by
    /// tampering, or a future writer) decodes and restores without it.
    @Test
    func decodingKeepsOnlyTheAccountKeys() throws {
        let json = #"""
            {"overrides":{"CLAUDE_CONFIG_DIR":"/Users/t/.claude-work","PROMPT_COMMAND":"touch /tmp/pwned"},
             "removedKeys":["BASH_ENV","CLAUDE_SECURESTORAGE_CONFIG_DIR"]}
            """#
        let account = try JSONDecoder().decode(ClaudeAccountPaneEnvironment.self, from: Data(json.utf8))

        #expect(account.overrides == [configKey: "/Users/t/.claude-work"])
        #expect(account.removedKeys == [secureStorageKey])
        #expect(account.clearedKeys == [secureStorageKey])
        // Older and partial records still decode.
        let empty = try JSONDecoder().decode(ClaudeAccountPaneEnvironment.self, from: Data("{}".utf8))
        #expect(empty.overrides.isEmpty && empty.removedKeys.isEmpty)
    }

    @Test
    func restoreNeverReplaysAKeyOtherThanTheAccountKeys() throws {
        let source = Workspace()
        defer { source.teardownAllPanels() }
        let sourcePanelID = try #require(source.focusedPanelId)
        var snapshot = source.sessionSnapshot(includeScrollback: false)
        let index = try #require(snapshot.panels.firstIndex { $0.id == sourcePanelID })
        snapshot.panels[index].terminal?.claudeAccountEnvironment = ClaudeAccountPaneEnvironment(
            overrides: [configKey: "/Users/t/.claude-work", "PROMPT_COMMAND": "touch /tmp/pwned"],
            removedKeys: ["BASH_ENV"]
        )
        snapshot = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot))

        let restored = Workspace()
        defer { restored.teardownAllPanels() }
        let restoredPanelID = try #require(restored.restoreSessionSnapshot(snapshot)[sourcePanelID])
        let panel = try #require(restored.terminalPanel(for: restoredPanelID))

        #expect(panel.surface.startupEnvironmentValue("PROMPT_COMMAND") == nil)
        #expect(panel.surface.startupEnvironmentValue(configKey) == "/Users/t/.claude-work")
        #expect(panel.claudeAccountEnvironment?.overrides.keys.sorted() == [configKey])
        #expect(panel.claudeAccountEnvironment?.removedKeys.isEmpty == true)
    }

    // MARK: Restored shell environment

    @Test
    func restoredSurfaceMasksOnlyInheritedClearedKeys() {
        let account = ClaudeAccountPaneEnvironment(
            overrides: [configKey: "/Users/t/.claude-work", secureStorageKey: ""],
            removedKeys: []
        )
        // A custom account: its directory, and the cleared key masked only where something
        // would otherwise supply it.
        #expect(ClaudeAccountSwitchSurfaceEnvironment(
            accountEnvironment: account.accountEnvironment,
            workspaceEnvironment: [:],
            processEnvironment: [:]
        ).overrides == [configKey: "/Users/t/.claude-work"])
        // The default account under a workspace that names another account: masked with "".
        #expect(ClaudeAccountSwitchSurfaceEnvironment(
            accountEnvironment: defaultAccount.accountEnvironment,
            workspaceEnvironment: [configKey: "/Users/t/.claude-work"],
            processEnvironment: [secureStorageKey: "/Users/t/.claude-work"]
        ).overrides == [configKey: "", secureStorageKey: ""])
    }

    @Test
    func relaunchedPaneKeepsTheDefaultAccountUnderAWorkspaceThatNamesAnother() throws {
        let workspaceEnvironment = [configKey: "/Users/t/.claude-work"]
        let source = Workspace(workspaceEnvironment: workspaceEnvironment)
        defer { source.teardownAllPanels() }
        let sourcePanelID = try #require(source.focusedPanelId)
        var snapshot = source.sessionSnapshot(includeScrollback: false)
        let index = try #require(snapshot.panels.firstIndex { $0.id == sourcePanelID })
        let account = ClaudeAccountPaneEnvironment(overrides: [configKey: ""], removedKeys: [secureStorageKey])
        snapshot.panels[index].terminal?.claudeAccountEnvironment = account
        snapshot = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot))

        let restored = Workspace(workspaceEnvironment: workspaceEnvironment)
        defer { restored.teardownAllPanels() }
        let restoredPanelID = try #require(restored.restoreSessionSnapshot(snapshot)[sourcePanelID])
        let panel = try #require(restored.terminalPanel(for: restoredPanelID))

        #expect(panel.surface.startupEnvironmentValue(configKey) == "")
        #expect(panel.claudeAccountEnvironment == account)
        // The next autosave writes it again, and a plain respawn keeps it.
        let resaved = restored.sessionSnapshot(includeScrollback: false)
        #expect(resaved.panels.first { $0.id == restoredPanelID }?.terminal?.claudeAccountEnvironment == account)
        let respawned = try #require(restored.respawnTerminalSurface(panelId: restoredPanelID, command: nil))
        #expect(respawned.surface.startupEnvironmentValue(configKey) == "")
        #expect(respawned.claudeAccountEnvironment == account)
    }

    @Test
    func paneWithoutAnAccountEnvironmentRestoresAsBefore() throws {
        let workspaceEnvironment = [configKey: "/Users/t/.claude-work"]
        let source = Workspace(workspaceEnvironment: workspaceEnvironment)
        defer { source.teardownAllPanels() }
        let sourcePanelID = try #require(source.focusedPanelId)
        let snapshot = source.sessionSnapshot(includeScrollback: false)
        #expect(snapshot.panels.first { $0.id == sourcePanelID }?.terminal?.claudeAccountEnvironment == nil)

        let restored = Workspace(workspaceEnvironment: workspaceEnvironment)
        defer { restored.teardownAllPanels() }
        let restoredPanelID = try #require(restored.restoreSessionSnapshot(snapshot)[sourcePanelID])
        let panel = try #require(restored.terminalPanel(for: restoredPanelID))

        #expect(panel.surface.startupEnvironmentValue(configKey) == "/Users/t/.claude-work")
        #expect(panel.claudeAccountEnvironment == nil)
    }

    // MARK: Restored resume

    @Test
    func restoreVerbUnsetsTheClearedKeys() {
        #expect(defaultAccount.restoreStartupInput(" cmux restore claude \(sessionID)\n")
            == " /usr/bin/env -u \(configKey) -u \(secureStorageKey) cmux restore claude \(sessionID)\n")
        #expect(defaultAccount.restoreStartupInput(" cmux restore --surface\n")
            == " /usr/bin/env -u \(configKey) -u \(secureStorageKey) cmux restore --surface\n")
        // Anything else, and a pane that clears nothing, is left alone.
        #expect(defaultAccount.restoreStartupInput("claude attach x\n") == "claude attach x\n")
        let custom = ClaudeAccountPaneEnvironment(overrides: [configKey: "/Users/t/.claude-work"], removedKeys: [])
        #expect(custom.restoreStartupInput(" cmux restore claude \(sessionID)\n") == " cmux restore claude \(sessionID)\n")
    }

    /// Waking a hibernated Claude types the same restore verb, so it unsets the cleared keys too.
    @Test
    func hibernationWakeResumesWithTheClearedKeysUnset() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panel = try #require(workspace.focusedPanelId.flatMap { workspace.terminalPanel(for: $0) })
        let agent = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: sessionID,
            workingDirectory: NSTemporaryDirectory(),
            launchCommand: nil
        )
        #expect(panel.agentHibernationResumeStartupInput(agent) == " cmux restore claude \(sessionID)\n")

        panel.claudeAccountEnvironment = defaultAccount

        #expect(panel.agentHibernationResumeStartupInput(agent)
            == " /usr/bin/env -u \(configKey) -u \(secureStorageKey) cmux restore claude \(sessionID)\n")
    }

    @Test
    func relaunchedClaudePaneResumesWithTheClearedKeysUnset() throws {
        let defaultsName = "cmux-claude-account-restore-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        defer { AgentResumeLaunchGuard.shared.releaseResumeLaunch(kind: "claude", sessionId: sessionID) }

        let source = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { source.teardownAllPanels() }
        let sourcePanelID = try #require(source.focusedPanelId)
        var snapshot = source.sessionSnapshot(includeScrollback: false)
        let index = try #require(snapshot.panels.firstIndex { $0.id == sourcePanelID })
        var terminal = try #require(snapshot.panels[index].terminal)
        terminal.workingDirectory = NSTemporaryDirectory()
        terminal.agent = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: sessionID,
            workingDirectory: NSTemporaryDirectory(),
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "claude",
                arguments: ["claude"],
                workingDirectory: NSTemporaryDirectory(),
                environment: [:],
                capturedAt: 1_791_158_107,
                source: "environment"
            )
        )
        terminal.wasAgentRunning = true
        terminal.claudeAccountEnvironment = defaultAccount
        snapshot.panels[index].terminal = terminal

        let restored = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { restored.teardownAllPanels() }
        let restoredPanelID = try #require(restored.restoreSessionSnapshot(snapshot)[sourcePanelID])
        let panel = try #require(restored.terminalPanel(for: restoredPanelID))

        #expect(panel.surface.debugInitialInputForTesting()
            == " /usr/bin/env -u \(configKey) -u \(secureStorageKey) cmux restore claude \(sessionID)\n")
    }
}
