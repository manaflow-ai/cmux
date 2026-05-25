import SwiftUI
import CmuxKit

struct RootView: View {
    @EnvironmentObject var hostStore: HostStore
    @EnvironmentObject var connection: ConnectionManager

    var body: some View {
        Group {
            if hostStore.hosts.isEmpty {
                EmptyStateView()
            } else if let host = hostStore.activeHost {
                NavigationSplitView {
                    WorkspaceSidebarView(host: host)
                        .navigationTitle(host.label)
                } content: {
                    if let workspaceID = connection.snapshot.focusedWorkspaceID,
                       let workspace = connection.snapshot.workspaces[workspaceID] {
                        PaneTreeView(workspace: workspace)
                            .navigationTitle(workspace.title ?? L10n.string("workspace.default_title", defaultValue: "Workspace"))
                    } else {
                        PlaceholderView(text: L10n.string("workspace.placeholder.select", defaultValue: "Select a workspace"))
                    }
                } detail: {
                    if let surfaceID = connection.snapshot.focusedSurfaceID,
                       let surface = connection.snapshot.surfaces[surfaceID] {
                        SurfaceDetailView(surface: surface)
                    } else {
                        PlaceholderView(text: L10n.string("surface.placeholder.none_selected", defaultValue: "No surface selected"))
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        ConnectionPhasePill(phase: connection.snapshot.connectionPhase)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        NotificationsToolbar(count: connection.snapshot.unreadNotifications)
                    }
                }
            } else {
                HostListView()
            }
        }
        .alert(
            L10n.string("host.key.trust.title", defaultValue: "Verify Host Key"),
            isPresented: Binding(
                get: { connection.pendingHostKeyTrust != nil },
                set: { isPresented in
                    if !isPresented {
                        connection.rejectPendingHostKeyTrust()
                    }
                }
            )
        ) {
            Button(
                L10n.string("host.key.trust.accept", defaultValue: "Trust Host")
            ) {
                connection.acceptPendingHostKeyTrust()
            }
            Button(
                L10n.string("host.key.trust.reject", defaultValue: "Do Not Trust"),
                role: .cancel
            ) {
                connection.rejectPendingHostKeyTrust()
            }
        } message: {
            if let pending = connection.pendingHostKeyTrust {
                Text(hostKeyTrustMessage(pending))
            } else {
                Text("")
            }
        }
    }

    private func hostKeyTrustMessage(_ pending: PendingHostKeyTrust) -> String {
        L10n.format(
            "host.key.trust.message",
            defaultValue: """
            Trust %@@%@:%lld for %@?

            Fingerprint:
            %@

            Compare with this on the Mac:
            ssh-keygen -E sha256 -lf /etc/ssh/ssh_host_*.pub

            Continue only if one SHA256 fingerprint matches exactly.
            """,
            pending.username,
            pending.hostname,
            Int64(pending.port),
            pending.label,
            pending.fingerprint
        )
    }
}

private struct EmptyStateView: View {
    @State private var showAdd = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text(L10n.string("empty.hosts.title", defaultValue: "Connect to a cmux host"))
                .font(.title2.weight(.semibold))
            Text(L10n.string(
                "empty.hosts.description",
                defaultValue: "Add the Mac where cmux is running and we'll sign in over SSH."
            ))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                showAdd = true
            } label: {
                Label(L10n.string("host.action.add_mac", defaultValue: "Add Mac"), systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        .sheet(isPresented: $showAdd) {
            HostAddView()
        }
    }
}

private struct PlaceholderView: View {
    let text: String

    var body: some View {
        VStack {
            Text(text)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}

private struct ConnectionPhasePill: View {
    let phase: ServerState.ConnectionPhase

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(.thinMaterial))
    }

    private var color: Color {
        switch phase {
        case .live: return .green
        case .syncing, .connecting, .authenticating: return .yellow
        case .disconnected: return .red
        }
    }

    private var label: String {
        switch phase {
        case .live: return L10n.string("connection.phase.live", defaultValue: "Live")
        case .syncing: return L10n.string("connection.phase.syncing", defaultValue: "Syncing")
        case .connecting: return L10n.string("connection.phase.connecting", defaultValue: "Connecting")
        case .authenticating: return L10n.string("connection.phase.authenticating", defaultValue: "Authenticating")
        case .disconnected(let err): return err == nil
            ? L10n.string("connection.phase.offline", defaultValue: "Offline")
            : L10n.string("connection.phase.error", defaultValue: "Error")
        }
    }
}

private struct NotificationsToolbar: View {
    let count: Int
    @State private var showList = false

    var body: some View {
        Button {
            showList = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bell")
                if count > 0 {
                    Text(count > 99 ? "99+" : "\(count)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.red, in: Capsule())
                        .foregroundStyle(.white)
                        .offset(x: 10, y: -6)
                }
            }
        }
        .accessibilityLabel(L10n.string("notifications.toolbar.label", defaultValue: "Notifications"))
        .accessibilityValue(L10n.format("notifications.toolbar.count", defaultValue: "%lld unread", Int64(count)))
        .sheet(isPresented: $showList) {
            NotificationsListView()
        }
    }
}
