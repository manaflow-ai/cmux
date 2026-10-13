#if os(iOS)
import CmuxTabsKit
import CnxAgentChat
import CnxDesign
import CnxModel
import Observation
import SwiftUI
import UIKit

/// Drives one workspace's `TabsView`: the workspace's tabs (agent chats,
/// terminals, browsers) as TabsKit tabs, with the last tab used on this
/// device active when the workspace opens. Every activation is remembered
/// (`AppStore.noteOpened`), so the next open (or the next launch) starts there.
@MainActor
@Observable
public final class WorkspaceTabsSource: TabsDataSource {
    public let workspaceID: String
    public private(set) var activeTabID: String?
    @ObservationIgnored let store: AppStore
    @ObservationIgnored let terminal: any TerminalTabContent
    @ObservationIgnored let sessions: AgentSessionDirectory
    /// Leaves the workspace (back to the list).
    @ObservationIgnored public var exit: @MainActor () -> Void = {}
    @ObservationIgnored private var surfaces: [String: AgentChatSurface] = [:]
    /// Created with their tabs (never during a view update); each model is
    /// itself observable, so toolbar state follows the page.
    @ObservationIgnored private var browsers: [String: BrowserTabModel] = [:]
    /// The chrome insets the pages were last laid out with, for cards.
    @ObservationIgnored private var lastInsets = EdgeInsets(top: 62, leading: 0, bottom: 98, trailing: 0)
    @ObservationIgnored var pageHeight: CGFloat = 874

    public init(store: AppStore, workspaceID: String, terminal: any TerminalTabContent = PlaceholderTerminalTabContent(),
                sessions: AgentSessionDirectory = .shared) {
        self.store = store
        self.workspaceID = workspaceID
        self.terminal = terminal
        self.sessions = sessions
        if let workspace = store.workspace(id: workspaceID), let tab = store.openingTab(for: workspace) {
            activeTabID = tab.id
            store.noteOpened(tabID: tab.id, in: workspaceID)
        }
        for tab in store.workspace(id: workspaceID)?.tabs ?? [] where tab.kind == .browser {
            browsers[tab.id] = BrowserTabModel(url: tab.url)
        }
    }

    public var workspace: Workspace? { store.workspace(id: workspaceID) }

    private var macName: String {
        guard let macID = workspace?.macID else { return "Mac" }
        return store.teams.flatMap(\.macs).first { $0.id == macID }?.name ?? "Mac"
    }

    private func workspaceTab(_ id: String) -> WorkspaceTab? {
        workspace?.tabs.first { $0.id == id }
    }

    // MARK: Tabs

    public var tabs: [TabsKitTab] {
        guard let workspace else { return [] }
        return workspace.tabs.map { kitTab($0, in: workspace) }
    }

    public let newTabOptions = [
        TabsKitNewTabOption(id: "claude", title: "New Claude Chat", systemImage: "sparkle", kind: TabsKitTabKind("agent")),
        TabsKitNewTabOption(id: "codex", title: "New Codex Chat", systemImage: "sparkle", kind: TabsKitTabKind("agent")),
        TabsKitNewTabOption(id: "terminal", title: "New Terminal", systemImage: "apple.terminal", kind: .terminal),
        TabsKitNewTabOption(id: "browser", title: "New Browser Tab", systemImage: "globe", kind: .web),
    ]

    func kitTab(_ tab: WorkspaceTab, in workspace: Workspace) -> TabsKitTab {
        switch tab.kind {
        case .agent:
            let session = tab.subtitle ?? tab.title
            return TabsKitTab(
                id: tab.id, kind: TabsKitTabKind("agent"), title: session, subtitle: "\(tab.title) · \(workspace.title)",
                systemImage: "sparkle",
                address: .title(session, subtitle: "\(tab.title) · \(workspace.title)"),
                // Back leaves the workspace: the tab has no history of its own.
                navigation: TabsKitNavigationState(canGoBack: true),
                features: [.history, .pageMenu]
            )
        case .terminal:
            return TabsKitTab(
                id: tab.id, kind: .terminal, title: tab.title, subtitle: tab.subtitle ?? workspace.directory,
                systemImage: "apple.terminal",
                address: .title(tab.title, subtitle: tab.subtitle ?? workspace.directory, monospaced: true),
                navigation: TabsKitNavigationState(canGoBack: true),
                features: [.history, .pageMenu],
                statusBarStyle: .lightContent
            )
        case .browser:
            let model = browsers[tab.id]
            let url = model?.url ?? tab.url
            let host = model?.host ?? url?.host() ?? tab.subtitle ?? ""
            return TabsKitTab(
                id: tab.id, kind: .web, title: (model?.title).flatMap { $0.isEmpty ? nil : $0 } ?? tab.title,
                subtitle: host, systemImage: "globe",
                address: url == nil ? .placeholder("Search or enter website") : .url(display: host, editingText: url?.absoluteString ?? ""),
                // Back walks the page history first, then leaves the workspace.
                navigation: TabsKitNavigationState(canGoBack: true, canGoForward: model?.canGoForward ?? false,
                                                   isLoading: model?.isLoading ?? false, progress: model?.progress ?? 1),
                features: .web
            )
        }
    }

