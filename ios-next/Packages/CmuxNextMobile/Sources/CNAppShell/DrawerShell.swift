#if os(iOS)
import CNAgentUI
import CNCore
import CNDesign
import CNSettingsUI
import CNTransport
import SwiftUI

/// ChatGPT-style shell: a push-aside sidebar under a full-width content card.
struct DrawerShell: View {
    let model: AppModel
    @State private var drawer = DrawerState()
    @State private var destination: ShellDestination = .initial
    @State private var visited: Set<ShellDestination> = [.initial]
    @State private var route: CNShellRoute?

    var body: some View {
        DrawerContainer(
            state: drawer,
            sidebar: DrawerSidebar(model: model, drawer: drawer, destination: destination, onSelect: select)
                .modifier(ShellEnvironment(model: model)),
            content: content.modifier(ShellEnvironment(model: model))
        )
        .ignoresSafeArea()
        .task { await model.shellData.run() }
        .task(id: ShellDataKey(generation: model.connection.generation, connected: model.connection.state.isConnected)) {
            await model.shellData.reloadIfNeeded()
        }
    }

    private var content: some View {
        let roots = ModuleRoots(model: model)
        return ZStack {
            ForEach(ShellDestination.allCases, id: \.self) { d in
                if visited.contains(d) {
                    roots.root(for: d)
                        .opacity(d == destination ? 1 : 0)
                        .allowsHitTesting(d == destination)
                        .accessibilityHidden(d != destination)
                        .cnStatusBarStyleSuppressed(d != destination)
                }
            }
        }
        .overlay(alignment: .top) {
            // Terminals show their own reconnecting toast; one indicator at a time.
            if !model.connection.state.isConnected, destination != .terminals {
                ConnectionPill(state: model.connection.state)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(CNTheme.shared.motion.fade, value: model.connection.state.isConnected)
        .background(Color.cn(\.background))
        .environment(\.cnLeadingBarItem, AnyView(HamburgerButton { drawer.open() }))
        .environment(\.cnShellRoute, route)
        .environment(\.cnDrawerIsOpen, drawer.isOpen)
        // The content lives in its own hosting controller, so its status
        // bar request is forwarded through the model (sidebar open: default).
        .onCNStatusBarStyleChange { [model, drawer] style in
            model.requestedContentStatusBarStyle = style
            model.statusBarStyle = drawer.isOpen ? nil : style
        }
        .onChange(of: drawer.isOpen) { _, open in
            model.statusBarStyle = open ? nil : model.requestedContentStatusBarStyle
        }
    }

    private func select(_ target: ShellDestination, _ newRoute: CNShellRoute?) {
        visited.insert(target)
        destination = target
        route = newRoute
        drawer.close()
    }
}

/// Environment the shells re-apply inside their UIKit-hosted subtrees.
struct ShellEnvironment: ViewModifier {
    let model: AppModel
    func body(content: Content) -> some View {
        content
            .environment(\.cnTerminalFontSize, CGFloat(model.preferences.terminalFontSize))
            .tint(.cn(\.ink))
    }
}

struct HamburgerButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "line.3.horizontal")
        }
        .accessibilityLabel("Open sidebar")
        .accessibilityIdentifier("shell.hamburger")
    }
}

