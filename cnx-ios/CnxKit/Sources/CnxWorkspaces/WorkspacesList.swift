#if os(iOS)
import CnxDesign
import CnxModel
import SwiftUI

private let theme = CnxTheme.standard

/// SPEC 11.1: the Workspaces tab, an inbox ordered by what needs the user.
///
/// - **Needs You** (only when not empty), then **Recent** (newest activity
///   first), then one folded line per offline Mac that expands in place.
/// - Two-line rows, Mail style: the name and its time, then the status in
///   words naming the agent and its task ("Claude is waiting · Refactor
///   transport layer"), or the branch when idle. A leading gutter holds a
///   warning disc, a spinner or a dot.
/// - The Mac filter is a toolbar menu, remembered per team (`MacFilter`).
///   The navigation subtitle says what is filtered or how many need you.
/// - A tap opens the last tab used here (else the Mac's active tab); a
///   needs-you workspace opens on its waiting tab. Hold a row for its tabs,
///   Rename and Close; swipe left for Close and Rename.
public struct WorkspacesList: View {
    let store: AppStore
    let creator: WorkspaceCreator
    /// Pushes a workspace (the new one, right after a tap).
    let open: (Workspace) -> Void
    /// The signed-in account, for "sign in as …" in the empty state.
    var accountEmail: String?
    /// Links a Mac (live only): a Mac whose list the phone does not have.
    var reconnect: ((String) -> Void)?
    /// Pull to refresh (live only).
    var refresh: (() async -> Void)?
    /// Moves to another team (the empty state offers the team where a Mac is).
    var switchTeam: ((String) -> Void)?
    /// Opens Settings → Account (the empty state, when no Mac uses this account).
    var openAccount: (() -> Void)?
    @State private var filter: MacFilter
    @State private var isRetrying = false
    @State private var query = ""
    /// Offline Macs whose rows are unfolded (this session).
    @State private var unfolded: Set<String> = []
    /// A refresh has taken long enough to say so.
    @State private var showsUpdating = false
    /// The offline workspace whose tap is being explained.
    @State private var unavailable: Workspace?
    @State private var renaming: Workspace?
    @State private var renameText = ""
    @State private var closing: Workspace?
    /// The rows' status gutter (32 pt at Large), for the separator inset.
    @ScaledMetric(relativeTo: .body) private var gutter: CGFloat = WorkspaceRow.gutter
    /// Where each offline Mac's line ends in the list's visible area, and
    /// where that area ends (above the tab bar): unfolding scrolls when needed.
    @State private var foldBottoms: [String: CGFloat] = [:]
    @State private var visibleBottom: CGFloat = .infinity
    /// Each row's frame in the list (read on demand, never drawn from).
    @State private var rowFrames = RowFrames()
    @State private var closingFrame: CGRect = .zero

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

    private func mac(_ id: String) -> MacDevice? { macs.first { $0.id == id } }

    private var inbox: WorkspaceInbox {
        WorkspaceInbox(scope: scope, macs: macs, workspaces: store.workspaces, query: query,
                       context: WorkspaceInbox.Context(pending: store.pendingWorkspaceIDs, seenAt: store.seenAt,
                                                       sync: store.workspaceListSync))
    }

    /// Refreshing: the team is loading, or the linked Mac's list has not arrived.
    private var isRefreshing: Bool { store.teamDataState == .loading || inbox.isUpdating }

