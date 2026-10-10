import CNCore
import Foundation

/// The demo Mac's workspace layout (PROTOCOL §4 layout), built over the demo
/// terminals, browser tabs and agent sessions:
///
/// - "cmux · fix-resize": two columns. Left: a pane with three tabs (two
///   terminals and an agent). Right: a browser pane (two tabs) over an agent
///   pane (60/40).
/// - "Docs": a single browser pane with a page and a Mac-only (CEF) tab that
///   cannot be streamed.
extension MockEngine {
    func currentLayout() -> MacLayout {
        let terms = terminalOrder.compactMap { terminals[$0]?.info }
        let browserTabs = tabOrder.compactMap { tabs[$0]?.tab }
        let agents = agentSessions.values.sorted { $0.updatedAt > $1.updatedAt }

        func termTab(_ t: Terminal) -> LayoutTab { LayoutTab(id: "lt_t_\(t.id)", kind: .terminal, title: t.title, refId: t.id) }
        func webTab(_ t: BrowserTab) -> LayoutTab { LayoutTab(id: "lt_b_\(t.id)", kind: .browser, title: t.title, refId: t.id, url: t.url) }
        func agentTab(_ a: AgentSession) -> LayoutTab { LayoutTab(id: "lt_a_\(a.id)", kind: .agent, title: a.title, refId: a.id) }

        var left = terms.prefix(2).map(termTab)
        if let a = agents.first { left.append(agentTab(a)) }
        let rightTop = browserTabs.prefix(2).map(webTab)
        let rightBottom = agents.dropFirst().prefix(1).map(agentTab)
        var docs = browserTabs.dropFirst(2).map(webTab)
        docs.append(LayoutTab(id: "lt_cef_linear", kind: .browser, title: "Linear — cmux-next roadmap", refId: nil,
                              streamable: false, url: "https://linear.app/manaflow/project/cmux-next"))

        func pane(_ id: String, _ rect: LayoutRect, _ tabs: [LayoutTab], workspace: String) -> LayoutPane? {
            guard !tabs.isEmpty else { return nil }
            let focused = layoutFocus[id].flatMap { f in tabs.contains { $0.id == f } ? f : nil } ?? tabs[0].id
            let marked = tabs.map { t -> LayoutTab in var t = t; t.focused = t.id == focused; return t }
            return LayoutPane(id: id, rect: rect, tabs: marked, focusedTabId: focused, active: layoutActivePane[workspace] == id)
        }
        let wsA = [
            pane("pane_a_left", LayoutRect(x: 0, y: 0, w: 0.5, h: 1), left, workspace: "ws_a"),
            pane("pane_a_web", LayoutRect(x: 0.5, y: 0, w: 0.5, h: 0.6), rightTop, workspace: "ws_a"),
            pane("pane_a_agent", LayoutRect(x: 0.5, y: 0.6, w: 0.5, h: 0.4), rightBottom, workspace: "ws_a"),
        ].compactMap { $0 }
        let wsB = [pane("pane_b_docs", LayoutRect(x: 0, y: 0, w: 1, h: 1), docs, workspace: "ws_b")].compactMap { $0 }
        return MacLayout(workspaces: [
            LayoutWorkspace(id: "ws_a", title: "cmux · fix-resize", active: true,
                            activePaneId: layoutActivePane["ws_a"] ?? wsA.first?.id, panes: wsA),
            LayoutWorkspace(id: "ws_b", title: "Docs", activePaneId: layoutActivePane["ws_b"] ?? wsB.first?.id, panes: wsB),
        ])
    }

    func focusLayoutTab(_ p: LayoutFocusParams) throws {
        let layout = currentLayout()
        guard let ws = layout.workspaces.first(where: { $0.panes.contains { $0.id == p.paneId } }),
              let pane = ws.panes.first(where: { $0.id == p.paneId }), pane.tabs.contains(where: { $0.id == p.tabId }) else {
            throw notFound("layout tab", p.tabId)
        }
        layoutFocus[p.paneId] = p.tabId
        layoutActivePane[ws.id] = p.paneId
        broadcast(.layoutChanged, LayoutResult(layout: currentLayout()))
    }
}