/// The drawer's sidebar: search + compose, destinations with their items, and
/// the selected Mac + account footer.
struct DrawerSidebar: View {
    let model: AppModel
    let drawer: DrawerState
    let destination: ShellDestination
    let onSelect: (ShellDestination, CNShellRoute?) -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var data: ShellDataModel { model.shellData }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    section(.home, items: conversations.prefix(searching ? 50 : 6).map { c in
                        SidebarItem(id: c.id, title: c.title, subtitle: c.lastMessage?.text, unread: c.unread > 0,
                                    route: CNShellRoute(kind: .conversation, id: c.id))
                    })
                    section(.agents, items: sessions.prefix(searching ? 50 : 8).map { s in
                        SidebarItem(id: s.id, title: s.title, subtitle: s.preview, unread: AgentReadState.shared.isUnread(s),
                                    status: Self.statusColor(s.status), route: CNShellRoute(kind: .agentSession, id: s.id))
                    })
                    section(.terminals, items: terminals.prefix(searching ? 50 : 5).map { t in
                        SidebarItem(id: t.id, title: t.title, subtitle: t.cwd, unread: false,
                                    status: t.running ? nil : .cn(\.textTertiary), route: CNShellRoute(kind: .terminal, id: t.id))
                    })
                    section(.browser, items: tabs.prefix(searching ? 50 : 5).map { tab in
                        SidebarItem(id: tab.id, title: tab.title.isEmpty ? tab.url : tab.title, subtitle: URL(string: tab.url)?.host(),
                                    unread: false, route: CNShellRoute(kind: .browserTab, id: tab.id))
                    })
                    if !searching {
                        DestinationRow(destination: .settings, selected: destination == .settings) { onSelect(.settings, nil) }
                            .padding(.top, 8)
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.immediately)
            footer
        }
        .background(Color.cn(\.background))
        .onChange(of: drawer.isOpen) { _, open in if !open { searchFocused = false } }
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private func matches(_ strings: String?...) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return strings.contains { $0?.localizedCaseInsensitiveContains(q) == true }
    }

    private var conversations: [Conversation] { data.conversations.filter { matches($0.title, $0.lastMessage?.text) } }
    private var sessions: [AgentSession] { data.sessions.filter { matches($0.title, $0.preview, $0.harness) } }
    private var terminals: [Terminal] { data.terminals.filter { matches($0.title, $0.cwd) } }
    private var tabs: [BrowserTab] { data.tabs.filter { matches($0.title, $0.url) } }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.cn(\.textTertiary))
                TextField("Search", text: $query)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("sidebar.search")
                if searching {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .foregroundStyle(.cn(\.textTertiary))
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .glassEffect(.regular.interactive(), in: .capsule)

            Button {
                onSelect(.home, CNShellRoute(kind: .compose))
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.cn(\.icon))
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("New chat")
            .accessibilityIdentifier("sidebar.compose")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func section(_ target: ShellDestination, items: [SidebarItem]) -> some View {
        if !searching || !items.isEmpty {
            DestinationRow(destination: target, selected: destination == target) { onSelect(target, nil) }
                .padding(.top, target == .home ? 0 : 10)
            ForEach(items) { item in
                Button {
                    onSelect(target, item.route)
                } label: {
                    HStack(spacing: 10) {
                        // Leading dot: unread, from the item's `unread` count in
                        // every section (same rule as Home).
                        Circle()
                            .fill(item.unread ? Color.cn(\.ink) : .clear)
                            .frame(width: 7, height: 7)
                            .accessibilityLabel(item.unread ? "Unread" : "")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(.body)
                                .foregroundStyle(.cn(\.textPrimary))
                                .lineLimit(1)
                            if let subtitle = item.subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.footnote)
                                    .foregroundStyle(.cn(\.textSecondary))
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        if let status = item.status {
                            Circle().fill(status).frame(width: 7, height: 7)
                        }
                    }
                    .padding(.leading, 24)
                    .padding(.trailing, 16)
                    .padding(.vertical, 7)
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SidebarRowStyle())
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.cn(\.hairline)).frame(height: 1)
            HStack(spacing: 12) {
                Button { onSelect(.settings, nil) } label: {
                    HStack(spacing: 10) {
                        Text(initials)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.cn(\.textPrimary))
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color.cn(\.personAvatar)))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.auth.state.user?.displayName ?? "Not signed in")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.cn(\.textPrimary))
                                .lineLimit(1)
                            hostLine
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar.account")

                hostMenu
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var hostLine: some View {
        let summary = ConnectionSummary(model.connection.state)
        return HStack(spacing: 5) {
            Circle().fill(summary.tone.color).frame(width: 6, height: 6)
            Text([model.selectedHost?.name ?? model.connection.hostInfo?.hostName, summary.compact].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.cn(\.textSecondary))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("shell.connectionPill")
    }

    private var hostMenu: some View {
        Menu {
            ForEach(model.hosts.hosts) { host in
                Button {
                    model.selectHost(host.id)
                } label: {
                    if host.id == model.preferences.selectedHostId {
                        Label(host.name, systemImage: "checkmark")
                    } else {
                        Text(host.online ? host.name : "\(host.name) (offline)")
                    }
                }
            }
            Divider()
            Button("Settings", systemImage: "gearshape") { onSelect(.settings, nil) }
        } label: {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 17))
                .foregroundStyle(.cn(\.icon))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Choose Mac")
        .accessibilityIdentifier("sidebar.hostMenu")
    }

    private var initials: String {
        let name = model.auth.state.user?.displayName ?? "?"
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "@" || $0 == "." }).prefix(2)
        return parts.compactMap(\.first).map { String($0).uppercased() }.joined()
    }

    static func statusColor(_ status: AgentSessionStatus) -> Color? {
        switch status {
        case .running: .cn(\.success)
        case .waiting: .cn(\.attention)
        case .error: .cn(\.danger)
        case .idle: .cn(\.textTertiary)
        default: nil
        }
    }
}

struct SidebarItem: Identifiable {
    var id: String
    var title: String
    var subtitle: String?
    /// Leading ink dot (unread).
    var unread: Bool
    /// Trailing state dot (agent status, exited terminal).
    var status: Color? = nil
    var route: CNShellRoute
}

struct DestinationRow: View {
    let destination: ShellDestination
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: destination.symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(.cn(\.icon))
                    .frame(width: 24)
                Text(destination.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.cn(\.textPrimary))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: CNTheme.shared.metrics.itemRadius, style: .continuous)
                .fill(selected ? Color.cn(\.fillSelection) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowStyle())
        .padding(.horizontal, 8)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("sidebar.\(destination.rawValue)")
    }
}

struct SidebarRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.cn(\.fillHover) : .clear)
    }
}
#endif
