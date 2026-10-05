import Bonsplit
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The opt-in compact pane tab bar cluster: which buttons each pane kind
/// shows, what "+" and the split button do, and which rows each menu lists.
/// The policy lives on `Workspace`.
@MainActor
@Suite struct CompactSurfaceTabBarClusterTests {
    private typealias Cluster = CompactSurfaceTabBarCluster

    private let workspace = Workspace(title: "Tests")
    private let everything = CompactSurfaceTabBarCluster.Availability(agentChat: true, browser: true, files: true)

    @Test func standardPanesShowPlusSplitAndMore() {
        #expect(workspace.compactSurfaceTabBarButtonIDs(for: .standard) == [Cluster.addButtonID, Cluster.splitButtonID, Cluster.moreButtonID])
    }

    @Test func agentChatPanesDropTheSplitButton() {
        #expect(workspace.compactSurfaceTabBarButtonIDs(for: .agentChat) == [Cluster.addButtonID, Cluster.moreButtonID])
    }

    @Test func showsAtMostFourSymbolsChosenByPaneKind() {
        let standard = workspace.compactSurfaceTabBarButtons(for: .standard, availability: everything)
        let agentChat = workspace.compactSurfaceTabBarButtons(for: .agentChat, availability: everything)
        #expect(standard.count <= 4)
        #expect(agentChat.count <= 4)
        #expect(standard.map(\.icon) == [.systemImage("plus"), .systemImage("square.split.2x1"), .systemImage("ellipsis")])
        #expect(agentChat.map(\.icon) == [.systemImage("plus"), .systemImage("ellipsis")])
    }

    @Test func plusClickOpensATerminalLikeCmdT() throws {
        #expect(workspace.compactSurfaceTabBarAddClickItem == .terminal)
        #expect(workspace.compactSurfaceTabBarAddClickItem.shortcutAction == CmuxSurfaceTabBarBuiltInAction.newTerminal.shortcutAction)
        let add = try #require(workspace.compactSurfaceTabBarButtons(for: .standard, availability: everything).first { $0.id == Cluster.addButtonID })
        #expect(add.tooltip == String(localized: "surfaceTabBar.compact.add.tooltip.terminal", defaultValue: "New Terminal"))
    }

    @Test func plusButtonHasSecondaryMenuAndKeepsDoubleClickTerminal() throws {
        let buttons = workspace.compactSurfaceTabBarButtons(for: .standard, availability: everything)
        let add = try #require(buttons.first { $0.id == Cluster.addButtonID })
        #expect(add.icon == .systemImage("plus"))
        #expect(add.menuBehavior == .secondary)
        #expect(add.action == .custom(Cluster.addButtonID))
        #expect(add.offersNewTerminal)
    }

    @Test func splitButtonClicksRightAndOptionClicksDown() throws {
        let buttons = workspace.compactSurfaceTabBarButtons(for: .standard, availability: everything)
        let split = try #require(buttons.first { $0.id == Cluster.splitButtonID })
        #expect(split.icon == .systemImage("square.split.2x1"))
        #expect(split.resolvedAction(optionKeyHeld: false) == .splitRight)
        #expect(split.resolvedAction(optionKeyHeld: true) == .splitDown)
        #expect(split.menuBehavior == .secondary)
    }

    @Test func remoteTmuxMirrorShowsBothSplitsWithoutMenus() {
        let buttons = workspace.compactSurfaceTabBarButtons(for: .standard, availability: everything)
            .filter { $0.action == .splitRight || $0.action == .splitDown }
            .flatMap(BonsplitConfiguration.remoteTmuxEmbeddedSplitButtons)
        #expect(buttons.map(\.action) == [.splitRight, .splitDown])
        #expect(buttons.map(\.icon) == [.systemImage("square.split.2x1"), .systemImage("square.split.1x2")])
        #expect(buttons.allSatisfy { $0.menuBehavior == .none && $0.alternateAction == nil })
        #expect(Set(buttons.map(\.id)).count == 2)
    }

