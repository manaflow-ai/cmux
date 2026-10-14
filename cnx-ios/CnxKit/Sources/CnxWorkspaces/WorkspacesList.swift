#if os(iOS)
import CnxDesign
import CnxModel
import SwiftUI

private let theme = CnxTheme.standard

/// SPEC 11.1: the Workspaces tab's content, modeled on ChatGPT's chat
/// history list.
///
/// - A chip row pinned under the title picks the Mac: All, then one chip
///   per Mac (online first; offline chips dimmed). Remembered per team
///   (`MacFilter`). All mixes every Mac with no per-Mac headers.
/// - Rows are one line: the workspace name in `body`, with a small leading
///   dot only when an agent needs the user or is working. No icons, no
///   subtitles, no separators. Recency headers (Today, Yesterday, Previous
///   7 Days, Previous 30 Days, then months) scroll with the rows.
/// - Pull down for search. Hold a row for Open, Rename and Close Workspace
///   under a header naming its Mac and branch.
/// - Offline Macs' workspaces are dimmed; a tap explains why they don't open.
/// - New Workspace creates at once on the chosen chip's Mac.
public struct WorkspacesList: View {
    let store: AppStore
    let creator: WorkspaceCreator
    /// Pushes a workspace (the new one, right after a tap).
    let open: (Workspace) -> Void
    /// The signed-in account, for "sign in as …" in the empty state.
    var accountEmail: String?
    /// Redials a Mac (live only; offered on a Mac chip's context menu).
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
    /// The offline workspace whose tap is being explained.
    @State private var unavailable: Workspace?
    @State private var renaming: Workspace?
    @State private var renameText = ""
    @State private var closing: Workspace?

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

