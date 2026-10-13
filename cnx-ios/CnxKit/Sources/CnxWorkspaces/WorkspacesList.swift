#if os(iOS)
import CnxDesign
import CnxModel
import SwiftUI

private let theme = CnxTheme.standard

/// SPEC 11.1: the Workspaces tab's content. One plain section per Mac
/// (presence dot, name, "Online" / "Last seen"), workspace rows with icon,
/// branch, tab count, relative time and status. Rows push `Workspace`
/// values; the enclosing NavigationStack maps them to `WorkspaceScreen`.
/// Loading, failure and the empty states come first.
public struct WorkspacesList: View {
    let store: AppStore
    let creator: WorkspaceCreator
    /// Pushes a workspace (the new one, right after a tap).
    let open: (Workspace) -> Void
    /// The signed-in account, for "sign in as …" in the empty state.
    var accountEmail: String?
    /// Redials a Mac (live only; the header menu hides it otherwise).
    var reconnect: ((String) -> Void)?
    /// Pull to refresh (live only).
    var refresh: (() async -> Void)?
    @AppStorage("cnx.workspaces.sort") private var sort: WorkspaceSort = .recent
    @AppStorage("cnx.workspaces.showOffline") private var showsOffline = true
    @State private var isRetrying = false

    public init(store: AppStore, creator: WorkspaceCreator, accountEmail: String? = nil,
                reconnect: ((String) -> Void)? = nil, refresh: (() async -> Void)? = nil,
                open: @escaping (Workspace) -> Void) {
        self.store = store
        self.creator = creator
        self.accountEmail = accountEmail
        self.reconnect = reconnect
        self.refresh = refresh
        self.open = open
    }

    public var body: some View {
        content
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NewWorkspaceButton(creator: creator, create: create)
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(WorkspaceSort.allCases) { Text($0.title).tag($0) }
                        }
                        Toggle("Show Offline Macs", systemImage: "moon.zzz", isOn: $showsOffline)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More")
                }
            }
    }

    /// Creates a workspace and pushes it at once; the row is optimistic
    /// until the Mac confirms (ShellModel handles a refusal).
    private func create(_ start: NewWorkspaceStart, directory: String?) {
        guard let workspace = creator.create(start: start, directory: directory) else {
            theme.haptics.warning()
            return
        }
        theme.haptics.impactLight()
        open(workspace)
    }

    @ViewBuilder private var content: some View {
        let macs = store.activeTeam?.macs ?? []
        switch store.teamDataState {
        case .loading:
            ScrollView { SkeletonList(rows: 6, leadingSquare: 36).padding(.top, 8) }
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
                ConnectMacEmptyState(email: accountEmail)
            } else if !macs.contains(where: \.isOnline) && !showsOffline {
                EmptyState(
                    symbol: "moon.zzz",
                    title: "Your Macs are asleep",
                    message: "Wake a Mac or open cmux on it to see its workspaces.",
                    secondaryTitle: "Show offline Macs", secondary: { showsOffline = true }
                )
            } else {
                list(macs: macs.filter { showsOffline || $0.isOnline })
            }
        }
    }

    private func list(macs: [MacDevice]) -> some View {
        let stamp = RelativeStamp()
        // Online Macs first, keeping the team's order inside each group.
        let ordered = macs.filter(\.isOnline) + macs.filter { !$0.isOnline }
        return List {
            ForEach(ordered) { mac in
                let items = sort.ordered(store.workspaces.filter { $0.macID == mac.id })
                Section {
                    if items.isEmpty {
                        Text(mac.isOnline ? "No workspaces" : "Offline")
                            .font(theme.type.rowSubtitle)
                            .foregroundStyle(theme.colors.label2)
                            .listRowBackground(theme.colors.bg.color)
                    }
                    ForEach(items) { ws in
                        NavigationLink(value: ws) {
                            WorkspaceRow(workspace: ws, stamp: stamp.string(for: ws.lastActivityAt), dimmed: !mac.isOnline,
                                         isPending: store.isPending(ws.id))
                        }
                        .listRowBackground(theme.colors.bg.color)
                        .listRowInsets(EdgeInsets(top: 0, leading: theme.metrics.sideMargin, bottom: 0, trailing: 16))
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 48 }
                    }
                } header: {
                    MacSectionHeader(mac: mac, presence: stamp.presence(isOnline: mac.isOnline, lastSeenAt: mac.lastSeenAt),
                                     link: store.macLinkStatus[mac.id],
                                     reconnect: reconnect.map { reconnect in { reconnect(mac.id) } })
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .modifier(OptionalRefresh(refresh: refresh))
        .animation(theme.motion.smooth.animation, value: sort)
        .animation(theme.motion.smooth.animation, value: showsOffline)
        .animation(theme.motion.smooth.animation, value: store.workspaces.map(\.id))
    }

    private func retry() {
        isRetrying = true
        Task {
            await Task.yield()
            store.teamDataState = .loaded
            isRetrying = false
        }
    }
}

/// Pull to refresh only where it does something.
private struct OptionalRefresh: ViewModifier {
    let refresh: (() async -> Void)?

    func body(content: Content) -> some View {
        if let refresh {
            content.refreshable { await refresh() }
        } else {
            content
        }
    }
}

/// No Mac yet. Pairing is account based: a Mac signed in to the same account
/// and team, with iPhone connections allowed, appears by itself, and
/// presence swaps this state for the list.
struct ConnectMacEmptyState: View {
    let email: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 28))
                    .foregroundStyle(theme.colors.label)
                    .accessibilityHidden(true)
                Text("Connect your Mac")
                    .font(theme.type.emptyTitle)
                    .foregroundStyle(theme.colors.label)
                    .padding(.top, 16)
                    .padding(.bottom, 20)
                ConnectMacSteps(email: email, onlineMac: nil)
            }
            .padding(.horizontal, theme.metrics.sideMargin)
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical) { height, _ in height * 0.8 }
        }
        .accessibilityIdentifier("workspaces.connect-mac")
    }
}

