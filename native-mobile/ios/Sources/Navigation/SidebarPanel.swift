import SwiftUI

/// The sidebar under the main card (desktop cmux-next sidebar on a phone):
/// Mac switcher and search, Home / Feed / Search / New Terminal, every
/// workspace with its terminals, and the account menu plus a New button.
struct SidebarPanel: View {
    let app: AppModel
    let navigator: AppNavigator
    @State private var searching = false
    @State private var query = ""
    @State private var expanded: Set<Int> = []
    @State private var pendingClose: DaemonTab?
    @State private var renaming: DaemonWorkspace?
    @FocusState private var searchFocused: Bool

    private static let collapsedLimit = 4

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if !searching {
                    items
                    Divider()
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                }
                workspaces
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .all)
        .scrollDismissesKeyboard(.immediately)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .background(Theme.background)
        .onChange(of: navigator.sidebarOpen) { _, open in
            if !open { endSearch() }
        }
        .renameWorkspaceAlert($renaming, connection: app.connection)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            if searching {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(String(localized: "Search terminals"), text: $query)
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .glassEffect(.regular.interactive(), in: .capsule)
                Button { endSearch() } label: {
                    Image(systemName: "xmark").font(.body.weight(.medium)).foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .glassCircle()
                .accessibilityLabel(String(localized: "Cancel search"))
            } else {
                hostMenu
                Spacer(minLength: 8)
                Button {
                    withAnimation(.smooth(duration: 0.25)) { searching = true }
                    searchFocused = true
                } label: {
                    Image(systemName: "magnifyingglass").font(.body.weight(.medium)).foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .glassCircle()
                .accessibilityLabel(String(localized: "Search terminals"))
                .accessibilityIdentifier("sidebar.search")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func endSearch() {
        searchFocused = false
        query = ""
        withAnimation(.smooth(duration: 0.25)) { searching = false }
    }

    private var hostMenu: some View {
        Menu {
            Section(String(localized: "Macs")) {
                ForEach(app.hosts) { host in
                    Button {
                        if host.id != app.connection?.host.id {
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
            Button { navigator.startPairing() } label: {
                Label(String(localized: "Add a Mac"), systemImage: "plus")
            }
            if let connection = app.connection, !connection.path.isEmpty {
                Section(String(localized: "Connection")) {
                    Text(connection.path == "relay" ? String(localized: "Encrypted relay") : String(localized: "Direct, end-to-end encrypted"))
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let connection = app.connection {
                    Circle().fill(statusColor(connection.phase)).frame(width: 8, height: 8)
                }
                Text(app.connection?.host.name ?? String(localized: "No Mac"))
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .contentShape(.rect)
        }
        .accessibilityLabel(hostMenuLabel)
        .accessibilityHint(String(localized: "Switch Mac or add one"))
        .accessibilityIdentifier("sidebar.hostMenu")
    }

    private var hostMenuLabel: String {
        guard let connection = app.connection else { return String(localized: "No Mac") }
        let status: String = switch connection.phase {
        case .connected: String(localized: "connected")
        case .connecting: String(localized: "connecting")
        case .reconnecting: String(localized: "reconnecting")
        case .offline: String(localized: "offline")
        }
        return "\(connection.host.name), \(status)"
    }

    private func statusColor(_ phase: HostConnection.Phase) -> Color {
        switch phase {
        case .connected: Theme.success
        case .connecting, .reconnecting: Theme.attention
        case .offline: Color.secondary
        }
    }

    // MARK: Items

    @ViewBuilder
    private var items: some View {
        SidebarItemRow(
            title: String(localized: "Home"), systemImage: "house",
            selected: navigator.destination == .home
        ) { navigator.select(.home, hostID: hostID) }
        .accessibilityIdentifier("sidebar.item.home")

        SidebarItemRow(
            title: String(localized: "Feed"), systemImage: "bell",
            badge: app.feed.unreadCount,
            selected: navigator.destination == .feed
        ) { navigator.select(.feed, hostID: hostID) }
        .accessibilityIdentifier("sidebar.item.feed")

        SidebarItemRow(title: String(localized: "Search"), systemImage: "magnifyingglass", selected: false) {
            navigator.searchRequested = true
            navigator.select(.home, hostID: hostID)
        }
        .accessibilityIdentifier("sidebar.item.search")

        SidebarItemRow(title: String(localized: "New Terminal"), systemImage: "apple.terminal", selected: false) {
            newTerminal()
        }
        .disabled(app.connection?.phase != .connected)
        .accessibilityIdentifier("sidebar.item.newTerminal")
    }

    // MARK: Workspaces

    @ViewBuilder
    private var workspaces: some View {
        if let connection = app.connection {
            let groups = filtered(connection.workspaces)
            if !searching, let kind = connection.phase.statusKind(hostName: connection.host.name), !connection.workspaces.isEmpty {
                ConnectionStatusCapsule(kind: kind, onRetry: { app.reconnect() })
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .transition(.opacity)
            }
            if groups.isEmpty {
                switch connection.phase {
                case .connecting where !searching:
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(0..<4, id: \.self) { index in
                            SkeletonRow(titleWidth: [150, 110, 170, 90][index], subtitleWidth: [90, 120, 70, 100][index], leading: 8)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                    .shimmer()
                    .accessibilityLabel(String(localized: "Loading terminals"))
                case .offline where !searching:
                    VStack(alignment: .leading, spacing: 10) {
                        Text(String(localized: "Couldn't reach \(connection.host.name)"))
                            .font(.subheadline.weight(.medium))
                        Button(String(localized: "Retry")) { app.reconnect() }
                            .buttonStyle(.primaryCapsule)
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                default:
                    Text(searching && !query.isEmpty ? String(localized: "No terminals match “\(query)”") : String(localized: "No terminals yet"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
            }
            ForEach(groups) { workspace in
                workspaceSection(workspace, connection: connection)
            }
        } else if case .failed = app.macList {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "Couldn't load your Macs"))
                    .font(.subheadline.weight(.medium))
                Button(String(localized: "Retry")) { Task { await app.reloadHosts() } }
                    .buttonStyle(.primaryCapsule)
                    .controlSize(.small)
                    .accessibilityIdentifier("sidebar.hosts.retry")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        } else if app.macList != .noMac {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<3, id: \.self) { _ in SkeletonRow(leading: 8) }
            }
            .padding(.horizontal, 14)
            .shimmer()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "No Mac connected")).font(.subheadline).foregroundStyle(.secondary)
                Button(String(localized: "Connect your Mac")) { navigator.startPairing() }
                    .buttonStyle(.primaryCapsule)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func workspaceSection(_ workspace: DaemonWorkspace, connection: HostConnection) -> some View {
        let terminals = workspace.tabs.filter(\.isTerminal)
        let isExpanded = expanded.contains(workspace.id) || searching || terminals.count <= Self.collapsedLimit
        let shown = isExpanded ? terminals : Array(terminals.prefix(Self.collapsedLimit - 1))

        HStack(spacing: 6) {
            Text(highlighted(workspace.displayName, searching ? query : ""))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let unread = workspace.unreadCount, unread > 0 {
                Text("\(unread)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Theme.attention))
                    .foregroundStyle(.black)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 2)
        .contentShape(.rect)
        .accessibilityAddTraits(.isHeader)
        .contextMenu {
            Button { renaming = workspace } label: {
                Label(String(localized: "Rename Workspace…"), systemImage: "pencil")
            }
            Button {
                Task {
                    if let surface = try? await connection.newTerminal(in: workspace) {
                        navigator.select(.terminal(surface: surface), hostID: hostID)
                    }
                }
            } label: { Label(String(localized: "New Terminal"), systemImage: "plus") }
        }

        ForEach(shown) { tab in
            SidebarTerminalRow(
                tab: tab,
                agent: connection.agents[tab.surface],
                selected: navigator.destination == .terminal(surface: tab.surface),
                query: searching ? query : ""
            ) {
                navigator.select(.terminal(surface: tab.surface), hostID: hostID)
            }
            .contextMenu {
                TerminalContextMenu(tab: tab, onRename: { renaming = workspace }, onClose: { pendingClose = tab })
            }
            // Anchored on the row so the popover points at the terminal it closes.
            .confirmationDialog(
                String(localized: "Close \(tab.displayTitle)?"),
                isPresented: Binding(
                    get: { pendingClose?.surface == tab.surface },
                    set: { if !$0 { pendingClose = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(String(localized: "Close Terminal"), role: .destructive) {
                    Task { await connection.close(surface: tab.surface) }
                }
            } message: {
                Text(String(localized: "The terminal and anything running in it end on your Mac."))
            }
        }

        if terminals.count > Self.collapsedLimit, !searching {
            Button {
                withAnimation(.smooth(duration: 0.25)) {
                    if expanded.contains(workspace.id) { expanded.remove(workspace.id) } else { expanded.insert(workspace.id) }
                }
            } label: {
                Text(expanded.contains(workspace.id)
                     ? String(localized: "Show less")
                     : String(localized: "See all \(terminals.count)"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    private func filtered(_ workspaces: [DaemonWorkspace]) -> [DaemonWorkspace] {
        filterWorkspaces(workspaces, query: searching ? query : "")
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Menu {
                Button { navigator.showSettings = true } label: {
                    Label(String(localized: "Settings"), systemImage: "gearshape")
                }
                Divider()
                Button(role: .destructive) { navigator.confirmSignOut = true } label: {
                    Label(String(localized: "Sign Out"), systemImage: "rectangle.portrait.and.arrow.right")
                }
            } label: {
                Text(initials)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Theme.elevated))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.08)))
            }
            .accessibilityLabel(String(localized: "Account"))
            .accessibilityIdentifier("sidebar.account")

            Spacer()

            Button { newTerminal() } label: {
                Label(String(localized: "New"), systemImage: "square.and.pencil")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .background(Capsule().fill(Color.primary))
            }
            .buttonStyle(.plain)
            .disabled(app.connection?.phase != .connected)
            .opacity(app.connection?.phase == .connected ? 1 : 0.4)
            .accessibilityLabel(String(localized: "New terminal"))
            .accessibilityIdentifier("sidebar.new")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var initials: String {
        let source = app.user?.name ?? app.user?.email ?? "?"
        let parts = source.split(whereSeparator: { $0 == " " || $0 == "@" || $0 == "." })
        let letters = parts.prefix(source.contains(" ") ? 2 : 1).compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    private var hostID: String? { app.connection?.host.id }

    /// New terminal in the open terminal's workspace, else a new workspace.
    private func newTerminal() {
        guard let connection = app.connection, connection.phase == .connected else { return }
        Haptics.tap()
        Task {
            var current: DaemonWorkspace?
            if case .terminal(let surface) = navigator.destination { current = connection.workspace(containing: surface) }
            let surface: Int?
            if let current {
                surface = try? await connection.newTerminal(in: current)
            } else {
                surface = try? await connection.newWorkspace(name: nil)
            }
            if let surface { navigator.select(.terminal(surface: surface), hostID: connection.host.id) }
        }
    }
}

/// Icon row at the top of the sidebar (Home, Feed, Search, New Terminal).
struct SidebarItemRow: View {
    let title: String
    let systemImage: String
    var badge = 0
    let selected: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    /// Icons grow with Dynamic Type (a fixed 17 pt stayed tiny next to
    /// accessibility-size titles).
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 24

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.body)
                    .frame(width: iconWidth)
                Text(title).font(.body)
                Spacer(minLength: 0)
                if badge > 0 {
                    Text(badge > 99 ? "99+" : "\(badge)")
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.attention))
                        .foregroundStyle(.black)
                        .accessibilityLabel(String(localized: "\(badge) unread"))
                }
            }
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .padding(.horizontal, 14)
            .frame(minHeight: 46)
            .background {
                if selected { Capsule().fill(Theme.elevated) }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A terminal under its workspace: agent status, title, short folder.
struct SidebarTerminalRow: View {
    let tab: DaemonTab
    let agent: DaemonAgent?
    let selected: Bool
    var query = ""
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: 10) {
                Group {
                    if let agent, agent.status != .idle, agent.status != .unknown {
                        AgentStatusDot(status: agent.status)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(highlighted(tab.displayTitle, query))
                        .font(.body.weight(selected ? .semibold : .regular))
                        .lineLimit(1)
                    if let cwd = tab.shortCwd {
                        Text(highlighted(cwd, query))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 0)
                if agent?.status == .blocked {
                    Image(systemName: "exclamationmark.bubble.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.attention)
                        .accessibilityLabel(String(localized: "Needs input"))
                }
            }
            .foregroundStyle(.primary)
            .padding(.leading, 10)
            .padding(.trailing, 14)
            .padding(.vertical, 7)
            .frame(minHeight: 46)
            .background {
                if selected { Capsule().fill(Theme.elevated) }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("sidebar.row")
    }
}
