#if os(iOS)
import CmuxAgentBrands
import CnxAgentChat
import CnxDesign
import CnxModel
import SwiftUI
import UIKit

private let theme = CnxTheme.standard

/// One agent conversation in the Home list (an agent tab of a workspace).
struct AgentConversation: Identifiable, Hashable {
    let workspaceID: String
    let tabID: String
    /// The row's title: the workspace ("cmux"); a workspace's second and
    /// later agent tabs add the agent ("cmux · Codex").
    let title: String
    let name: String
    let workspaceTitle: String
    let harness: String
    let preview: String
    let date: Date
    let needsYou: Bool
    var id: String { tabID }
}

/// Markdown to one plain line, as a list preview: the rows, Chief's pin
/// bubble and its VoiceOver label (F4).
func plainPreview(_ markdown: String) -> String {
    markdown
        .replacingOccurrences(of: "```[a-z]*", with: "", options: .regularExpression)
        .replacingOccurrences(of: "[*_`#>]", with: "", options: .regularExpression)
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
}

/// Home (SPEC 3.1, 6): a Messages-style conversation list. Chief is pinned
/// in Messages' pinned grid at the top (large avatar, preview or typing
/// bubble above it); agent conversations follow as Messages rows (unread
/// dot gutter, 45 pt monogram, name, date and chevron, two-line preview,
/// swipe actions). Chief pushes the CmuxConversation transcript; agents push
/// their chat.
public struct ConversationsHome<Leading: ToolbarContent>: View {
    let store: AppStore
    /// The Cloud Chief (the default once it answers) and the Mac Chief.
    let sources: ChiefSources
    let leading: Leading
    let open: (HomeConversationRoute) -> Void
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var unread: Set<String> = []
    @State private var muted: Set<String> = []
    @State private var deleted: Set<String> = []
    /// The New Chief name prompt is up.
    @State private var namingChief = false
    @State private var newChiefName = ""