/// The New Workspace toolbar button. A tap creates a workspace at once with
/// the defaults (the preferred or only Mac, its last-used directory or home,
/// the Mac's default first tab: a terminal). Holding it opens a menu of the
/// other ways to start, as Safari's new-tab button and Notes' compose button
/// do. Only options the Mac's backend supports are listed.
struct NewWorkspaceButton: View {
    let creator: WorkspaceCreator
    let create: (NewWorkspaceStart, String?) -> Void

    var body: some View {
        Menu {
            menu
        } label: {
            Label("New Workspace", systemImage: "square.and.pencil")
        } primaryAction: {
            create(.terminal, nil)
        }
        .disabled(creator.targetMac == nil)
        .accessibilityIdentifier("workspaces.new")
    }

    @ViewBuilder private var menu: some View {
        if let mac = creator.targetMac {
            let options = creator.options(on: mac.id)
            let macs = creator.availableMacs
            if macs.count > 1 {
                Section("On \(mac.name)") { starts(options) }
            } else {
                Section { starts(options) }
            }
            let recents = creator.recentDirectories(on: mac.id)
            if !recents.isEmpty {
                Section("Recent Directories") {
                    ForEach(recents, id: \.self) { directory in
                        Button {
                            create(.terminal, directory)
                        } label: {
                            Label {
                                Text(Self.folderName(directory))
                                Text(directory)
                            } icon: {
                                Image(systemName: "folder")
                            }
                        }
                    }
                }
            }
            if macs.count > 1 {
                Section {
                    Picker(selection: Binding(get: { mac.id }, set: { creator.prefer(macID: $0) })) {
                        ForEach(macs) { Text($0.name).tag($0.id) }
                    } label: {
                        Label("Mac", systemImage: "desktopcomputer")
                    }
                    .pickerStyle(.menu)
                }
            }
        }
    }

    @ViewBuilder private func starts(_ options: WorkspaceCreationOptions) -> some View {
        Button("New Workspace", systemImage: "apple.terminal") { create(.terminal, nil) }
        ForEach(options.agents, id: \.self) { harness in
            Button("New \(Self.agentName(harness)) Workspace", systemImage: "sparkle") { create(.agent(harness), nil) }
        }
        if options.browser {
            Button("New Browser Workspace", systemImage: "globe") { create(.browser, nil) }
        }
    }

