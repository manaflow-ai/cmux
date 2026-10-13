import SwiftUI

/// Workspaces and their terminals on the selected Mac, like a chat list:
/// each terminal is a row with its agent's state, title, folder and branch.
struct SessionsScreen: View {
    let app: AppModel
    let navigator: AppNavigator
    @State private var search = ""
    @State private var searchPresented = false
    @State private var showNewWorkspace = false
    @State private var pendingClose: DaemonTab?
    @State private var renaming: DaemonWorkspace?

    var body: some View {
        content
            .navigationTitle(app.connection?.host.name ?? String(localized: "Home"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleMenu { hostMenuItems }
            .toolbar { if hasMac { toolbar } }
            .modifier(TerminalSearch(enabled: hasMac, text: $search, isPresented: $searchPresented))
            .onAppear(perform: consumeSearchRequest)
            .onChange(of: navigator.searchRequested) { consumeSearchRequest() }
            .sheet(isPresented: $showNewWorkspace) {
                if let connection = app.connection {
                    NewWorkspaceSheet(connection: connection) { surface in
                        if let surface { open(surface: surface) }
                    }
                    .presentationDetents([.medium])
                }
            }
            .confirmationDialog(
                String(localized: "Close \(pendingClose?.displayTitle ?? "")?"),
                isPresented: Binding(get: { pendingClose != nil }, set: { if !$0 { pendingClose = nil } }),
                titleVisibility: .visible,
                presenting: pendingClose
            ) { tab in
                Button(String(localized: "Close Terminal"), role: .destructive) {
                    Haptics.warning()
                    Task { await app.connection?.close(surface: tab.surface) }
                }
            } message: { _ in
                Text(String(localized: "The terminal and anything running in it end on your Mac."))
            }
            .renameWorkspaceAlert($renaming, connection: app.connection)
    }

    /// No Mac yet: the first-run state stands alone (no search, no new workspace).
    private var hasMac: Bool { app.macList == .macs || app.macList == .loading }

    private func consumeSearchRequest() {
        guard navigator.searchRequested else { return }
        navigator.searchRequested = false
        searchPresented = true
    }

    private func open(surface: Int) {
        navigator.select(.terminal(surface: surface), hostID: app.connection?.host.id)
    }

    @ViewBuilder
    private var content: some View {
        if app.macList == .noMac {
            ConnectMacEmptyState { navigator.startPairing($0) }
        } else if case .failed(let message) = app.macList {
            LoadFailedView(title: String(localized: "Couldn't load your Macs"), message: message) {
                Task { await app.reloadHosts() }
            }
        } else if let connection = app.connection {
            switch connection.phase {
            case .connecting where connection.workspaces.isEmpty:
                HomeSkeleton(hostName: connection.host.name)
            case .offline(let message) where connection.workspaces.isEmpty:
                OfflineState(hostName: connection.host.name, message: message) { app.reconnect() }
            default:
                list(connection)
            }
        } else {
            HomeSkeleton(hostName: nil)
        }
    }

    private func list(_ connection: HostConnection) -> some View {
        List {
            ForEach(filtered(connection.workspaces)) { workspace in
                Section {
                    ForEach(workspace.tabs.filter(\.isTerminal)) { tab in
                        Button {
                            Haptics.selection()
                            open(surface: tab.surface)
                        } label: {
                            TerminalRow(tab: tab, agent: connection.agents[tab.surface], query: search)
                        }
                        .foregroundStyle(.primary)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { pendingClose = tab } label: {
                                Label(String(localized: "Close"), systemImage: "xmark")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            if let cwd = tab.cwd {
                                Button {
                                    UIPasteboard.general.string = cwd
                                    Haptics.success()
                                } label: {
                                    Label(String(localized: "Copy Path"), systemImage: "doc.on.doc")
                                }
                                .tint(.gray)
                            }
                        }
                        .contextMenu {
                            TerminalContextMenu(
                                tab: tab,
                                onRename: { renaming = workspace },
                                onClose: { pendingClose = tab }
                            )
                        } preview: {
                            TerminalRow(tab: tab, agent: connection.agents[tab.surface], query: "")
                                .padding(16)
                                .frame(width: 340)
                                .background(Color(uiColor: .secondarySystemGroupedBackground))
                        }
                    }
                } header: {
                    WorkspaceHeader(workspace: workspace, query: search) {
                        Task {
                            if let surface = try? await connection.newTerminal(in: workspace) { open(surface: surface) }
                        }
                    }
                    .contextMenu {
                        Button { renaming = workspace } label: {
                            Label(String(localized: "Rename Workspace…"), systemImage: "pencil")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(18)
        .refreshable { await connection.refresh() }
        .animation(.smooth(duration: 0.3), value: connection.workspaces)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let kind = connection.phase.statusKind(hostName: connection.host.name) {
                ConnectionStatusCapsule(kind: kind, onRetry: { app.reconnect() })
                    .padding(.vertical, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.3), value: connection.phase)
        .task(id: connection.workspaces.count) {
            // Diagnostics: CMUX_NATIVE_AUTO_OPEN=1 opens the first terminal
            // (device debugging without UI automation).
            guard ProcessInfo.processInfo.environment["CMUX_NATIVE_AUTO_OPEN"] == "1",
                  let tab = connection.workspaces.first?.tabs.first(where: \.isTerminal) else { return }
            open(surface: tab.surface)
        }
        .overlay {
            if filtered(connection.workspaces).isEmpty && search.isEmpty {
                StateMessageView(
                    systemImage: "apple.terminal",
                    title: String(localized: "No terminals yet"),
                    message: String(localized: "Start one here or on your Mac and it shows up instantly.")
                ) {
                    Button(String(localized: "New workspace")) { showNewWorkspace = true }
                        .buttonStyle(.primaryCapsule)
                        .disabled(connection.phase != .connected)
                }
            } else if !search.isEmpty && filtered(connection.workspaces).isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
    }

    private func filtered(_ workspaces: [DaemonWorkspace]) -> [DaemonWorkspace] {
        filterWorkspaces(workspaces, query: search)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showNewWorkspace = true } label: { Image(systemName: "square.and.pencil") }
                .accessibilityLabel(String(localized: "New workspace"))
                .accessibilityIdentifier("sessions.new")
                .disabled(app.connection?.phase != .connected)
        }
    }

    /// Codex-style title menu: switch Mac, pair another, connection info.
    @ViewBuilder
    private var hostMenuItems: some View {
        Section(String(localized: "Macs")) {
            ForEach(app.hosts) { host in
                Button {
                    if host.id != app.connection?.host.id {
                        Haptics.selection()
                        app.connect(host)
                        navigator.hostChanged()
                    }
                } label: {
                    if host.id == app.connection?.host.id {
                        Label(host.name, systemImage: "checkmark")
                    } else {
                        Text(host.name)
                    }
                }
            }
        }
        Section {
            Button { navigator.startPairing() } label: { Label(String(localized: "Add a Mac"), systemImage: "plus") }
            Button { navigator.showSettings = true } label: { Label(String(localized: "Settings"), systemImage: "gearshape") }
        }
        if let connection = app.connection, !connection.path.isEmpty {
            Section(String(localized: "Connection")) {
                Text(connection.path == "relay" ? String(localized: "Encrypted relay") : String(localized: "Direct, end-to-end encrypted"))
            }
        }
    }
}

/// The toolbar search field, only once there is something to search.
private struct TerminalSearch: ViewModifier {
    let enabled: Bool
    @Binding var text: String
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $text, isPresented: $isPresented, placement: .toolbar, prompt: String(localized: "Search terminals"))
        } else {
            content
        }
    }
}

/// Terminals whose title, folder, branch or workspace match `query`.
func filterWorkspaces(_ workspaces: [DaemonWorkspace], query: String) -> [DaemonWorkspace] {
    let withTerminals = workspaces.filter { $0.tabs.contains(where: \.isTerminal) }
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !needle.isEmpty else { return withTerminals }
    return withTerminals.compactMap { workspace in
        let matches = workspace.tabs.filter { tab in
            tab.isTerminal && [tab.displayTitle, tab.cwd ?? "", tab.gitBranch ?? "", workspace.displayName]
                .contains { $0.lowercased().contains(needle) }
        }
        guard !matches.isEmpty else { return nil }
        var copy = workspace
        copy.screens = [DaemonScreen(id: 0, name: nil, active: true, panes: [DaemonPane(id: 0, name: nil, activeTab: nil, tabs: matches, dead: nil)])]
        return copy
    }
}

/// Shared long-press menu for a terminal row (Home and sidebar).
struct TerminalContextMenu: View {
    let tab: DaemonTab
    let onRename: () -> Void
    let onClose: () -> Void

    var body: some View {
        Button(action: onRename) {
            Label(String(localized: "Rename Workspace…"), systemImage: "pencil")
        }
        if let cwd = tab.cwd {
            Button {
                UIPasteboard.general.string = cwd
                Haptics.success()
            } label: {
                Label(String(localized: "Copy Path"), systemImage: "doc.on.doc")
            }
        }
        Divider()
        Button(role: .destructive, action: onClose) {
            Label(String(localized: "Close Terminal"), systemImage: "xmark")
        }
    }
}

extension View {
    /// Alert with a text field that renames a workspace on the Mac.
    func renameWorkspaceAlert(_ workspace: Binding<DaemonWorkspace?>, connection: HostConnection?) -> some View {
        modifier(RenameWorkspaceAlert(workspace: workspace, connection: connection))
    }
}

private struct RenameWorkspaceAlert: ViewModifier {
    @Binding var workspace: DaemonWorkspace?
    let connection: HostConnection?
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert(
                String(localized: "Rename Workspace"),
                isPresented: Binding(get: { workspace != nil }, set: { if !$0 { workspace = nil } }),
                presenting: workspace
            ) { target in
                TextField(String(localized: "Name"), text: $name)
                Button(String(localized: "Cancel"), role: .cancel) {}
                Button(String(localized: "Rename")) {
                    let newName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !newName.isEmpty, let connection else { return }
                    Task { try? await connection.renameWorkspace(target, to: newName) }
                }
            }
            .onChange(of: workspace) { _, value in name = value?.displayName ?? "" }
    }
}

struct WorkspaceHeader: View {
    let workspace: DaemonWorkspace
    var query = ""
    let onNewTerminal: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(highlighted(workspace.displayName, query))
                .font(.footnote.weight(.semibold))
                .textCase(nil)
                .lineLimit(1)
            if let unread = workspace.unreadCount, unread > 0 {
                Text("\(unread)").font(.caption2.weight(.bold)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Theme.attention)).foregroundStyle(.black)
                    .accessibilityLabel(String(localized: "\(unread) unread"))
            }
            Spacer()
            Button(action: onNewTerminal) {
                Image(systemName: "plus").font(.footnote.weight(.semibold))
                    .frame(width: 32, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "New terminal in \(workspace.displayName)"))
        }
        .accessibilityElement(children: .contain)
    }
}

