#if os(iOS)
import CmuxTabsKit
import CnxAgentChat
import CnxBrowserStream
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
    /// The tab chosen on this screen. When it disappears (a new workspace
    /// whose placeholder tab became the Mac's real tab), the active tab
    /// falls back to the workspace's opening tab.
    private var selectedTabID: String?
    public var activeTabID: String? {
        guard let workspace else { return nil }
        if let selectedTabID, workspace.tabs.contains(where: { $0.id == selectedTabID }) { return selectedTabID }
        return store.openingTab(for: workspace)?.id
    }
    @ObservationIgnored let store: AppStore
    @ObservationIgnored let terminal: any TerminalTabContent
    @ObservationIgnored let sessions: AgentSessionDirectory
    /// Opens and closes tabs on the workspace's Mac (nil: nothing to open them on).
    @ObservationIgnored let creator: WorkspaceCreator?
    /// Leaves the workspace (back to the list).
    @ObservationIgnored public var exit: @MainActor () -> Void = {}
    @ObservationIgnored private var surfaces: [String: AgentChatSurface] = [:]
    /// Created with their tabs (never during a view update); each model is
    /// itself observable, so toolbar state follows the page.
    @ObservationIgnored private var browsers: [String: BrowserTabModel] = [:]
    /// Streamed browser tabs while linked to a Mac.
    @ObservationIgnored private let streamed = StreamedBrowserDirectory.shared
    /// The chrome insets the pages were last laid out with, for cards.
    @ObservationIgnored private var lastInsets = EdgeInsets(top: 62, leading: 0, bottom: 98, trailing: 0)
    @ObservationIgnored var pageHeight: CGFloat = 874
    /// A workspace created on this phone opens its first tab ready to type.
    /// Kept while the Mac creates it, since the placeholder tab becomes the
    /// Mac's real tab (a new page) once it confirms.
    @ObservationIgnored private(set) var focusOnOpen = false

    public init(store: AppStore, workspaceID: String, terminal: any TerminalTabContent = PlaceholderTerminalTabContent(),
                sessions: AgentSessionDirectory = .shared, creator: WorkspaceCreator? = nil) {
        self.store = store
        self.creator = creator
        self.workspaceID = workspaceID
        self.terminal = terminal
        self.sessions = sessions
        // Reads only. SwiftUI builds a screen's source while it updates the
        // view graph (a navigation destination re-runs on every change it
        // read), so a write here notifies the update that is running and it
        // re-runs forever: the workspace hang of verify/e2e-matrix.md #4.
        // The writes (remember the tab, consume the focus request) wait for
        // `opened()`, which the screen calls when it appears.
        if let workspace = store.workspace(id: workspaceID), let tab = store.openingTab(for: workspace) {
            selectedTabID = tab.id
        }
        focusOnOpen = store.wantsFocusOnOpen(workspaceID)
        // Linked to a Mac, browser tabs stream from it; otherwise each has a web view.
        if !streamed.isLive {
            for tab in store.workspace(id: workspaceID)?.tabs ?? [] where tab.kind == .browser {
                browsers[tab.id] = BrowserTabModel(url: tab.url)
            }
        }
    }

    public var workspace: Workspace? { store.workspace(id: workspaceID) }

    /// The screen appeared (an action, outside any view update): remembers
    /// the opening tab and consumes this workspace's focus request. `init`
    /// already armed `focusOnOpen` from it; a page that appeared first may
    /// have used it, so this only consumes (re-arming would raise the
    /// keyboard on the next page shown).
    public func opened() {
        if let activeTabID { store.noteOpened(tabID: activeTabID, in: workspaceID) }
        _ = store.takeFocusOnOpen(workspaceID)
    }

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

    /// What the Mac can open in this workspace right now. Every option
    /// becomes a real tab on the Mac; none are shown while it can't.
    public var newTabOptions: [TabsKitNewTabOption] {
        guard let workspace, let creator else { return [] }
        return creator.backend.tabKinds(on: workspace.macID).map(Self.option)
    }

    static func option(_ kind: NewTabKind) -> TabsKitNewTabOption {
        switch kind {
        case .agent(let harness):
            let name = harness == "codex" ? "Codex" : harness == "claude" ? "Claude" : harness.capitalized
            return TabsKitNewTabOption(id: "agent:\(harness)", title: "New \(name) Chat", systemImage: "sparkle", kind: TabsKitTabKind("agent"))
        case .terminal:
            return TabsKitNewTabOption(id: "terminal", title: "New Terminal", systemImage: "apple.terminal", kind: .terminal)
        case .browser:
            return TabsKitNewTabOption(id: "browser", title: "New Browser Tab", systemImage: "globe", kind: .web)
        }
    }

    static func kind(of option: TabsKitNewTabOption) -> NewTabKind {
        if option.id.hasPrefix("agent:") { return .agent(String(option.id.dropFirst("agent:".count))) }
        return option.id == "browser" ? .browser : .terminal
    }

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
            let model: (any BrowserTabState)? = streamed.model(tab: tab.id, url: tab.url) ?? browsers[tab.id]
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
        selectedTabID = id
        store.noteOpened(tabID: id, in: workspaceID)
        CnxTheme.standard.haptics.selection()
    }

    /// Closes the tab on the Mac. It leaves the page at once and comes back
    /// at its place, with a notice, if the Mac refuses.
    public func close(_ id: TabsKitTab.ID) {
        guard let workspace, let position = workspace.tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = workspace.tabs[position]
        guard let creator else {
            notice = "Connect to \(macName) to close tabs."
            return
        }
        let next = store.removeTab(id, from: workspaceID)
        surfaces[id] = nil
        browsers[id] = nil
        streamed.drop(tab: id)
        if selectedTabID == id || workspaceTab(selectedTabID ?? "") == nil {
            selectedTabID = next?.id
            if let next { store.noteOpened(tabID: next.id, in: workspaceID) }
        }
        let workspaceID = workspaceID
        Task { [weak self] in
            do {
                try await creator.backend.closeTab(tab, in: workspace)
            } catch {
                guard let self else { return }
                self.store.insertTab(tab, at: position, in: workspaceID)
                if tab.kind == .browser, !self.streamed.isLive { self.browsers[tab.id] = BrowserTabModel(url: tab.url) }
                self.notice = "Couldn't close \(tab.title) on \(self.macName): \(Self.message(error))"
                CnxTheme.standard.haptics.error()
            }
        }
    }

    /// Shown by TabsKit as a glass toast (a tab that could not be created).
    public private(set) var notice: String?
    public func clearNotice() { notice = nil }

    /// Opens the tab on the Mac and activates it once the Mac lists it (so a
    /// terminal attaches at once and a chat is bound to its session). A
    /// refusal shows as a notice; nothing phone-only is ever added.
    public func createTab(_ option: TabsKitNewTabOption) async -> TabsKitTab.ID? {
        guard let workspace else {
            notice = "This workspace is no longer on the Mac."
            return nil
        }
        guard let creator, !creator.backend.tabKinds(on: workspace.macID).isEmpty else {
            notice = "Connect to \(macName) to open tabs."
            return nil
        }
        let kind = Self.kind(of: option)
        let tab: WorkspaceTab
        do {
            tab = try await creator.backend.createTab(kind, in: workspace)
        } catch {
            notice = "Couldn't open \(option.title.replacingOccurrences(of: "New ", with: "a new ")) on \(macName): \(Self.message(error))"
            CnxTheme.standard.haptics.error()
            return nil
        }
        // The mock keeps tabs in its own store; a live Mac's list already has it.
        if store.workspace(id: workspaceID)?.tabs.contains(where: { $0.id == tab.id }) != true {
            store.appendTab(tab, to: workspaceID)
        }
        let id = tab.id
        if tab.kind == .browser, !streamed.isLive, browsers[id] == nil { browsers[id] = BrowserTabModel(url: tab.url) }
        // A new chat opens ready to type (SPEC 6.2; ChatGPT, Claude and Grok
        // open a new chat with the keyboard up).
        if tab.kind == .agent { surface(id).composerFocused = true }
        activate(id)
        // A new terminal is the same: a fresh shell's next step is a
        // command, and terminal apps (Blink, Termius, Prompt) raise the
        // keyboard for a new session.
        if tab.kind == .terminal, let workspace = self.workspace { terminal.focusInput(for: tab, in: workspace) }
        return id
    }

    static func message(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    // MARK: Per-tab state

    /// A page appeared: in a workspace this phone just created, its active
    /// agent chat or terminal opens with the keyboard up.
    func pageAppeared(_ tabID: String) {
        guard focusOnOpen, tabID == activeTabID, let workspace, let tab = workspaceTab(tabID) else { return }
        switch tab.kind {
        case .agent: surface(tabID).composerFocused = true
        case .terminal: terminal.focusInput(for: tab, in: workspace)
        case .browser: break
        }
        if !store.isPending(workspaceID) { focusOnOpen = false }
    }

    func surface(_ id: String) -> AgentChatSurface {
        if let surface = surfaces[id] { return surface }
        let surface = AgentChatSurface()
        surfaces[id] = surface
        return surface
    }

    func chatStore(_ tab: WorkspaceTab, _ workspace: Workspace) -> AgentChatStore {
        sessions.store(workspace: workspace, tab: tab, macName: macName)
    }

    /// The tab's page: streamed from the Mac while linked, else a local web view.
    func browser(_ tab: WorkspaceTab) -> any BrowserTabState {
        if let model = streamed.model(tab: tab.id, url: tab.url) { return model }
        return localBrowser(tab)
    }

    func localBrowser(_ tab: WorkspaceTab) -> BrowserTabModel {
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
        guard let id = activeTabID else { return }
        if let tab = workspaceTab(id), tab.kind == .browser { browser(tab).takeSnapshot() }
        if let tab = workspaceTab(id), tab.kind == .terminal { terminal.overviewWillAppear(active: tab) }
    }

    // MARK: Toolbar actions

    public func goBack(_ id: TabsKitTab.ID) {
        if let tab = workspaceTab(id), tab.kind == .browser, browser(tab).canGoBack {
            browser(tab).goBack()
        } else {
            exit()
        }
    }

    public func goForward(_ id: TabsKitTab.ID) {
        if let tab = workspaceTab(id), tab.kind == .browser { browser(tab).goForward() }
    }

    public func reloadOrStop(_ id: TabsKitTab.ID) {
        if let tab = workspaceTab(id), tab.kind == .browser { browser(tab).reloadOrStop() }
    }

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
                    TabsKitMenuItem(title: "Agent edits", systemImage: "plus.forwardslash.minus",
                                    isEnabled: AgentChatSurface.hasAgentEdits(store)) { surface.openAllChanges(of: store) },
                    TabsKitMenuItem(title: "Files and Artifacts", systemImage: "folder") { surface.showArtifacts = true },
                    TabsKitMenuItem(title: "Copy Session ID", systemImage: "doc.on.doc") { UIPasteboard.general.string = store.summary.id },
                ],
                [
                    TabsKitMenuItem(title: store.subagents.isEmpty ? "Subagents" : "Subagents (\(store.subagents.count))",
                                    systemImage: "person.2.wave.2") { surface.parityRoute = .subagents },
                ] + (store.source.supportsCheckpoints
                    ? [TabsKitMenuItem(title: "Checkpoints", systemImage: "clock.arrow.circlepath") { surface.parityRoute = .checkpoints }]
                    : []) + [
                    TabsKitMenuItem(title: "Continue in…", systemImage: "arrow.triangle.branch") { surface.parityRoute = .handoff },
                ],
                [leave],
                [
                    TabsKitMenuItem(title: "Stop Agent", systemImage: "stop.circle", isEnabled: store.isRunning, isDestructive: true) { store.cancel() },
                    close,
                ],
            ]
        case .terminal:
            let own = terminal.actions(for: tab, in: workspace).map { action in
                TabsKitMenuItem(title: action.title, systemImage: action.systemImage, isEnabled: action.isEnabled,
                                isDestructive: action.isDestructive) { action.perform() }
            }
            let copy = TabsKitMenuItem(title: "Copy Directory", systemImage: "doc.on.doc") { UIPasteboard.general.string = tab.subtitle ?? workspace.directory }
            return [own, [copy, leave], [close]].filter { !$0.isEmpty }
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
                .onAppear {
                    source.remember(context.safeAreaInsets, pageHeight: context.pageSize.height)
                    source.pageAppeared(tabID)
                }
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
                onUserScroll: { context.reportScroll(fingerDelta: $0) }
            )
            .background(Color.cnxBackground)
            // A page built during a zoom or swipe is laid out before its
            // composer is measured; once it settles, a following chat lands
            // on its newest turn above the composer.
            .onChange(of: context.isInteractive) { _, interactive in
                if interactive, surface.following { surface.scrollToBottom(animated: false) }
            }
        case .terminal:
            source.terminal.page(for: tab, in: workspace, context: terminalContext)
        case .browser:
            if let model = source.browser(tab) as? StreamedBrowserModel {
                StreamedBrowserPage(model: model, insets: insets, reportScroll: { context.reportScroll(fingerDelta: $0) })
            } else {
                BrowserPage(model: source.localBrowser(tab), insets: insets, isZoomGestureActive: context.isZoomGestureActive,
                            reportScroll: { context.reportScroll(fingerDelta: $0) })
            }
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
        row.modifier(AccessoryFloor(context: context))
    }

    @ViewBuilder private var row: some View {
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

/// Keeps the accessory row from going below its resting place above the
/// expanded toolbar. TabsKit places the row at the keyboard's height while
/// the keyboard is up; an interactive dismissal drags the keyboard under the
/// toolbar before it reports 0, so the row followed it down, then jumped
/// back up. This lifts the row by however far it would sink, as a render
/// effect (no layout feedback). A collapsed toolbar rests lower, so the
/// floor applies only with the toolbar expanded.
struct AccessoryFloor: ViewModifier {
    let context: TabsKitContentContext

    func body(content: Content) -> some View {
        let floor = context.pageSize.height - context.safeAreaInsets.bottom
        let applies = !context.isToolbarCollapsed && floor > 0
        content.visualEffect { effect, proxy in
            effect.offset(y: applies ? -Self.overshoot(maxY: proxy.frame(in: .global).maxY, floor: floor) : 0)
        }
    }

    /// Points the row's bottom sits below the floor (0 when above it).
    nonisolated static func overshoot(maxY: CGFloat, floor: CGFloat) -> CGFloat {
        max(0, maxY - floor)
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
                if let model = source.browser(tab) as? StreamedBrowserModel {
                    StreamedBrowserCard(model: model)
                } else {
                    BrowserCard(model: source.localBrowser(tab), insets: insets)
                }
            }
        } else {
            Color.cnxBackground
        }
    }
}
#endif
