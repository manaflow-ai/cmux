import SwiftUI

struct TerminalSidebarRootView: View {
    @StateObject private var store: TerminalSidebarStore
    @ObservedObject private var routeStore: NotificationRouteStore
    @State private var navigationPath = NavigationPath()
    @State private var searchText = ""
    @State private var editorDraft: TerminalHostEditorDraft?
    @State private var pendingStartHostID: TerminalHost.ID?
    private let inboxCacheRepository: InboxCacheRepository?

    init(
        store: TerminalSidebarStore? = nil,
        routeStore: NotificationRouteStore? = nil,
        inboxCacheRepository: InboxCacheRepository? = nil
    ) {
        _store = StateObject(
            wrappedValue: store ?? Self.makeLiveStore()
        )
        _routeStore = ObservedObject(wrappedValue: routeStore ?? NotificationRouteStore.shared)
        self.inboxCacheRepository = inboxCacheRepository ?? Self.makeDefaultInboxCacheRepository()
    }

    @MainActor
    static func makeLiveStore() -> TerminalSidebarStore {
        TerminalSidebarStore(
            snapshotStore: Self.makeDefaultSnapshotStore(),
            serverDiscovery: TerminalServerDiscovery()
        )
    }

    private static func makeDefaultSnapshotStore() -> TerminalSnapshotPersisting {
        do {
            let database = try AppDatabase.live()
            try AppDatabaseMigrator.importLegacySnapshotIfNeeded(
                from: TerminalSnapshotStore(),
                into: database
            )
            return TerminalCacheRepository(database: database)
        } catch {
            #if DEBUG
            print("Failed to initialize SQLite terminal cache: \(error)")
            #endif
            return TerminalSnapshotStore()
        }
    }

    private static func makeDefaultInboxCacheRepository() -> InboxCacheRepository? {
        do {
            return InboxCacheRepository(database: try AppDatabase.live())
        } catch {
            #if DEBUG
            print("Failed to initialize SQLite inbox cache: \(error)")
            #endif
            return nil
        }
    }

    private var filteredWorkspaces: [TerminalWorkspace] {
        let staleThreshold = Date.now.addingTimeInterval(-24 * 60 * 60)

        let base: [TerminalWorkspace]
        if searchText.isEmpty {
            base = store.workspaces
        } else {
            let query = searchText.localizedLowercase
            base = store.workspaces.filter { workspace in
                guard let host = store.server(for: workspace.hostID) else { return false }
                return workspace.matches(query: query, host: host)
            }
        }

        let visible = base.filter { workspace in
            // Hide stale workspaces: idle with no activity in 24 hours
            if workspace.phase == .idle, workspace.lastActivity < staleThreshold {
                return false
            }
            return true
        }

        // Pre-compute sort keys to avoid repeated store lookups during sort.
        let sortKeys = Dictionary(
            uniqueKeysWithValues: visible.map { ($0.id, workspaceSortOrder($0)) }
        )
        return visible.sorted { lhs, rhs in
            let lhsOrder = sortKeys[lhs.id] ?? 1
            let rhsOrder = sortKeys[rhs.id] ?? 1
            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            return lhs.lastActivity > rhs.lastActivity
        }
    }

