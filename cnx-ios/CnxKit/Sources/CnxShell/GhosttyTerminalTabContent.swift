#if os(iOS)
import CnxModel
import CnxTerminal
import CnxWorkspaces
import SwiftUI

/// Plugs CnxTerminal into the workspace tabs in its embedded chrome: TabsKit
/// owns the status bar area and the toolbar, the terminal's actions go into
/// the page menu, and the grid card is a snapshot of the page (no second live
/// surface). One host (model + controller) per tab, kept while the tab exists,
/// so the surface and scrollback survive tab switches.
@MainActor
final class GhosttyTerminalTabContent: TerminalTabContent {
    private var hosts: [String: TerminalTabHost] = [:]
    /// Tabs whose host runs on a live session (the rest are mock hosts).
    private var liveTabs: Set<String> = []
    private var workspaceOwner: [String: String] = [:]
    /// Live mode: a session on the Mac for a terminal tab (a daemon surface),
    /// or nil to fall back to the mock.
    var sessionProvider: (@MainActor (WorkspaceTab) -> (any TerminalSession)?)?
    /// Live mode: Files and Links previews from the Mac (else the mock files).
    var artifactSourceProvider: (@MainActor (WorkspaceTab) -> (any ArtifactSource)?)?

    private func host(for tab: WorkspaceTab, in workspace: Workspace) -> TerminalTabHost {
        // A mock host built before live data arrived (no coordinator or no
        // tree yet) is replaced once the tab has a live session.
        if let host = hosts[tab.id], liveTabs.contains(tab.id) || sessionProvider == nil { return host }
        // Closed tabs release their surface.
        let open = Set(workspace.tabs.map(\.id))
        for (id, owner) in workspaceOwner where owner == workspace.id && !open.contains(id) {
            hosts[id] = nil
            workspaceOwner[id] = nil
            liveTabs.remove(id)
        }
        let live = sessionProvider?(tab)
        if let host = hosts[tab.id], live == nil { return host }
        if live != nil { liveTabs.insert(tab.id) }
        let session = live ?? MockTerminalSession()
        let artifacts = live == nil ? nil : artifactSourceProvider?(tab)
        let model = TerminalModel(session: session, artifactSource: artifacts ?? MockArtifactSource(), title: tab.title)
        let host = TerminalTabHost(model: model)
        hosts[tab.id] = host
        workspaceOwner[tab.id] = workspace.id
        return host
    }

    /// Drops every host (another account or live data stopped).
    func reset() {
        hosts = [:]
        workspaceOwner = [:]
        liveTabs = []
    }

    func page(for tab: WorkspaceTab, in workspace: Workspace, context: TerminalTabContext) -> AnyView {
        AnyView(TerminalTabPage(host: host(for: tab, in: workspace), insets: context.safeAreaInsets, isInteractive: context.isInteractive))
    }

    func card(for tab: WorkspaceTab, in workspace: Workspace) -> AnyView {
        AnyView(TerminalTabCard(model: host(for: tab, in: workspace).model, insets: EdgeInsets(top: 62, leading: 0, bottom: 98, trailing: 0)))
    }

    func overviewWillAppear(active tab: WorkspaceTab) {
        hosts[tab.id]?.prepareCard()
    }

    func actions(for tab: WorkspaceTab, in workspace: Workspace) -> [TerminalTabAction] {
        let model = host(for: tab, in: workspace).model
        return [
            TerminalTabAction(title: model.keyboardVisible ? "Hide Keyboard" : "Show Keyboard",
                              systemImage: model.keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard") { model.toggleKeyboard() },
            TerminalTabAction(title: "Files and Links", systemImage: "folder") { model.showFilesAndLinks() },
            TerminalTabAction(title: "Paste", systemImage: "doc.on.clipboard") { model.paste() },
            TerminalTabAction(title: "Send Ctrl-C", systemImage: "xmark.octagon") { model.sendControl("c") },
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