    enum Filter: String, CaseIterable, Identifiable {
        case all, unread, needsYou
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .all: "All Conversations"
            case .unread: "Unread"
            case .needsYou: "Needs You"
            }
        }
    }

    /// `open` pushes a conversation New Message opened onto Home's stack.
    public init(store: AppStore, sources: ChiefSources = .shared,
                open: @escaping (HomeConversationRoute) -> Void,
                @ToolbarContentBuilder leading: () -> Leading) {
        self.store = store
        self.sources = sources
        self.open = open
        self.leading = leading()
    }

    /// The default Chief: compose, New Message and the first pin.
    private var session: ChiefSession { sources.primary }

    private var agents: [AgentConversation] {
        var all: [AgentConversation] = []
        for workspace in store.activeWorkspaces {
            for tab in workspace.tabs where tab.kind == .agent {
                all.append(conversation(tab, in: workspace))
            }
        }
        return all
            .filter { !deleted.contains($0.id) && matches($0) }
            .sorted { $0.date > $1.date }
    }

    private func conversation(_ tab: WorkspaceTab, in workspace: Workspace) -> AgentConversation {
        let chat = AgentSessionDirectory.shared.existingStore(id: tab.id)
        let lastTurn = chat?.turns.last
        let answer: String? = lastTurn.map { $0.answerMarkdown.isEmpty ? $0.prompt : $0.answerMarkdown }
        let agentTabs = workspace.tabs.filter { $0.kind == .agent }
        return AgentConversation(
            workspaceID: workspace.id, tabID: tab.id,
            title: Self.title(of: tab, in: workspace.title, agentIDs: agentTabs.map(\.id)),
            name: tab.title, workspaceTitle: workspace.title,
            harness: tab.harness ?? "claude",
            preview: Self.plain(answer ?? tab.subtitle ?? ""),
            date: lastTurn?.promptAt ?? workspace.lastActivityAt,
            needsYou: workspace.needsAttention && tab.id == agentTabs.first?.id
        )
    }

    /// A row's title (SPEC 1.2): the workspace, and for its second and later
    /// agent tabs the agent too, so rows read by topic, not by "Claude".
    static func title(of tab: WorkspaceTab, in workspace: String, agentIDs: [String]) -> String {
        guard let index = agentIDs.firstIndex(of: tab.id), index > 0 else { return workspace }
        return "\(workspace) · \(tab.title)"
    }

    private func matches(_ conversation: AgentConversation) -> Bool {
        let passesFilter: Bool = switch filter {
        case .all: true
        case .unread: unread.contains(conversation.id)
        case .needsYou: conversation.needsYou
        }
        guard passesFilter else { return false }
        if query.isEmpty { return true }
        let haystack = "\(conversation.name) \(conversation.workspaceTitle) \(conversation.preview)"
        return haystack.localizedCaseInsensitiveContains(query)
    }

    /// Chief's pin follows the filter too (SPEC 1.6): Unread while it has
    /// unread messages, Needs You while it waits on the user.
    private var showsChief: Bool { shows(session) || sources.secondary.map(shows) == true }

    private func shows(_ session: ChiefSession) -> Bool {
        let passesFilter: Bool = switch filter {
        case .all: true
        case .unread: session.unreadCount > 0
        case .needsYou: session.needsYou
        }
        guard passesFilter else { return false }
        return query.isEmpty || "chief \(session.preview)".localizedCaseInsensitiveContains(query)
    }

    /// Markdown to one plain line, as a list preview.
    static func plain(_ markdown: String) -> String { plainPreview(markdown) }

    public var body: some View {
        let stamp = MessagesStamp()
        List {
            if showsChief {
                HStack(alignment: .bottom, spacing: 0) {
                    if shows(session) {
                        PinnedGrid(session: session, route: ChiefRoute(place: sources.primaryPlace), name: primaryName,
                                   identifier: "home.chief", cloud: sources.isCloudReady ? sources : nil,
                                   newChief: startNewChief)
                    }
                    if let mac = sources.secondary, shows(mac) {
                        PinnedGrid(session: mac, route: ChiefRoute(place: .mac), name: String(localized: "Mac Chief"),
                                   identifier: "home.chief.mac")
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(theme.colors.bg.color)
            }
            // The Cloud Chief could not take the pin: say why, under the Mac Chief.
            if filter == .all, query.isEmpty, let status = sources.cloudStatus {
                VStack(spacing: 6) {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(theme.colors.label2.color)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("home.chief.cloudStatus")
                    cloudActions
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(theme.colors.bg.color)
            }
            let rows = agents
            if filter != .all, rows.isEmpty, !showsChief {
                Text("No Conversations")
                    .font(.callout)
                    .foregroundStyle(theme.colors.label2.color)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 120)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(theme.colors.bg.color)
            }
            ForEach(rows) { conversation in
                NavigationLink(value: AgentChatDestination(workspaceID: conversation.workspaceID, tabID: conversation.tabID)) {
                    MessagesRow(
                        title: conversation.title,
                        agent: conversation.title.hasSuffix("· \(conversation.name)") ? nil : conversation.name,
                        preview: conversation.preview,
                        stamp: stamp.string(for: conversation.date),
                        isUnread: unread.contains(conversation.id),
                        isMuted: muted.contains(conversation.id),
                        needsYou: conversation.needsYou
                    ) { size in
                        AgentAvatar(harness: conversation.harness, size: size)
                    }
                }
                .navigationLinkIndicatorVisibility(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 16))
                .listRowBackground(theme.colors.bg.color)
                // Trailing only: a rightward pan on a tab root opens the team
                // drawer (SPEC swipe rules). Messages' set, outermost first.
                .swipeActions(edge: .trailing) {
                    Button("Delete", systemImage: "trash", role: .destructive) { deleted.insert(conversation.id) }
                        // The shell tints every tab with the label color (white in
                        // dark mode); clear it so the destructive role draws the
                        // system red, as in Mail.
                        .tint(nil)
                    Button(muted.contains(conversation.id) ? "Show Alerts" : "Hide Alerts",
                           systemImage: muted.contains(conversation.id) ? "bell" : "bell.slash") {
                        toggle(&muted, conversation.id)
                    }
                    .tint(Color(uiColor: .systemIndigo))
                    Button(unread.contains(conversation.id) ? "Read" : "Unread",
                           systemImage: unread.contains(conversation.id) ? "message" : "message.badge") {
                        toggle(&unread, conversation.id)
                    }
                    .tint(Color(uiColor: .systemBlue))
                }
                .contextMenu {
                    Button(unread.contains(conversation.id) ? "Mark as Read" : "Mark as Unread", systemImage: "message.badge") {
                        toggle(&unread, conversation.id)
                    }
                    Button(muted.contains(conversation.id) ? "Show Alerts" : "Hide Alerts", systemImage: "bell.slash") {
                        toggle(&muted, conversation.id)
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) { deleted.insert(conversation.id) }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.colors.bg.color.ignoresSafeArea())
        // Workspaces' search: the native drawer, revealed by a pull-down.
        .cnxPullDownSearch(text: $query)
        // No visible title (user feedback): Chief's pin sits right under the
        // toolbar. The title still names the screen for
        // VoiceOver and the back menu.
        .navigationTitle("Conversations")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbar {
            leading
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Filter", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    // A Label, not a bare Image: the bar then hosts a native button whose touch
                    // area covers the whole 44 pt glass circle (a bare Image label was 36 pt).
                    Label("Filter", systemImage: filter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityLabel("Filter")
                // Compose opens the Chief conversation with the keyboard up
                // (SPEC 1.4): the phone cannot create conversations, so
                // every other recipient is already a row here, and Chief
                // routes work to agents itself.
                Button("New Message to Chief", systemImage: "square.and.pencil") {
                    open(.chiefComposing(sources.primaryPlace))
                }
                .accessibilityIdentifier("home.compose")
            }
        }
        .navigationDestination(for: ChiefRoute.self) { route in
            let chief = sources.session(for: route.place)
            ChiefConversationScreen(session: chief, compose: ChiefComposer(store: store, session: chief, open: open),
                                    focusesComposer: route.focusesComposer)
        }
        // Back on Home: look for the Cloud Chief again if it was not reachable.
        .task { sources.refreshIfNeeded() }
        .alert("New Chief", isPresented: $namingChief) {
            TextField("Name", text: $newChiefName)
                .accessibilityIdentifier("home.chief.newName")
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = newChiefName
                Task { await sources.createChief(named: name) }
            }
            .accessibilityIdentifier("home.chief.newCreate")
        } message: {
            Text("A new Cloud Chief with its own conversation and memory.")
        }
        .animation(theme.motion.smooth.animation, value: filter)
        .animation(theme.motion.smooth.animation, value: deleted)
    }

    /// The first pin's name: the Cloud Chief's own name once it is the default.
    private var primaryName: String {
        if let chief = sources.cloudChief, !chief.displayName.isEmpty { return chief.displayName }
        return String(localized: "Chief")
    }

    private func startNewChief() {
        newChiefName = String(localized: "Chief")
        namingChief = true
    }

    /// Under the Cloud status: make a chief, turn its brain on, or open another one.
    @ViewBuilder private var cloudActions: some View {
        HStack(spacing: 12) {
            switch sources.cloudAction {
            case .create:
                Button("Create Cloud Chief", action: startNewChief)
                    .accessibilityIdentifier("home.chief.create")
            case let .turnOn(chief):
                Button("Turn On Cloud Chief") { Task { await sources.turnOn(chief) } }
                    .accessibilityIdentifier("home.chief.turnOn")
            case nil:
                EmptyView()
            }
            if sources.cloudChiefs.count > 1 {
                ChiefPickerMenu(sources: sources, newChief: startNewChief) {
                    Text("Other Chiefs")
                }
            }
        }
        .font(.footnote.weight(.semibold))
        .buttonStyle(.borderless)
        .disabled(sources.isChanging)
        if sources.isChanging {
            ProgressView().controlSize(.small)
        }
        if let error = sources.changeError {
            Text(error)
                .font(.footnote)
                .foregroundStyle(Color(uiColor: .systemRed))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("home.chief.changeError")
        }
    }

    private func toggle(_ set: inout Set<String>, _ id: String) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        theme.haptics.selection()
    }
}