    /// Sort priority: connected first (0), disconnected-but-online next (1), offline last (2).
    private func workspaceSortOrder(_ workspace: TerminalWorkspace) -> Int {
        if store.server(for: workspace.hostID)?.machineStatus == .offline {
            return 2
        }
        switch workspace.phase {
        case .connected:
            return 0
        default:
            return 1
        }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 14) {
                            ForEach(store.hosts) { host in
                                Button {
                                    if store.isConfigured(host) {
                                        let workspaceID = store.startWorkspace(on: host)
                                        navigationPath.append(workspaceID)
                                    } else if host.source == .custom {
                                        pendingStartHostID = host.id
                                        editorDraft = TerminalHostEditorDraft(
                                            host: host,
                                            credentials: store.credentials(for: host)
                                        )
                                    }
                                } label: {
                                    TerminalServerPinView(
                                        host: host,
                                        workspaceCount: store.workspaceCount(for: host),
                                        isConfigured: store.isConfigured(host)
                                    )
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    if host.source == .custom {
                                        Button(TerminalHomeStrings.editServerLabel) {
                                            editorDraft = TerminalHostEditorDraft(
                                                host: host,
                                                credentials: store.credentials(for: host)
                                            )
                                        }
                                        Button(TerminalHomeStrings.deleteServerLabel, role: .destructive) {
                                            store.deleteHost(host)
                                        }
                                    }
                                }
                                .accessibilityIdentifier("terminal.server.\(host.accessibilityIdentifierSlug)")
                            }

                            Button {
                                editorDraft = TerminalHostEditorDraft(
                                    host: store.newHostDraft(),
                                    credentials: TerminalSSHCredentials(password: "", privateKey: "")
                                )
                            } label: {
                                TerminalAddServerPinView()
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("terminal.server.add")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } header: {
                    Text(TerminalHomeStrings.serversHeader)
                } footer: {
                    Text(TerminalHomeStrings.serversFooter)
                }

                Section(TerminalHomeStrings.workspacesHeader) {
                    if filteredWorkspaces.isEmpty {
                        ContentUnavailableView(
                            TerminalHomeStrings.emptyTitle,
                            systemImage: "terminal",
                            description: Text(TerminalHomeStrings.emptyDescription)
                        )
                        .listRowSeparator(.hidden)
                    } else {
                        ForEach(filteredWorkspaces) { workspace in
                            if let host = store.server(for: workspace.hostID) {
                                let row = TerminalWorkspaceConversationRow(
                                    workspace: workspace,
                                    host: host
                                )
                                Button {
                                    let workspaceID = store.openWorkspace(workspace)
                                    navigationPath.append(workspaceID)
                                } label: {
                                    row
                                }
                                .buttonStyle(.plain)
                                .accessibilityElement(children: .ignore)
                                .accessibilityIdentifier("terminal.workspace.\(workspace.id.uuidString)")
                                .accessibilityLabel(row.accessibilityTitle)
                                .accessibilityValue(row.accessibilitySummary)
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button {
                                        store.toggleUnread(for: workspace.id)
                                    } label: {
                                        Label(
                                            workspace.unread ? TerminalHomeStrings.markReadAction : TerminalHomeStrings.markUnreadAction,
                                            systemImage: workspace.unread ? "message" : "message.badge"
                                        )
                                    }
                                    .tint(.blue)
                                    .accessibilityIdentifier("terminal.workspace.action.toggleUnread.\(workspace.id.uuidString)")
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        store.closeWorkspace(workspace)
                                    } label: {
                                        Label(TerminalHomeStrings.deleteAction, systemImage: "trash")
                                    }
                                    .accessibilityIdentifier("terminal.workspace.action.delete.\(workspace.id.uuidString)")
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .accessibilityIdentifier("terminal.home")
            .navigationTitle(TerminalHomeStrings.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: TerminalHomeStrings.searchPrompt)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(TerminalHomeStrings.addServerLabel) {
                            editorDraft = TerminalHostEditorDraft(
                                host: store.newHostDraft(),
                                credentials: TerminalSSHCredentials(password: "", privateKey: "")
                            )
                        }
                        NavigationLink(destination: SettingsView()) {
                            Label(TerminalHomeStrings.settingsLabel, systemImage: "gear")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .accessibilityLabel(TerminalHomeStrings.moreLabel)
                    }
                }
            }
            .navigationDestination(for: TerminalWorkspace.ID.self) { workspaceID in
                if let workspace = store.workspace(with: workspaceID),
                   let host = store.server(for: workspace.hostID) {
                    TerminalWorkspaceScreen(
                        workspace: workspace,
                        host: host,
                        controller: store.controller(for: workspace)
                    )
                } else {
                    ContentUnavailableView(
                        TerminalHomeStrings.missingTitle,
                        systemImage: "terminal",
                        description: Text(TerminalHomeStrings.missingDescription)
                    )
                }
            }
        }
        .sheet(item: $editorDraft) { draft in
            TerminalHostEditorView(
                draft: draft
            ) { host, credentials in
                store.saveHost(host, credentials: credentials)
                editorDraft = nil
                if pendingStartHostID == host.id, store.isConfigured(host) {
                    pendingStartHostID = nil
                    let workspaceID = store.startWorkspace(on: host)
                    navigationPath.append(workspaceID)
                }
            } onCancel: {
                pendingStartHostID = nil
                editorDraft = nil
            }
        }
        .onAppear {
            handlePendingRouteIfPossible()
        }
        .onChange(of: routeStore.pendingRoute) { _, _ in
            handlePendingRouteIfPossible()
        }
    }