    public var body: some View {
        content
            .navigationTitle("Workspaces")
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if macs.count > 1 { filterMenu }
                    NewWorkspaceButton(creator: creator, target: target, showsMacPicker: scope == .all) { start, directory in
                        create(start, directory: directory, on: target?.id)
                    }
                }
            }
            .task(id: isRefreshing) {
                // Say "Updating…" only when a refresh is slow, not on every one.
                guard isRefreshing else {
                    showsUpdating = false
                    return
                }
                try? await Task.sleep(for: .seconds(1.5))
                if !Task.isCancelled { showsUpdating = true }
            }
            .alert(unavailableTitle, isPresented: isPresented($unavailable), presenting: unavailable) { _ in
                Button("OK", role: .cancel) {}
            } message: { ws in
                Text(unavailableMessage(ws))
            }
            .alert("Rename Workspace", isPresented: isPresented($renaming), presenting: renaming) { ws in
                TextField("Name", text: $renameText)
                    .submitLabel(.done)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { creator.rename(ws, to: renameText) }
                    .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
    }

    /// Filtered: the Mac and its presence. Else "Updating…" for a slow
    /// refresh, "2 need you", or with several Macs how many are online.
    private var subtitle: String {
        if let mac = scopedMac {
            return "\(mac.name) · " + RelativeStamp().presence(isOnline: mac.isOnline, lastSeenAt: mac.lastSeenAt)
        }
        if showsUpdating && isRefreshing { return "Updating…" }
        let waiting = inbox.needsYouCount
        if waiting > 0 { return waiting == 1 ? "1 needs you" : "\(waiting) need you" }
        if macs.count > 1 { return "\(macs.filter(\.isOnline).count) of \(macs.count) Macs online" }
        return ""
    }

    private func isPresented<T>(_ item: Binding<T?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }

    private var unavailableTitle: String {
        unavailable.flatMap { mac($0.macID) }.map { "\($0.name) is offline" } ?? "Mac is offline"
    }

    private func unavailableMessage(_ ws: Workspace) -> String {
        let seen = mac(ws.macID).map { RelativeStamp().presence(isOnline: false, lastSeenAt: $0.lastSeenAt) } ?? "Offline"
        return "\(seen). \u{201C}\(ws.title)\u{201D} opens when the Mac is awake with cmux running."
    }

    private func select(_ value: MacScope) {
        guard let team = store.activeTeam, value != scope else { return }
        theme.haptics.selection()
        withAnimation(theme.motion.smooth.animation) { filter.select(value, in: team.id) }
        // Live: the phone links one Mac at a time; showing another links it.
        if let id = value.macID, mac(id)?.isOnline == true, store.listState(macID: id) == .notConnected {
            reconnect?(id)
        }
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

    /// Opens a workspace: a needs-you one on its waiting tab, else the
    /// last tab used here (`AppStore.openingTab`). Clears its "Done".
    private func openWorkspace(_ ws: Workspace, status: WorkspaceStatus, tab: WorkspaceTab? = nil) {
        if status == .offline {
            theme.haptics.warning()
            unavailable = ws
            return
        }
        if let tab = tab ?? (status == .needsYou ? ws.agentTab(for: .needsYou) : nil) {
            store.noteOpened(tabID: tab.id, in: ws.id)
        }
        store.markSeen(ws.id)
        open(ws)
    }

    @ViewBuilder private var content: some View {
        switch store.teamDataState {
        case .loading where store.activeWorkspaces.isEmpty || macs.isEmpty:
            skeleton
        case .failed:
            EmptyState(
                symbol: "cloud",
                title: "Couldn't load workspaces",
                message: "Check your connection and try again.",
                primaryTitle: "Retry",
                isPrimaryLoading: isRetrying,
                primary: retry
            )
        case .loading, .loaded:
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
                list(inbox)
            }
        }
    }

    private var skeleton: some View {
        ScrollView { SkeletonList(rows: 6, leadingSquare: nil).padding(.top, 8) }
            .scrollDisabled(true)
            .accessibilityIdentifier("workspaces.loading")
    }

    private func list(_ inbox: WorkspaceInbox) -> some View {
        ScrollViewReader { proxy in
            inboxList(inbox, proxy: proxy)
        }
    }

    private func inboxList(_ inbox: WorkspaceInbox, proxy: ScrollViewProxy) -> some View {
        List {
            if inbox.allAsleep && query.isEmpty {
                asleepHeader
            }
            if !inbox.needsYou.isEmpty {
                Section {
                    SectionTitle(title: "Needs You")
                    ForEach(inbox.needsYou) { row($0, inbox) }
                }
            }
            if !inbox.recent.isEmpty {
                Section {
                    if !inbox.needsYou.isEmpty || !inbox.folds.isEmpty {
                        SectionTitle(title: "Recent")
                    }
                    ForEach(inbox.recent) { row($0, inbox) }
                }
            }
            ForEach(inbox.folds) { fold in
                Section {
                    // Filtered to this Mac: its rows alone; the navigation
                    // subtitle already says when it was last seen.
                    if scope.macID != fold.mac.id {
                        foldLine(fold, proxy: proxy)
                    }
                    if fold.isForcedOpen || unfolded.contains(fold.mac.id) {
                        ForEach(fold.workspaces) { row($0, inbox) }
                    }
                }
            }
        }
        .listStyle(.plain)
        .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height - $0.contentInsets.bottom } action: { _, height in
            visibleBottom = height
        }
        .listSectionSpacing(4)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .overlay(alignment: .topLeading) { closeAnchor }
        .overlay {
            if inbox.isLoading {
                skeleton
            } else if inbox.isEmpty {
                emptyState
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .background { PullDownSearch() }
        .modifier(OptionalRefresh(refresh: refresh))
        .animation(theme.motion.smooth.animation, value: inbox.scope)
        .animation(theme.motion.smooth.animation, value: inbox.needsYou.map(\.id))
        .animation(theme.motion.smooth.animation, value: store.workspaces.map(\.id))
        .accessibilityIdentifier("workspaces.list")
    }

    private func row(_ ws: Workspace, _ inbox: WorkspaceInbox) -> some View {
        let status = inbox.status(ws)
        let macName = mac(ws.macID)?.name
        let canManage = status != .offline && creator.canManage(ws)
        return Button {
            openWorkspace(ws, status: status)
        } label: {
            WorkspaceRow(workspace: ws, status: status, macName: inbox.showsMacNames ? macName : nil,
                         offlineMacName: status == .offline ? macName : nil)
        }
        .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 20))
        .listRowBackground(theme.colors.bg.color)
        .alignmentGuide(.listRowSeparatorLeading) { _ in gutter }
        // Trailing only: a rightward swipe from the leading edge belongs to
        // the team sidebar.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canManage {
                Button("Close", systemImage: "xmark", role: .destructive) { confirmClose(ws) }
                    // The app tints controls with the foreground color
                    // (white in dark mode), which turned this into a blank
                    // white pill. Back to the system tint: red for the role.
                    .tint(nil)
                    .accessibilityIdentifier("workspace.swipe.close")
                Button("Rename", systemImage: "pencil") { startRename(ws) }
                    .tint(.gray)
                    .accessibilityIdentifier("workspace.swipe.rename")
            }
        }
        .contextMenu { menu(ws, status: status, canManage: canManage) }
        // Where the row is, so the close popover can point at it.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rowFrames.byID[ws.id] = $0 }
        .accessibilityActions {
            if canManage {
                Button("Rename") { startRename(ws) }
                Button("Close") { confirmClose(ws) }
            }
        }
        .accessibilityIdentifier("workspace.row.\(ws.id)")
    }

    /// Asks before closing, in a popover pointing at the row (Mail).
    private func confirmClose(_ ws: Workspace) {
        let row = rowFrames.byID[ws.id] ?? .zero
        closingFrame = row.offsetBy(dx: -rowFrames.origin.x, dy: -rowFrames.origin.y)
        closing = ws
    }

    /// The close popover's anchor: a view over the list at the row's place.
    /// Not on the row itself: a row's own presentation is dropped while its
    /// swipe actions close.
    private var closeAnchor: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { rowFrames.origin = $0 }
            .overlay(alignment: .topLeading) { anchor }
            .allowsHitTesting(false)
    }

    private var anchor: some View {
        Color.clear
            .frame(width: max(closingFrame.width, 1), height: max(closingFrame.height, 1))
            // Padding, not an offset: the popover points at the layout frame.
            .padding(.leading, max(closingFrame.minX, 0))
            .padding(.top, max(closingFrame.minY, 0))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .confirmationDialog(closing.map { "Close \u{201C}\($0.title)\u{201D}?" } ?? "", isPresented: isPresented($closing),
                                titleVisibility: .visible, presenting: closing) { ws in
                Button("Close Workspace", role: .destructive) {
                    theme.haptics.impactLight()
                    withAnimation(theme.motion.smooth.animation) { creator.close(ws) }
                }
            } message: { ws in
                Text("Its tabs close on \(mac(ws.macID)?.name ?? "the Mac").")
            }
    }

    private func startRename(_ ws: Workspace) {
        renameText = ws.title
        renaming = ws
    }

    /// The row menu: the Mac and branch as its header, the workspace's tabs
    /// (jump straight to one), then Rename and Close.
    @ViewBuilder private func menu(_ ws: Workspace, status: WorkspaceStatus, canManage: Bool) -> some View {
        let macName = mac(ws.macID)?.name ?? "Unknown Mac"
        Section(menuHeader(ws, macName: macName, offline: status == .offline)) {
            if status == .offline {
                if scope == .all {
                    Button("Show \(macName)", systemImage: "line.3.horizontal.decrease") { select(.mac(ws.macID)) }
                }
            } else {
                ForEach(ws.tabs) { tab in
                    Button { openWorkspace(ws, status: status, tab: tab) } label: {
                        // An agent tab by its task (as on the row), the agent as the subtitle.
                        if tab.isAgent, let task = tab.task {
                            Text(task)
                            Text(tab.agentName)
                            Image(systemName: tab.systemImage)
                        } else {
                            Label(tab.title, systemImage: tab.systemImage)
                        }
                    }
                }
            }
        }
        if canManage {
            Section {
                Button("Rename", systemImage: "pencil") { startRename(ws) }
                Button("Close Workspace", systemImage: "xmark", role: .destructive) { confirmClose(ws) }
            }
        }
    }

    /// "Aziz's Mac Studio · feat-cnx-ios", "· Offline" for an offline Mac.
    private func menuHeader(_ ws: Workspace, macName: String, offline: Bool) -> String {
        var parts = [macName]
        if !ws.place.isEmpty { parts.append(ws.place) }
        if offline { parts.append("Offline") }
        return parts.joined(separator: " · ")
    }

    /// One line for an offline Mac ("MacBook Pro · Last seen 2h ago  3 ›"),
    /// unfolding its rows in place; or for an online Mac the phone is not
    /// linked to (live), linking it on a tap.
    private func foldLine(_ fold: WorkspaceInbox.Fold, proxy: ScrollViewProxy) -> some View {
        let isOpen = fold.isForcedOpen || unfolded.contains(fold.mac.id)
        let detail = fold.reason == .offline
            ? RelativeStamp().presence(isOnline: false, lastSeenAt: fold.mac.lastSeenAt)
            : "Not connected"
        return Button {
            switch fold.reason {
            case .offline:
                theme.haptics.selection()
                let opening = !unfolded.contains(fold.mac.id)
                withAnimation(theme.motion.smooth.animation) {
                    if opening { unfolded.insert(fold.mac.id) } else { unfolded.remove(fold.mac.id) }
                }
                // Rows opening below the visible area: bring the first into view.
                if opening, let first = fold.workspaces.first,
                   (foldBottoms[fold.mac.id] ?? 0) + WorkspaceRow.minHeight > visibleBottom {
                    Task { @MainActor in
                        await Task.yield()
                        withAnimation(theme.motion.smooth.animation) { proxy.scrollTo(first.id, anchor: .bottom) }
                    }
                }
            case .notConnected:
                reconnect?(fold.mac.id)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: fold.reason == .offline ? "moon.zzz" : "link")
                    .accessibilityHidden(true)
                Text("\(fold.mac.name) · \(detail)")
                    .lineLimit(3)
                Spacer(minLength: 8)
                if fold.reason == .notConnected {
                    if reconnect != nil { Text("Connect") }
                } else if !fold.isForcedOpen {
                    Text("\(fold.workspaces.count)")
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .animation(theme.motion.snap.animation, value: isOpen)
                        .accessibilityHidden(true)
                }
            }
            .font(theme.type.meta.weight(.semibold))
            .foregroundStyle(theme.colors.label2)
            .frame(minHeight: 32)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(fold.isForcedOpen || (fold.reason == .notConnected && reconnect == nil))
        .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 4, trailing: 20))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityValue(fold.reason == .offline && !fold.isForcedOpen ? (isOpen ? "Expanded" : "Collapsed") : "")
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .scrollView).maxY } action: { foldBottoms[fold.mac.id] = $0 }
        .accessibilityIdentifier("workspaces.fold.\(fold.mac.id)")
    }

    private var asleepHeader: some View {
        VStack(spacing: 8) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 28))
                .foregroundStyle(theme.colors.label)
                .accessibilityHidden(true)
            Text("Your Macs are asleep")
                .font(theme.type.emptyTitle)
                .foregroundStyle(theme.colors.label)
            Text("Wake a Mac or open cmux on it to open its workspaces.")
                .font(theme.type.rowSubtitle)
                .foregroundStyle(theme.colors.label2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("workspaces.empty.asleep")
    }

    @ViewBuilder private var emptyState: some View {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search(text: query)
        } else if let mac = scopedMac {
            if !mac.isOnline {
                EmptyState(
                    symbol: "moon.zzz",
                    title: "\(mac.name) is offline",
                    message: "\(RelativeStamp().presence(isOnline: false, lastSeenAt: mac.lastSeenAt)). Open cmux on it to see its workspaces."
                )
                .accessibilityIdentifier("workspaces.empty.offline")
            } else if store.listState(macID: mac.id) == .notConnected {
                EmptyState(
                    symbol: "link",
                    title: "\(mac.name) isn't connected",
                    message: "This iPhone shows one Mac's workspaces at a time.",
                    primaryTitle: reconnect == nil ? nil : "Connect",
                    primary: reconnect.map { reconnect in { reconnect(mac.id) } }
                )
                .accessibilityIdentifier("workspaces.empty.not-connected")
            } else {
                let canCreate = target != nil
                EmptyState(
                    symbol: "macwindow",
                    title: "No workspaces on \(mac.name)",
                    message: canCreate ? "New workspaces open right away." : "\(mac.name) can't take new workspaces from this iPhone yet.",
                    primaryTitle: canCreate ? "New Workspace" : nil,
                    primary: canCreate ? { create(.terminal, directory: nil, on: mac.id) } : nil
                )
                .accessibilityIdentifier("workspaces.empty.mac")
            }
        } else if let target {
            EmptyState(
                symbol: "macwindow",
                title: "No workspaces yet",
                message: "New workspaces open right away on \(target.name).",
                primaryTitle: "New Workspace",
                primary: { create(.terminal, directory: nil, on: target.id) }
            )
            .accessibilityIdentifier("workspaces.empty.all")
        } else {
            EmptyState(
                symbol: "moon.zzz",
                title: "Your Macs are asleep",
                message: "Wake a Mac or open cmux on it to see its workspaces."
            )
            .accessibilityIdentifier("workspaces.empty.asleep")
        }
    }

    /// The Mac filter: All Macs, then each Mac (online first) with its
    /// presence (and the live link line) as the subtitle.
    private var filterMenu: some View {
        Menu {
            // Toggles, not an inline Picker: a Picker drops each Mac's
            // presence subtitle. The chosen row shows the checkmark.
            Toggle(isOn: chosen(.all)) {
                Label("All Macs", systemImage: "square.stack.3d.up")
            }
            .accessibilityIdentifier("workspaces.filter.all")
            ForEach(MacScope.menuOrder(macs)) { mac in
                // A title and a subtitle Text directly in the label: a menu
                // shows the second as the subtitle (not inside a Label).
                Toggle(isOn: chosen(.mac(mac.id))) {
                    Text(mac.name)
                    Text(macDetail(mac))
                    // The model has no Mac kind (laptop or desktop) yet.
                    Image(systemName: "desktopcomputer")
                }
                .accessibilityIdentifier("workspaces.filter.\(mac.id)")
            }
        } label: {
            Label("Filter", systemImage: scope == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityIdentifier("workspaces.filter")
        .accessibilityValue(scopedMac?.name ?? "All Macs")
    }

    /// On for the chosen scope; turning one on chooses it (turning the chosen one off does nothing).
    private func chosen(_ value: MacScope) -> Binding<Bool> {
        Binding(get: { scope == value }, set: { if $0 { select(value) } })
    }

    private func macDetail(_ mac: MacDevice) -> String {
        let presence = RelativeStamp().presence(isOnline: mac.isOnline, lastSeenAt: mac.lastSeenAt)
        return [presence, store.macLinkStatus[mac.id]].compactMap(\.self).joined(separator: " · ")
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

/// Row frames for the close popover's anchor. A plain reference, so
/// scrolling (which updates it) does not re-render the list.
final class RowFrames {
    var byID: [String: CGRect] = [:]
    /// The list's own origin, in the same (global) space.
    var origin: CGPoint = .zero
}

/// A section title as a row that scrolls with the list (not a pinned
/// header: pinned plain headers overlap rows under the glass bar).
struct SectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(theme.type.meta.weight(.semibold))
            .foregroundStyle(theme.colors.label2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 2, trailing: 20))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .accessibilityAddTraits(.isHeader)
    }
}

