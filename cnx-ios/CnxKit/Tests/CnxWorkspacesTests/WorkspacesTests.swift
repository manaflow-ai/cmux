import CnxModel
import Foundation
import Testing
@testable import CnxWorkspaces

@Suite struct RelativeStampTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func compactUnits() {
        let stamp = RelativeStamp(now: now)
        #expect(stamp.string(for: now.addingTimeInterval(-20)) == "now")
        #expect(stamp.string(for: now.addingTimeInterval(-4 * 60)) == "4m")
        #expect(stamp.string(for: now.addingTimeInterval(-3 * 3600)) == "3h")
        #expect(stamp.string(for: now.addingTimeInterval(-2 * 86_400)) == "2d")
    }

    @Test func presenceLine() {
        let stamp = RelativeStamp(now: now)
        #expect(stamp.presence(isOnline: true, lastSeenAt: nil) == "Online")
        #expect(stamp.presence(isOnline: false, lastSeenAt: now.addingTimeInterval(-7200)) == "Last seen 2h ago")
        #expect(stamp.presence(isOnline: false, lastSeenAt: nil) == "Offline")
    }
}

@Suite struct WorkspaceSortTests {
    @Test func recentThenName() {
        let now = Date()
        let a = Workspace(id: "a", macID: "m", title: "zeta", directory: "~", tabs: [], lastActivityAt: now)
        let b = Workspace(id: "b", macID: "m", title: "alpha", directory: "~", tabs: [], lastActivityAt: now.addingTimeInterval(-60))
        #expect(WorkspaceSort.recent.ordered([b, a]).map(\.id) == ["a", "b"])
        #expect(WorkspaceSort.name.ordered([a, b]).map(\.id) == ["b", "a"])
    }
}

#if os(iOS)
import CmuxTabsKit
import SwiftUI

@MainActor @Suite struct WorkspaceTabsSourceTests {
    func make(_ memory: [String: String] = [:]) -> (AppStore, WorkspaceTabsSource) {
        let store = AppStore.mock(tabMemory: .inMemory(memory))
        return (store, WorkspaceTabsSource(store: store, workspaceID: "ws-cmux"))
    }

    @Test func opensOnTheLastTabUsedOnThisDevice() {
        let (_, source) = make(["ws-cmux": "t-docs"])
        #expect(source.activeTabID == "t-docs")
        let (_, fresh) = make()
        #expect(fresh.activeTabID == "t-claude")
    }

    @Test func everyActivationIsRemembered() {
        let (store, source) = make()
        source.activate("t-zsh")
        #expect(store.lastTabByWorkspace["ws-cmux"] == "t-zsh")
        // Reopening the workspace starts there.
        #expect(WorkspaceTabsSource(store: store, workspaceID: "ws-cmux").activeTabID == "t-zsh")
    }

    @Test func closingTheActiveTabActivatesItsNeighbor() {
        let (store, source) = make()
        source.activate("t-zsh")
        source.close("t-zsh")
        #expect(source.activeTabID == "t-docs")
        #expect(store.lastTabByWorkspace["ws-cmux"] == "t-docs")
        #expect(source.tabs.map(\.id) == ["t-claude", "t-docs"])
    }

    @Test func newTabsGoLastAndBecomeActive() async {
        let (store, source) = make()
        let option = source.newTabOptions.first { $0.id == "terminal" }!
        let id = await source.createTab(option)
        #expect(source.tabs.last?.id == id)
        #expect(source.activeTabID == id)
        #expect(store.lastTabByWorkspace["ws-cmux"] == id)
    }

    @Test func tabsMapToTabsKitChrome() {
        let (_, source) = make()
        let tabs = Dictionary(uniqueKeysWithValues: source.tabs.map { ($0.id, $0) })
        #expect(tabs["t-claude"]?.kind == TabsKitTabKind("agent"))
        #expect(tabs["t-claude"]?.features == [.history, .pageMenu])
        // No page history: back leaves the workspace, so it is enabled.
        #expect(tabs["t-claude"]?.navigation.canGoBack == true)
        #expect(tabs["t-zsh"]?.kind == .terminal)
        #expect(tabs["t-zsh"]?.statusBarStyle == .lightContent)
        #expect(tabs["t-docs"]?.kind == .web)
        #expect(tabs["t-docs"]?.features == .web)
        if case .url(let display, _, _)? = tabs["t-docs"]?.address {
            #expect(display == "developer.apple.com")
        } else {
            Issue.record("browser tab should show its host")
        }
    }

    @Test func backLeavesTheWorkspaceWithoutPageHistory() {
        let (_, source) = make()
        var left = 0
        source.exit = { left += 1 }
        source.goBack("t-claude")
        source.goBack("t-docs")
        #expect(left == 2)
    }
}
/// A terminal content that adds its own page menu actions and records grid prep.
@MainActor final class RecordingTerminalContent: TerminalTabContent {
    var prepared: [String] = []
    var performed: [String] = []

    func page(for tab: WorkspaceTab, in workspace: Workspace, context: TerminalTabContext) -> AnyView { AnyView(EmptyView()) }
    func card(for tab: WorkspaceTab, in workspace: Workspace) -> AnyView { AnyView(EmptyView()) }
    func overviewWillAppear(active tab: WorkspaceTab) { prepared.append(tab.id) }
    func actions(for tab: WorkspaceTab, in workspace: Workspace) -> [TerminalTabAction] {
        [TerminalTabAction(title: "Show Keyboard", systemImage: "keyboard") { self.performed.append("keyboard") },
         TerminalTabAction(title: "Files and Links", systemImage: "folder") { self.performed.append("files") }]
    }
}

@MainActor @Suite struct TerminalTabEmbeddingTests {
    @Test func terminalActionsLeadThePageMenu() throws {
        let content = RecordingTerminalContent()
        let store = AppStore.mock(tabMemory: .inMemory(["ws-cmux": "t-zsh"]))
        let source = WorkspaceTabsSource(store: store, workspaceID: "ws-cmux", terminal: content)
        let kit = try #require(source.tabs.first { $0.id == "t-zsh" })
        let groups = source.pageMenu(for: kit)
        #expect(groups.first?.map(\.title) == ["Show Keyboard", "Files and Links"])
        #expect(groups.dropFirst().first?.map(\.title) == ["Copy Directory", "All Workspaces"])
        #expect(groups.last?.map(\.title) == ["Close Tab"])
        groups.first?.last?.action()
        #expect(content.performed == ["files"])
    }

    @Test func gridOpeningPreparesTheActiveTerminalCard() {
        let content = RecordingTerminalContent()
        let store = AppStore.mock(tabMemory: .inMemory(["ws-cmux": "t-zsh"]))
        let source = WorkspaceTabsSource(store: store, workspaceID: "ws-cmux", terminal: content)
        source.overviewWillAppear()
        source.activate("t-claude")
        source.overviewWillAppear()
        #expect(content.prepared == ["t-zsh"])
    }
}
#endif
