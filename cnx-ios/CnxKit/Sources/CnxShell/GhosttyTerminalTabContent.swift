#if os(iOS)
import CnxModel
import CnxTerminal
import CnxWorkspaces
import SwiftUI
import UIKit
import Observation
import OSLog

private let warmLog = Logger(subsystem: "dev.cmux.cnx", category: "terminal")

/// Plugs CnxTerminal into the workspace tabs in its embedded chrome: TabsKit
/// owns the status bar area and the toolbar, the terminal's actions go into
/// the page menu, and the grid card is a snapshot of the page (no second live
/// surface). One host (model + controller) per tab. The `warmLimit` most
/// recently shown tabs keep their surface and attached session, so switching
/// between them needs no reattach and no new surface; an older one is cooled
/// (session detached, surface released) and keeps its last frame, which its
/// page shows at once, dimmed, while it reattaches.
@MainActor
final class GhosttyTerminalTabContent: TerminalTabContent {
    /// Live Ghostty surfaces (and Mac attaches) kept across tab switches.
    static let warmLimit = 4
    private var hosts: [String: TerminalTabHost] = [:]
    private var warm = TerminalWarmSet<String>(limit: GhosttyTerminalTabContent.warmLimit)
    /// Cooled tabs' pages as last seen.
    private var lastFrames: [String: UIImage] = [:]
    /// Tabs whose host runs on a live session (the rest show the connecting
    /// placeholder, or the mock in DEBUG mock mode).
    private var liveTabs: Set<String> = []
    private var workspaceOwner: [String: String] = [:]
    /// Per tab: "Reattaching…" in the title pill after a slow reattach (P5),
    /// fed from the host model's `connectionState` while the tab has a host.
    private var indicators: [String: ReattachIndicator<ContinuousClock>] = [:]
    private var feeds: [String: Task<Void, Never>] = [:]
    /// Live mode: a session on the Mac for a terminal tab (a daemon surface),
    /// or nil while there is none yet (the tab then shows "Connecting…").
    var sessionProvider: (@MainActor (WorkspaceTab) -> (any TerminalSession)?)?
    /// Live mode: Files and Links previews from the Mac.
    var artifactSourceProvider: (@MainActor (WorkspaceTab) -> (any ArtifactSource)?)?
    /// Live mode: uploads a terminal attachment to the Mac, returning its path there.
    var uploaderProvider: (@MainActor (WorkspaceTab) -> (@MainActor (Data, String) async throws -> String)?)?
    /// DEBUG mock mode (Settings → Developer → Mock): tabs with no live
    /// session run the scripted mock. Ignored outside DEBUG builds.
    var mockDataEnabled = false
    /// The workspace's Mac, for the connecting placeholder's label.
    var macName: (@MainActor (Workspace) -> String?)?

    private func host(for tab: WorkspaceTab, in workspace: Workspace) -> TerminalTabHost {
        // A placeholder (or mock) host built before live data arrived (no
        // coordinator or no tree yet) is replaced once the tab has a live session.
        if let host = hosts[tab.id], liveTabs.contains(tab.id) || sessionProvider == nil { return host }
        // Closed tabs release their surface.
        let open = Set(workspace.tabs.map(\.id))
        for (id, owner) in workspaceOwner where owner == workspace.id && !open.contains(id) {
            hosts[id] = nil
            stopWatching(id)
            indicators[id] = nil
            workspaceOwner[id] = nil
            liveTabs.remove(id)
            warm.remove(id)
            lastFrames[id] = nil
        }
        let live = sessionProvider?(tab)
        if let host = hosts[tab.id], live == nil { return host }
        if live != nil { liveTabs.insert(tab.id) }
        // A live tab never builds the mock: without a session it shows the
        // honest connecting placeholder (TerminalSessionChoice).
        let mock = mockDataEnabled && live == nil && sessionProvider == nil
        let session = TerminalSessionChoice.session(live: live, mockDataEnabled: mock, macName: macName?(workspace), programName: tab.title)
        let artifacts = live == nil ? nil : artifactSourceProvider?(tab)
        let model = TerminalModel(
            session: session,
            artifactSource: artifacts ?? TerminalSessionChoice.fallbackArtifactSource(mockDataEnabled: mock),
            title: tab.title
        )
        model.uploader = live == nil ? nil : uploaderProvider?(tab)
        model.restoreLastFrame(lastFrames.removeValue(forKey: tab.id))
        let host = TerminalTabHost(model: model)
        hosts[tab.id] = host
        watchReattach(tab.id, model: model)
        workspaceOwner[tab.id] = workspace.id
        return host
    }

