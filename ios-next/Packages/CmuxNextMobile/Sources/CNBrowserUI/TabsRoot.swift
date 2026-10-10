#if os(iOS)
public import CNTransport
import CNAgentUI
import CNCore
import CNTerminalUI
public import SwiftUI
import UIKit

/// The Mac's panes on a canvas that scrolls both ways (its workspaces and
/// splits, `layout.v1`), each pane showing its focused tab: browser tabs,
/// terminals and agents open from their panes with the same zoom, pinch,
/// swipe and toolbar as `BrowserRoot`. Press and hold a pane to pick one of
/// its tabs. Without the Mac's layout it is a tab grid of browser tabs and
/// terminals.
public struct TabsRoot: View {
    let connection: HostConnection
    @State private var tabs: TabsModel
    @State private var terminals: TerminalTabs

    public init(connection: HostConnection) {
        self.connection = connection
        let model = TabsModel(connection: connection, includesTerminals: true)
        let terminals = TerminalTabs(connection: connection)
        model.terminalImage = { [weak terminals] id in terminals?.thumbnails.images[id] }
        model.showTerminalCards = { [weak terminals] ids in terminals?.showCards(ids) }
        _tabs = State(initialValue: model)
        _terminals = State(initialValue: terminals)
    }

    public var body: some View {
        TabsScreenHost(
            tabs: tabs, connection: connection,
            terminalContent: { id, size in
                AnyView(TerminalContent(handle: terminals.handle(id), layoutSize: size))
            },
            terminalFontStep: { step in
                guard let id = tabs.activeTerminal?.id else { return }
                terminals.handle(id).stepFontSize(by: Double(step))
            },
            agentContent: { id in AnyView(AgentChatView(connection: connection, sessionId: id)) })
            .onChange(of: tabs.terminals.map(\.id)) { _, ids in terminals.retain(ids) }
            .onDisappear { terminals.thumbnails.stopAll() }
    }
}

/// One `TerminalHandle` per terminal (kept while the terminal exists, so a
/// card and the full screen share one controller) and the grid's live
/// terminal thumbnails.
@MainActor
@Observable
final class TerminalTabs {
    let connection: HostConnection
    let thumbnails: TerminalThumbnails
    @ObservationIgnored private var handles: [String: TerminalHandle] = [:]

    init(connection: HostConnection) {
        self.connection = connection
        thumbnails = TerminalThumbnails(connection: connection)
    }

    func handle(_ id: String) -> TerminalHandle {
        if let h = handles[id] { return h }
        let h = TerminalHandle(connection: connection, terminalId: id)
        handles[id] = h
        return h
    }

    func showCards(_ ids: [String]) {
        // Page proportions: cards and panes show the page scaled to their
        // width, so the text fills a tall pane too.
        let screen = UIScreen.main.bounds.size
        let cardWidth = ((screen.width - 48) / 2).rounded(.down)
        thumbnails.show(ids, cardSize: CGSize(width: cardWidth, height: (cardWidth * screen.height / max(1, screen.width)).rounded()))
    }

    /// Drops handles and thumbnails of terminals that are gone.
    func retain(_ ids: [String]) {
        for id in handles.keys where !ids.contains(id) {
            handles[id] = nil
            thumbnails.forget(id)
        }
    }
}
#endif
