#if os(iOS)
public import CNTransport
import CNCore
import CNDesign
public import SwiftUI

/// The terminals on the connected Mac: title, working directory and whether
/// the process runs. + opens a new terminal; swipe closes one; a row opens
/// the terminal full screen.
public struct TerminalsRoot: View {
    let connection: HostConnection
    @State private var model: TerminalListModel
    @State private var path: [TerminalRoute] = []

    public init(connection: HostConnection) {
        self.connection = connection
        _model = State(initialValue: TerminalListModel(connection: connection))
    }

    public var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(model.terminals) { terminal in
                    NavigationLink(value: TerminalRoute.existing(terminal.id)) {
                        TerminalRow(terminal: terminal)
                    }
                    .accessibilityIdentifier("terminal.row.\(terminal.id)")
                    .listRowBackground(Color.cn(\.background))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task { await model.close(terminal.id) }
                        } label: {
                            Label(TerminalText.closeTerminal, systemImage: "xmark")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.cn(\.background))
            .overlay { emptyState }
            .navigationTitle(TerminalText.listTitle)
            .cnShellLeadingBarItem()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        // The screen creates the terminal with the grid that fits it.
                        path.append(.new(UUID()))
                    } label: {
                        Label(TerminalText.newTerminal, systemImage: "plus")
                    }
                    .disabled(!connection.state.isConnected)
                    .accessibilityIdentifier("terminal.new")
                }
            }
            .navigationDestination(for: TerminalRoute.self) { route in
                TerminalScreenView(connection: connection, route: route)
            }
            .refreshable { await model.reload() }
        }
        .task(id: connection.generation) { await model.reload() }
        .task { await model.listen() }
    }

    @ViewBuilder private var emptyState: some View {
        if model.terminals.isEmpty, model.loaded {
            ContentUnavailableView(TerminalText.emptyTitle, systemImage: "apple.terminal",
                                   description: Text(TerminalText.emptyMessage))
        } else if model.terminals.isEmpty, !connection.state.isConnected {
            ContentUnavailableView(TerminalText.offlineTitle, systemImage: "wifi.slash",
                                   description: Text(TerminalText.offlineMessage))
        }
    }
}

struct TerminalRow: View {
    let terminal: Terminal

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: terminal.running ? "apple.terminal" : "apple.terminal.on.rectangle")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.cn(\.icon))
                .frame(width: 36, height: 36)
                .background(.cn(\.control), in: .rect(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(terminal.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.cn(\.textPrimary))
                    .lineLimit(1)
                Text(terminal.cwd)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.cn(\.textSecondary))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Circle()
                    .fill(terminal.running ? Color.cn(\.success) : Color.cn(\.textTertiary))
                    .frame(width: 7, height: 7)
                Text(terminal.running ? TerminalText.running : TerminalText.exited)
                    .font(.footnote)
                    .foregroundStyle(.cn(\.textTertiary))
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// The terminal list: loaded on every connection generation, kept current
/// by `term.updated` / `term.exited` pushes.
@MainActor
@Observable
final class TerminalListModel {
    let connection: HostConnection
    private(set) var terminals: [Terminal] = []
    private(set) var loaded = false
    var error: String?

    init(connection: HostConnection) {
        self.connection = connection
    }

    func reload() async {
        guard let client = connection.client else { return }
        do {
            terminals = try await client.listTerminals()
            loaded = true
            error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    func listen() async {
        for await push in connection.pushes() {
            switch push {
            case .terminalUpdated(let terminal):
                if let index = terminals.firstIndex(where: { $0.id == terminal.id }) {
                    terminals[index] = terminal
                } else {
                    terminals.append(terminal)
                }
            case .terminalExited:
                // Exit and close share the event: the list tells them apart.
                await reload()
            default:
                break
            }
        }
    }

    func close(_ id: String) async {
        terminals.removeAll { $0.id == id }
        guard let client = connection.client else { return }
        try? await client.closeTerminal(id)
    }
}
#endif