    @Test func moreButtonOpensMenuOnClick() throws {
        let buttons = workspace.compactSurfaceTabBarButtons(for: .standard, availability: everything)
        let more = try #require(buttons.first { $0.id == Cluster.moreButtonID })
        #expect(more.icon == .systemImage("ellipsis"))
        #expect(more.menuBehavior == .primary)
    }

    @Test func plusMenuListsAgentChatFirstThenTerminalAndBrowser() {
        #expect(
            workspace.compactSurfaceTabBarMenuItems(forButton: Cluster.addButtonID, content: .standard, availability: everything)
                == [.agentChat, .terminal, .browser]
        )
    }

    @Test func plusMenuHidesUnavailableKinds() {
        let terminalOnly = Cluster.Availability(agentChat: false, browser: false)
        #expect(
            workspace.compactSurfaceTabBarMenuItems(forButton: Cluster.addButtonID, content: .standard, availability: terminalOnly)
                == [.terminal]
        )
    }

    @Test func splitMenuListsBothDirections() {
        #expect(
            workspace.compactSurfaceTabBarMenuItems(forButton: Cluster.splitButtonID, content: .standard, availability: everything)
                == [.splitRight, .splitDown]
        )
    }

    @Test func moreMenuMovesSplitsInForAgentChatPanes() {
        #expect(
            workspace.compactSurfaceTabBarMenuItems(forButton: Cluster.moreButtonID, content: .standard, availability: everything)
                == [.files, .openFolder, .newWindow]
        )
        #expect(
            workspace.compactSurfaceTabBarMenuItems(forButton: Cluster.moreButtonID, content: .agentChat, availability: everything)
                == [.splitRight, .splitDown, .separator, .files, .openFolder, .newWindow]
        )
    }

    @Test func unknownButtonsHaveNoMenu() {
        #expect(workspace.compactSurfaceTabBarMenuItems(forButton: "cmux.newTerminal", content: .standard, availability: everything) == nil)
    }

    @Test func menuRowsMapToExistingShortcuts() {
        #expect(Cluster.Item.terminal.shortcutAction == .newSurface)
        #expect(Cluster.Item.browser.shortcutAction == .openBrowser)
        #expect(Cluster.Item.splitRight.shortcutAction == .splitRight)
        #expect(Cluster.Item.splitDown.shortcutAction == .splitDown)
        #expect(Cluster.Item.files.shortcutAction == .switchRightSidebarToFiles)
        #expect(Cluster.Item.openFolder.shortcutAction == .openFolder)
        #expect(Cluster.Item.newWindow.shortcutAction == .newWindow)
        #expect(Cluster.Item.agentChat.shortcutAction == nil)
    }

    @Test func agentChatURLMatchesOwnedServerTokenPath() throws {
        let base = try #require(URL(string: "http://127.0.0.1:52011/abc123/"))
        #expect(Cluster.isAgentChatURL(URL(string: "http://127.0.0.1:52011/abc123/"), agentChatBaseURLs: [base]))
        #expect(Cluster.isAgentChatURL(
            URL(string: "http://localhost:52011/abc123/terminal/ID?transparent=1"),
            agentChatBaseURLs: [base]
        ))
        #expect(!Cluster.isAgentChatURL(URL(string: "http://127.0.0.1:52011/abc1234/"), agentChatBaseURLs: [base]))
        #expect(!Cluster.isAgentChatURL(URL(string: "http://127.0.0.1:52012/abc123/"), agentChatBaseURLs: [base]))
        #expect(!Cluster.isAgentChatURL(URL(string: "https://example.com/abc123/"), agentChatBaseURLs: [base]))
        #expect(!Cluster.isAgentChatURL(nil, agentChatBaseURLs: [base]))
    }

    @Test func agentChatURLMatchesConfiguredServerRoot() throws {
        let configured = try #require(URL(string: "http://127.0.0.1:7739"))
        #expect(Cluster.isAgentChatURL(URL(string: "http://127.0.0.1:7739/chat/1"), agentChatBaseURLs: [configured]))
        #expect(!Cluster.isAgentChatURL(URL(string: "http://127.0.0.1:3000/"), agentChatBaseURLs: [configured]))
    }
}

