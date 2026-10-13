#if os(iOS)
import CnxDesign
import CnxModel
import SwiftUI

private let theme = CnxTheme.standard

/// SPEC 11.1: the Workspaces tab's content.
///
/// The navigation title is the Mac filter ("All Macs ⌄" or one Mac's name),
/// a title menu as in Mail's mailbox title and the Codex title menu. All
/// Macs groups rows under sticky per-Mac headers; one Mac shows a flat list.
/// The choice is remembered per team (`MacFilter`). New Workspace targets
/// the filtered Mac. Rows push `Workspace` values; the enclosing
/// NavigationStack maps them to `WorkspaceScreen`.
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
    /// Moves to another team (the empty state offers the team where a Mac is).
    var switchTeam: ((String) -> Void)?
    /// Opens Settings → Account (the empty state, when no Mac uses this account).
    var openAccount: (() -> Void)?
    @AppStorage("cnx.workspaces.sort") private var sort: WorkspaceSort = .recent
    @AppStorage("cnx.workspaces.showOffline") private var showsOffline = true
    @State private var filter: MacFilter
    @State private var isRetrying = false

    public init(store: AppStore, creator: WorkspaceCreator, accountEmail: String? = nil,
                reconnect: ((String) -> Void)? = nil, refresh: (() async -> Void)? = nil,
                switchTeam: ((String) -> Void)? = nil, openAccount: (() -> Void)? = nil,
                filter: MacFilter = MacFilter(),
                open: @escaping (Workspace) -> Void) {
        self.store = store
        self.creator = creator
        self.accountEmail = accountEmail
        self.reconnect = reconnect
        self.refresh = refresh
        self.switchTeam = switchTeam
        self.openAccount = openAccount
        _filter = State(initialValue: filter)
        self.open = open
    }

    private var macs: [MacDevice] { store.activeTeam?.macs ?? [] }
    private var scope: MacScope { filter.scope(in: store.activeTeam) }
    private var scopedMac: MacDevice? { scope.macID.flatMap { id in macs.first { $0.id == id } } }
    private var target: MacDevice? {
        scope.newWorkspaceMac(available: creator.availableMacs, fallback: creator.targetMac)
    }

    public var body: some View {
        content
            .navigationTitle(macs.isEmpty ? "Workspaces" : scope.title(macs: macs))
            .navigationSubtitle(subtitle)
            .toolbarTitleMenu { if !macs.isEmpty { titleMenu } }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NewWorkspaceButton(creator: creator, target: target, showsMacPicker: scope == .all) { start, directory in
                        create(start, directory: directory, on: target?.id)
                    }
                    moreMenu
                }
            }
    }

    /// Under the title: how many Macs are online, or the chosen Mac's presence.
    private var subtitle: String {
        guard !macs.isEmpty, store.teamDataState == .loaded else { return "" }
        if let mac = scopedMac {
            return RelativeStamp().presence(isOnline: mac.isOnline, lastSeenAt: mac.lastSeenAt)
        }
        let online = macs.count(where: \.isOnline)
        return online == macs.count ? (macs.count == 1 ? "Online" : "\(online) Macs online") : "\(online) of \(macs.count) Macs online"
    }

    private var scopeBinding: Binding<MacScope> {
        Binding(get: { scope }, set: { newValue in
            guard let team = store.activeTeam else { return }
            theme.haptics.selection()
            withAnimation(theme.motion.smooth.animation) { filter.select(newValue, in: team.id) }
        })
    }

    /// The title menu: All Macs, then each Mac with its presence. Online Macs
    /// first, as in the list. Toggles rather than a Picker so each row keeps
    /// its subtitle ("Online · 2 workspaces", "Last seen 2h ago") and the
    /// Macs get their own section.
    @ViewBuilder private var titleMenu: some View {
        let stamp = RelativeStamp()
        Section {
            Toggle(isOn: selects(.all)) {
                Image(systemName: "square.stack")
                Text("All Macs")
                Text(Self.count(store.workspaces.count(where: { ws in macs.contains { $0.id == ws.macID } })))
            }
        }
        Section("Macs") {
            ForEach(macs.filter(\.isOnline) + macs.filter { !$0.isOnline }) { mac in
                Toggle(isOn: selects(.mac(mac.id))) {
                    Image(systemName: mac.isOnline ? "circle.fill" : "circle")
                    Text(mac.name)
                    Text(mac.isOnline
                         ? "Online · \(Self.count(store.workspaces.count(where: { $0.macID == mac.id })))"
                         : stamp.presence(isOnline: false, lastSeenAt: mac.lastSeenAt))
                }
            }
        }
    }

    private func selects(_ value: MacScope) -> Binding<Bool> {
        Binding(get: { scope == value }, set: { on in if on { scopeBinding.wrappedValue = value } })
    }

    static func count(_ n: Int) -> String { n == 0 ? "No workspaces" : n == 1 ? "1 workspace" : "\(n) workspaces" }

    private var moreMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(WorkspaceSort.allCases) { Text($0.title).tag($0) }
            }
            if scope == .all {
                Toggle("Show Offline Macs", systemImage: "moon.zzz", isOn: $showsOffline)
            } else if let mac = scopedMac, mac.isOnline, let reconnect {
                Button("Reconnect", systemImage: "arrow.clockwise") { reconnect(mac.id) }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More")
    }

    /// Creates a workspace and pushes it at once; the row is optimistic
    /// until the Mac confirms (ShellModel handles a refusal).
    private func create(_ start: NewWorkspaceStart, directory: String?, on macID: String?) {
        guard let workspace = creator.create(start: start, directory: directory, macID: macID) else {
            theme.haptics.warning()
            return
        }
        theme.haptics.impactLight()
        open(workspace)
    }

    @ViewBuilder private var content: some View {
        switch store.teamDataState {
        case .loading:
            ScrollView { SkeletonList(rows: 6, leadingSquare: nil).padding(.top, 8) }
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
                ConnectMacEmptyState(
                    email: accountEmail,
                    teamName: store.teams.count > 1 ? store.activeTeam?.name : nil,
                    elsewhere: store.teamWithMacsElsewhere(),
                    switchTeam: switchTeam,
                    noMacsForAccount: store.accountMacCount == 0,
                    openAccount: openAccount
                )
            } else {
                loaded
            }
        }
    }

    @ViewBuilder private var loaded: some View {
        let layout = WorkspaceListLayout(scope: scope, macs: macs, workspaces: store.workspaces, sort: sort, showsOffline: showsOffline)
        if let mac = scopedMac, layout.isEmpty {
            if mac.isOnline {
                let canCreate = target != nil
                EmptyState(
                    symbol: "macwindow",
                    title: "No workspaces on \(mac.name)",
                    message: canCreate ? "New workspaces open right away." : "\(mac.name) can't take new workspaces from this iPhone yet.",
                    primaryTitle: canCreate ? "New Workspace" : nil,
                    primary: canCreate ? { create(.terminal, directory: nil, on: mac.id) } : nil,
                    secondaryTitle: "Show All Macs",
                    secondary: { scopeBinding.wrappedValue = .all }
                )
                .accessibilityIdentifier("workspaces.empty.mac")
            } else {
                EmptyState(
                    symbol: "moon.zzz",
                    title: "\(mac.name) is offline",
                    message: "\(RelativeStamp().presence(isOnline: false, lastSeenAt: mac.lastSeenAt)). Open cmux on it to see its workspaces.",
                    secondaryTitle: "Show All Macs",
                    secondary: { scopeBinding.wrappedValue = .all }
                )
                .accessibilityIdentifier("workspaces.empty.offline")
            }
        } else if scope == .all && !macs.contains(where: \.isOnline) && !showsOffline {
            EmptyState(
                symbol: "moon.zzz",
                title: "Your Macs are asleep",
                message: "Wake a Mac or open cmux on it to see its workspaces.",
                secondaryTitle: "Show offline Macs", secondary: { showsOffline = true }
            )
        } else if scope == .all && layout.isEmpty, let target {
            EmptyState(
                symbol: "macwindow",
                title: "No workspaces yet",
                message: "New workspaces open right away on \(target.name).",
                primaryTitle: "New Workspace",
                primary: { create(.terminal, directory: nil, on: target.id) }
            )
            .accessibilityIdentifier("workspaces.empty.all")
        } else {
            list(layout)
        }
    }

    private func list(_ layout: WorkspaceListLayout) -> some View {
        let stamp = RelativeStamp()
        return List {
            if layout.isGrouped {
                ForEach(layout.sections) { section in
                    Section {
                        if section.workspaces.isEmpty {
                            emptySectionRow(section.mac)
                        }
                        rows(section, stamp: stamp)
                    } header: {
                        MacSectionHeader(mac: section.mac,
                                         presence: stamp.presence(isOnline: section.mac.isOnline, lastSeenAt: section.mac.lastSeenAt),
                                         count: section.workspaces.count,
                                         link: store.macLinkStatus[section.mac.id],
                                         reconnect: reconnect.map { reconnect in { reconnect(section.mac.id) } })
                    }
                }
            } else if let section = layout.sections.first {
                if let note = scopeNote(section.mac, stamp: stamp) {
                    Text(note)
                        .font(theme.type.meta)
                        .foregroundStyle(theme.colors.label2)
                        .listRowBackground(theme.colors.bg.color)
                        .listRowSeparator(.hidden)
                        .contentTransition(.opacity)
                        .accessibilityIdentifier("workspaces.scope-note")
                }
                rows(section, stamp: stamp)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .modifier(OptionalRefresh(refresh: refresh))
        .animation(theme.motion.smooth.animation, value: sort)
        .animation(theme.motion.smooth.animation, value: showsOffline)
        .animation(theme.motion.smooth.animation, value: layout.scope)
        .animation(theme.motion.smooth.animation, value: store.workspaces.map(\.id))
        .accessibilityIdentifier("workspaces.list")
    }

    /// One Mac chosen: a line above the rows for what the header would say
    /// (offline, or the live link line).
    private func scopeNote(_ mac: MacDevice, stamp: RelativeStamp) -> String? {
        if !mac.isOnline {
            return "Offline. Workspaces open when \(mac.name) is back."
        }
        return store.macLinkStatus[mac.id]
    }

    @ViewBuilder private func rows(_ section: MacSection, stamp: RelativeStamp) -> some View {
        ForEach(section.workspaces) { ws in
            let row = WorkspaceRow(workspace: ws, stamp: stamp.string(for: ws.lastActivityAt),
                                   isAvailable: section.mac.isOnline, isPending: store.isPending(ws.id))
            Group {
                if section.mac.isOnline {
                    NavigationLink(value: ws) { row }
                } else {
                    row
                }
            }
            .listRowBackground(theme.colors.bg.color)
            .listRowInsets(EdgeInsets(top: 0, leading: theme.metrics.sideMargin - WorkspaceRow.gutter, bottom: 0, trailing: 16))
            .alignmentGuide(.listRowSeparatorLeading) { _ in theme.metrics.sideMargin }
        }
    }

    /// An online Mac with nothing open, under All Macs.
    @ViewBuilder private func emptySectionRow(_ mac: MacDevice) -> some View {
        // Side by side, or stacked at accessibility sizes.
        ViewThatFits(in: .horizontal) {
            HStack { emptySectionContent(mac, spacer: true) }
            VStack(alignment: .leading, spacing: 8) { emptySectionContent(mac, spacer: false) }
                .padding(.vertical, 8)
        }
        .frame(minHeight: 44)
        .listRowBackground(theme.colors.bg.color)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: theme.metrics.sideMargin, bottom: 0, trailing: 16))
    }

    @ViewBuilder private func emptySectionContent(_ mac: MacDevice, spacer: Bool) -> some View {
            Text(mac.isOnline ? "No workspaces" : "No workspaces seen")
                .font(theme.type.rowSubtitle)
                .foregroundStyle(theme.colors.label2)
                .fixedSize()
            if spacer { Spacer(minLength: 8) }
            if mac.isOnline, creator.availableMacs.contains(where: { $0.id == mac.id }) {
                Button {
                    create(.terminal, directory: nil, on: mac.id)
                } label: {
                    Label("New Workspace", systemImage: "plus")
                        .labelStyle(TightLabelStyle())
                        .font(theme.type.rowSubtitle.weight(.medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(theme.colors.label)
                .accessibilityLabel("New Workspace on \(mac.name)")
                .fixedSize()
            }
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

/// No Mac in this team. Pairing is account based: a Mac signed in to the
/// same account, with iPhone connections allowed, appears by itself, and the
/// phone moves to its team when it comes online. Says which team the phone
/// shows, and offers the team where one of the account's Macs already is.
struct ConnectMacEmptyState: View {
    let email: String?
    /// The team shown, when the account has several.
    let teamName: String?
    /// Another team with one of the account's Macs.
    let elsewhere: (team: Team, mac: MacDevice)?
    let switchTeam: ((String) -> Void)?
    let noMacsForAccount: Bool
    let openAccount: (() -> Void)?

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
                if let teamName {
                    Text("No Macs in \(teamName) yet.")
                        .font(theme.type.rowSubtitle)
                        .foregroundStyle(theme.colors.label2)
                        .multilineTextAlignment(.center)
                        .padding(.top, -8)
                        .padding(.bottom, 20)
                        .accessibilityIdentifier("workspaces.connect-mac.team")
                }
                if let elsewhere, let switchTeam {
                    VStack(spacing: 12) {
                        Text("\(elsewhere.mac.name) is in \(elsewhere.team.name).")
                            .font(theme.type.body)
                            .foregroundStyle(theme.colors.label)
                            .multilineTextAlignment(.center)
                        PrimaryCapsule("Switch to \(elsewhere.team.name)") { switchTeam(elsewhere.team.id) }
                            .accessibilityIdentifier("workspaces.connect-mac.switch")
                    }
                    .padding(.bottom, 28)
                }
                ConnectMacSteps(email: email, onlineMac: nil, noMacsForAccount: noMacsForAccount, openAccount: openAccount)
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
    /// The Mac a tap creates on: the filtered Mac, else the preferred one.
    let target: MacDevice?
    /// The Mac picker is offered only under All Macs; with one Mac chosen,
    /// the title menu is where the Mac changes.
    let showsMacPicker: Bool
    let create: (NewWorkspaceStart, String?) -> Void

    var body: some View {
        Menu {
            menu
        } label: {
            Label("New Workspace", systemImage: "square.and.pencil")
        } primaryAction: {
            create(.terminal, nil)
        }
        .disabled(target == nil)
        .accessibilityIdentifier("workspaces.new")
        .accessibilityHint(target.map { "Creates a workspace on \($0.name)" } ?? "")
    }

    @ViewBuilder private var menu: some View {
        if let mac = target {
            let options = creator.options(on: mac.id)
            let macs = creator.availableMacs
            if macs.count > 1 || !showsMacPicker {
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
            if showsMacPicker && macs.count > 1 {
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

/// Sticky section header under All Macs: presence dot, Mac name, workspace
/// count, "Online" / "Last seen …", trailing More menu, and the live link
/// line when the app dials this Mac.
struct MacSectionHeader: View {
    let mac: MacDevice
    let presence: String
    var count: Int = 0
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
        .padding(.leading, theme.metrics.sideMargin)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Pinned headers sit over scrolled rows; keep them opaque.
        .background(theme.colors.bg.color)
        .listRowInsets(EdgeInsets())
        .animation(theme.motion.snappy.animation, value: link)
    }

    private var row: some View {
        HStack(spacing: 8) {
            StatusDot(mac.isOnline ? .online : .offline, size: 7)
            Text(mac.name)
                .font(theme.type.rowSubtitle.weight(.semibold))
                .foregroundStyle(mac.isOnline ? theme.colors.label : theme.colors.label2)
                .lineLimit(1)
            Text(presence)
                .font(theme.type.meta)
                .foregroundStyle(theme.colors.label2)
                .lineLimit(1)
            Spacer(minLength: 0)
            if count > 0 {
                Text("\(count)")
                    .font(theme.type.meta.monospacedDigit())
                    .foregroundStyle(theme.colors.label2)
                    .accessibilityLabel(WorkspacesList.count(count))
            }
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
        .accessibilityAddTraits(.isHeader)
    }
}

/// SPEC 11.1 workspace row, Mail/Messages style: an unread gutter, then
/// three lines.
/// 1. Title, relative time.
/// 2. Branch (or directory) in mono, then the tab kinds as glyphs.
/// 3. Activity: "Needs you", a live working indicator, or the latest
///    tab's subtitle.
struct WorkspaceRow: View {
    let workspace: Workspace
    let stamp: String
    /// The Mac is online; offline rows are greyed and not tappable.
    var isAvailable = true
    /// Being created on the Mac (optimistic row).
    var isPending = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Leading gutter for the unread dot (Mail, Messages).
    static let gutter: CGFloat = 16

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Circle()
                .fill(theme.colors.label.color)
                .frame(width: 8, height: 8)
                .opacity(workspace.hasUnread && isAvailable ? 1 : 0)
                .frame(width: Self.gutter, alignment: .leading)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(workspace.title)
                        .font(theme.type.rowTitle.weight(.semibold))
                        .foregroundStyle(isAvailable ? theme.colors.label : theme.colors.label2)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(stamp)
                        .font(theme.type.meta.monospacedDigit())
                        .foregroundStyle(theme.colors.label2)
                        .fixedSize()
                }
                details
                activity
            }
        }
        .padding(.vertical, 10)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(isAvailable ? [] : .isStaticText)
    }

    private var location: String {
        if let branch = workspace.branch { return branch }
        return (workspace.directory as NSString).abbreviatingWithTildeInPath
    }

    private var details: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label {
                Text(location).monospaced()
            } icon: {
                Image(systemName: workspace.branch == nil ? "folder" : "arrow.triangle.branch")
                    .imageScale(.small)
            }
            .labelStyle(TightLabelStyle())
            .lineLimit(1)
            .truncationMode(.middle)
            .layoutPriority(-1)
            ForEach(TabKindSummary(workspace.tabs).entries, id: \.kind) { entry in
                HStack(spacing: 2) {
                    Image(systemName: Self.glyph(entry.kind)).imageScale(.small)
                    if entry.count > 1 { Text("\(entry.count)").monospacedDigit() }
                }
                .fixedSize()
            }
        }
        .font(theme.type.meta)
        .foregroundStyle(theme.colors.label2)
    }

    static func glyph(_ kind: WorkspaceTab.Kind) -> String {
        switch kind {
        case .agent: "sparkle"
        case .terminal: "apple.terminal"
        case .browser: "globe"
        }
    }

    @ViewBuilder private var activity: some View {
        Group {
            if isPending {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Creating…")
                }
                .foregroundStyle(theme.colors.label2)
            } else if !isAvailable {
                Text("Unavailable while offline")
                    .foregroundStyle(theme.colors.label3)
            } else {
                switch WorkspaceActivity(workspace) {
                case let .needsYou(agent, detail):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(theme.colors.warning.color).frame(width: 7, height: 7)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3.5 }
                        Text("\(Text("Needs you").fontWeight(.semibold).foregroundStyle(theme.colors.label.color))\(Text(Self.suffix(agent, detail)).foregroundStyle(theme.colors.label2.color))")
                    }
                    .accessibilityIdentifier("workspace.needs-you")
                case let .working(agent, detail):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "ellipsis")
                            .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating, isActive: !reduceMotion)
                            .foregroundStyle(theme.colors.label)
                        Text("\(Text("\(agent ?? "Agent") is working").foregroundStyle(theme.colors.label.color))\(Text(detail.map { " · \($0)" } ?? "").foregroundStyle(theme.colors.label2.color))")
                    }
                    .accessibilityIdentifier("workspace.working")
                case let .idle(text):
                    // Skip a subtitle that only repeats line 2 (a new terminal at "~").
                    if let text, text != location {
                        Text(text).foregroundStyle(theme.colors.label2)
                    }
                }
            }
        }
        .font(theme.type.rowSubtitle)
        .lineLimit(1)
    }

    static func suffix(_ agent: String?, _ detail: String?) -> String {
        switch (agent, detail) {
        case let (agent?, detail?): " · \(agent): \(detail)"
        case let (agent?, nil): " · \(agent)"
        case let (nil, detail?): " · \(detail)"
        default: ""
        }
    }

    private var spoken: String {
        var parts = [workspace.title]
        if workspace.hasUnread && isAvailable { parts.append("Unread") }
        parts.append(location)
        let tabs = TabKindSummary(workspace.tabs).spoken
        if !tabs.isEmpty { parts.append(tabs) }
        if isPending {
            parts.append("Creating")
        } else if !isAvailable {
            parts.append("Unavailable while offline")
        } else {
            switch WorkspaceActivity(workspace) {
            case let .needsYou(agent, detail): parts.append("Needs you" + Self.suffix(agent, detail))
            case let .working(agent, detail): parts.append("\(agent ?? "Agent") is working" + (detail.map { ", \($0)" } ?? ""))
            case let .idle(text): if let text, text != location { parts.append(text) }
            }
        }
        parts.append(stamp)
        return parts.joined(separator: ", ")
    }
}

/// Icon and title 3 pt apart (the default Label spacing is too loose for meta).
private struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

#endif