/// SPEC 11.1 workspace row, Mail anatomy: a status gutter (32 pt at Large,
/// scaling with Dynamic Type), then the name and its time, then the status
/// sentence.
struct WorkspaceRow: View {
    let workspace: Workspace
    let status: WorkspaceStatus
    /// Named on idle rows when Recent mixes several Macs.
    var macName: String?
    /// The offline Mac, for the VoiceOver hint.
    var offlineMacName: String?
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The status gutter; separators start at the text.
    @ScaledMetric(relativeTo: .body) private var gutter: CGFloat = Self.gutter
    @ScaledMetric(relativeTo: .body) private var needsYouDisc: CGFloat = 10
    @ScaledMetric(relativeTo: .body) private var doneDisc: CGFloat = 8

    /// The gutter at Large; the list scales it the same way for separators.
    static let gutter: CGFloat = 32
    /// About one row: unfolding scrolls when the first new row would not fit.
    static let minHeight: CGFloat = 60

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            mark
                .frame(width: gutter)
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + needsYouDisc / 2 }
                .animation(theme.motion.snap.animation, value: status)
            VStack(alignment: .leading, spacing: 3) {
                // The time stays trailing on line 1, beside a name that wraps
                // to two lines at accessibility sizes (no line of its own).
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    name.lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                    Spacer(minLength: 8)
                    time
                }
                StatusLine(workspace: workspace, status: status, macName: macName)
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                    .opacity(status == .offline ? 0.6 : 1)
            }
        }
        .frame(minHeight: 40, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityHint(offlineMacName.map { "\($0) is offline" } ?? "")
        .accessibilityAddTraits(.isButton)
    }

    private var name: some View {
        Text(workspace.title)
            .font(theme.type.rowTitle.weight(.semibold))
            .foregroundStyle(status == .offline ? theme.colors.label3 : theme.colors.label)
    }

    /// Only a real activity time: none for a live workspace with no activity
    /// seen since the phone connected.
    @ViewBuilder private var time: some View {
        if workspace.hasActivityTime {
            Text(RelativeStamp().string(for: workspace.lastActivityAt))
                .font(theme.type.meta)
                .monospacedDigit()
                .foregroundStyle(status == .needsYou ? theme.colors.label : theme.colors.label2)
                .fixedSize()
        }
    }

    @ViewBuilder private var mark: some View {
        switch status {
        case .needsYou:
            Circle().fill(theme.colors.warning.color).frame(width: needsYouDisc, height: needsYouDisc)
                .accessibilityIdentifier("workspace.needs-you")
        case .working, .creating:
            ProgressView().controlSize(.mini)
                .accessibilityIdentifier(status == .working ? "workspace.working" : "workspace.creating")
        case .done:
            Circle().fill(theme.colors.label.color).frame(width: doneDisc, height: doneDisc)
                .accessibilityIdentifier("workspace.done")
        case .idle, .offline:
            Color.clear.frame(width: doneDisc, height: doneDisc)
        }
    }

    private var spoken: String {
        var parts = [workspace.title]
        let line = StatusLine.words(workspace, status: status, macName: macName)
        parts.append(contentsOf: line)
        if workspace.hasActivityTime, status != .creating {
            parts.append(RelativeDateTimeFormatter().localizedString(for: workspace.lastActivityAt, relativeTo: Date()))
        }
        return parts.joined(separator: ", ")
    }
}