    private func handlePendingRouteIfPossible() {
        guard let route = routeStore.pendingRoute else { return }
        guard route.kind == .workspace else {
            routeStore.consume()
            return
        }

        if let cachedItem = cachedWorkspaceItem(for: route),
           let workspaceID = store.openInboxWorkspace(cachedItem, source: .push) {
            routeStore.consume()
            navigationPath.append(workspaceID)
            return
        }

        guard let workspace = store.workspaces.first(where: { $0.remoteWorkspaceID == route.workspaceID }) else {
            return
        }

        routeStore.consume()
        navigationPath.append(store.openWorkspace(workspace, source: .push))
    }

    private func cachedWorkspaceItem(for route: NotificationRoute) -> UnifiedInboxItem? {
        guard let inboxCacheRepository,
              let items = try? inboxCacheRepository.load() else {
            return nil
        }

        return items.first { item in
            guard item.kind == .workspace else { return false }
            guard item.workspaceID == route.workspaceID else { return false }
            if let machineID = route.machineID {
                return item.machineID == machineID
            }
            return true
        }
    }
}

private struct TerminalHostEditorDraft: Identifiable {
    var host: TerminalHost
    var credentials: TerminalSSHCredentials

    var id: TerminalHost.ID {
        host.id
    }
}

private enum TerminalHomeStrings {
    static let navigationTitle = String(localized: "terminal.home.navigation_title", defaultValue: "Terminals")
    static let searchPrompt = String(localized: "terminal.home.search_prompt", defaultValue: "Search workspaces")
    static let serversHeader = String(localized: "terminal.home.servers_header", defaultValue: "Servers")
    static let serversFooter = String(localized: "terminal.home.servers_footer", defaultValue: "Tap a server to start a workspace.")
    static let workspacesHeader = String(localized: "terminal.home.workspaces_header", defaultValue: "Recent")
    static let emptyTitle = String(localized: "terminal.home.empty_title", defaultValue: "No Workspaces")
    static let emptyDescription = String(localized: "terminal.home.empty_description", defaultValue: "Start a workspace from the pinned servers above.")
    static let markReadAction = String(localized: "terminal.home.action.mark_read", defaultValue: "Read")
    static let markUnreadAction = String(localized: "terminal.home.action.mark_unread", defaultValue: "Unread")
    static let deleteAction = String(localized: "terminal.home.action.delete", defaultValue: "Delete")
    static let settingsLabel = String(localized: "terminal.home.settings_label", defaultValue: "Settings")
    static let moreLabel = String(localized: "terminal.home.more_label", defaultValue: "More")
    static let missingTitle = String(localized: "terminal.home.missing_title", defaultValue: "Workspace Missing")
    static let missingDescription = String(localized: "terminal.home.missing_description", defaultValue: "This workspace is no longer available.")
    static let addServerLabel = String(localized: "terminal.home.add_server", defaultValue: "Add Server")
    static let editServerLabel = String(localized: "terminal.home.edit_server", defaultValue: "Edit Server")
    static let deleteServerLabel = String(localized: "terminal.home.delete_server", defaultValue: "Delete Server")
    static let notReadyLabel = String(localized: "terminal.home.server_not_ready", defaultValue: "Setup")
    static let connectedLabel = String(localized: "terminal.home.status.connected", defaultValue: "Connected")
    static let connectingLabel = String(localized: "terminal.home.status.connecting", defaultValue: "Connecting")
    static let reconnectingLabel = String(localized: "terminal.home.status.reconnecting", defaultValue: "Reconnecting")
    static let directConnectingLabel = String(
        localized: "terminal.home.status.direct_connecting",
        defaultValue: "Connecting to cmuxd"
    )
    static let directReconnectingLabel = String(
        localized: "terminal.home.status.direct_reconnecting",
        defaultValue: "Reconnecting to cmuxd"
    )
    static let failedLabel = String(localized: "terminal.home.status.failed", defaultValue: "Failed")
    static let offlineLabel = String(localized: "terminal.home.status.offline", defaultValue: "Offline")
    static let readyToConfigureLabel = String(localized: "terminal.home.status.needs_setup", defaultValue: "Setup Required")
    static let disconnectedLabel = String(localized: "terminal.home.status.disconnected", defaultValue: "Disconnected")
    static let editorNewTitle = String(localized: "terminal.host_editor.new_title", defaultValue: "New Server")
    static let editorEditTitle = String(localized: "terminal.host_editor.edit_title", defaultValue: "Server")
    static let editorSave = String(localized: "terminal.host_editor.save", defaultValue: "Save")
    static let editorCancel = String(localized: "terminal.host_editor.cancel", defaultValue: "Cancel")
    static let editorName = String(localized: "terminal.host_editor.name", defaultValue: "Name")
    static let editorHostname = String(localized: "terminal.host_editor.hostname", defaultValue: "Hostname")
    static let editorPort = String(localized: "terminal.host_editor.port", defaultValue: "Port")
    static let editorUsername = String(localized: "terminal.host_editor.username", defaultValue: "Username")
    static let editorAuthentication = String(
        localized: "terminal.host_editor.authentication",
        defaultValue: "Authentication"
    )
    static let editorAuthenticationPassword = String(
        localized: "terminal.host_editor.authentication.password",
        defaultValue: "Password"
    )
    static let editorAuthenticationPrivateKey = String(
        localized: "terminal.host_editor.authentication.private_key",
        defaultValue: "Private Key"
    )
    static let editorTransport = String(
        localized: "terminal.host_editor.transport",
        defaultValue: "Transport"
    )
    static let editorTransportRawSSH = String(
        localized: "terminal.host_editor.transport.raw_ssh",
        defaultValue: "SSH"
    )
    static let editorTransportRemoteDaemon = String(
        localized: "terminal.host_editor.transport.remote_daemon",
        defaultValue: "cmuxd"
    )
    static let editorTransportFooter = String(
        localized: "terminal.host_editor.transport_footer",
        defaultValue: "Choose how iOS reaches this server. cmuxd uses the direct daemon path when available."
    )
    static let editorAllowsSSHFallback = String(
        localized: "terminal.host_editor.allow_ssh_fallback",
        defaultValue: "Allow SSH Fallback"
    )
    static let editorDirectTLSPins = String(
        localized: "terminal.host_editor.direct_tls_pins",
        defaultValue: "Direct TLS Pins"
    )
    static let editorDirectTLSPinsFooter = String(
        localized: "terminal.host_editor.direct_tls_pins_footer",
        defaultValue: "Add one sha256:... certificate pin per line for direct cmuxd connections."
    )
    static let editorPassword = String(localized: "terminal.host_editor.password", defaultValue: "Password")
    static let editorPasswordFooter = String(
        localized: "terminal.host_editor.password_footer",
        defaultValue: "Store the SSH password in the iOS keychain."
    )
    static let editorPrivateKeyFooter = String(
        localized: "terminal.host_editor.private_key_footer",
        defaultValue: "Paste an unencrypted OpenSSH Ed25519 or ECDSA private key."
    )
    static let editorPendingHostKey = String(
        localized: "terminal.host_editor.pending_host_key",
        defaultValue: "Pending Host Key"
    )
    static let editorPendingHostKeyFooter = String(
        localized: "terminal.host_editor.pending_host_key_footer",
        defaultValue: "Trust this key to allow the first SSH connection."
    )
    static let editorTrustPendingHostKey = String(
        localized: "terminal.host_editor.trust_pending_host_key",
        defaultValue: "Trust Pending Key"
    )
    static let editorClearPendingHostKey = String(
        localized: "terminal.host_editor.clear_pending_host_key",
        defaultValue: "Clear Pending Key"
    )
    static let editorTrustedHostKey = String(
        localized: "terminal.host_editor.trusted_host_key",
        defaultValue: "Trusted Host Key"
    )
    static let editorTrustedHostKeyFooter = String(
        localized: "terminal.host_editor.trusted_host_key_footer",
        defaultValue: "Future SSH connections must match this pinned host key."
    )
    static let editorClearTrustedHostKey = String(
        localized: "terminal.host_editor.clear_trusted_host_key",
        defaultValue: "Clear Trusted Key"
    )
    static let editorBootstrap = String(localized: "terminal.host_editor.bootstrap", defaultValue: "Bootstrap Command")
    static let editorBootstrapFooter = String(localized: "terminal.host_editor.bootstrap_footer", defaultValue: "Use {{session}} to inject the workspace tmux session name.")
    static let reconnectLabel = String(localized: "terminal.workspace.reconnect", defaultValue: "Reconnect")
    static let yesterdayLabel = String(localized: "terminal.home.timestamp.yesterday", defaultValue: "Yesterday")
    static let terminalOpening = String(localized: "terminal.workspace.opening", defaultValue: "Opening terminal...")
}

