#if os(iOS)
import CnxDesign
import CnxModel
import SwiftUI

private let theme = CnxTheme.standard

/// Leading toolbar item every root tab shares: the glass `line.3.horizontal`
/// circle that opens the team sidebar.
struct SidebarToolbarItem: ToolbarContent {
    let sidebar: SidebarModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Teams", systemImage: "line.3.horizontal") { sidebar.open() }
                .accessibilityLabel("Teams")
        }
    }
}

/// Centered toolbar title in `screenTitle`.
struct ScreenTitle: ToolbarContent {
    let title: LocalizedStringKey

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text(title).font(theme.type.screenTitle).foregroundStyle(theme.colors.label)
        }
    }
}

struct HomeScreen: View {
    let shell: ShellModel

    var body: some View {
        @Bindable var shell = shell
        NavigationStack(path: $shell.homePath) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(shell.store.activeWorkspaces) { ws in
                        if let tab = ws.tabs.first(where: { $0.kind == .agent }) {
                            ConversationRow(title: "\(tab.title) · \(ws.title)", preview: tab.subtitle ?? "", date: ws.lastActivityAt)
                        }
                    }
                }
                .padding(.top, 8)
            }
            .overlay {
                if shell.store.activeWorkspaces.isEmpty {
                    EmptyState(symbol: "sparkles", title: "Ask Chief", message: "Chief runs your agents across every Mac in this team.")
                }
            }
            .background(theme.colors.bg.color.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                SidebarToolbarItem(sidebar: shell.sidebar)
                ScreenTitle(title: "Chief")
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
    let date: Date

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkle")
                .font(.system(size: 17))
                .foregroundStyle(theme.colors.label)
                .frame(width: 40, height: 40)
                .background(theme.colors.surfaceRaised, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(theme.type.rowTitle.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Text(date, format: .relative(presentation: .numeric)).font(theme.type.meta).foregroundStyle(theme.colors.label2)
                }
                Text(preview).font(theme.type.rowSubtitle).foregroundStyle(theme.colors.label2).lineLimit(2)
            }
        }
        .padding(.horizontal, theme.metrics.sideMargin)
        .padding(.vertical, 10)
    }
}

struct WorkspacesScreen: View {
    let shell: ShellModel
    @State private var showsOffline = false
    @State private var isRetrying = false

    private var store: AppStore { shell.store }

    var body: some View {
        @Bindable var shell = shell
        NavigationStack(path: $shell.workspacesPath) {
            content
                .background(theme.colors.bg.color.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: Workspace.self) { ws in
                    WorkspaceDetailPlaceholder(workspace: ws, store: store)
                }
                .toolbar {
                    SidebarToolbarItem(sidebar: shell.sidebar)
                    ScreenTitle(title: "Workspaces")
                }
                .cnxBanner(store.isOffline ? .offline : nil)
        }
    }

    @ViewBuilder private var content: some View {
        let macs = store.activeTeam?.macs ?? []
        switch store.teamDataState {
        case .loading:
            ScrollView { SkeletonList(rows: 6).padding(.top, 8) }
                .scrollDisabled(true)
        case .failed:
            EmptyState(
                symbol: "cloud",
                title: "Couldn't load workspaces",
                message: "Check your connection and try again.",
                primaryTitle: "Retry",
                isPrimaryLoading: isRetrying,
                primary: retry
            )
        case .loaded:
            if macs.isEmpty {
                EmptyState(
                    symbol: "desktopcomputer",
                    title: "Connect your Mac",
                    message: "Open cmux on your Mac and choose Pair iPhone to get a code.",
                    primaryTitle: "Scan QR code", primary: {},
                    secondaryTitle: "Enter code manually", secondary: {}
                )
            } else if !macs.contains(where: \.isOnline) && !showsOffline {
                EmptyState(
                    symbol: "moon.zzz",
                    title: "Your Macs are asleep",
                    message: "Wake a Mac or open cmux on it to see its workspaces.",
                    secondaryTitle: "Show offline Macs", secondary: { showsOffline = true }
                )
            } else {
                list(macs: macs)
            }
        }
    }