struct TerminalRow: View {
    let tab: DaemonTab
    let agent: DaemonAgent?
    var query = ""
    @ScaledMetric(relativeTo: .body) private var tile: CGFloat = 38

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(uiColor: Theme.terminalBackground))
                    .frame(width: tile, height: tile)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08)))
                if let agent, let name = agent.agent {
                    AgentAvatar(agent: name).scaleEffect(tile / 40).frame(width: tile, height: tile)
                } else {
                    Image(systemName: "apple.terminal").font(.system(size: tile * 0.4, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(highlighted(tab.displayTitle, query)).font(.body.weight(.medium)).lineLimit(1)
                    if let agent, agent.status != .idle, agent.status != .unknown {
                        AgentStatusDot(status: agent.status)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { cwdText; branchText }
                    VStack(alignment: .leading, spacing: 1) { cwdText; branchText }
                }
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let agent, agent.status == .blocked {
                Text(String(localized: "Needs input"))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.attention.opacity(0.16)))
                    .foregroundStyle(Theme.attention)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sessions.row")
    }

    @ViewBuilder private var cwdText: some View {
        if let cwd = tab.shortCwd { Text(highlighted(cwd, query)).lineLimit(1).truncationMode(.head) }
    }

    @ViewBuilder private var branchText: some View {
        if let branch = tab.gitBranch {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch").font(.caption2).accessibilityHidden(true)
                Text(highlighted(branch, query)).lineLimit(1)
            }
        }
    }
}