    public func activate(_ id: TabsKitTab.ID) {
        guard workspaceTab(id) != nil else { return }
        activeTabID = id
        store.noteOpened(tabID: id, in: workspaceID)
        CnxTheme.standard.haptics.selection()
    }

    public func close(_ id: TabsKitTab.ID) {
        let next = store.removeTab(id, from: workspaceID)
        surfaces[id] = nil
        browsers[id] = nil
        if activeTabID == id || workspaceTab(activeTabID ?? "") == nil {
            activeTabID = next?.id
            if let next { store.noteOpened(tabID: next.id, in: workspaceID) }
        }
    }

    public func createTab(_ option: TabsKitNewTabOption) async -> TabsKitTab.ID? {
        let id = "t-\(UUID().uuidString.prefix(8).lowercased())"
        let tab: WorkspaceTab
        switch option.id {
        case "claude": tab = WorkspaceTab(id: id, kind: .agent, title: "Claude", subtitle: "New session", harness: "claude")
        case "codex": tab = WorkspaceTab(id: id, kind: .agent, title: "Codex", subtitle: "New session", harness: "codex")
        case "browser": tab = WorkspaceTab(id: id, kind: .browser, title: "New Tab")
        default: tab = WorkspaceTab(id: id, kind: .terminal, title: "zsh", subtitle: workspace?.directory)
        }
        if tab.kind == .browser { browsers[id] = BrowserTabModel(url: nil) }
        store.appendTab(tab, to: workspaceID)
        activate(id)
        return id
    }

    // MARK: Per-tab state

    func surface(_ id: String) -> AgentChatSurface {
        if let surface = surfaces[id] { return surface }
        let surface = AgentChatSurface()
        surfaces[id] = surface
        return surface
    }

    func chatStore(_ tab: WorkspaceTab, _ workspace: Workspace) -> AgentChatStore {
        sessions.store(workspace: workspace, tab: tab, macName: macName)
    }

    func browser(_ tab: WorkspaceTab) -> BrowserTabModel {
        if let model = browsers[tab.id] { return model }
        let model = BrowserTabModel(url: tab.url)
        browsers[tab.id] = model
        return model
    }

    // MARK: Content

    public func content(for kit: TabsKitTab, context: TabsKitContentContext) -> some View {
        WorkspaceTabPage(source: self, tabID: kit.id, context: context)
    }

    public func card(for kit: TabsKitTab) -> some View {
        WorkspaceTabCard(source: self, tabID: kit.id, insets: lastInsets)
    }

    public func accessory(for kit: TabsKitTab, context: TabsKitContentContext) -> some View {
        WorkspaceTabAccessory(source: self, tabID: kit.id, context: context)
    }

    func remember(_ insets: EdgeInsets, pageHeight: CGFloat) {
        if insets != lastInsets { lastInsets = insets }
        self.pageHeight = pageHeight
    }

    public func overviewWillAppear() {
        if let id = activeTabID { browsers[id]?.takeSnapshot() }
    }

    // MARK: Toolbar actions

    public func goBack(_ id: TabsKitTab.ID) {
        if let model = browsers[id], model.canGoBack {
            model.goBack()
        } else {
            exit()
        }
    }

    public func goForward(_ id: TabsKitTab.ID) { browsers[id]?.goForward() }
    public func reloadOrStop(_ id: TabsKitTab.ID) { browsers[id]?.reloadOrStop() }

    public func navigate(_ id: TabsKitTab.ID, to text: String) {
        guard let tab = workspaceTab(id), tab.kind == .browser else { return }
        browser(tab).navigate(to: text)
    }

