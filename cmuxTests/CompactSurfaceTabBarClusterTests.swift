import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The compact pane tab bar cluster shown when cmux.json sets no surface tab
/// bar buttons: which buttons each pane kind shows, what "+" and the split
/// button do, and which rows each menu lists.
@Suite struct CompactSurfaceTabBarClusterTests {
    private typealias Cluster = CompactSurfaceTabBarCluster

    private let everything = CompactSurfaceTabBarCluster.Availability(agentChat: true, browser: true, files: true)

    @Test func standardPanesShowPlusSplitAndMore() {
        #expect(Cluster.buttonIDs(for: .standard) == [Cluster.addButtonID, Cluster.splitButtonID, Cluster.moreButtonID])
    }

    @Test func agentChatPanesDropTheSplitButton() {
        #expect(Cluster.buttonIDs(for: .agentChat) == [Cluster.addButtonID, Cluster.moreButtonID])
    }

    @Test func neverMoreThanThreeButtons() {
        for content in [Cluster.PaneContent.standard, .agentChat] {
            #expect(Cluster.bonsplitButtons(for: content, availability: everything).count <= 3)
        }
    }

    @Test func plusClickCreatesAgentChatWhenAvailableElseTerminal() {
        #expect(Cluster.addClickItem(availability: everything) == .agentChat)
        let noAgentChat = Cluster.Availability(agentChat: false, browser: true)
        #expect(Cluster.addClickItem(availability: noAgentChat) == .terminal)
    }

    @Test func plusButtonHasSecondaryMenuAndKeepsDoubleClickTerminal() throws {
        let buttons = Cluster.bonsplitButtons(for: .standard, availability: everything)
        let add = try #require(buttons.first { $0.id == Cluster.addButtonID })
        #expect(add.icon == .systemImage("plus"))
        #expect(add.menuBehavior == .secondary)
        #expect(add.action == .custom(Cluster.addButtonID))
        #expect(add.offersNewTerminal)
    }

    @Test func splitButtonClicksRightAndOptionClicksDown() throws {
        let buttons = Cluster.bonsplitButtons(for: .standard, availability: everything)
        let split = try #require(buttons.first { $0.id == Cluster.splitButtonID })
        #expect(split.icon == .systemImage("square.split.2x1"))
        #expect(split.resolvedAction(optionKeyHeld: false) == .splitRight)
        #expect(split.resolvedAction(optionKeyHeld: true) == .splitDown)
        #expect(split.menuBehavior == .secondary)
    }

    @Test func remoteTmuxMirrorShowsBothSplitsWithoutMenus() {
        let buttons = Cluster.bonsplitButtons(for: .standard, availability: everything)
            .filter { $0.action == .splitRight || $0.action == .splitDown }
            .flatMap(BonsplitConfiguration.remoteTmuxEmbeddedSplitButtons)
        #expect(buttons.map(\.action) == [.splitRight, .splitDown])
        #expect(buttons.map(\.icon) == [.systemImage("square.split.2x1"), .systemImage("square.split.1x2")])
        #expect(buttons.allSatisfy { $0.menuBehavior == .none && $0.alternateAction == nil })
        #expect(Set(buttons.map(\.id)).count == 2)
    }

    @Test func moreButtonOpensMenuOnClick() throws {
        let buttons = Cluster.bonsplitButtons(for: .standard, availability: everything)
        let more = try #require(buttons.first { $0.id == Cluster.moreButtonID })
        #expect(more.icon == .systemImage("ellipsis"))
        #expect(more.menuBehavior == .primary)
    }

    @Test func plusMenuListsAgentChatFirstThenTerminalAndBrowser() {
        #expect(
            Cluster.menuItems(forButton: Cluster.addButtonID, content: .standard, availability: everything)
                == [.agentChat, .terminal, .browser]
        )
    }

    @Test func plusMenuHidesUnavailableKinds() {
        let terminalOnly = Cluster.Availability(agentChat: false, browser: false)
        #expect(
            Cluster.menuItems(forButton: Cluster.addButtonID, content: .standard, availability: terminalOnly)
                == [.terminal]
        )
    }

    @Test func splitMenuListsBothDirections() {
        #expect(
            Cluster.menuItems(forButton: Cluster.splitButtonID, content: .standard, availability: everything)
                == [.splitRight, .splitDown]
        )
    }

    @Test func moreMenuMovesSplitsInForAgentChatPanes() {
        #expect(
            Cluster.menuItems(forButton: Cluster.moreButtonID, content: .standard, availability: everything)
                == [.files, .openFolder, .newWindow]
        )
        #expect(
            Cluster.menuItems(forButton: Cluster.moreButtonID, content: .agentChat, availability: everything)
                == [.splitRight, .splitDown, .separator, .files, .openFolder, .newWindow]
        )
    }

    @Test func unknownButtonsHaveNoMenu() {
        #expect(Cluster.menuItems(forButton: "cmux.newTerminal", content: .standard, availability: everything) == nil)
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
