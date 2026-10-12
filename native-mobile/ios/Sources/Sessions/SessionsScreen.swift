import SwiftUI

/// Workspaces and their terminals on the selected Mac, like a chat list:
/// each terminal is a row with its agent's state, title, folder and branch.
struct SessionsScreen: View {
    let app: AppModel
    @State private var search = ""
    @State private var showPairing = false
    @State private var showNewWorkspace = false
    @State private var showSettings = false
    @State private var path: [DaemonTab] = []

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle(app.connection?.host.name ?? String(localized: "Sessions"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .navigationDestination(for: DaemonTab.self) { tab in
                    if let connection = app.connection { TerminalScreen(connection: connection, tab: tab) }
                }
                .searchable(text: $search, placement: .toolbar, prompt: String(localized: "Search terminals"))
                .sheet(isPresented: $showPairing) { PairingFlow(app: app) }
                .sheet(isPresented: $showSettings) { SettingsScreen(app: app) }
                .sheet(isPresented: $showNewWorkspace) {
                    if let connection = app.connection {
                        NewWorkspaceSheet(connection: connection) { surface in
                            if let surface, let tab = connection.tab(surface: surface) { path.append(tab) }
                        }
                        .presentationDetents([.medium])
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if app.hostsLoaded && app.hosts.isEmpty {
            ConnectMacEmptyState { showPairing = true }
        } else if let connection = app.connection {
            switch connection.phase {
            case .connected, .reconnecting:
                list(connection)
            case .connecting:
                ConnectingState(hostName: connection.host.name, path: nil)
            case .offline(let message):
                OfflineState(hostName: connection.host.name, message: message) { app.reconnect() }
            }
        } else {
            ConnectingState(hostName: nil, path: nil)
        }
    }

    private func list(_ connection: HostConnection) -> some View {
        List {
            if case .reconnecting = connection.phase {
                Label(String(localized: "Reconnecting…"), systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote).foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            ForEach(filtered(connection.workspaces)) { workspace in
                Section {
                    ForEach(workspace.tabs.filter(\.isTerminal)) { tab in
                        NavigationLink(value: tab) {
                            TerminalRow(tab: tab, agent: connection.agents[tab.surface])
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await connection.close(surface: tab.surface) }
                            } label: { Label(String(localized: "Close"), systemImage: "xmark") }
                        }
                        .contextMenu {
                            Button { UIPasteboard.general.string = tab.cwd } label: { Label(String(localized: "Copy Path"), systemImage: "doc.on.doc") }
                            Button(role: .destructive) { Task { await connection.close(surface: tab.surface) } } label: {
                                Label(String(localized: "Close Terminal"), systemImage: "xmark")
                            }
                        }
                    }
                } header: {
                    WorkspaceHeader(workspace: workspace) {
                        Task {
                            if let surface = try? await connection.newTerminal(in: workspace), let tab = connection.tab(surface: surface) {
                                path.append(tab)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await connection.refresh() }
        .overlay {
            if connection.workspaces.isEmpty {
                ContentUnavailableView(String(localized: "No terminals"), systemImage: "terminal", description: Text(String(localized: "Start one on your Mac or tap + to open a new workspace.")))
            } else if !search.isEmpty && filtered(connection.workspaces).isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
    }

    private func filtered(_ workspaces: [DaemonWorkspace]) -> [DaemonWorkspace] {
        guard !search.isEmpty else { return workspaces.filter { !$0.tabs.filter(\.isTerminal).isEmpty } }
        let query = search.lowercased()
        return workspaces.compactMap { workspace in
            var copy = workspace
            let matches = workspace.tabs.filter { tab in
                [tab.displayTitle, tab.cwd ?? "", tab.gitBranch ?? "", workspace.displayName].contains { $0.lowercased().contains(query) }
            }
            guard !matches.isEmpty else { return nil }
            copy.screens = [DaemonScreen(id: 0, name: nil, active: true, panes: [DaemonPane(id: 0, name: nil, activeTab: nil, tabs: matches, dead: nil)])]
            return copy
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) { hostMenu }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .accessibilityLabel(String(localized: "Settings"))
                .accessibilityIdentifier("sessions.settings")
        }
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
            Button { showNewWorkspace = true } label: { Image(systemName: "square.and.pencil") }
                .accessibilityLabel(String(localized: "New workspace"))
                .accessibilityIdentifier("sessions.new")
                .disabled(app.connection?.phase != .connected)
        }
    }

    /// Codex-style title menu: switch Mac, pair another, connection info.
    private var hostMenu: some View {
        Menu {
            Section(String(localized: "Macs")) {
                ForEach(app.hosts) { host in
                    Button {
                        app.connect(host)
                    } label: {
                        if host.id == app.connection?.host.id {
                            Label(host.name, systemImage: "checkmark")
                        } else {
                            Text(host.name)
                        }
                    }
                }
            }
            Button { showPairing = true } label: { Label(String(localized: "Connect a Mac"), systemImage: "plus") }
            if let connection = app.connection, !connection.path.isEmpty {
                Section(String(localized: "Connection")) {
                    Text(connection.path)
                }
            }
        } label: {
            Image(systemName: "desktopcomputer")
        }
        .accessibilityIdentifier("sessions.hostMenu")
    }
}

struct WorkspaceHeader: View {
    let workspace: DaemonWorkspace
    let onNewTerminal: () -> Void

    var body: some View {
        HStack {
            Text(workspace.displayName).font(.footnote.weight(.semibold)).textCase(nil)
            if let unread = workspace.unreadCount, unread > 0 {
                Text("\(unread)").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Theme.attention)).foregroundStyle(.black)
            }
            Spacer()
            Button(action: onNewTerminal) { Image(systemName: "plus").font(.footnote.weight(.semibold)) }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "New terminal in \(workspace.displayName)"))
        }
    }
}

struct TerminalRow: View {
    let tab: DaemonTab
    let agent: DaemonAgent?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: Theme.terminalBackground))
                    .frame(width: 38, height: 38)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
                if let agent, let name = agent.agent {
                    AgentAvatar(agent: name).scaleEffect(0.95).frame(width: 38, height: 38)
                } else {
                    Image(systemName: "terminal").font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tab.displayTitle).font(.body.weight(.medium)).lineLimit(1)
                    if let agent, agent.status != .idle, agent.status != .unknown {
                        AgentStatusDot(status: agent.status)
                    }
                }
                HStack(spacing: 4) {
                    if let cwd = tab.shortCwd { Text(cwd).lineLimit(1).truncationMode(.head) }
                    if let branch = tab.gitBranch {
                        Image(systemName: "arrow.triangle.branch").font(.caption2)
                        Text(branch).lineLimit(1)
                    }
                }
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let agent, agent.status == .blocked {
                Text(String(localized: "Needs input")).font(.caption.weight(.semibold)).foregroundStyle(Theme.attention)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sessions.row")
    }
}

struct NewWorkspaceSheet: View {
    let connection: HostConnection
    let onCreated: (Int?) -> Void
    @State private var name = ""
    @State private var creating = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextField(String(localized: "Workspace name"), text: $name)
                    .focused($focused)
                    .padding(.horizontal, 16).frame(height: 52)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.elevated))
                    .submitLabel(.go)
                    .onSubmit(create)
                Text(String(localized: "Opens a new workspace with a terminal on your Mac."))
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button(action: create) {
                    Text(creating ? String(localized: "Creating…") : String(localized: "Create workspace"))
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .background(Capsule().fill(Color.primary))
                }
                .buttonStyle(.plain)
                .disabled(creating)
            }
            .padding(20)
            .navigationTitle(String(localized: "New workspace"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .close) { dismiss() }
                }
            }
            .onAppear { focused = true }
        }
    }

    private func create() {
        creating = true
        Task {
            let surface = try? await connection.newWorkspace(name: name)
            dismiss()
            onCreated(surface)
        }
    }
}