/// Messages' pinned conversations: a grid of large avatars with names, a
/// preview (or typing) bubble above an avatar with something new.
struct PinnedGrid: View {
    let session: ChiefSession
    /// Which Chief the pin opens.
    var route = ChiefRoute()
    var name = String(localized: "Chief")
    var identifier = "home.chief"
    /// The Cloud Chief's pin: its menu lists the account's other chiefs.
    var cloud: ChiefSources?
    var newChief: (() -> Void)?

    var body: some View {
        NavigationLink(value: route) {
            pin
                .frame(maxWidth: .infinity)
                // The bubble rides above the avatar: room for it, so it
                // keeps clear of the bar and the search drawer at every size (F3).
                .padding(.top, showsBubble ? 14 + bubbleClearance : 14)
                .padding(.bottom, 10)
                .contentShape(.rect)
        }
        .navigationLinkIndicatorVisibility(.hidden)
        .buttonStyle(.plain)
        .contextMenu {
            if session.conversationID != nil {
                Button(session.isMuted ? "Show Alerts" : "Hide Alerts", systemImage: session.isMuted ? "bell" : "bell.slash") {
                    session.setMuted(!session.isMuted)
                }
            }
            if let cloud {
                ChiefPickerItems(sources: cloud, newChief: newChief)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(identifier)
        .animation(theme.motion.snappy.animation, value: session.isWorking)
        .animation(theme.motion.snappy.animation, value: showsPreview)
        .animation(theme.motion.snappy.animation, value: showsBubble)
    }

    /// The preview bubble: something unread, or Chief waiting on the user
    /// (an unsent message, or a question not yet opened), which stays up
    /// after the unread count clears until the chat is opened (SPEC 1.5).
    private var showsPreview: Bool {
        session.unreadCount > 0 || session.isWaitingOnYou
    }

    private var showsBubble: Bool { session.isWorking || showsPreview }

    /// Extra top room while a bubble shows, growing with the text (the
    /// search drawer above does too). Measured round 2: 10 pt left 8 pt at Large
    /// and 4 pt at AX5; scaled, capped at 18 pt, it leaves at least 6 pt at
    /// every size (R2-7).
    @ScaledMetric(relativeTo: .body) private var scaledClearance: CGFloat = 10
    private var bubbleClearance: CGFloat { min(max(scaledClearance, 10), 18) }

    private var previewText: String { plainPreview(session.preview) }

    private var accessibilityLabel: Text {
        if session.isWorking { return Text("\(name), typing") }
        if showsPreview { return Text("\(name), \(previewText)") }
        return Text("\(name), pinned")
    }

    private var pin: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                ChiefAvatar(text: session.avatar, size: 88)
                if session.isWorking {
                    TypingBubble()
                        .offset(x: -14, y: -18)
                        .transition(.scale(scale: 0.6, anchor: .bottomTrailing).combined(with: .opacity))
                } else if showsPreview {
                    Text(previewText)
                        .font(.caption2)
                        // A glance, not the message: it stays a small bubble
                        // over the avatar at accessibility sizes too.
                        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                        .lineLimit(2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: 110, alignment: .leading)
                        .background(theme.colors.surfaceRaised.color, in: .rect(cornerRadius: 12, style: .continuous))
                        .offset(x: -24, y: -26)
                        .transition(.scale(scale: 0.6, anchor: .bottomTrailing).combined(with: .opacity))
                }
            }
            HStack(spacing: 4) {
                if session.unreadCount > 0 {
                    Circle().fill(theme.colors.label.color).frame(width: 8, height: 8)
                }
                Text(name)
                    .font(.footnote)
                    .foregroundStyle(theme.colors.label.color)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if session.isMuted {
                    Image(systemName: "bell.slash.fill")
                        .font(.caption2)
                        .foregroundStyle(theme.colors.label3.color)
                        .accessibilityLabel("Alerts hidden")
                }
            }
        }
        .frame(minWidth: 110)
    }
}

