import CNMProtocol
import SwiftUI

/// The drawer: search and new chat on top, places, agent chats grouped by
/// recency (attention first), and the account row at the bottom.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(ShellState.self) private var shell
    @State private var query = ""
    @FocusState private var searching: Bool

    private struct Row: Identifiable, Hashable {
        var id: String { host + "/" + info.id }
        let host: String
        let hostName: String
        let info: AgentSessionInfo
    }

    private var rows: [Row] {
        model.hosts.flatMap { host in
            host.agents.filter { !$0.archived }.map { Row(host: host.id, hostName: host.name, info: $0) }
        }
        .filter { query.isEmpty || $0.info.title.localizedCaseInsensitiveContains(query) || $0.info.cwd.localizedCaseInsensitiveContains(query) }
        .sorted { $0.info.updatedAt > $1.info.updatedAt }
    }

    private var sections: [(String, [Row])] {
        let calendar = Calendar.current
        var attention: [Row] = []
        var today: [Row] = []
        var yesterday: [Row] = []
        var week: [Row] = []
        var older: [Row] = []
        for row in rows {
            if row.info.state == .awaitingPermission { attention.append(row); continue }
            let date = row.info.updatedAt
            if calendar.isDateInToday(date) { today.append(row) }
            else if calendar.isDateInYesterday(date) { yesterday.append(row) }
            else if date > .now.addingTimeInterval(-7 * 86400) { week.append(row) }
            else { older.append(row) }
        }
        return [
            (String(localized: "Needs you"), attention), (String(localized: "Today"), today),
            (String(localized: "Yesterday"), yesterday), (String(localized: "Previous 7 days"), week),
            (String(localized: "Older"), older),
        ].filter { !$0.1.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    place("Home", symbol: "bubble.left.and.bubble.right", destination: .home, badge: unreadCount)
                        .accessibilityIdentifier("sidebar.home")
                    place("Terminals", symbol: "apple.terminal", destination: .terminals, badge: 0)
                        .accessibilityIdentifier("sidebar.terminals")
                    place("Macs", symbol: "laptopcomputer", destination: .macs, badge: 0, trailing: macStatus)
                        .accessibilityIdentifier("sidebar.macs")

                    ForEach(sections, id: \.0) { title, rows in
                        Text(title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 22)
                            .padding(.bottom, 6)
                        ForEach(rows) { row in agentRow(row) }
                    }

                    if rows.isEmpty, model.hostsLoaded {
                        Text(query.isEmpty ? "Agent chats you start show up here." : "No chats match “\(query)”.")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.top, 24)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.immediately)
            profileRow
        }
        .background(Color(.systemBackground))
    }

    private var unreadCount: Int {
        model.hosts.reduce(0) { $0 + $1.conversations.reduce(0) { $0 + $1.unreadCount } }
    }

    private var macStatus: AnyView {
        let connected = model.hosts.filter(\.status.isConnected).count
        return AnyView(
            Circle()
                .fill(connected > 0 ? CmuxTheme.success : Color(.tertiaryLabel))
                .frame(width: 7, height: 7)
                .opacity(model.hosts.isEmpty ? 0 : 1)
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $query)
                    .focused($searching)
                    .submitLabel(.search)
                    .accessibilityIdentifier("sidebar.search")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Color(.secondarySystemFill), in: .capsule)

            Button {
                shell.go(.newAgent)
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New agent chat")
            .accessibilityIdentifier("sidebar.new")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func place(_ title: LocalizedStringKey, symbol: String, destination: Destination, badge: Int, trailing: AnyView? = nil) -> some View {
        let selected = shell.destination == destination
        return Button {
            searching = false
            shell.go(destination)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .frame(width: 24)
                Text(title).font(.system(size: 17, weight: selected ? .semibold : .regular))
                Spacer()
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(CmuxTheme.highlight, in: .capsule)
                }
                trailing
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(selected ? Color(.secondarySystemFill) : .clear, in: .rect(cornerRadius: 12, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func agentRow(_ row: Row) -> some View {
        let selected = shell.destination == .agent(host: row.host, session: row.info.id)
        return Button {
            searching = false
            shell.go(.agent(host: row.host, session: row.info.id))
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.info.title)
                        .font(.system(size: 16, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                    Text("\((row.info.cwd as NSString).lastPathComponent) · \(row.hostName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                AgentStateDot(state: row.info.state)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(selected ? Color(.secondarySystemFill) : .clear, in: .rect(cornerRadius: 12, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                model.host(row.host)?.archiveAgent(row.info.id)
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
        }
    }

    private var profileRow: some View {
        Button {
            shell.showSettings = true
        } label: {
            HStack(spacing: 12) {
                Avatar(name: model.user?.displayName ?? model.user?.email ?? "?", size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.user?.displayName ?? model.user?.email ?? "")
                        .font(.system(size: 16, weight: .medium))
                        .lineLimit(1)
                    if model.user?.displayName != nil, let email = model.user?.email {
                        Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar.profile")
    }
}

struct AgentStateDot: View {
    let state: AgentSessionInfo.State
    @State private var pulse = false

    var body: some View {
        switch state {
        case .working, .starting:
            Circle()
                .fill(CmuxTheme.highlight)
                .frame(width: 8, height: 8)
                .opacity(pulse ? 0.35 : 1)
                .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true } }
                .accessibilityLabel("Working")
        case .awaitingPermission:
            Circle().fill(Color.orange).frame(width: 8, height: 8).accessibilityLabel("Needs approval")
        case .failed:
            Circle().fill(CmuxTheme.danger).frame(width: 8, height: 8).accessibilityLabel("Failed")
        default:
            EmptyView()
        }
    }
}

struct Avatar: View {
    let name: String
    var size: CGFloat = 40

    var body: some View {
        let initial = name.first.map { String($0).uppercased() } ?? "?"
        Circle()
            .fill(LinearGradient(colors: [Color(hex: 0xA5A9B4), Color(hex: 0x858994)], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay {
                Text(initial)
                    .font(.system(size: size * 0.45, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
            }
    }
}