/// Line 2 of a row: "**Claude is waiting** · Refactor transport layer",
/// "Codex is working · Fix pricing page" (shimmering), "**Done** · Claude:
/// Audit runner labels", else the branch or directory.
struct StatusLine: View {
    let workspace: Workspace
    let status: WorkspaceStatus
    var macName: String?

    var body: some View {
        Group {
            switch status {
            case .needsYou:
                if let task { Text("\(emphasis(waiting)) · \(task)") } else { emphasis(waiting) }
            case .working:
                // One text under the shimmer, so it truncates as one line.
                ShimmerText(text: [working, task].compactMap(\.self).joined(separator: " · "))
            case .done:
                if let task { Text("\(emphasis("Done")) · \(agentName ?? "Agent"): \(task)") } else { emphasis("Done") }
            case .creating:
                Text(workspace.directory.isEmpty ? "Creating…" : Self.directoryName(workspace.directory))
            case .idle, .offline:
                Text(Self.place(workspace, macName: macName))
            }
        }
        .font(theme.type.rowSubtitle)
        .foregroundStyle(theme.colors.label2)
        .contentTransition(.opacity)
    }

    private var tab: WorkspaceTab? { workspace.agentTab(for: status) }
    private var agentName: String? { tab?.agentName }
    private var task: String? { tab?.task }
    private var waiting: String { agentName.map { "\($0) is waiting" } ?? "Needs you" }
    private var working: String { agentName.map { "\($0) is working" } ?? "Working" }

