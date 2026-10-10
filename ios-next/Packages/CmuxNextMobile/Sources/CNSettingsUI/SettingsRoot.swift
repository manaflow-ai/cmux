#if os(iOS)
import CNBackend
import CNCore
import CNDesign
import CNTransport
import SwiftUI

/// Settings: account, Macs, connection, appearance, terminal, about. A native
/// grouped `Form` in its own `NavigationStack`.
public struct SettingsRoot: View {
    let auth: AuthSession
    let hosts: HostsStore
    let connection: HostConnection
    let preferences: AppPreferences
    let onSelectHost: (String) -> Void

    @State private var showAddMac = false
    @State private var confirmSignOut = false
    @State private var confirmDelete = false
    @State private var hostPendingRemoval: HostRecord?
    @State private var actionError: String?

    public init(auth: AuthSession, hosts: HostsStore, connection: HostConnection, preferences: AppPreferences,
                onSelectHost: @escaping (String) -> Void) {
        self.auth = auth
        self.hosts = hosts
        self.connection = connection
        self.preferences = preferences
        self.onSelectHost = onSelectHost
    }

    public var body: some View {
        @Bindable var preferences = preferences
        NavigationStack {
            Form {
                accountSection
                macsSection
                connectionSection
                Section("Appearance") {
                    Picker("Appearance", selection: $preferences.appearance) {
                        ForEach(AppPreferences.Appearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("settings.appearance")
                }
                Section("Terminal") {
                    Stepper(value: $preferences.terminalFontSize, in: AppPreferences.terminalFontRange, step: 1) {
                        LabeledContent("Font size", value: "\(Int(preferences.terminalFontSize)) pt")
                    }
                    .accessibilityIdentifier("settings.terminalFontSize")
                    Text("The quick brown fox jumps over 13 lazy dogs")
                        .font(.system(size: preferences.terminalFontSize, design: .monospaced))
                        .foregroundStyle(.cn(\.textSecondary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                aboutSection
            }
            .navigationTitle("Settings")
            .cnShellLeadingBarItem()
            .refreshable { await hosts.refresh() }
            .sheet(isPresented: $showAddMac) {
                AddMacSheet(hosts: hosts, apiBase: apiBase) { host in onSelectHost(host.id) }
            }
            .confirmationDialog("Sign out of cmux?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { Task { await auth.signOut() } }
            }
            .alert("Delete your account?", isPresented: $confirmDelete) {
                Button("Delete Account", role: .destructive) { Task { await deleteAccount() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes your account and unpairs every Mac. It cannot be undone.")
            }
            .alert("Remove \(hostPendingRemoval?.name ?? "Mac")?", isPresented: Binding(
                get: { hostPendingRemoval != nil }, set: { if !$0 { hostPendingRemoval = nil } }
            )) {
                Button("Remove", role: .destructive) {
                    if let host = hostPendingRemoval { Task { await remove(host) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The Mac must be paired again with `cmux-next-host login` to reconnect.")
            }
            .alert("Something went wrong", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actionError ?? "")
            }
        }
        .tint(.cn(\.ink))
    }

    private var apiBase: String { auth.backend.configuration.baseURL.absoluteString }

    // MARK: Sections

    private var accountSection: some View {
        Section("Account") {
            if let user = auth.state.user {
                LabeledContent("Email", value: user.email ?? "—")
                if let name = user.name, !name.isEmpty { LabeledContent("Name", value: name) }
            }
            Button("Sign Out") { confirmSignOut = true }
                .accessibilityIdentifier("settings.signOut")
            Button("Delete Account", role: .destructive) { confirmDelete = true }
                .accessibilityIdentifier("settings.deleteAccount")
        }
    }

    private var macsSection: some View {
        Section {
            ForEach(hosts.hosts) { host in
                Button {
                    onSelectHost(host.id)
                } label: {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(host.online ? Color.cn(\.success) : Color.cn(\.textTertiary).opacity(0.5))
                            .frame(width: 8, height: 8)
                            .accessibilityLabel(host.online ? "Online" : "Offline")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.name).foregroundStyle(.cn(\.textPrimary))
                            Text(hostSubtitle(host)).font(.caption).foregroundStyle(.cn(\.textSecondary))
                        }
                        Spacer()
                        if host.id == preferences.selectedHostId {
                            Image(systemName: "checkmark").foregroundStyle(.cn(\.ink)).fontWeight(.semibold)
                        }
                    }
                }
                .swipeActions {
                    Button("Remove", role: .destructive) { hostPendingRemoval = host }
                }
                .contextMenu {
                    Button("Remove", systemImage: "trash", role: .destructive) { hostPendingRemoval = host }
                }
            }
            Button {
                showAddMac = true
            } label: {
                Label("Add Mac", systemImage: "plus")
            }
            .accessibilityIdentifier("settings.addMac")
        } header: {
            Text("Macs")
        } footer: {
            if let error = hosts.lastError { Text(error) }
        }
    }

    private var connectionSection: some View {
        @Bindable var preferences = preferences
        let summary = ConnectionSummary(connection.state)
        let path = connection.pathInfo
        return Section {
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Image(systemName: summary.symbol).imageScale(.small)
                    Text(summary.title)
                }
                .foregroundStyle(summary.tone.color)
                .fixedSize()
            }
            .accessibilityIdentifier("settings.connectionStatus")
            // Rows keep a stable identity (placeholder values while not
            // connected); inserting them conditionally left blank cells.
            LabeledContent("Transport", value: path?.transport ?? "—")
            LabeledContent("Local candidate", value: path?.localCandidate?.rawValue ?? "—")
            LabeledContent("Remote candidate", value: path?.remoteCandidate?.rawValue ?? "—")
            LabeledContent("Round trip", value: path?.rttMs.map { "\(Int($0.rounded())) ms" } ?? "—")
            if path == nil, let detail = summary.detail {
                Text(detail).font(.caption).foregroundStyle(.cn(\.textSecondary))
            }
            Toggle("Force relay (TURN)", isOn: $preferences.forceRelay)
                .tint(.cn(\.highlight))
                .accessibilityIdentifier("settings.forceRelay")
            Button("Reconnect") { connection.retry() }
        } header: {
            Text("Connection")
        } footer: {
            Text("Direct paths go peer to peer. Force relay routes through the TURN server, for testing networks that block direct paths.")
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: Self.versionString)
            if let info = connection.hostInfo {
                LabeledContent("Mac host", value: "\(info.hostName) · \(info.version)")
            }
            LabeledContent("Server", value: auth.backend.configuration.baseURL.host() ?? apiBase)
        }
    }

    // MARK: Actions

    private func hostSubtitle(_ host: HostRecord) -> String {
        if host.online { return "Online · \(host.os)" }
        guard let seen = host.lastSeenAt else { return "Offline · \(host.os)" }
        let date = Date(timeIntervalSince1970: TimeInterval(seen) / 1000)
        return "Last seen \(date.formatted(.relative(presentation: .named)))"
    }

    private func deleteAccount() async {
        do { try await auth.deleteAccount() } catch {
            actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func remove(_ host: HostRecord) async {
        do { try await hosts.delete(hostId: host.id) } catch {
            actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }
}

extension ConnectionSummary.Tone {
    /// Status colors: the semantic palette, no accent hue.
    public var color: Color {
        switch self {
        case .good: .cn(\.success)
        case .relayed: .cn(\.attention)
        case .pending: .cn(\.textSecondary)
        case .bad: .cn(\.danger)
        }
    }
}
#endif