    public var body: some View {
        content
            .navigationTitle("Workspaces")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NewWorkspaceButton(creator: creator, target: target, showsMacPicker: scope == .all) { start, directory in
                        create(start, directory: directory, on: target?.id)
                    }
                }
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
                list(WorkspaceListLayout(scope: scope, macs: macs, workspaces: store.workspaces, query: query))
            }
        }
    }

    private func list(_ layout: WorkspaceListLayout) -> some View {
        List {
            ForEach(linkLines, id: \.self) { line in
                Text(line)
                    .font(theme.type.meta)
                    .foregroundStyle(theme.colors.label2)
                    .lineLimit(2)
                    .listRowInsets(EdgeInsets(top: 4, leading: WorkspaceRow.textInset, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .contentTransition(.opacity)
                    .accessibilityIdentifier("mac-link-status")
            }
            ForEach(layout.sections) { section in
                Section {
                    RecencyHeader(title: section.title)
                    ForEach(section.workspaces) { ws in
                        row(ws)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .overlay { if layout.isEmpty { emptyState } }
        // An inset, not a `safeAreaBar`: with a bar the search drawer never
        // comes back on a pull-down once a long list has hidden it.
        .safeAreaInset(edge: .top, spacing: 0) {
            MacChipRow(macs: macs, scope: scope, linkStatus: store.macLinkStatus, select: select,
                       reconnect: reconnect)
                .background(theme.colors.bg.color)
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .background { PullDownSearch() }
        .modifier(OptionalRefresh(refresh: refresh))
        .animation(theme.motion.smooth.animation, value: layout.scope)
        .animation(theme.motion.smooth.animation, value: store.workspaces.map(\.id))
        .accessibilityIdentifier("workspaces.list")
    }

    /// The live link line ("Connected · WireGuard relay · 27 ms") for the
    /// chosen Mac, or for every Mac the app dials under All.
    private var linkLines: [String] {
        if let mac = scopedMac {
            return store.macLinkStatus[mac.id].map { [$0] } ?? []
        }
        return macs.compactMap { mac in store.macLinkStatus[mac.id].map { "\(mac.name): \($0)" } }
    }

    private func row(_ ws: Workspace) -> some View {
        let available = mac(ws.macID)?.isOnline ?? false
        let canManage = creator.canManage(ws)
        return Button {
            if available {
                open(ws)
            } else {
                theme.haptics.warning()
                unavailable = ws
            }
        } label: {
            WorkspaceRow(workspace: ws, isAvailable: available, isPending: store.isPending(ws.id),
                         macName: mac(ws.macID)?.name)
        }
        .buttonStyle(WorkspaceRowButtonStyle())
        .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        // Trailing only: a rightward swipe from the leading edge belongs to
        // the team sidebar. The system destructive style, no custom tint.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canManage {
                Button("Close", systemImage: "xmark", role: .destructive) { closing = ws }
                    // The app tints controls with the foreground color
                    // (white in dark mode), which turned this into a blank
                    // white pill. Back to the system tint: red for the role.
                    .tint(nil)
            }
        }
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contextMenu {
            Section(menuHeader(ws)) {
                Button("Open", systemImage: "arrow.up.forward.app") { open(ws) }
                    .disabled(!available)
                Button("Rename", systemImage: "pencil") {
                    renameText = ws.title
                    renaming = ws
                }
                .disabled(!canManage)
                Button("Close Workspace", systemImage: "xmark", role: .destructive) { closing = ws }
                    .disabled(!canManage)
            }
        }
        .accessibilityIdentifier("workspace.row.\(ws.id)")
    }

    /// "Aziz's Mac Studio · feat-cnx-ios", or the directory without a branch;
    /// "· Offline" for an offline Mac.
    private func menuHeader(_ ws: Workspace) -> String {
        let where_ = ws.branch ?? (ws.directory.isEmpty ? nil : ws.directory)
        var parts = [mac(ws.macID)?.name ?? "Unknown Mac"]
        if let where_ { parts.append(where_) }
        if mac(ws.macID)?.isOnline != true { parts.append("Offline") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var emptyState: some View {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search(text: query)
        } else if let mac = scopedMac {
            if mac.isOnline {
                let canCreate = target != nil
                EmptyState(
                    symbol: "macwindow",
                    title: "No workspaces on \(mac.name)",
                    message: canCreate ? "New workspaces open right away." : "\(mac.name) can't take new workspaces from this iPhone yet.",
                    primaryTitle: canCreate ? "New Workspace" : nil,
                    primary: canCreate ? { create(.terminal, directory: nil, on: mac.id) } : nil
                )
                .accessibilityIdentifier("workspaces.empty.mac")
            } else {
                EmptyState(
                    symbol: "moon.zzz",
                    title: "\(mac.name) is offline",
                    message: "\(RelativeStamp().presence(isOnline: false, lastSeenAt: mac.lastSeenAt)). Open cmux on it to see its workspaces."
                )
                .accessibilityIdentifier("workspaces.empty.offline")
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

    private func retry() {
        isRetrying = true
        Task {
            await Task.yield()
            store.teamDataState = .loaded
            isRetrying = false
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
            // so the first header sits right under the chips.
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

/// The Mac picker: a horizontally scrolling row of chips pinned under the
/// title. All, then each Mac, online first. The chosen chip is filled;
/// offline Macs' chips are dimmed. Holding a Mac chip shows its presence
/// (and Reconnect in live mode).
struct MacChipRow: View {
    let macs: [MacDevice]
    let scope: MacScope
    var linkStatus: [String: String] = [:]
    let select: (MacScope) -> Void
    var reconnect: ((String) -> Void)?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    MacChip(title: "All", isSelected: scope == .all, isOnline: true) { select(.all) }
                        .id(MacScope.all)
                        .accessibilityIdentifier("workspaces.chip.all")
                    ForEach(MacScope.chipOrder(macs)) { mac in
                        chip(mac).id(MacScope.mac(mac.id))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .onAppear { proxy.scrollTo(scope, anchor: .center) }
        }
    }

    private func chip(_ mac: MacDevice) -> some View {
        let presence = RelativeStamp().presence(isOnline: mac.isOnline, lastSeenAt: mac.lastSeenAt)
        return MacChip(title: mac.name, isSelected: scope == .mac(mac.id), isOnline: mac.isOnline) { select(.mac(mac.id)) }
            .accessibilityValue(presence)
            .accessibilityIdentifier("workspaces.chip.\(mac.id)")
            .contextMenu {
                Section([presence, linkStatus[mac.id]].compactMap(\.self).joined(separator: " · ")) {
                    Button("Show Workspaces", systemImage: "line.3.horizontal") { select(.mac(mac.id)) }
                    if mac.isOnline, let reconnect {
                        Button("Reconnect", systemImage: "arrow.clockwise") { reconnect(mac.id) }
                    }
                }
            }
    }
}

/// One chip: a capsule, filled with the foreground color when chosen.
struct MacChip: View {
    let title: String
    let isSelected: Bool
    let isOnline: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(theme.type.rowSubtitle.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .background(background, in: Capsule())
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isOnline ? "" : "Offline")
        .animation(theme.motion.snap.animation, value: isSelected)
    }

    private var foreground: Color {
        if isSelected { return theme.colors.onAccent.color.opacity(isOnline ? 1 : 0.7) }
        return isOnline ? theme.colors.label.color : theme.colors.label3.color
    }

    private var background: Color {
        if isSelected { return theme.colors.accent.color.opacity(isOnline ? 1 : 0.55) }
        return theme.colors.fill.color
    }
}

/// "Today", "Yesterday", …: small secondary text above its rows, scrolling
/// with them (not pinned), as in ChatGPT's history.
struct RecencyHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(theme.type.meta.weight(.semibold))
            .foregroundStyle(theme.colors.label2)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 18)
            .padding(.bottom, 6)
            .listRowInsets(EdgeInsets(top: 0, leading: WorkspaceRow.textInset, bottom: 0, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .accessibilityAddTraits(.isHeader)
    }
}

/// SPEC 11.1 workspace row, ChatGPT history style: the name on one line in
/// `body`, and a small dot in a leading gutter only while an agent needs
/// the user (`warning`) or is working (the foreground color, pulsing).
struct WorkspaceRow: View {
    let workspace: Workspace
    /// The Mac is online; offline rows are dimmed and explain on tap.
    var isAvailable = true
    /// Being created on the Mac (optimistic row).
    var isPending = false
    var macName: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Where row text starts from the screen edge (rows, headers, chip text).
    static let textInset: CGFloat = 30
    /// The dot's gutter, inside the row's 10 pt inset and 10 pt padding.
    static let gutter: CGFloat = 14

    var body: some View {
        HStack(spacing: 0) {
            indicator
                .frame(width: Self.gutter, alignment: .leading)
            Text(workspace.title)
                .font(theme.type.rowTitle)
                .foregroundStyle(isAvailable ? theme.colors.label : theme.colors.label3)
                .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, Self.textInset - 10 - Self.gutter)
        .padding(.trailing, 10)
        .padding(.vertical, 11)
        .frame(minHeight: 46)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityHint(isAvailable ? "" : "\(macName ?? "Its Mac") is offline")
        .accessibilityAddTraits(.isButton)
    }

    private enum Status { case none, needsYou, working, pending }

    private var status: Status {
        if isPending { return .pending }
        guard isAvailable else { return .none }
        if workspace.needsAttention { return .needsYou }
        if workspace.isWorking { return .working }
        return .none
    }

    @ViewBuilder private var indicator: some View {
        switch status {
        case .none: Color.clear.frame(width: 1, height: 1)
        case .pending: ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 7, height: 7)
        case .needsYou:
            Circle().fill(theme.colors.warning.color).frame(width: 7, height: 7)
                .accessibilityIdentifier("workspace.needs-you")
        case .working:
            WorkingDot().accessibilityIdentifier("workspace.working")
        }
    }

    private var spoken: String {
        var parts = [workspace.title]
        switch status {
        case .needsYou: parts.append("Needs you")
        case .working: parts.append("Agent working")
        case .pending: parts.append("Creating")
        case .none: break
        }
        if !isAvailable { parts.append("Unavailable while offline") }
        return parts.joined(separator: ", ")
    }
}

/// The working dot: the foreground color, breathing (static with Reduce Motion).
private struct WorkingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(theme.colors.label.color)
            .frame(width: 7, height: 7)
            .phaseAnimator(reduceMotion ? [1.0] : [1.0, 0.3]) { dot, opacity in
                dot.opacity(opacity)
            } animation: { _ in .easeInOut(duration: 0.9) }
    }
}

/// The row's pressed state: a rounded fill, like ChatGPT's selected chat.
private struct WorkspaceRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(configuration.isPressed ? theme.colors.fillSelected.color : .clear)
            )
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
    /// The Mac a tap creates on: the chosen chip's Mac, else the preferred one.
    let target: MacDevice?
    /// The Mac picker is offered only under the All chip; with one Mac
    /// chosen, the chip row is where the Mac changes.
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