/// The `app.compactPaneTabBar` setting: off by default, the pane tab bar keeps
/// the 0.64.25 buttons; on, the compact cluster replaces them.
@MainActor
@Suite struct CompactPaneTabBarSettingTests {
    /// The 0.64.25 pane tab bar, in order.
    private static let baselineActions: [BonsplitConfiguration.SplitActionButton.Action] = [
        .newTerminal, .newBrowser, .splitRight, .splitDown
    ]

    private static let defaultButtons: [CmuxSurfaceTabBarButton] = [
        .builtIn(.newTerminal),
        .builtIn(.newBrowser),
        .builtIn(.splitRight),
        .builtIn(.splitDown)
    ]

    private func makeDefaults() throws -> UserDefaults {
        let suite = "CompactPaneTabBarSettingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func applyDefaultButtons(to workspace: Workspace) {
        workspace.applySurfaceTabBarButtons(
            Self.defaultButtons,
            sourcePath: nil,
            globalConfigPath: "/tmp/cmux-test-global-config.json",
            terminalCommandSourcePaths: [:],
            workspaceCommands: [:],
            allowsCompactCluster: true
        )
    }

    @Test func settingDefaultsOff() {
        #expect(AppCatalogSection().compactPaneTabBar.defaultValue == false)
        #expect(CmuxSurfaceTabBarButton.defaults.map(\.id) == Self.defaultButtons.map(\.id))
    }

    @Test func defaultOffShowsThe0_64_25Buttons() throws {
        let defaults = try makeDefaults()
        let workspace = Workspace(closeTabWarningDefaults: defaults)
        applyDefaultButtons(to: workspace)

        #expect(!workspace.surfaceTabBarUsesCompactCluster)
        let buttons = workspace.bonsplitController.configuration.appearance.splitButtons
        #expect(buttons.map(\.action) == Self.baselineActions)
        #expect(buttons.allSatisfy { $0.menuBehavior == .none && $0.alternateAction == nil && !$0.offersNewTerminal })
        for pane in workspace.bonsplitController.allPaneIds {
            #expect(workspace.bonsplitController.splitButtons(forPane: pane) == nil)
        }
    }

    @Test func turningItOnShowsAtMostFourSymbolsAndOffRestoresTheBaseline() throws {
        let defaults = try makeDefaults()
        let workspace = Workspace(closeTabWarningDefaults: defaults)
        applyDefaultButtons(to: workspace)

        defaults.set(true, forKey: AppCatalogSection().compactPaneTabBar.userDefaultsKey)
        workspace.refreshCompactPaneTabBarSetting()
        #expect(workspace.surfaceTabBarUsesCompactCluster)
        let compact = workspace.bonsplitController.configuration.appearance.splitButtons
        #expect(compact.count <= 4)
        #expect(compact.map(\.id) == workspace.compactSurfaceTabBarButtonIDs(for: .standard))

        defaults.set(false, forKey: AppCatalogSection().compactPaneTabBar.userDefaultsKey)
        workspace.refreshCompactPaneTabBarSetting()
        #expect(!workspace.surfaceTabBarUsesCompactCluster)
        #expect(workspace.bonsplitController.configuration.appearance.splitButtons.map(\.action) == Self.baselineActions)
    }

    @Test func configuredButtonsWinOverTheSetting() throws {
        let defaults = try makeDefaults()
        defaults.set(true, forKey: AppCatalogSection().compactPaneTabBar.userDefaultsKey)
        let workspace = Workspace(closeTabWarningDefaults: defaults)
        workspace.applySurfaceTabBarButtons(
            [.builtIn(.splitRight)],
            sourcePath: nil,
            globalConfigPath: "/tmp/cmux-test-global-config.json",
            terminalCommandSourcePaths: [:],
            workspaceCommands: [:],
            allowsCompactCluster: false
        )
        #expect(!workspace.surfaceTabBarUsesCompactCluster)
        #expect(workspace.bonsplitController.configuration.appearance.splitButtons.map(\.action) == [.splitRight])
    }
}