    private func emphasis(_ word: String) -> Text {
        Text(word).foregroundStyle(theme.colors.label).fontWeight(.semibold)
    }

    /// "Home" for the home directory, as the New Workspace menu says.
    static func directoryName(_ directory: String) -> String {
        directory == "~" ? "Home" : directory
    }

    static func place(_ workspace: Workspace, macName: String?) -> String {
        let place = workspace.branch ?? (workspace.directory.isEmpty ? nil : directoryName(workspace.directory))
        return [place, macName].compactMap(\.self).joined(separator: " · ")
    }

    /// The same line for VoiceOver.
    static func words(_ workspace: Workspace, status: WorkspaceStatus, macName: String?) -> [String] {
        let tab = workspace.agentTab(for: status)
        switch status {
        case .needsYou: return [tab.map { "\($0.agentName) is waiting" } ?? "Needs you", tab?.task].compactMap(\.self)
        case .working: return [tab.map { "\($0.agentName) is working" } ?? "Working", tab?.task].compactMap(\.self)
        case .done: return ["Done", tab.map { "\($0.agentName)" }, tab?.task].compactMap(\.self)
        case .creating: return ["Creating"]
        case .idle: return ["idle", place(workspace, macName: macName)]
        case .offline: return ["offline", place(workspace, macName: nil)]
        }
    }
}