    private func list(macs: [MacDevice]) -> some View {
        List {
            ForEach(macs) { mac in
                let items = store.workspaces.filter { $0.macID == mac.id }
                Section {
                    if items.isEmpty {
                        Text(mac.isOnline ? "No workspaces" : "Offline")
                            .font(theme.type.rowSubtitle)
                            .foregroundStyle(theme.colors.label2)
                    }
                    ForEach(items) { ws in
                        NavigationLink(value: ws) { WorkspaceRow(workspace: ws) }
                            .listRowBackground(theme.colors.bg.color)
                    }
                } header: {
                    HStack(spacing: 8) {
                        StatusDot(mac.isOnline ? .online : .offline, size: 7)
                        Text(mac.name)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text("\(mac.name), \(mac.isOnline ? "online" : "offline")"))
                }
                .listRowBackground(theme.colors.bg.color)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {}
    }

    private func retry() {
        isRetrying = true
        Task {
            // Mock source: the next team snapshot is local, so the retry resolves
            // on the next main-actor turn.
            await Task.yield()
            store.teamDataState = .loaded
            isRetrying = false
        }
    }
}

struct WorkspaceRow: View {
    let workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(workspace.title).font(theme.type.rowTitle.weight(.semibold)).lineLimit(1)
                if workspace.needsAttention {
                    StatusDot(.busy)
                        .accessibilityLabel("Needs attention")
                }
                Spacer()
                Text(workspace.lastActivityAt, format: .relative(presentation: .numeric))
                    .font(theme.type.meta).foregroundStyle(theme.colors.label2)
            }
            HStack(spacing: 6) {
                if let branch = workspace.branch {
                    Label(branch, systemImage: "arrow.triangle.branch").labelStyle(.titleAndIcon)
                }
                Text(workspace.tabs.count == 1 ? "1 tab" : "\(workspace.tabs.count) tabs")
            }
            .font(theme.type.meta).foregroundStyle(theme.colors.label2)
        }
        .frame(minHeight: 44)
    }
}

/// Stand-in until CmuxTabsKit hosts the real tab content.
struct WorkspaceDetailPlaceholder: View {
    let workspace: Workspace
    let store: AppStore

    var body: some View {
        let tab = store.openingTab(for: workspace)
        EmptyState(symbol: tab?.systemImage ?? "square.stack", title: LocalizedStringKey(tab?.title ?? workspace.title), message: LocalizedStringKey(tab?.subtitle ?? ""))
            .background(theme.colors.bg.color.ignoresSafeArea())
            .navigationTitle(workspace.title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct FeedScreen: View {
    let shell: ShellModel

    var body: some View {
        @Bindable var shell = shell
        NavigationStack(path: $shell.feedPath) {
            Group {
                if shell.store.feed.isEmpty {
                    EmptyState(symbol: "bubble.left.and.text.bubble.right", title: "Nothing yet", message: "Agent updates, questions and finished tasks show up here.")
                } else {
                    List {
                        ForEach(shell.store.feed) { event in
                            FeedRowPlaceholder(event: event)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(theme.colors.bg.color)
                                .listRowSeparatorTint(theme.colors.separator.color)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(theme.colors.bg.color.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                SidebarToolbarItem(sidebar: shell.sidebar)
                ScreenTitle(title: "Feed")
            }
        }
    }
}

/// Placeholder cell until `CnxFeed` lands; already on tokens (gray quote bubble).
struct FeedRowPlaceholder: View {
    let event: FeedEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(event.agentName).font(theme.type.rowSubtitle.weight(.semibold))
                Text("·").foregroundStyle(theme.colors.label2)
                Text(event.createdAt, format: .relative(presentation: .numeric)).font(theme.type.rowSubtitle).foregroundStyle(theme.colors.label2)
            }
            if let quote = event.quotedPrompt {
                Text(quote)
                    .font(theme.type.rowSubtitle)
                    .foregroundStyle(theme.colors.label2)
                    .lineLimit(3)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(theme.colors.bubble, in: .rect(cornerRadius: 16, style: .continuous))
            }
            Text((try? AttributedString(markdown: event.markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(event.markdown))
                .font(theme.type.body)
                .lineLimit(8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
#endif
