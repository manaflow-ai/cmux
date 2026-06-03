import OSLog
import SwiftUI
import UIKit

private let log = Logger(subsystem: "ai.manaflow.cmux.ios", category: "terminal.sidebar-view")

struct TerminalSidebarRootView: View {
    @SwiftUI.Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?
    @State private var store: TerminalSidebarStore
    private let routeStore: NotificationRouteStore
    @State private var navigationPath = NavigationPath()
    @State private var splitColumnVisibility: NavigationSplitViewVisibility = .all
    @State private var selectedWorkspaceID: TerminalWorkspace.ID?
    @State private var searchText = ""
    @State private var editorDraft: TerminalHostEditorDraft?
    @State private var showScanner = false
    @State private var pendingStartHostID: TerminalHost.ID?
    @State private var renamingHost: TerminalHost?
    @State private var renameText = ""
    @State private var renamingWorkspaceID: TerminalWorkspace.ID?
    @State private var workspaceRenameText = ""
    private let inboxCacheRepository: InboxCacheRepository?

    init(
        store: TerminalSidebarStore? = nil,
        routeStore: NotificationRouteStore? = nil,
        inboxCacheRepository: InboxCacheRepository? = nil
    ) {
        _store = State(
            wrappedValue: store ?? Self.makeLiveStore()
        )
        self.routeStore = routeStore ?? NotificationRouteStore.shared
        self.inboxCacheRepository = inboxCacheRepository ?? Self.makeDefaultInboxCacheRepository()
    }

    @MainActor
    static func makeLiveStore() -> TerminalSidebarStore {
        let snapshotStore = Self.makeDefaultSnapshotStore()
        return TerminalSidebarStore(
            snapshotStore: snapshotStore,
            serverDiscovery: TailscaleServerDiscovery()  // Uses debug auto-probing in DEBUG builds
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
            log.error("Failed to initialize SQLite terminal cache: \(error.localizedDescription, privacy: .public)")
            #endif
            return TerminalSnapshotStore()
        }
    }

    private static func makeDefaultInboxCacheRepository() -> InboxCacheRepository? {
        do {
            return InboxCacheRepository(database: try AppDatabase.live())
        } catch {
            #if DEBUG
            log.error("Failed to initialize SQLite inbox cache: \(error.localizedDescription, privacy: .public)")
            #endif
            return nil
        }
    }