    static func agentName(_ harness: String) -> String {
        switch harness {
        case "claude": "Claude"
        case "codex": "Codex"
        default: harness.prefix(1).uppercased() + harness.dropFirst()
        }
    }

    static func folderName(_ directory: String) -> String {
        directory == "~" ? "Home" : (directory as NSString).lastPathComponent
    }
}

/// Section header: 44 pt, presence dot, Mac name, "Online" / "Last seen …",
/// trailing More menu.
struct MacSectionHeader: View {
    let mac: MacDevice
    let presence: String
    /// The live link line for this Mac, when the app dials it.
    var link: String?
    /// Redials this Mac; nil hides the menu (nothing else in it works yet).
    var reconnect: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if let link {
                Text(link)
                    .font(theme.type.meta)
                    .foregroundStyle(theme.colors.label2)
                    .lineLimit(2)
                    .padding(.leading, 15)
                    .padding(.bottom, 6)
                    .contentTransition(.opacity)
                    .accessibilityIdentifier("mac-link-status")
            }
        }
        .textCase(nil)
        .animation(theme.motion.snappy.animation, value: link)
    }

    private var row: some View {
        HStack(spacing: 8) {
            StatusDot(mac.isOnline ? .online : .offline, size: 7)
            Text(mac.name)
                .font(theme.type.rowSubtitle.weight(.semibold))
                .foregroundStyle(theme.colors.label)
            Text(presence)
                .font(theme.type.meta)
                .foregroundStyle(theme.colors.label2)
            Spacer(minLength: 0)
            if let reconnect, mac.isOnline {
                Menu {
                    Button("Reconnect", systemImage: "arrow.clockwise", action: reconnect)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.colors.label2)
                        .frame(width: 32, height: 32)
                        .contentShape(.rect)
                }
                .accessibilityLabel("\(mac.name) options")
            }
        }
        .textCase(nil)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

/// SPEC 11.1 workspace row (64 pt).
struct WorkspaceRow: View {
    let workspace: Workspace
    let stamp: String
    var dimmed = false
    /// Being created on the Mac (optimistic row).
    var isPending = false

    var body: some View {
        HStack(spacing: 12) {
            WorkspaceIcon(workspace: workspace)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if workspace.hasUnread {
                        Circle().fill(theme.colors.label.color).frame(width: 8, height: 8)
                            .accessibilityLabel("Unread")
                    }
                    Text(workspace.title).font(theme.type.rowTitle.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(stamp).font(theme.type.meta).foregroundStyle(theme.colors.label2)
                }
                HStack(spacing: 6) {
                    subtitle
                        .font(theme.type.meta)
                        .foregroundStyle(theme.colors.label2)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    status
                }
            }
        }
        .frame(minHeight: 64)
        .opacity(dimmed ? 0.55 : 1)
        .contentShape(.rect)
    }

    private var subtitle: Text {
        if isPending { return Text("Creating…") }
        let tabs = workspace.tabs.count == 1 ? "1 tab" : "\(workspace.tabs.count) tabs"
        if let branch = workspace.branch {
            return Text("\(Text(branch).monospaced()) · \(tabs)")
        }
        return Text(tabs)
    }

    @ViewBuilder private var status: some View {
        if isPending {
            ProgressView().controlSize(.mini)
                .frame(width: 12, height: 12)
                .accessibilityLabel("Creating")
        } else if workspace.needsAttention {
            HStack(spacing: 5) {
                Circle().fill(theme.colors.warning.color).frame(width: 6, height: 6)
                Text("Needs you").font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(theme.colors.fill.color, in: .capsule)
        } else if workspace.isWorking {
            ProgressView().controlSize(.mini)
                .frame(width: 12, height: 12)
                .accessibilityLabel("Working")
        }
    }
}

/// 36 pt rounded square with the workspace's icon in its color.
struct WorkspaceIcon: View {
    let workspace: Workspace

    var body: some View {
        let tint = workspace.colorHex.map { theme.colors.team($0).color } ?? theme.colors.label2.color
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint.opacity(0.18))
            if let icon = workspace.icon, icon.unicodeScalars.first?.properties.isEmojiPresentation == true {
                Text(icon).font(.system(size: 18))
            } else {
                Image(systemName: workspace.icon ?? "folder")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 36, height: 36)
        .accessibilityHidden(true)
    }
}

#endif
