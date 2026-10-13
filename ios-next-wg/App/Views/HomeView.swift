import CmuxMobileSSH
import SwiftUI

/// The paired Mac's terminals, grouped by workspace.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [Int] = []
    @State private var showingSettings = false
    @State private var creating = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let connection = model.selected {
                    TerminalList(connection: connection, open: { path.append($0) })
                } else {
                    Color.black
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "line.3.horizontal")
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .principal) {
                    HostMenu()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { newTerminal() } label: {
                        if creating { ProgressView() } else { Image(systemName: "plus") }
                    }
                    .disabled(model.selected?.phase != .connected || creating)
                    .accessibilityLabel("New terminal")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Int.self) { surface in
                if let connection = model.selected {
                    TerminalScreen(connection: connection, surface: surface)
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }

    private func newTerminal() {
        guard let connection = model.selected else { return }
        creating = true
        Task {
            let size = TerminalScreen.estimatedGrid()
            let surface = try? await connection.newTerminal(cols: size.cols, rows: size.rows)
            creating = false
            if let surface { path.append(surface) }
        }
    }
}

/// The title: the Mac's name with a status dot; a menu switches Macs.
struct HostMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            ForEach(model.connections) { connection in
                Button {
                    model.selectedHostID = connection.id
                    connection.connect()
                } label: {
                    if connection.id == model.selected?.id {
                        Label(connection.host.hostName, systemImage: "checkmark")
                    } else {
                        Text(connection.host.hostName)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.selected?.phase.dotColor ?? .gray)
                    .frame(width: 7, height: 7)
                Text(model.selected?.host.hostName ?? "")
                    .font(.headline)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
        }
    }
}

extension HostConnection.Phase {
    var dotColor: Color {
        switch self {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .red
        case .idle: .gray
        }
    }
}

struct TerminalList: View {
    let connection: HostConnection
    let open: (Int) -> Void

    var body: some View {
        List {
            switch connection.phase {
            case .connecting where connection.workspaces.isEmpty:
                StatusRow(icon: nil, title: "Connecting to \(connection.host.hostName)…",
                          detail: "WireGuard handshake in progress")
            case .failed(let message):
                StatusRow(icon: "wifi.exclamationmark", title: "Can't reach \(connection.host.hostName)", detail: message,
                          action: ("Retry", { connection.connect() }))
            case .idle:
                StatusRow(icon: "bolt.horizontal.circle", title: "Not connected", detail: nil,
                          action: ("Connect", { connection.connect() }))
            default:
                EmptyView()
            }
            ForEach(connection.workspaces) { workspace in
                if !workspace.terminals.isEmpty {
                    Section {
                        ForEach(workspace.terminals) { terminal in
                            Button { open(terminal.surface) } label: {
                                TerminalRow(terminal: terminal)
                            }
                            .swipeActions {
                                Button("Close", role: .destructive) {
                                    Task { await connection.close(terminal) }
                                }
                            }
                        }
                    } header: {
                        Text(workspace.name.isEmpty ? "Workspace" : workspace.name)
                    }
                }
            }
            if connection.phase == .connected, connection.terminals.isEmpty {
                StatusRow(icon: "terminal", title: "No terminals", detail: "Tap + to open one on your Mac.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .refreshable { await connection.refresh() }
        .task { connection.connect() }
    }
}

struct TerminalRow: View {
    let terminal: CmuxTUITerminal

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: terminal.dead ? "xmark.square" : "terminal")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(terminal.displayTitle)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let cols = terminal.cols, let rows = terminal.rows {
                    Text("\(cols)×\(rows)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

extension CmuxTUITerminal {
    var displayTitle: String {
        if let name, !name.isEmpty { return name }
        if !title.isEmpty { return title }
        return String(localized: "Terminal")
    }
}

struct StatusRow: View {
    let icon: String?
    let title: String
    let detail: String?
    var action: (String, () -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            if let icon {
                Image(systemName: icon).font(.title2).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            Text(title).font(.headline).multilineTextAlignment(.center)
            if let detail {
                Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if let action {
                PrimaryCapsuleButton(title: LocalizedStringKey(action.0), action: action.1)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .listRowBackground(Color.clear)
    }
}