extension TerminalHostPalette {
    var gradient: LinearGradient {
        switch self {
        case .sky:
            return LinearGradient(colors: [Color.blue.opacity(0.95), Color.cyan.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .mint:
            return LinearGradient(colors: [Color.green.opacity(0.95), Color.teal.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .amber:
            return LinearGradient(colors: [Color.orange.opacity(0.95), Color.yellow.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .rose:
            return LinearGradient(colors: [Color.red.opacity(0.95), Color.pink.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    var accent: Color {
        switch self {
        case .sky: return .blue
        case .mint: return .green
        case .amber: return .orange
        case .rose: return .pink
        }
    }
}

private struct TerminalServerPinView: View {
    let host: TerminalHost
    let workspaceCount: Int
    let isConfigured: Bool

    private var isOffline: Bool {
        host.machineStatus == .offline
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(host.palette.gradient)
                    .frame(width: 62, height: 62)
                    .overlay {
                        if isOffline {
                            Circle()
                                .fill(Color.gray.opacity(0.5))
                        }
                    }

                Image(systemName: host.symbolName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)

                if workspaceCount > 0 {
                    Text("\(workspaceCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.72)))
                        .offset(x: 8, y: -6)
                }
            }

            Text(host.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isOffline ? .secondary : .primary)
                .lineLimit(1)

            if isOffline {
                Text(TerminalHomeStrings.offlineLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(isConfigured ? host.subtitle : TerminalHomeStrings.notReadyLabel)
                    .font(.caption2)
                    .foregroundStyle(isConfigured ? Color.secondary : Color.orange)
                    .lineLimit(1)
            }
        }
        .frame(width: 92)
        .opacity(isOffline ? 0.5 : 1.0)
    }
}

private struct TerminalAddServerPinView: View {
    var body: some View {
        VStack(spacing: 6) {
            Circle()
                .fill(Color.secondary.opacity(0.14))
                .frame(width: 62, height: 62)
                .overlay(
                    Image(systemName: "plus")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                )

            Text(TerminalHomeStrings.addServerLabel)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(String(localized: "terminal.home.ssh_label", defaultValue: "SSH"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 92)
    }
}

private struct TerminalWorkspaceConversationRow: View {
    let workspace: TerminalWorkspace
    let host: TerminalHost

    private var isOffline: Bool {
        host.machineStatus == .offline
    }

    var accessibilityTitle: String {
        workspace.title
    }

    var accessibilitySummary: String {
        let readState = workspace.unread
            ? TerminalHomeStrings.markUnreadAction
            : TerminalHomeStrings.markReadAction
        var parts = [host.name]
        if isOffline {
            parts.append(TerminalHomeStrings.offlineLabel)
        } else {
            parts.append(previewText(for: workspace, host: host))
            parts.append(statusText(for: workspace.phase))
        }
        parts.append(contentsOf: [readState, relativeTimestamp(for: workspace.lastActivity)])
        return parts
        .joined(separator: ", ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(host.palette.gradient)
                    .frame(width: 46, height: 46)

                Image(systemName: host.symbolName)
                    .font(.headline)
                    .foregroundStyle(.white)

                if workspace.unread {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                        .offset(x: 2, y: 2)
                        .accessibilityElement()
                        .accessibilityLabel(TerminalHomeStrings.markUnreadAction)
                        .accessibilityIdentifier("terminal.workspace.unread.\(workspace.id.uuidString)")
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(workspace.title)
                        .font(.headline)
                        .foregroundStyle(isOffline ? .secondary : .primary)
                        .lineLimit(1)

                    Spacer(minLength: 10)

                    Text(relativeTimestamp(for: workspace.lastActivity))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("terminal.workspace.timestamp.\(workspace.id.uuidString)")
                }

                if isOffline {
                    HStack(spacing: 6) {
                        Text(host.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text("•")
                            .foregroundStyle(.tertiary)
                        Text(TerminalHomeStrings.offlineLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .accessibilityIdentifier("terminal.workspace.preview.\(workspace.id.uuidString)")
                } else {
                    HStack(spacing: 6) {
                        Text(host.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(host.palette.accent)
                            .lineLimit(1)
                        Text("•")
                            .foregroundStyle(.tertiary)
                        Text(previewText(for: workspace, host: host))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .accessibilityIdentifier("terminal.workspace.preview.\(workspace.id.uuidString)")
                    }
                }

                if !isOffline {
                    if let lastError = workspace.lastError, workspace.phase == .failed {
                        Text(lastError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    } else {
                        Text(statusText(for: workspace.phase))
                            .font(.caption)
                            .foregroundStyle(statusColor(for: workspace.phase))
                            .lineLimit(1)
                            .accessibilityIdentifier("terminal.workspace.status.\(workspace.id.uuidString)")
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(isOffline ? 0.5 : 1.0)
    }

    private func relativeTimestamp(for date: Date) -> String {
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }

        if calendar.isDateInYesterday(date) {
            return TerminalHomeStrings.yesterdayLabel
        }

        let days = calendar.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }

        return date.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits).year(.twoDigits))
    }

    private func previewText(for workspace: TerminalWorkspace, host: TerminalHost) -> String {
        let usesPlaceholderPreview = workspace.preview.isEmpty || workspace.preview == host.subtitle

        if !usesPlaceholderPreview {
            return workspace.preview
        }

        if let backendPreview = workspace.backendMetadata?.preview, !backendPreview.isEmpty {
            return backendPreview
        }

        if !workspace.preview.isEmpty {
            return workspace.preview
        }

        return statusText(for: workspace.phase)
    }

    private func statusText(for phase: TerminalConnectionPhase) -> String {
        switch phase {
        case .connected:
            return TerminalHomeStrings.connectedLabel
        case .connecting:
            return host.transportPreference == .remoteDaemon
                ? TerminalHomeStrings.directConnectingLabel
                : TerminalHomeStrings.connectingLabel
        case .reconnecting:
            return host.transportPreference == .remoteDaemon
                ? TerminalHomeStrings.directReconnectingLabel
                : TerminalHomeStrings.reconnectingLabel
        case .failed:
            return TerminalHomeStrings.failedLabel
        case .needsConfiguration:
            return TerminalHomeStrings.readyToConfigureLabel
        case .disconnected:
            return TerminalHomeStrings.disconnectedLabel
        case .idle:
            return TerminalHomeStrings.disconnectedLabel
        }
    }

    private func statusColor(for phase: TerminalConnectionPhase) -> Color {
        switch phase {
        case .connected:
            return .green
        case .connecting, .reconnecting:
            return .orange
        case .failed:
            return .red
        case .needsConfiguration:
            return .orange
        case .disconnected, .idle:
            return .secondary
        }
    }
}

struct TerminalWorkspaceDestinationView: View {
    @ObservedObject var store: TerminalSidebarStore
    let workspaceID: TerminalWorkspace.ID

    var body: some View {
        if let workspace = store.workspace(with: workspaceID),
           let host = store.server(for: workspace.hostID) {
            TerminalWorkspaceScreen(
                workspace: workspace,
                host: host,
                controller: store.controller(for: workspace)
            )
        } else {
            ContentUnavailableView(
                TerminalHomeStrings.missingTitle,
                systemImage: "terminal",
                description: Text(TerminalHomeStrings.missingDescription)
            )
        }
    }
}

struct TerminalWorkspaceScreen: View {
    let workspace: TerminalWorkspace
    let host: TerminalHost
    @ObservedObject var controller: TerminalSessionController

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if let surfaceView = controller.surfaceView {
                GhosttySurfaceRepresentable(surfaceView: surfaceView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(edges: [.horizontal, .bottom])
            } else {
                ProgressView(TerminalHomeStrings.terminalOpening)
                    .tint(.white)
            }
        }
        .accessibilityIdentifier("terminal.workspace.detail")
        .safeAreaInset(edge: .top, spacing: 0) {
            if controller.phase != .connected || controller.errorMessage != nil || controller.statusMessage != nil {
                TerminalStatusBanner(
                    host: host,
                    phase: controller.phase,
                    message: controller.statusMessage ?? controller.errorMessage
                )
            }
        }
        .navigationTitle(workspace.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(TerminalHomeStrings.reconnectLabel) {
                    controller.reconnectNow()
                }
            }
        }
        .task {
            controller.resumeIfNeeded()
            controller.surfaceView?.focusInput()
        }
        .onDisappear {
            controller.suspendPreservingState()
        }
    }
}

private struct TerminalStatusBanner: View {
    let host: TerminalHost
    let phase: TerminalConnectionPhase
    let message: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.caption.weight(.semibold))
            Text(message ?? fallbackText)
                .font(.caption.weight(.medium))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .foregroundStyle(.white)
        .accessibilityIdentifier("terminal.status.banner")
    }

    private var iconName: String {
        switch phase {
        case .connected: return "checkmark.circle.fill"
        case .connecting: return "bolt.horizontal.circle.fill"
        case .reconnecting: return "arrow.clockwise.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .needsConfiguration: return "slider.horizontal.3"
        case .disconnected, .idle: return "pause.circle.fill"
        }
    }

    private var fallbackText: String {
        switch phase {
        case .connected:
            return TerminalHomeStrings.connectedLabel
        case .connecting:
            return host.transportPreference == .remoteDaemon
                ? TerminalHomeStrings.directConnectingLabel
                : TerminalHomeStrings.connectingLabel
        case .reconnecting:
            return host.transportPreference == .remoteDaemon
                ? TerminalHomeStrings.directReconnectingLabel
                : TerminalHomeStrings.reconnectingLabel
        case .failed:
            return TerminalHomeStrings.failedLabel
        case .needsConfiguration:
            return TerminalHomeStrings.readyToConfigureLabel
        case .disconnected, .idle:
            return TerminalHomeStrings.disconnectedLabel
        }
    }
}

final class TerminalHostedViewContainer: UIView {
    private(set) var hostedView: UIView?

    func setHostedView(_ view: UIView) {
        guard hostedView !== view else { return }

        hostedView?.removeFromSuperview()
        hostedView = view

        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

private struct GhosttySurfaceRepresentable: UIViewRepresentable {
    let surfaceView: GhosttySurfaceView

    func makeUIView(context: Context) -> TerminalHostedViewContainer {
        let container = TerminalHostedViewContainer()
        container.setHostedView(surfaceView)
        return container
    }

    func updateUIView(_ uiView: TerminalHostedViewContainer, context: Context) {
        uiView.setHostedView(surfaceView)
    }
}

private struct TerminalHostEditorView: View {
    @State private var host: TerminalHost
    @State private var credentials: TerminalSSHCredentials
    @State private var directTLSPinsText: String

    let onSave: (TerminalHost, TerminalSSHCredentials) -> Void
    let onCancel: () -> Void

    init(
        draft: TerminalHostEditorDraft,
        onSave: @escaping (TerminalHost, TerminalSSHCredentials) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _host = State(initialValue: draft.host)
        _credentials = State(initialValue: draft.credentials)
        _directTLSPinsText = State(initialValue: draft.host.directTLSPins.joined(separator: "\n"))
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(TerminalHomeStrings.editorName, text: $host.name)
                        .accessibilityIdentifier("terminal.hostEditor.name")
                    TextField(TerminalHomeStrings.editorHostname, text: $host.hostname)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .accessibilityIdentifier("terminal.hostEditor.hostname")
                    TextField(TerminalHomeStrings.editorPort, value: $host.port, format: .number)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("terminal.hostEditor.port")
                    TextField(TerminalHomeStrings.editorUsername, text: $host.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .accessibilityIdentifier("terminal.hostEditor.username")
                    Picker(TerminalHomeStrings.editorAuthentication, selection: $host.sshAuthenticationMethod) {
                        Text(TerminalHomeStrings.editorAuthenticationPassword).tag(TerminalSSHAuthenticationMethod.password)
                        Text(TerminalHomeStrings.editorAuthenticationPrivateKey).tag(TerminalSSHAuthenticationMethod.privateKey)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("terminal.hostEditor.authentication")
                }

                if host.source == .custom {
                    Section {
                        Picker(TerminalHomeStrings.editorTransport, selection: $host.transportPreference) {
                            Text(TerminalHomeStrings.editorTransportRawSSH).tag(TerminalTransportPreference.rawSSH)
                            Text(TerminalHomeStrings.editorTransportRemoteDaemon).tag(TerminalTransportPreference.remoteDaemon)
                        }
                        .pickerStyle(.segmented)

                        if host.transportPreference == .remoteDaemon {
                            Toggle(TerminalHomeStrings.editorAllowsSSHFallback, isOn: $host.allowsSSHFallback)
                                .accessibilityIdentifier("terminal.hostEditor.allowSSHFallback")
                            TextField(
                                TerminalHomeStrings.editorDirectTLSPins,
                                text: $directTLSPinsText,
                                axis: .vertical
                            )
                            .lineLimit(3...6)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .font(.system(.footnote, design: .monospaced))
                            .accessibilityIdentifier("terminal.hostEditor.directTLSPins")
                        }
                    } footer: {
                        Text(
                            host.transportPreference == .remoteDaemon
                                ? TerminalHomeStrings.editorDirectTLSPinsFooter
                                : TerminalHomeStrings.editorTransportFooter
                        )
                    }
                }

                Section {
                    if host.sshAuthenticationMethod == .password {
                        SecureField(
                            TerminalHomeStrings.editorPassword,
                            text: Binding(
                                get: { credentials.password ?? "" },
                                set: { credentials.password = $0 }
                            )
                        )
                        .accessibilityIdentifier("terminal.hostEditor.password")
                    } else {
                        TextEditor(
                            text: Binding(
                                get: { credentials.privateKey ?? "" },
                                set: { credentials.privateKey = $0 }
                            )
                        )
                        .frame(minHeight: 140)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .accessibilityIdentifier("terminal.hostEditor.privateKey")
                    }
                } footer: {
                    Text(
                        host.sshAuthenticationMethod == .password
                            ? TerminalHomeStrings.editorPasswordFooter
                            : TerminalHomeStrings.editorPrivateKeyFooter
                    )
                }

                if let pendingHostKey = host.pendingHostKey, !pendingHostKey.isEmpty {
                    Section {
                        TerminalHostKeyValueView(value: pendingHostKey)
                        Button(TerminalHomeStrings.editorTrustPendingHostKey) {
                            host.trustedHostKey = pendingHostKey
                            host.pendingHostKey = nil
                        }
                        Button(TerminalHomeStrings.editorClearPendingHostKey, role: .destructive) {
                            host.pendingHostKey = nil
                        }
                    } header: {
                        Text(TerminalHomeStrings.editorPendingHostKey)
                    } footer: {
                        Text(TerminalHomeStrings.editorPendingHostKeyFooter)
                    }
                }

                if let trustedHostKey = host.trustedHostKey, !trustedHostKey.isEmpty {
                    Section {
                        TerminalHostKeyValueView(value: trustedHostKey)
                        Button(TerminalHomeStrings.editorClearTrustedHostKey, role: .destructive) {
                            host.trustedHostKey = nil
                        }
                    } header: {
                        Text(TerminalHomeStrings.editorTrustedHostKey)
                    } footer: {
                        Text(TerminalHomeStrings.editorTrustedHostKeyFooter)
                    }
                }

                Section {
                    TextField(TerminalHomeStrings.editorBootstrap, text: $host.bootstrapCommand, axis: .vertical)
                        .lineLimit(2...4)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .accessibilityIdentifier("terminal.hostEditor.bootstrap")
                } footer: {
                    Text(TerminalHomeStrings.editorBootstrapFooter)
                }
            }
            .accessibilityIdentifier("terminal.hostEditor")
            .navigationTitle(host.hostname.isEmpty && host.username.isEmpty ? TerminalHomeStrings.editorNewTitle : TerminalHomeStrings.editorEditTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(TerminalHomeStrings.editorCancel) {
                        onCancel()
                    }
                    .accessibilityIdentifier("terminal.hostEditor.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(TerminalHomeStrings.editorSave) {
                        onSave(normalizedHost, credentials.normalized)
                    }
                    .disabled(host.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("terminal.hostEditor.save")
                }
            }
        }
    }

    private var normalizedHost: TerminalHost {
        var host = host
        host.name = host.name.trimmingCharacters(in: .whitespacesAndNewlines)
        host.hostname = host.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        host.username = host.username.trimmingCharacters(in: .whitespacesAndNewlines)
        host.bootstrapCommand = host.bootstrapCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        host.directTLSPins = directTLSPinsText.components(separatedBy: .newlines)
        if host.bootstrapCommand.isEmpty {
            host.bootstrapCommand = "tmux new-session -A -s {{session}}"
        }
        if host.port <= 0 {
            host.port = 22
        }
        return host
    }
}

private struct TerminalHostKeyValueView: View {
    let value: String

    var body: some View {
        Text(verbatim: value)
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
