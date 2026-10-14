#if os(iOS) && DEBUG
import CNCore
import CNDesign
import CNTransport
import SwiftUI

/// DEBUG sample for the combined Tabs screen (`CMUX_NEXT_TERMINAL_CARDS=1`
/// adds a button to the terminal list): a grid of live `TerminalThumbnail`
/// cards; a tap opens `TerminalContent` laid out at full page size with an
/// external `TerminalAccessory` above a host-owned bottom toolbar.
struct TerminalCardsDemo: View {
    let connection: HostConnection
    let terminals: [Terminal]
    @State private var thumbnails: TerminalThumbnails
    @State private var open: TerminalHandle?
    @Environment(\.dismiss) private var dismiss

    init(connection: HostConnection, terminals: [Terminal]) {
        self.connection = connection
        self.terminals = terminals
        _thumbnails = State(initialValue: TerminalThumbnails(connection: connection))
    }

    private let card = CGSize(width: 170, height: 260)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ScrollView {
                    HStack {
                        Spacer()
                        Button("Close") { dismiss() }.accessibilityIdentifier("cards.close")
                    }
                    .padding(.horizontal, 20)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: card.width), spacing: 16)], spacing: 16) {
                        ForEach(terminals) { t in
                            VStack(spacing: 6) {
                                TerminalThumbnail(thumbnails: thumbnails, terminalId: t.id)
                                    .frame(width: card.width, height: card.height)
                                    .clipShape(.rect(cornerRadius: 16, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(.cn(\.hairline)))
                                    .accessibilityIdentifier("terminal.card.\(t.id)")
                                Text(t.title).font(.footnote).lineLimit(1)
                            }
                            .onTapGesture {
                                open = TerminalHandle(connection: connection, terminalId: t.id, accessoryPlacement: .external)
                            }
                        }
                    }
                    .padding(16)
                }
                if let open {
                    // Laid out at the full page size; the host's accessory
                    // and toolbar sit in a bottom inset that rides the keyboard.
                    Color.cn(\.terminalBackground).ignoresSafeArea()
                        .overlay(alignment: .top) {
                            TerminalContent(handle: open, layoutSize: CGSize(width: geo.size.width, height: geo.size.height)) {
                                self.open = nil
                            }
                        }
                        .clipped()
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            VStack(spacing: 0) {
                                TerminalAccessory(handle: open)
                                HStack {
                                    Button("Done") { self.open = nil }.accessibilityIdentifier("cards.done")
                                    Spacer()
                                    Button("Paste") { open.paste() }
                                    Button(open.composerMode ? "Raw" : "Composer") { open.composerMode.toggle() }
                                        .accessibilityIdentifier("cards.composer")
                                }
                                .padding(.horizontal, 20)
                                .frame(height: 50)
                                .background(.bar)
                            }
                        }
                }
            }
        }
        // `.unspecified`: the thumbnails follow the app's light/dark themselves.
        .onAppear { thumbnails.show(terminals.map(\.id), cardSize: card) }
        .task {
            // DEBUG harness (no UI driver on some build hosts):
            // CMUX_NEXT_TERMINAL_CARDS_SCRIPT="<send>~<open index>" types
            // <send> ("_" for spaces) and Return into the first terminal, then opens card <index> at 8 s
            // and closes it at 14 s, for card-vs-live screenshots.
            guard let script = ProcessInfo.processInfo.environment["CMUX_NEXT_TERMINAL_CARDS_SCRIPT"] else { return }
            let parts = script.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
            if let first = terminals.first, let client = connection.client, let send = parts.first, !send.isEmpty {
                let r = try? await client.attachTerminal(first.id, cols: first.cols, rows: first.rows)
                if let r {
                    try? client.sendTerminalInput(streamId: r.streamId, Data((send.replacingOccurrences(of: "_", with: " ") + "\r").utf8))
                    try? await Task.sleep(for: .seconds(1))
                    try? await client.detachTerminal(streamId: r.streamId)
                }
            }
            let index = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            try? await Task.sleep(for: .seconds(8))
            guard terminals.indices.contains(index) else { return }
            open = TerminalHandle(connection: connection, terminalId: terminals[index].id, accessoryPlacement: .external)
            try? await Task.sleep(for: .seconds(6))
            open = nil
        }
        .onDisappear { thumbnails.stopAll() }
    }
}
#endif
