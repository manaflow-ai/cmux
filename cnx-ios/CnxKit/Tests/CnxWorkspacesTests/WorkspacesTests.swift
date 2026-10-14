import CnxModel
import Foundation
import Observation
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

#if os(iOS)
import CmuxTabsKit
import SwiftUI

@MainActor @Suite struct WorkspaceTabsSourceTests {
    func make(_ memory: [String: String] = [:], backend: (any WorkspaceCreationBackend)? = MockWorkspaceCreationBackend(latency: .zero))
        -> (AppStore, WorkspaceTabsSource) {
        let store = AppStore.mock(tabMemory: .inMemory(memory))
        let creator = backend.map { WorkspaceCreator(store: store, backend: $0) }
        return (store, WorkspaceTabsSource(store: store, workspaceID: "ws-cmux", creator: creator))
    }

    @Test func closeTheMacRefusesPutsTheTabBack() async {
        let refusing = MockWorkspaceCreationBackend(latency: .zero)
        let (_, source) = make(backend: refusing)
        refusing.failNext = "tab is busy"
        source.close("t-zsh")
        #expect(!source.tabs.contains { $0.id == "t-zsh" })
        for _ in 0..<200 where !source.tabs.contains(where: { $0.id == "t-zsh" }) { await Task.yield() }
        #expect(source.tabs.map(\.id) == ["t-claude", "t-zsh", "t-docs"])
        #expect(source.notice?.contains("tab is busy") == true)
    }

    @Test func aRefusedNewTabAddsNothing() async {
        let refusing = MockWorkspaceCreationBackend(latency: .zero)
        let (_, source) = make(backend: refusing)
        refusing.failNext = "no pane"
        let id = await source.createTab(source.newTabOptions.first { $0.id == "terminal" }!)
        #expect(id == nil)
        #expect(source.tabs.count == 3)
        #expect(source.notice?.contains("no pane") == true)
    }

    @Test func withoutAMacNoTabsAreMade() async {
        let (_, source) = make(backend: nil)
        #expect(source.newTabOptions.isEmpty)
        let id = await source.createTab(TabsKitNewTabOption(id: "terminal", title: "New Terminal", systemImage: "apple.terminal", kind: .terminal))
        #expect(id == nil)
        #expect(source.tabs.count == 3)
        source.close("t-zsh")
        #expect(source.tabs.count == 3)
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
    var focused: [String] = []
    func focusInput(for tab: WorkspaceTab, in workspace: Workspace) { focused.append(tab.id) }
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

    /// Round 2: new chats and terminals open with the keyboard up; existing ones do not.
    @Test func newWorkspacesAndTabsOpenReadyToType() async throws {
        let content = RecordingTerminalContent()
        let store = AppStore.mock(tabMemory: .inMemory(["ws-cmux": "t-claude"]))
        // Opening an existing workspace leaves the keyboard down.
        let existing = WorkspaceTabsSource(store: store, workspaceID: "ws-cmux", terminal: content)
        existing.pageAppeared("t-claude")
        #expect(existing.surface("t-claude").composerFocused == false)
        // A workspace this phone just created opens focused (agent chat).
        store.requestFocusOnOpen("ws-cmux")
        let created = WorkspaceTabsSource(store: store, workspaceID: "ws-cmux", terminal: content,
                                          creator: WorkspaceCreator(store: store, backend: MockWorkspaceCreationBackend(latency: .zero)))
        created.pageAppeared("t-claude")
        #expect(created.surface("t-claude").composerFocused)
        // A new terminal tab raises the keyboard on its composer.
        let id = await created.createTab(try #require(created.newTabOptions.first { $0.id == "terminal" }))
        #expect(content.focused == [try #require(id)])
    }

    /// verify/e2e-matrix.md #4: the navigation destination builds a
    /// `WorkspaceScreen` on every update it re-runs; building one (and its
    /// source) must not write the store, or the update re-invalidates
    /// itself forever. The writes happen once, when the screen appears.
    @Test func buildingAWorkspaceScreenWritesNothing() throws {
        let content = RecordingTerminalContent()
        let store = AppStore.mock(tabMemory: .inMemory(["ws-cmux": "gone"]))
        store.requestFocusOnOpen("ws-cmux")
        let notified = ObservedChanges()
        withObservationTracking { Self.readAll(store) } onChange: { notified.count += 1 }
        var source: WorkspaceTabsSource?
        for _ in 0..<5 {
            _ = WorkspaceScreen(store: store, workspaceID: "ws-cmux", terminal: content)
            source = WorkspaceTabsSource(store: store, workspaceID: "ws-cmux", terminal: content)
        }
        #expect(notified.count == 0)
        let opened = try #require(source)
        #expect(opened.activeTabID == "t-claude")
        // Appearing remembers the tab and consumes the focus request, once.
        opened.opened()
        #expect(notified.count == 1)
        #expect(store.lastTabByWorkspace["ws-cmux"] == "t-claude")
        #expect(!store.wantsFocusOnOpen("ws-cmux"))
        opened.pageAppeared("t-claude")
        #expect(opened.surface("t-claude").composerFocused)
    }

    /// Runs like a SwiftUI destination update: again while an observation
    /// installed before the run saw a change.
    @Test func aDestinationUpdateSettles() {
        let content = RecordingTerminalContent()
        let store = AppStore.mock(tabMemory: .inMemory())
        var runs = 0
        let dirty = ObservedChanges()
        dirty.count = 1
        while dirty.count > 0, runs < 20 {
            dirty.count = 0
            runs += 1
            withObservationTracking { Self.readAll(store) } onChange: { dirty.count += 1 }
            _ = WorkspaceTabsSource(store: store, workspaceID: "ws-cmux", terminal: content).activeTabID
        }
        #expect(runs == 1)
    }

    final class ObservedChanges: @unchecked Sendable {
        var count = 0
    }

    static func readAll(_ store: AppStore) {
        _ = store.workspaces
        _ = store.lastTabByWorkspace
        _ = store.focusOnOpenWorkspaceIDs
        _ = store.workspaceAliases
        _ = store.pendingWorkspaceIDs
        _ = store.teams
        _ = store.seenAt
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