    public func pageMenu(for kit: TabsKitTab) -> [[TabsKitMenuItem]] {
        guard let workspace, let tab = workspaceTab(kit.id) else { return [] }
        let close = TabsKitMenuItem(title: "Close Tab", systemImage: "xmark", isDestructive: true) { [weak self] in self?.close(kit.id) }
        let leave = TabsKitMenuItem(title: "All Workspaces", systemImage: "square.stack.3d.up") { [weak self] in self?.exit() }
        switch tab.kind {
        case .agent:
            let store = chatStore(tab, workspace)
            let surface = surface(tab.id)
            return [
                [
                    TabsKitMenuItem(title: "Changes", systemImage: "plus.forwardslash.minus") { surface.openAllChanges(of: store) },
                    TabsKitMenuItem(title: "Copy Session ID", systemImage: "doc.on.doc") { UIPasteboard.general.string = store.summary.id },
                ],
                [leave],
                [
                    TabsKitMenuItem(title: "Stop Agent", systemImage: "stop.circle", isEnabled: store.isRunning, isDestructive: true) { store.cancel() },
                    close,
                ],
            ]
        case .terminal:
            return [
                [TabsKitMenuItem(title: "Copy Directory", systemImage: "doc.on.doc") { UIPasteboard.general.string = tab.subtitle ?? workspace.directory }],
                [leave],
                [close],
            ]
        case .browser:
            let model = browser(tab)
            return [
                [
                    TabsKitMenuItem(title: "Copy Link", systemImage: "link", isEnabled: model.url != nil) { UIPasteboard.general.url = model.url },
                    TabsKitMenuItem(title: "Reload", systemImage: "arrow.clockwise") { model.reloadOrStop() },
                ],
                [leave],
                [close],
            ]
        }
    }
}

/// A tab's live page, by kind.
struct WorkspaceTabPage: View {
    let source: WorkspaceTabsSource
    let tabID: String
    let context: TabsKitContentContext

    var body: some View {
        if let workspace = source.workspace, let tab = workspace.tabs.first(where: { $0.id == tabID }) {
            page(tab, workspace)
                .onAppear { source.remember(context.safeAreaInsets, pageHeight: context.pageSize.height) }
        }
    }

    @ViewBuilder
    private func page(_ tab: WorkspaceTab, _ workspace: Workspace) -> some View {
        let insets = context.safeAreaInsets
        switch tab.kind {
        case .agent:
            let surface = source.surface(tab.id)
            AgentChatTranscript(
                store: source.chatStore(tab, workspace), surface: surface,
                topInset: insets.top + 8,
                bottomInset: Self.bottomInset(surface: surface, insets: insets, pageHeight: context.pageSize.height),
                onUserScroll: { context.reportScroll(fingerDelta: $0) }
            )
            .background(Color.cnxBackground)
        case .terminal:
            source.terminal.page(for: tab, in: workspace, context: terminalContext)
        case .browser:
            BrowserPage(model: source.browser(tab), insets: insets, isZoomGestureActive: context.isZoomGestureActive,
                        reportScroll: { context.reportScroll(fingerDelta: $0) })
        }
    }

    /// Above the floating composer (which rides the toolbar or the keyboard).
    static func bottomInset(surface: AgentChatSurface, insets: EdgeInsets, pageHeight: CGFloat) -> CGFloat {
        guard let top = surface.bottomStackTop, top > 0, pageHeight > 0 else { return insets.bottom + 72 }
        return max(insets.bottom, pageHeight - top) + 12
    }

    private var terminalContext: TerminalTabContext {
        let context = context
        return TerminalTabContext(safeAreaInsets: context.safeAreaInsets, isInteractive: context.isInteractive,
                                  isZoomGestureActive: context.isZoomGestureActive,
                                  reportScroll: { context.reportScroll(fingerDelta: $0) })
    }
}

/// The row above the toolbar: the agent's composer (or permission bar), the
/// terminal's key bar. Browser tabs have none.
struct WorkspaceTabAccessory: View {
    let source: WorkspaceTabsSource
    let tabID: String
    let context: TabsKitContentContext

    var body: some View {
        if let workspace = source.workspace, let tab = workspace.tabs.first(where: { $0.id == tabID }) {
            switch tab.kind {
            case .agent:
                AgentChatBottomStack(store: source.chatStore(tab, workspace), surface: source.surface(tab.id))
            case .terminal:
                let context = context
                source.terminal.accessory(for: tab, in: workspace, context: TerminalTabContext(
                    safeAreaInsets: context.safeAreaInsets, isInteractive: context.isInteractive,
                    isZoomGestureActive: context.isZoomGestureActive, reportScroll: { context.reportScroll(fingerDelta: $0) }))
            case .browser:
                EmptyView()
            }
        }
    }
}

/// A tab's card in the grid: the page as it looks at rest.
struct WorkspaceTabCard: View {
    let source: WorkspaceTabsSource
    let tabID: String
    let insets: EdgeInsets

    var body: some View {
        if let workspace = source.workspace, let tab = workspace.tabs.first(where: { $0.id == tabID }) {
            switch tab.kind {
            case .agent:
                let surface = source.surface(tab.id)
                AgentChatPreview(store: source.chatStore(tab, workspace), topInset: insets.top + 8,
                                 bottomInset: WorkspaceTabPage.bottomInset(surface: surface, insets: insets, pageHeight: source.pageHeight))
            case .terminal:
                source.terminal.card(for: tab, in: workspace)
            case .browser:
                BrowserCard(model: source.browser(tab), insets: insets)
            }
        } else {
            Color.cnxBackground
        }
    }
}
#endif
