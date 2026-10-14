#if os(iOS)
public import CNTransport
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
            terminalAccessory: { id in AnyView(TerminalAccessory(handle: terminals.handle(id))) })
            .onChange(of: tabs.terminals.map(\.id)) { _, ids in terminals.retain(ids) }
            .onDisappear { terminals.thumbnails.stopAll() }
    }
}

/// The grid's terminals: CNTerminalUI's handle pool (at most two live
/// renderers, bounded off-screen thumbnails, released on memory warnings).
@MainActor
@Observable
final class TerminalTabs {
    let connection: HostConnection
    let pool: TerminalHandlePool
    var thumbnails: TerminalThumbnails { pool.thumbnails }

    init(connection: HostConnection) {
        self.connection = connection
        // The composer and key bar go above the tabs toolbar (TerminalAccessory).
        pool = TerminalHandlePool(connection: connection, accessoryPlacement: .external)
    }

    func handle(_ id: String) -> TerminalHandle { pool.handle(id) }

    func showCards(_ ids: [String]) {
        // Page proportions: cards and panes show the page scaled to their
        // width, so the text fills a tall pane too.
        let screen = UIScreen.main.bounds.size
        let cardWidth = ((screen.width - 48) / 2).rounded(.down)
        pool.showCards(ids, cardSize: CGSize(width: cardWidth, height: (cardWidth * screen.height / max(1, screen.width)).rounded()))
    }

    /// Drops handles and thumbnails of terminals that are gone.
    func retain(_ ids: [String]) { pool.retain(ids) }
}
#endif