struct NewWorkspaceSheet: View {
    let connection: HostConnection
    let onCreated: (Int?) -> Void
    @State private var name = ""
    @State private var creating = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextField(String(localized: "Workspace name"), text: $name)
                    .focused($focused)
                    .padding(.horizontal, 16).frame(minHeight: 52)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.elevated))
                    .submitLabel(.go)
                    .onSubmit(create)
                    .accessibilityIdentifier("newWorkspace.name")
                Text(String(localized: "Opens a new workspace with a terminal on your Mac. Leave the name empty to use the folder name."))
                    .font(.footnote).foregroundStyle(.secondary)
                if let error {
                    Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(Theme.danger)
                }
                Spacer()
                Button(action: create) {
                    if creating { ProgressView().tint(Color(uiColor: .systemBackground)) } else { Text(String(localized: "Create workspace")) }
                }
                .buttonStyle(.primaryCapsuleWide)
                .disabled(creating || connection.phase != .connected)
                .accessibilityIdentifier("newWorkspace.create")
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
        guard !creating else { return }
        creating = true
        error = nil
        Task {
            defer { creating = false }
            do {
                let surface = try await connection.newWorkspace(name: name)
                Haptics.success()
                dismiss()
                onCreated(surface)
            } catch {
                Haptics.warning()
                self.error = error.localizedDescription
            }
        }
    }
}
