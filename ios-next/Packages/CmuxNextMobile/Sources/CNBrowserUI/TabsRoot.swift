#if os(iOS)
public import CNTransport
import CNCore
import CNTerminalUI
public import SwiftUI
import UIKit

/// The Mac's browser tabs and terminals in one Safari-style tab grid: the
/// same grid, zoom, pinch, swipe and toolbar as `BrowserRoot`, with terminal
/// cards (live thumbnails), live terminals zoomed from their cards, and an
/// All · Browser · Terminals filter.
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
            })
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
        let width = UIScreen.main.bounds.width
        let cardWidth = ((width - 48) / 2).rounded(.down)
        thumbnails.show(ids, cardSize: CGSize(width: cardWidth, height: cardWidth * 249.3 / 177))
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
