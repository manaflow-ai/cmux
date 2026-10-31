import AppKit
import CMUXAgentLaunch
import CmuxCommandPalette
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The terminal menu and the command palette offer the same accounts: every registered one,
/// the pane's current account checked and never pickable, and nothing at all until the user
/// registers a second account.
@MainActor
struct ClaudeAccountSwitchMenuModelTests {
    private let home = "/Users/cmux-test"
    private let configKey = "CLAUDE_CONFIG_DIR"

    @Test
    func onlyTheDefaultAccountOffersNoSwitch() {
        let registry = ClaudeAccountRegistry(declarations: [], homeDirectory: home)

        let model = ClaudeAccountSwitchMenuModel(
            registry: registry,
            current: registry.account(forEnvironment: nil)
        )

        #expect(model == nil)
    }

    @Test
    func listsEveryRegisteredAccountWithTheCurrentOneMarked() throws {
        let registry = workAndAltRegistry()

        let model = try #require(ClaudeAccountSwitchMenuModel(
            registry: registry,
            current: registry.account(forEnvironment: [configKey: "\(home)/.claude-work"])
        ))

        #expect(model.entries == [
            .init(accountName: "default", isCurrent: false),
            .init(accountName: "work", isCurrent: true),
            .init(accountName: "alt", isCurrent: false),
        ])
        #expect(model.switchTargetNames == ["default", "alt"])
    }

    @Test
    func defaultAccountIsCurrentWhenNoConfigDirectoryIsSet() throws {
        let registry = workAndAltRegistry()

        let model = try #require(ClaudeAccountSwitchMenuModel(
            registry: registry,
            current: registry.account(forEnvironment: [:])
        ))

        #expect(model.entries.map(\.isCurrent) == [true, false, false])
        #expect(model.switchTargetNames == ["work", "alt"])
    }

    @Test
    func unregisteredCurrentAccountComesFirstAndCannotBePicked() throws {
        let registry = workAndAltRegistry()
        let current = registry.account(forEnvironment: [configKey: "\(home)/.claude-scratch"])
        #expect(!current.isRegistered)

        let model = try #require(ClaudeAccountSwitchMenuModel(registry: registry, current: current))

        #expect(model.entries == [
            .init(accountName: current.name, isCurrent: true),
            .init(accountName: "default", isCurrent: false),
            .init(accountName: "work", isCurrent: false),
            .init(accountName: "alt", isCurrent: false),
        ])
        #expect(model.switchTargetNames == ["default", "work", "alt"])
    }

    @Test
    func menuChecksAndDisablesTheCurrentAccountAndSendsTheOthersByName() throws {
        let registry = workAndAltRegistry()
        let model = try #require(ClaudeAccountSwitchMenuModel(
            registry: registry,
            current: registry.account(forEnvironment: [configKey: "\(home)/.claude-work"])
        ))
        let target = NSObject()

        let item = GhosttyNSView.makeSwitchClaudeAccountMenuItem(for: model, target: target)

        #expect(item.title == String(
            localized: "terminalContextMenu.switchClaudeAccount",
            defaultValue: "Switch Claude Account"
        ))
        let rows = try #require(item.submenu?.items)
        #expect(rows.map(\.title) == ["default", "work", "alt"])
        #expect(rows.map(\.state) == [.off, .on, .off])
        #expect(rows.map(\.isEnabled) == [true, false, true])
        let pickable = rows.filter(\.isEnabled)
        #expect(pickable.map { $0.representedObject as? String } == ["default", "alt"])
        #expect(pickable.allSatisfy {
            $0.action == #selector(GhosttyNSView.switchClaudeAccountFromContextMenu(_:)) && $0.target === target
        })
    }

    @Test
    func paletteOffersOneCommandPerSwitchTargetOnClaudeTerminalsOnly() throws {
        let contributions = ContentView.claudeAccountSwitchCommandContributions(
            targetNames: ["default", "alt"],
            subtitle: { _ in "" }
        )
        var claudeTerminal = CommandPaletteContextSnapshot()
        claudeTerminal.setBool(CommandPaletteContextKeys.panelIsTerminal, true)
        claudeTerminal.setBool(CommandPaletteContextKeys.panelHasClaudeAgent, true)
        var plainTerminal = CommandPaletteContextSnapshot()
        plainTerminal.setBool(CommandPaletteContextKeys.panelIsTerminal, true)
        plainTerminal.setBool(CommandPaletteContextKeys.panelHasClaudeAgent, false)

        #expect(contributions.map(\.commandId) == [
            "palette.switchClaudeAccount.default",
            "palette.switchClaudeAccount.alt",
        ])
        #expect(contributions.allSatisfy { $0.when(claudeTerminal) })
        #expect(contributions.allSatisfy { !$0.when(plainTerminal) })
        let altTitle = try #require(contributions.last).title(claudeTerminal)
        #expect(altTitle.contains("alt"))
    }

    @Test
    func everyPaletteCommandHasAHandlerFromTheSameTargetList() throws {
        let targetNames = ["default", "alt"]
        var registry = CommandPaletteHandlerRegistry()
        var switchedTo: [String] = []
        ContentView.registerClaudeAccountSwitchHandlers(&registry, targetNames: targetNames) {
            switchedTo.append($0)
        }

        let contributions = ContentView.claudeAccountSwitchCommandContributions(
            targetNames: targetNames,
            subtitle: { _ in "" }
        )

        #expect(contributions.count == targetNames.count)
        for contribution in contributions {
            let handler = try #require(registry.handler(for: contribution.commandId))
            handler()
        }
        #expect(switchedTo == targetNames)
    }

    @Test
    func paneWithoutClaudeOffersNoSwitch() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)

        #expect(!workspace.hasClaudeAgent(panelId: panelId))
        #expect(workspace.claudeAccountSwitchMenuModel(panelId: panelId) == nil)
    }

    @Test
    func paneWithClaudeReportsItsAgentWithoutTheRegistry() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setRestoredAgentSnapshotForTesting(
            SessionRestorableAgentSnapshot(
                kind: .claude,
                sessionId: "a22293b7-bcef-4707-8439-2f538c8517a4",
                workingDirectory: "/tmp/claude-account-menu",
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: "claude",
                    executablePath: "/opt/homebrew/bin/claude",
                    arguments: ["/opt/homebrew/bin/claude"],
                    workingDirectory: "/tmp/claude-account-menu",
                    environment: nil,
                    capturedAt: 123,
                    source: "process"
                )
            ),
            panelId: panelId
        )

        #expect(workspace.hasClaudeAgent(panelId: panelId))
    }

    private func workAndAltRegistry() -> ClaudeAccountRegistry {
        ClaudeAccountRegistry(
            declarations: [
                ClaudeAccountDeclaration(name: "work", configDir: "~/.claude-work"),
                ClaudeAccountDeclaration(name: "alt", configDir: "~/.claude-alt"),
            ],
            homeDirectory: home
        )
    }
}
