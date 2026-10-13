#if os(iOS)
import CnxDesign
import CnxModel
import SwiftUI

/// Leading toolbar item every root tab shares: the hamburger that opens the team sidebar.
struct SidebarToolbarItem: ToolbarContent {
    let openSidebar: () -> Void
    @Environment(AppStore.self) private var store

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(action: openSidebar) {
                if let team = store.activeTeam {
                    TeamAvatar(name: team.name, colorHex: team.appearance.colorHex, emoji: team.appearance.emoji, size: 26)
                } else {
                    Image(systemName: "line.3.horizontal")
                }
            }
            .accessibilityLabel("Teams")
        }
    }
}

struct HomeScreen: View {
    let openSidebar: () -> Void
    @Environment(AppStore.self) private var store

    var body: some View {
        NavigationStack {
            List {
                ConversationRow(title: "Chief", preview: "Two agents need you. The transport PR is ready for review.", time: "now", isChief: true)
                ForEach(store.workspaces) { ws in
                    if let tab = ws.tabs.first(where: { $0.kind == .agent }) {
                        ConversationRow(title: "\(tab.title) · \(ws.title)", preview: tab.subtitle ?? "", time: ws.lastActivityAt.formatted(.relative(presentation: .numeric)), isChief: false)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Home")
            .toolbar {
                SidebarToolbarItem(openSidebar: openSidebar)
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New conversation", systemImage: "square.and.pencil") {}
                }
            }
        }
    }
}

struct ConversationRow: View {
    let title: String
    let preview: String
    let time: String
    let isChief: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(isChief ? AnyShapeStyle(Color.primary.gradient) : AnyShapeStyle(Color.secondary.opacity(0.35).gradient))
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: isChief ? "sparkles" : "sparkle")
                        .foregroundStyle(isChief ? Color(uiColor: .systemBackground) : .primary)
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.body.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Text(time).font(.subheadline).foregroundStyle(.secondary)
                }
                Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

struct WorkspacesScreen: View {
    let openSidebar: () -> Void
    @Environment(AppStore.self) private var store

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.activeTeam?.macs ?? []) { mac in
                    let items = store.workspaces.filter { $0.macID == mac.id }
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { ws in
                                NavigationLink(value: ws) { WorkspaceRow(workspace: ws) }
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Circle().fill(mac.isOnline ? CnxTheme.standard.palette.online : CnxTheme.standard.palette.offline).frame(width: 7, height: 7)
                                Text(mac.name)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Workspaces")
            .navigationDestination(for: Workspace.self) { ws in
                WorkspaceDetailPlaceholder(workspace: ws)
            }
            .toolbar { SidebarToolbarItem(openSidebar: openSidebar) }
        }
    }
}

struct WorkspaceRow: View {
    let workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(workspace.title).font(.body.weight(.semibold))
                if workspace.needsAttention {
                    Circle().fill(CnxTheme.standard.palette.attention).frame(width: 8, height: 8)
                        .accessibilityLabel("Needs attention")
                }
                Spacer()
                Text(workspace.lastActivityAt, format: .relative(presentation: .numeric))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if let branch = workspace.branch {
                    Label(branch, systemImage: "arrow.triangle.branch").labelStyle(.titleAndIcon)
                }
                Text("\(workspace.tabs.count) tabs")
            }
            .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// Stand-in until CmuxTabsKit hosts the real tab content.
struct WorkspaceDetailPlaceholder: View {
    let workspace: Workspace
    @Environment(AppStore.self) private var store

    var body: some View {
        let tab = store.openingTab(for: workspace)
        ContentUnavailableView(tab?.title ?? workspace.title, systemImage: tab?.systemImage ?? "square.stack", description: Text(tab?.subtitle ?? ""))
            .navigationTitle(workspace.title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct FeedScreen: View {
    let openSidebar: () -> Void
    @Environment(AppStore.self) private var store

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.feed) { event in
                        FeedRowPlaceholder(event: event)
                        Divider()
                    }
                }
            }
            .navigationTitle("Feed")
            .toolbar { SidebarToolbarItem(openSidebar: openSidebar) }
        }
    }
}

struct FeedRowPlaceholder: View {
    let event: FeedEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(event.agentName).font(.subheadline.weight(.semibold))
                Text(event.createdAt, format: .relative(presentation: .numeric)).font(.subheadline).foregroundStyle(.secondary)
            }
            if let quote = event.quotedPrompt {
                Text(quote)
                    .font(.subheadline)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color(uiColor: .systemBlue), in: .rect(cornerRadius: 17, style: .continuous))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            Text((try? AttributedString(markdown: event.markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(event.markdown))
                .font(.body)
                .lineLimit(8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

struct SettingsScreen: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    Label("Signed in", systemImage: "person.crop.circle")
                }
                Section("Connection") {
                    Picker(selection: .constant(0)) {
                        Text("WebRTC").tag(0)
                        Text("WireGuard").tag(1)
                    } label: {
                        Label("Transport", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                }
                Section {
                    Button("Log out", role: .destructive) {}
                }
            }
            .navigationTitle("Settings")
        }
    }
}
#endif
