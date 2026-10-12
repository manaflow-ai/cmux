#if os(iOS)
public import CNTransport
import CNAgentUI
import CNCore
import CNTerminalUI
public import SwiftUI
import UIKit

/// The Mac's browser tabs and terminals in one Safari tab grid: the same
/// grid, zoom, pinch, swipe and toolbar as `BrowserRoot`, with each terminal
/// a card (live thumbnail) that zooms into the live terminal.
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
            agentContent: { id in AnyView(AgentChatView(connection: connection, sessionId: id)) },
            terminalAccessory: { id in AnyView(TerminalAccessory(handle: terminals.handle(id))) })
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
        // The composer and key bar go above the tabs toolbar (TerminalAccessory).
        let h = TerminalHandle(connection: connection, terminalId: id, accessoryPlacement: .external)
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