/// A Messages conversation row: the unread (or needs-you) gutter, the
/// avatar, the title with the date and chevron, and a two-line preview. At
/// accessibility text sizes it stacks as Messages does (SPEC 1.7): the
/// title on its own lines, then the date and chevron, then the preview.
struct MessagesRow<Avatar: View>: View {
    let title: String
    /// The agent, for VoiceOver (F5): the avatar mark says it to the eye
    /// only. nil when the title already names it ("cmux · Codex").
    var agent: String?
    let preview: String
    let stamp: String
    let isUnread: Bool
    let isMuted: Bool
    let needsYou: Bool
    @ViewBuilder let avatar: (CGFloat) -> Avatar
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var scaledAvatar: CGFloat = 45

    /// 45 pt at Large, scaled with the text, at most 64 pt.
    private var avatarSize: CGFloat { min(max(scaledAvatar, 45), 64) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            gutter
                .frame(width: 26, height: avatarSize)
            avatar(avatarSize)
                .padding(.trailing, 12)
            Group {
                if typeSize.isAccessibilitySize { stacked } else { standard }
            }
            // The separator starts under the text, as in Messages.
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
        .padding(.vertical, 12)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// "Needs you, cmux, Claude, 1:46 AM, Refactor transport layer".
    private var accessibilityText: String {
        var parts: [String] = []
        if isUnread { parts.append(String(localized: "Unread")) } else if needsYou { parts.append(String(localized: "Needs you")) }
        parts.append(title)
        if let agent { parts.append(agent) }
        parts.append(stamp)
        if !preview.isEmpty { parts.append(preview) }
        if isMuted { parts.append(String(localized: "Alerts hidden")) }
        return parts.joined(separator: ", ")
    }

    /// Messages keeps a gutter for the unread dot. Unread wins; then the
    /// needs-you dot; then the muted bell.
    @ViewBuilder private var gutter: some View {
        if isUnread {
            Circle().fill(theme.colors.label.color).frame(width: 10, height: 10)
                .accessibilityLabel("Unread")
        } else if needsYou {
            Circle().fill(theme.colors.needsYou.color).frame(width: 10, height: 10)
                .accessibilityLabel("Needs you")
        } else if isMuted {
            Image(systemName: "bell.slash.fill").font(.system(size: 10)).foregroundStyle(theme.colors.label2.color)
                .accessibilityLabel("Alerts hidden")
        } else {
            Color.clear
        }
    }

    private var titleText: some View {
        Text(title).font(.body.weight(.semibold))
    }

    private var dateAndChevron: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(stamp)
                .font(.subheadline)
                .foregroundStyle(theme.colors.label2.color)
                .lineLimit(1)
                .fixedSize()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(theme.colors.label3.color)
                .accessibilityHidden(true)
        }
    }

    private func previewText(lines: Int) -> some View {
        Text(preview.isEmpty ? " " : preview)
            .font(.subheadline)
            .foregroundStyle(theme.colors.label2.color)
            .lineLimit(lines, reservesSpace: true)
    }

    private var standard: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                titleText.lineLimit(1)
                Spacer(minLength: 4)
                dateAndChevron
            }
            previewText(lines: 2)
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 2) {
            titleText
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            dateAndChevron
            Text(preview.isEmpty ? " " : preview)
                .font(.subheadline)
                .foregroundStyle(theme.colors.label2.color)
                .lineLimit(3)
        }
    }
}