/// SPEC 4.5's shimmer for a row's "is working" line: `label2` at rest (never
/// fainter than the rest of line 2), a `label` highlight sweeping across.
/// Static `label2` with Reduce Motion.
struct ShimmerText: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Text(text).foregroundStyle(theme.colors.label2)
        } else {
            TimelineView(.animation) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                Text(text)
                    .foregroundStyle(theme.colors.label2)
                    .overlay {
                        Text(text)
                            .foregroundStyle(theme.colors.label)
                            .mask {
                                GeometryReader { proxy in
                                    let width = proxy.size.width
                                    LinearGradient(colors: [.clear, .white, .clear], startPoint: .leading, endPoint: .trailing)
                                        .frame(width: max(width * 0.4, 30))
                                        .offset(x: -width * 0.4 + width * 1.4 * phase)
                                }
                            }
                            .accessibilityHidden(true)
                    }
            }
        }
    }
}

/// Starts the list with the search field tucked under the navigation bar,
/// so it appears on a pull-down (ChatGPT, Mail). `.searchable`'s drawer is
/// otherwise open at the top on launch; UIKit hides it once the list's
/// offset passes the field, so the list starts that far down, once.
private struct PullDownSearch: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ uiView: Probe, context: Context) {}

    final class Probe: UIView {
        private var done = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, !done else { return }
            DispatchQueue.main.async { [weak self] in self?.tuck() }
        }

        private func tuck() {
            guard !done, let controller = owningController(),
                  let search = controller.navigationItemWithSearch()?.searchController?.searchBar,
                  let scroll = controller.view.firstSubview(of: UICollectionView.self) else { return }
            done = true
            let height = search.frame.height
            guard height > 0, scroll.contentOffset.y <= -scroll.adjustedContentInset.top + 1 else { return }
            scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top + height), animated: false)
            // The collapsed drawer shrinks the top inset; settle on the new top
            // so the first row sits right under the bar.
            DispatchQueue.main.async {
                scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
            }
        }

        private func owningController() -> UIViewController? {
            var responder: UIResponder? = self
            while let next = responder?.next {
                if let controller = next as? UIViewController { return controller }
                responder = next
            }
            return nil
        }
    }
}

private extension UIViewController {
    /// This controller's or an ancestor's navigation item that carries the search controller.
    func navigationItemWithSearch() -> UINavigationItem? {
        var controller: UIViewController? = self
        while let current = controller {
            if current.navigationItem.searchController != nil { return current.navigationItem }
            controller = current.parent
        }
        return nil
    }
}

private extension UIView {
    func firstSubview<T: UIView>(of type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T { return match }
            if let match = subview.firstSubview(of: type) { return match }
        }
        return nil
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
    /// The Mac picker is offered only under All Macs; with one Mac
    /// filtered, the filter menu is where the Mac changes.
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

#endif