    /// Drops every host (another account or live data stopped).
    func reset() {
        for id in Array(feeds.keys) { stopWatching(id) }
        indicators = [:]
        hosts = [:]
        workspaceOwner = [:]
        liveTabs = []
        warm = TerminalWarmSet(limit: Self.warmLimit)
        lastFrames = [:]
    }

    func page(for tab: WorkspaceTab, in workspace: Workspace, context: TerminalTabContext) -> AnyView {
        let host = host(for: tab, in: workspace)
        for id in warm.touch(tab.id) { cool(id) }
        return AnyView(TerminalTabPage(host: host, insets: context.safeAreaInsets, isInteractive: context.isInteractive))
    }

    /// Releases a tab that fell out of the warm set: its Mac attach and its
    /// Ghostty surface go, its last frame stays for the card and for the page
    /// when it is shown again (a new host, attached in the background).
    private func cool(_ id: String) {
        guard let host = hosts.removeValue(forKey: id) else { return }
        if let frame = host.model.snapshot { lastFrames[id] = frame }
        host.model.session.stop()
        stopWatching(id)
        liveTabs.remove(id)
        warmLog.info("terminal tab \(id, privacy: .public) cooled (warm set of \(Self.warmLimit, privacy: .public)), last frame \(self.lastFrames[id] == nil ? "none" : "kept", privacy: .public)")
    }

    // MARK: Reattach indicator (design/terminal P5)

    /// The tab's indicator, made on first read and kept, so the tab list
    /// that read it observes it before the tab's host exists. Not observed
    /// state itself: making one during a view update notifies nothing.
    private func indicator(_ id: String) -> ReattachIndicator<ContinuousClock> {
        if let indicator = indicators[id] { return indicator }
        let indicator = ReattachIndicator()
        indicators[id] = indicator
        return indicator
    }

    /// Feeds the tab's indicator from its host model's connection state.
    private func watchReattach(_ id: String, model: TerminalModel) {
        stopWatching(id)
        let indicator = indicator(id)
        feeds[id] = Task { [weak indicator, model] in
            for await state in Observations({ model.connectionState }) {
                guard let indicator else { return }
                if case .reattaching = state { indicator.update(reattaching: true) } else { indicator.update(reattaching: false) }
            }
        }
    }

    /// The host went away (closed or cooled). A cooled tab's next host feeds
    /// the same indicator again.
    private func stopWatching(_ id: String) {
        feeds.removeValue(forKey: id)?.cancel()
        indicators[id]?.cancel()
    }

    /// A read (no host is created): the tab's pill says "Reattaching…" while
    /// its reattach has lasted 400 ms or more.
    func statusSubtitle(for tab: WorkspaceTab) -> String? {
        indicator(tab.id).isShown ? "Reattaching…" : nil
    }

    func focusInput(for tab: WorkspaceTab, in workspace: Workspace) {
        host(for: tab, in: workspace).model.focusComposer()
    }

    func card(for tab: WorkspaceTab, in workspace: Workspace) -> AnyView {
        AnyView(TerminalTabCard(model: host(for: tab, in: workspace).model, insets: EdgeInsets(top: 62, leading: 0, bottom: 98, trailing: 0)))
    }

    func overviewWillAppear(active tab: WorkspaceTab) {
        hosts[tab.id]?.prepareCard()
    }

    func actions(for tab: WorkspaceTab, in workspace: Workspace) -> [TerminalTabAction] {
        let model = host(for: tab, in: workspace).model
        // The keyboard toggle and ^C live on the key bar, and Back leaves
        // the workspace, so the menu does not repeat them (design/terminal P1).
        return [
            TerminalTabAction(title: "Files and Links", systemImage: "folder") { model.showFilesAndLinks() },
            TerminalTabAction(title: "Paste", systemImage: "doc.on.clipboard") { model.paste() },
            TerminalTabAction(title: "Clear", systemImage: "clear") { model.sendControl("l") },
            TerminalTabAction(title: "Scroll to Bottom", systemImage: "arrow.down.to.line", isEnabled: model.isScrolledUp) { model.scrollToBottom() },
        ]
    }

    #if DEBUG
    /// DEBUG demos drive the open terminal tab through its model.
    func model(forTabID id: String) -> TerminalModel? { hosts[id]?.model }
    #endif
}
#endif