/// Contacts' monogram gradient as Messages draws it (measured from the
/// iOS 26 / 27 simulator: a muted slate, lighter at the top).
let monogramGradient = LinearGradient(
    colors: [Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.33, green: 0.32, blue: 0.45, alpha: 1) : UIColor(red: 0.66, green: 0.68, blue: 0.75, alpha: 1) }),
             Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.19, green: 0.18, blue: 0.27, alpha: 1) : UIColor(red: 0.53, green: 0.55, blue: 0.62, alpha: 1) })],
    startPoint: .top, endPoint: .bottom
)

/// Messages' monogram: initials on the contact gradient circle.
struct Monogram: View {
    let text: String
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(monogramGradient)
            .overlay {
                Text(text).font(.system(size: size * 0.4, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Chief's avatar: its avatar text (the Mac's, else "C") white on the
/// monogram gradient, the one drawing of Chief everywhere (SPEC 2).
struct ChiefAvatar: View {
    let text: String
    let size: CGFloat

    var body: some View {
        Monogram(text: text, size: size)
    }
}

/// An agent conversation's avatar: the harness's mark (Claude, Codex)
/// white on the monogram gradient, 20 pt at the row's 45 pt.
struct AgentAvatar: View {
    let harness: String
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(monogramGradient)
            .overlay {
                AgentBrandMark(agent: harness, size: size * 20 / 45)
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The three-dot typing bubble Messages shows on a pinned avatar.
struct TypingBubble: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(theme.colors.label2.color)
                        .frame(width: 7, height: 7)
                        .opacity(0.35 + 0.65 * max(0, sin((t * 4) - Double(index) * 0.8)))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(theme.colors.surfaceRaised.color, in: .capsule)
        }
        .accessibilityLabel("Typing")
    }
}

/// The account's Cloud Chiefs, the open one checked, and New Chief.
struct ChiefPickerItems: View {
    let sources: ChiefSources
    var newChief: (() -> Void)?

    var body: some View {
        Section("Cloud Chiefs") {
            ForEach(sources.cloudChiefs.filter { $0.mainConversation != nil }, id: \.id) { chief in
                Button {
                    sources.select(chief)
                } label: {
                    if chief.id == sources.cloudChief?.id {
                        Label(Self.name(chief), systemImage: "checkmark")
                    } else {
                        Text(Self.name(chief))
                    }
                }
            }
            if let newChief {
                Button("New Chief", systemImage: "plus", action: newChief)
            }
        }
    }

    static func name(_ chief: CloudChief) -> String {
        chief.displayName.isEmpty ? String(localized: "Chief") : chief.displayName
    }
}

/// ``ChiefPickerItems`` as a menu button.
struct ChiefPickerMenu<MenuLabel: View>: View {
    let sources: ChiefSources
    var newChief: (() -> Void)?
    @ViewBuilder let label: () -> MenuLabel

    var body: some View {
        Menu {
            ChiefPickerItems(sources: sources, newChief: newChief)
        } label: {
            label()
        }
        .accessibilityIdentifier("home.chief.picker")
    }
}
#endif