    private var visibleHosts: [TerminalHost] {
        // Discovered (scanned) hosts disappear when offline; the scanner will
        // re-add them the moment they come back. Custom hosts stay visible
        // offline so the user can reconnect them manually.
        store.hosts.filter { host in
            guard host.source == .discovered else { return true }
            return host.machineStatus != .offline
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
            // Hide workspaces belonging to offline discovered hosts. Custom
            // (user-configured) hosts stay visible offline so they can be
            // reconnected; ephemeral scan results should not linger.
            if let host = store.server(for: workspace.hostID),
               host.source == .discovered,
               host.machineStatus == .offline {
                return false
            }
            // For discovered hosts the daemon's workspace.list is
            // authoritative. Hide unbound placeholders (no remoteWorkspaceID)
            // so iOS mirrors the mac sidebar exactly and never shows orphan
            // rows for workspaces that don't exist on the daemon.
            if let host = store.server(for: workspace.hostID),
               host.source == .discovered,
               workspace.remoteWorkspaceID == nil {
                return false
            }
            // Hide stale workspaces: idle with no activity in 24 hours
            if workspace.phase == .idle, workspace.lastActivity < staleThreshold {
                return false
            }
            return true
        }

        // Remote workspaces preserve server tab order, but pinned
        // workspaces always float to the top of each group.
        let hasRemote = visible.contains { $0.remoteWorkspaceID != nil }
        if hasRemote {
            let pinned = visible.filter { $0.pinned }
            let unpinned = visible.filter { !$0.pinned }
            return pinned + unpinned
        }

        let sortKeys = Dictionary(
            visible.map { ($0.id, workspaceSortOrder($0)) },
            uniquingKeysWith: { first, _ in first }
        )
        return visible.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned {
                return lhs.pinned
            }
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
        Group {
            if usesSplitLayout {
                splitLayout
            } else {
                stackLayout
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
                    presentWorkspace(store.startWorkspace(on: host))
                }
            } onCancel: {
                pendingStartHostID = nil
                editorDraft = nil
            }
        }
        .sheet(isPresented: $showScanner) {
            ServerScannerView(
                connectedPorts: Set(store.hosts.compactMap(\.wsPort))
            ) { server in
                addServerFromScan(server)
            } onRemove: { server in
                removeServerFromScan(server)
            } onDismiss: {
                showScanner = false
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .alert(
            TerminalHomeStrings.renameServerLabel,
            isPresented: Binding(
                get: { renamingHost != nil },
                set: { if !$0 { renamingHost = nil } }
            )
        ) {
            TextField(TerminalHomeStrings.renameServerPlaceholder, text: $renameText)
            Button(TerminalHomeStrings.editorSave) {
                if let host = renamingHost {
                    var updatedHost = host
                    updatedHost.name = renameText
                    store.saveHost(updatedHost, credentials: store.credentials(for: host))
                }
                renamingHost = nil
            }
            Button(TerminalHomeStrings.editorCancel, role: .cancel) {
                renamingHost = nil
            }
        }
        .alert(
            TerminalHomeStrings.renameWorkspaceAction,
            isPresented: Binding(
                get: { renamingWorkspaceID != nil },
                set: { if !$0 { renamingWorkspaceID = nil } }
            )
        ) {
            TextField(TerminalHomeStrings.renameWorkspacePlaceholder, text: $workspaceRenameText)
            Button(TerminalHomeStrings.editorSave) {
                if let id = renamingWorkspaceID {
                    store.renameWorkspace(id, to: workspaceRenameText)
                }
                renamingWorkspaceID = nil
            }
            Button(TerminalHomeStrings.editorCancel, role: .cancel) {
                renamingWorkspaceID = nil
            }
        }
        .onAppear {
            handlePendingRouteIfPossible()
        }
        .onChange(of: routeStore.pendingRoute) { _, _ in
            handlePendingRouteIfPossible()
        }
    }

    private var usesSplitLayout: Bool {
        horizontalSizeClass == .regular
    }

    private var splitSelectedWorkspaceID: TerminalWorkspace.ID? {
        guard let selectedWorkspaceID,
              let workspace = store.workspaceResolvingReplacement(with: selectedWorkspaceID),
              filteredWorkspaces.contains(where: { $0.id == workspace.id }) else {
            return nil
        }
        return workspace.id
    }

    private var stackLayout: some View {
        NavigationStack(path: $navigationPath) {
            workspaceHomeList(selectedWorkspaceID: nil) { workspace in
                let workspaceID = store.openWorkspace(workspace)
                navigationPath.append(workspaceID)
            } startWorkspace: { host in
                navigationPath.append(store.startWorkspace(on: host))
            }
            .navigationDestination(for: TerminalWorkspace.ID.self) { workspaceID in
                workspaceDestination(for: workspaceID)
            }
        }
    }

    private var splitLayout: some View {
        NavigationSplitView(columnVisibility: $splitColumnVisibility) {
            workspaceHomeList(selectedWorkspaceID: splitSelectedWorkspaceID) { workspace in
                selectedWorkspaceID = store.openWorkspace(workspace)
            } startWorkspace: { host in
                selectedWorkspaceID = store.startWorkspace(on: host)
            }
            .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 440)
        } detail: {
            if let selectedWorkspaceID = splitSelectedWorkspaceID {
                workspaceDestination(for: selectedWorkspaceID)
            } else {
                TerminalWorkspaceEmptyState(
                    title: TerminalHomeStrings.selectWorkspaceTitle,
                    description: TerminalHomeStrings.selectWorkspaceDescription
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(TerminalHomeStrings.navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private func workspaceHomeList(
        selectedWorkspaceID: TerminalWorkspace.ID?,
        openWorkspace: @escaping (TerminalWorkspace) -> Void,
        startWorkspace: @escaping (TerminalHost) -> Void
    ) -> some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(visibleHosts) { host in
                            Button {
                                activateServer(host, startWorkspace: startWorkspace)
                            } label: {
                                TerminalServerPinView(
                                    host: host,
                                    workspaceCount: store.workspaceCount(for: host),
                                    isConfigured: store.isConfigured(host)
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(TerminalHomeStrings.renameServerLabel) {
                                    renameText = host.name
                                    renamingHost = host
                                }
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
                            .accessibilityElement(children: .ignore)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel(host.name)
                            .accessibilityValue(host.subtitle)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } header: {
                HStack {
                    Text(TerminalHomeStrings.serversHeader)

                    Spacer()

                    Button {
                        presentNewServerEditor()
                    } label: {
                        Label(TerminalHomeStrings.findServersLabel, systemImage: "magnifyingglass")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                    .accessibilityIdentifier("terminal.server.find")
                }
                .textCase(nil)
            }

            Section {
                if filteredWorkspaces.isEmpty {
                    let configuredHosts = store.hosts.filter { store.isConfigured($0) }
                    if !configuredHosts.isEmpty {
                        TerminalWorkspaceEmptyState(
                            title: TerminalHomeStrings.emptyTitle,
                            description: TerminalHomeStrings.serversFooter
                        )
                        .listRowSeparator(.hidden)
                    } else {
                        TerminalWorkspaceEmptyState(
                            title: TerminalHomeStrings.emptyTitle,
                            description: TerminalHomeStrings.emptyDescription
                        )
                        .listRowSeparator(.hidden)
                    }
                } else {
                    ForEach(filteredWorkspaces) { workspace in
                        if let host = store.server(for: workspace.hostID) {
                            let row = TerminalWorkspaceConversationRow(
                                workspace: workspace,
                                host: host
                            )
                            let isSelected = selectedWorkspaceID == workspace.id
                            let showsSelectionStyle = selectedWorkspaceID != nil

                            Button {
                                openWorkspace(workspace)
                            } label: {
                                row
                                    .padding(.horizontal, showsSelectionStyle ? 12 : 0)
                                    .background {
                                        if isSelected {
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .fill(Color.accentColor.opacity(0.16))
                                        }
                                    }
                                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .ignore)
                            .accessibilityAddTraits(.isButton)
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

                                Button {
                                    store.togglePinned(for: workspace.id)
                                } label: {
                                    Label(
                                        workspace.pinned ? TerminalHomeStrings.unpinAction : TerminalHomeStrings.pinAction,
                                        systemImage: workspace.pinned ? "pin.slash.fill" : "pin.fill"
                                    )
                                }
                                .tint(.orange)
                                .accessibilityIdentifier("terminal.workspace.action.togglePin.\(workspace.id.uuidString)")
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    store.closeWorkspace(workspace)
                                } label: {
                                    Label(TerminalHomeStrings.deleteAction, systemImage: "trash")
                                }
                                .accessibilityIdentifier("terminal.workspace.action.delete.\(workspace.id.uuidString)")
                            }
                            .contextMenu {
                                Button {
                                    store.togglePinned(for: workspace.id)
                                } label: {
                                    Label(
                                        workspace.pinned ? TerminalHomeStrings.unpinAction : TerminalHomeStrings.pinAction,
                                        systemImage: workspace.pinned ? "pin.slash" : "pin"
                                    )
                                }
                                Button {
                                    workspaceRenameText = workspace.title
                                    renamingWorkspaceID = workspace.id
                                } label: {
                                    Label(TerminalHomeStrings.renameWorkspaceAction, systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    store.closeWorkspace(workspace)
                                } label: {
                                    Label(TerminalHomeStrings.deleteAction, systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(.compact)
        .refreshable {
            // Pull-to-refresh waits for every pooled daemon connection
            // to tear down + reconnect + land its first post-reconnect
            // workspace.subscribe response, so the spinner only
            // dismisses after fresh state has actually arrived.
            await TerminalDaemonConnectionPool.shared.refreshAll()
        }
        .accessibilityIdentifier("terminal.home")
        .navigationTitle(TerminalHomeStrings.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: TerminalHomeStrings.searchPrompt)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        presentNewServerEditor()
                    } label: {
                        Label(TerminalHomeStrings.findServersLabel, systemImage: "magnifyingglass")
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
    }

    private func activateServer(
        _ host: TerminalHost,
        startWorkspace: @escaping (TerminalHost) -> Void
    ) {
        if store.isConfigured(host) {
            startWorkspace(host)
        } else if host.source == .custom {
            pendingStartHostID = UITestConfig.terminalSetupSaveOnlyFixtureEnabled ? nil : host.id
            editorDraft = TerminalHostEditorDraft(
                host: host,
                credentials: store.credentials(for: host)
            )
        }
    }

    @ViewBuilder
    private func workspaceDestination(for workspaceID: TerminalWorkspace.ID) -> some View {
        if let workspace = store.workspaceResolvingReplacement(with: workspaceID),
           let host = store.server(for: workspace.hostID) {
            TerminalWorkspaceScreen(
                workspace: workspace,
                host: host,
                controller: store.controller(for: workspace),
                store: store
            )
        } else {
            ContentUnavailableView(
                TerminalHomeStrings.missingTitle,
                systemImage: "terminal",
                description: Text(TerminalHomeStrings.missingDescription)
            )
        }
    }

    private func presentWorkspace(_ workspaceID: TerminalWorkspace.ID) {
        if usesSplitLayout {
            selectedWorkspaceID = workspaceID
        } else {
            navigationPath.append(workspaceID)
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
            presentWorkspace(workspaceID)
            return
        }

        guard let workspace = store.workspaces.first(where: { $0.remoteWorkspaceID == route.workspaceID }) else {
            return
        }

        routeStore.consume()
        presentWorkspace(store.openWorkspace(workspace, source: .push))
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

    private func presentNewServerEditor() {
        showScanner = true
    }

    private func presentManualServerEditor() {
        editorDraft = TerminalHostEditorDraft(
            host: store.newHostDraft(),
            credentials: TerminalSSHCredentials(password: "", privateKey: "")
        )
    }

    private func addServerFromScan(_ server: DiscoveredServer) {
        let host = TerminalHost(
            stableID: server.instanceID ?? "\(server.hostname)-\(server.port)",
            name: server.hostname == "127.0.0.1"
                ? "Local Dev (:\(server.port))"
                : "\(server.hostname) (:\(server.port))",
            hostname: server.hostname,
            port: 22,
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .sky,
            source: .discovered,
            transportPreference: .remoteDaemon,
            serverID: server.instanceID,
            wsPort: server.port,
            wsSecret: server.wsSecret
        )
        store.saveHost(host, credentials: TerminalSSHCredentials(password: "", privateKey: ""))
    }

    private func removeServerFromScan(_ server: DiscoveredServer) {
        if let host = store.hosts.first(where: {
            if let instanceID = server.instanceID, $0.stableID == instanceID {
                return true
            }
            return $0.wsPort == server.port && $0.hostname == server.hostname
        }) {
            store.deleteHost(host)
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
    static let navigationTitle = String(localized: "terminal.home.navigation_title", defaultValue: "Workspaces")
    static let searchPrompt = String(localized: "terminal.home.search_prompt", defaultValue: "Search workspaces")
    static let serversHeader = String(localized: "terminal.home.servers_header", defaultValue: "Servers")
    static let serversFooter = String(localized: "terminal.home.servers_footer", defaultValue: "Tap a server to start a workspace.")
    static let workspacesHeader = String(localized: "terminal.home.workspaces_header", defaultValue: "Recent")
    static let emptyTitle = String(localized: "terminal.home.empty_title", defaultValue: "No Workspaces")
    static let emptyDescription = String(localized: "terminal.home.empty_description", defaultValue: "Start a workspace from the pinned servers above.")
    static let selectWorkspaceTitle = String(localized: "terminal.home.select_workspace_title", defaultValue: "Select a Workspace")
    static let selectWorkspaceDescription = String(localized: "terminal.home.select_workspace_description", defaultValue: "Choose a workspace from the sidebar.")

    static let markReadAction = String(localized: "terminal.home.action.mark_read", defaultValue: "Read")
    static let markUnreadAction = String(localized: "terminal.home.action.mark_unread", defaultValue: "Unread")
    static let deleteAction = String(localized: "terminal.home.action.delete", defaultValue: "Delete")
    static let pinAction = String(localized: "terminal.home.action.pin", defaultValue: "Pin")
    static let unpinAction = String(localized: "terminal.home.action.unpin", defaultValue: "Unpin")
    static let renameWorkspaceAction = String(localized: "terminal.home.action.rename_workspace", defaultValue: "Rename")
    static let renameWorkspacePlaceholder = String(localized: "terminal.home.rename_workspace.placeholder", defaultValue: "Workspace name")
    static let settingsLabel = String(localized: "terminal.home.settings_label", defaultValue: "Settings")
    static let moreLabel = String(localized: "terminal.home.more_label", defaultValue: "More")
    static let missingTitle = String(localized: "terminal.home.missing_title", defaultValue: "Workspace Missing")
    static let missingDescription = String(localized: "terminal.home.missing_description", defaultValue: "This workspace is no longer available.")
    static let addServerLabel = String(localized: "terminal.home.add_server", defaultValue: "Add Server")
    static let findServersLabel = String(localized: "terminal.home.find_servers", defaultValue: "Find Servers")
    static let editServerLabel = String(localized: "terminal.home.edit_server", defaultValue: "Edit Server")
    static let deleteServerLabel = String(localized: "terminal.home.delete_server", defaultValue: "Delete Server")
    static let renameServerLabel = String(localized: "terminal.home.rename_server", defaultValue: "Rename")
    static let renameServerPlaceholder = String(localized: "terminal.home.rename_server.placeholder", defaultValue: "Server name")
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

private struct TerminalWorkspaceEmptyState: View {
    let title: String
    let description: String

    var body: some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)

            Text(description)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 28)
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
                    if workspace.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("terminal.workspace.pinned.\(workspace.id.uuidString)")
                    }

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
                    Text(TerminalHomeStrings.offlineLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("terminal.workspace.preview.\(workspace.id.uuidString)")
                } else {
                    Text(previewText(for: workspace, host: host))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("terminal.workspace.preview.\(workspace.id.uuidString)")
                }

                if !isOffline, let lastError = workspace.lastError, workspace.phase == .failed {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
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

        let raw: String
        if !usesPlaceholderPreview {
            raw = workspace.preview
        } else if let backendPreview = workspace.backendMetadata?.preview, !backendPreview.isEmpty {
            raw = backendPreview
        } else if !workspace.preview.isEmpty {
            raw = workspace.preview
        } else {
            return statusText(for: workspace.phase)
        }

        // Strip ANSI escape sequences (CSI with or without ESC prefix, and OSC)
        return raw.replacingOccurrences(
            of: "\\x1B?\\[\\??[0-9;]*[A-Za-z]|\\x1B\\][^\u{07}]*\u{07}|\\x1B[()][0-9A-Za-z]",
            with: "",
            options: .regularExpression
        )
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
    var store: TerminalSidebarStore
    let workspaceID: TerminalWorkspace.ID

    var body: some View {
        if let workspace = store.workspaceResolvingReplacement(with: workspaceID),
           let host = store.server(for: workspace.hostID) {
            TerminalWorkspaceScreen(
                workspace: workspace,
                host: host,
                controller: store.controller(for: workspace),
                store: store
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

private struct ArrowNubRepresentable: UIViewRepresentable {
    let onArrowKey: (Data) -> Void

    func makeUIView(context: Context) -> TerminalArrowNubView {
        let nub = TerminalArrowNubView()
        nub.onArrowKey = onArrowKey
        return nub
    }

    func updateUIView(_ uiView: TerminalArrowNubView, context: Context) {
        uiView.onArrowKey = onArrowKey
    }
}

struct TerminalWorkspaceScreen: View {
    @SwiftUI.Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?
    let workspace: TerminalWorkspace
    let host: TerminalHost
    var controller: TerminalSessionController
    var store: TerminalSidebarStore
    @State private var selectedPaneIndex: Int = 0

    private static let monokaiBackground = Color(red: 0x27/255.0, green: 0x28/255.0, blue: 0x22/255.0)

    private var resolvedBackground: Color {
        if let surfaceBg = controller.surfaceView?.configBackgroundColor {
            return Color(surfaceBg)
        }
        return Self.monokaiBackground
    }

    /// Live panes from the store (updated by subscription push).
    private var panes: [TerminalPane] {
        store.workspace(with: workspace.id)?.panes ?? workspace.panes
    }
    private var hasMultiplePanes: Bool { panes.count > 1 }
    private var shouldAutofocusTerminal: Bool { horizontalSizeClass != .regular }
    private var terminalFullBleedEdges: Edge.Set {
        horizontalSizeClass == .regular ? [] : [.horizontal, .bottom]
    }
    private var navigationTitleMaxWidth: CGFloat {
        horizontalSizeClass == .regular ? 420 : 176
    }

    var body: some View {
        ZStack {
            resolvedBackground
                .ignoresSafeArea(edges: terminalFullBleedEdges)

            if let surfaceView = controller.surfaceView {
                GhosttySurfaceRepresentable(
                    surfaceView: surfaceView,
                    autofocusOnAttach: shouldAutofocusTerminal
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .ignoresSafeArea(edges: terminalFullBleedEdges)
            } else {
                ProgressView(TerminalHomeStrings.terminalOpening)
                    .tint(.white)
            }

            #if DEBUG
            TerminalRenderedTextAccessibilityProbe(text: controller.accessibilityTerminalText)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
            #endif
        }
        .accessibilityIdentifier("terminal.workspace.detail")
        #if DEBUG
        .accessibilityValue(controller.accessibilityTerminalText)
        #endif
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
        .toolbarBackground(resolvedBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if hasMultiplePanes {
                    Menu {
                        ForEach(Array(panes.enumerated()), id: \.element.id) { index, pane in
                            Button {
                                selectedPaneIndex = index
                                switchToPane(pane)
                            } label: {
                                Label(
                                    paneLabel(pane, index: index),
                                    systemImage: index == selectedPaneIndex ? "checkmark.circle.fill" : "terminal"
                                )
                            }
                            .accessibilityIdentifier("terminal.workspace.pane.\(workspace.id.uuidString).\(index)")
                        }
                    } label: {
                        TerminalWorkspaceNavigationTitle(
                            title: workspace.title,
                            paneCount: panes.count,
                            maxWidth: navigationTitleMaxWidth
                        )
                    }
                    .accessibilityIdentifier("terminal.workspace.paneMenu.\(workspace.id.uuidString)")
                } else {
                    TerminalWorkspaceNavigationTitle(
                        title: workspace.title,
                        paneCount: nil,
                        maxWidth: navigationTitleMaxWidth
                    )
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(TerminalHomeStrings.reconnectLabel) {
                    controller.reconnectNow()
                }
            }
        }
        .task {
            store.setWorkspaceDetailVisible(workspace.id, visible: true)
            if shouldAutofocusTerminal {
                controller.surfaceView?.focusInput()
            }
        }
        .onDisappear {
            store.setWorkspaceDetailVisible(workspace.id, visible: false)
        }
    }

    private func paneLabel(_ pane: TerminalPane, index: Int) -> String {
        if !pane.title.isEmpty {
            return pane.title
        }
        if !pane.directory.isEmpty {
            let dir = pane.directory
            return (dir as NSString).lastPathComponent
        }
        return String(localized: "terminal.pane.label", defaultValue: "Pane \(index + 1)")
    }

    private func switchToPane(_ pane: TerminalPane) {
        guard let sessionID = pane.sessionID else { return }
        controller.switchSession(to: sessionID)
    }
}

private struct TerminalWorkspaceNavigationTitle: View {
    let title: String
    let paneCount: Int?
    let maxWidth: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.85)
                .layoutPriority(0)

            if let paneCount {
                Text("\(paneCount)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.2))
                    .clipShape(Capsule())
                    .fixedSize()
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .fixedSize()
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: maxWidth)
        .clipped()
        .contentShape(Rectangle())
    }
}

#if DEBUG
private struct TerminalRenderedTextAccessibilityProbe: UIViewRepresentable {
    let text: String

    func makeUIView(context _: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "terminal.workspace.renderedText"
        view.accessibilityLabel = "Rendered terminal text"
        return view
    }

    func updateUIView(_ uiView: UIView, context _: Context) {
        uiView.accessibilityValue = text
    }
}
#endif

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
    let autofocusOnAttach: Bool

    func makeUIView(context: Context) -> TerminalHostedViewContainer {
        let container = TerminalHostedViewContainer()
        surfaceView.autoFocusOnWindowAttach = autofocusOnAttach
        container.setHostedView(surfaceView)
        return container
    }

    func updateUIView(_ uiView: TerminalHostedViewContainer, context: Context) {
        surfaceView.autoFocusOnWindowAttach = autofocusOnAttach
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
