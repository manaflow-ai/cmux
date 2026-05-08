import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var store: CmxConnectionStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if horizontalSizeClass == .compact {
            NavigationStack {
                WorkspaceListView(navigationStyle: .push)
                    .navigationDestination(for: WorkspaceNavigationRoute.self) { route in
                        TerminalDetailView()
                            .onAppear {
                                store.select(workspaceID: route.workspaceID)
                            }
                    }
            }
        } else {
            NavigationSplitView {
                WorkspaceListView(navigationStyle: .sidebar)
            } detail: {
                TerminalDetailView()
            }
        }
    }
}

private struct WorkspaceListView: View {
    @EnvironmentObject private var store: CmxConnectionStore
    @State private var searchText = ""
    @State private var visibilityFilter = CmxWorkspaceVisibilityFilter.all
    @State private var listScope = WorkspaceListScope.recent
    @State private var isShowingSettings = false
    let navigationStyle: WorkspaceNavigationStyle

    private var scopedWorkspaces: [CmxWorkspace] {
        let workspaces = store.visibleWorkspaces(matching: searchText, filter: visibilityFilter)
        switch listScope {
        case .recent, .groupedByNode:
            return workspaces
        case .node(let nodeID):
            return workspaces.filter { $0.nodeID == nodeID }
        }
    }

    private var rows: [WorkspaceListRowSnapshot] {
        let selectedWorkspaceID = store.selectedWorkspaceID
        return scopedWorkspaces.map { workspace in
            let node = store.node(for: workspace)
            return WorkspaceListRowSnapshot(
                workspace: workspace,
                node: node,
                isHiddenUnavailable: store.hiddenUnavailableNodeIDs.contains(node.id),
                isSelected: navigationStyle == .sidebar && workspace.id == selectedWorkspaceID
            )
        }
    }

    private var groupedSections: [WorkspaceNodeSectionSnapshot] {
        let grouped = Dictionary(grouping: rows, by: { $0.node.id })
        return grouped.compactMap { _, rows in
            guard let first = rows.first else { return nil }
            return WorkspaceNodeSectionSnapshot(
                node: first.node,
                rows: rows.sorted { lhs, rhs in
                    if lhs.workspace.lastActivity != rhs.workspace.lastActivity {
                        return lhs.workspace.lastActivity > rhs.workspace.lastActivity
                    }
                    return lhs.workspace.title.localizedCaseInsensitiveCompare(rhs.workspace.title) == .orderedAscending
                }
            )
        }
        .sorted { lhs, rhs in
            if lhs.latestActivity != rhs.latestActivity {
                return lhs.latestActivity > rhs.latestActivity
            }
            return lhs.node.name.localizedCaseInsensitiveCompare(rhs.node.name) == .orderedAscending
        }
    }

    var body: some View {
        List {
            if !store.workspaces.isEmpty || !searchText.isEmpty {
                WorkspaceSearchField(text: $searchText)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 14, trailing: 16))
                    .listRowSeparator(.hidden)
            }

            if rows.isEmpty {
                EmptyWorkspaceSearch(
                    isSearching: !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    isLoading: store.isAwaitingInitialWorkspaceSnapshot
                )
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 18, leading: 16, bottom: 18, trailing: 16))
            } else {
                if listScope == .groupedByNode {
                    ForEach(groupedSections) { section in
                        Section {
                            ForEach(section.rows) { row in
                                workspaceRow(row)
                            }
                        } header: {
                            WorkspaceNodeSectionHeader(node: section.node, count: section.rows.count)
                        }
                    }
                } else {
                    ForEach(rows) { row in
                        workspaceRow(row)
                    }
                }
            }
        }
        .listStyle(.plain)
        .refreshable {
            await store.refreshHiveDiscoveryIfPossible()?.value
        }
        .toolbar {
            if navigationStyle == .push {
                ToolbarItem(placement: .principal) {
                    Text(String(localized: "nav.workspaces", defaultValue: "Workspaces"))
                        .font(.headline.weight(.semibold))
                }
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                WorkspaceFilterMenu(
                    filter: $visibilityFilter,
                    scope: $listScope,
                    nodes: store.nodes
                )
                Button {
                    isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel(String(localized: "home.settings", defaultValue: "Settings"))
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            WorkspaceSettingsView()
        }
    }

    @ViewBuilder
    private func workspaceRow(_ row: WorkspaceListRowSnapshot) -> some View {
        WorkspaceNavigationRow(
            workspace: row.workspace,
            node: row.node,
            isHiddenUnavailable: row.isHiddenUnavailable,
            isSelected: row.isSelected,
            navigationStyle: navigationStyle,
            selectWorkspace: { store.select(workspace: $0) },
            togglePinned: { store.togglePinned(for: $0) },
            toggleUnread: { store.toggleUnread(for: $0) },
            hideUnavailableNode: { store.hideUnavailableWorkspaces(from: $0) },
            showUnavailableNode: { store.showUnavailableWorkspaces(from: $0) },
            prefetchWorkspace: { store.prefetch(workspace: $0) }
        )
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 12))
    }
}

private struct WorkspaceSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: CmxConnectionStore

    private var teamSelection: Binding<String> {
        Binding(
            get: { store.effectiveHiveTeamID ?? "" },
            set: { store.selectHiveTeam(id: $0) }
        )
    }

    private var unavailableNodes: [CmxHiveNode] {
        store.nodes
            .filter { !$0.isOnline }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if store.hiveTeams.isEmpty {
                        Text(String(localized: "settings.team.unavailable", defaultValue: "Sign in to load workspace teams."))
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(
                            String(localized: "settings.team.picker", defaultValue: "Workspace Team"),
                            selection: teamSelection
                        ) {
                            ForEach(store.hiveTeams) { team in
                                Text(team.displayName).tag(team.id)
                            }
                        }
                    }
                } header: {
                    Text(String(localized: "settings.team.section", defaultValue: "Team"))
                }

                Section {
                    if unavailableNodes.isEmpty {
                        Text(String(localized: "settings.nodes.none_unavailable", defaultValue: "No unavailable machines."))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(unavailableNodes) { node in
                            HStack(spacing: 12) {
                                Image(systemName: node.symbolName)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(node.name)
                                    Text(node.subtitle)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    store.unlinkHiveNode(node)
                                } label: {
                                    Text(String(localized: "settings.nodes.unlink", defaultValue: "Unlink"))
                                }
                            }
                        }
                    }
                } header: {
                    Text(String(localized: "settings.nodes.section", defaultValue: "Machines"))
                }
            }
                .navigationTitle(String(localized: "home.settings", defaultValue: "Settings"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "common.done", defaultValue: "Done")) {
                            dismiss()
                        }
                    }
                }
        }
    }
}

private struct WorkspaceListRowSnapshot: Identifiable {
    let workspace: CmxWorkspace
    let node: CmxHiveNode
    let isHiddenUnavailable: Bool
    let isSelected: Bool

    var id: UInt64 {
        workspace.id
    }
}

private struct WorkspaceNodeSectionSnapshot: Identifiable {
    let node: CmxHiveNode
    let rows: [WorkspaceListRowSnapshot]

    var id: UInt64 {
        node.id
    }

    var latestActivity: Date {
        rows.map(\.workspace.lastActivity).max() ?? .distantPast
    }
}

private enum WorkspaceListScope: Equatable {
    case recent
    case groupedByNode
    case node(UInt64)
}

private enum WorkspaceNavigationStyle {
    case push
    case sidebar
}

private struct WorkspaceNavigationRoute: Hashable {
    var workspaceID: UInt64
}

private struct WorkspaceNavigationRow: View {
    let workspace: CmxWorkspace
    let node: CmxHiveNode
    let isHiddenUnavailable: Bool
    let isSelected: Bool
    let navigationStyle: WorkspaceNavigationStyle
    let selectWorkspace: (CmxWorkspace) -> Void
    let togglePinned: (CmxWorkspace) -> Void
    let toggleUnread: (CmxWorkspace) -> Void
    let hideUnavailableNode: (CmxHiveNode) -> Void
    let showUnavailableNode: (CmxHiveNode) -> Void
    let prefetchWorkspace: (CmxWorkspace) -> Void

    var body: some View {
        Group {
            switch navigationStyle {
            case .push:
                NavigationLink(value: WorkspaceNavigationRoute(workspaceID: workspace.id)) {
                    row
                }
                .disabled(!node.isOnline)
            case .sidebar:
                Button {
                    selectWorkspace(workspace)
                } label: {
                    row
                }
                .buttonStyle(.plain)
                .disabled(!node.isOnline)
            }
        }
        .accessibilityIdentifier("workspace.row.\(workspace.id)")
        .onAppear {
            if node.isOnline {
                prefetchWorkspace(workspace)
            }
        }
        .opacity(node.isOnline ? 1 : 0.52)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                toggleUnread(workspace)
            } label: {
                Label(
                    workspace.unread
                        ? String(localized: "home.action.mark_read", defaultValue: "Read")
                        : String(localized: "home.action.mark_unread", defaultValue: "Unread"),
                    systemImage: workspace.unread ? "message" : "message.badge"
                )
            }
            .tint(.accentColor)
            .accessibilityIdentifier("workspace.action.unread.\(workspace.id)")

            Button {
                togglePinned(workspace)
            } label: {
                Label(
                    workspace.pinned
                        ? String(localized: "home.action.unpin", defaultValue: "Unpin")
                        : String(localized: "home.action.pin", defaultValue: "Pin"),
                    systemImage: workspace.pinned ? "pin.slash.fill" : "pin.fill"
                )
            }
            .tint(.orange)
            .accessibilityIdentifier("workspace.action.pin.\(workspace.id)")
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !node.isOnline {
                Button {
                    if isHiddenUnavailable {
                        showUnavailableNode(node)
                    } else {
                        hideUnavailableNode(node)
                    }
                } label: {
                    Label(
                        isHiddenUnavailable
                            ? String(localized: "home.action.show_unavailable", defaultValue: "Show")
                            : String(localized: "home.action.hide_unavailable", defaultValue: "Hide"),
                        systemImage: isHiddenUnavailable ? "eye" : "eye.slash"
                    )
                }
                .tint(.gray)
                .accessibilityIdentifier("workspace.action.hide_unavailable.\(workspace.id)")
            }
        }
    }

    private var row: some View {
        WorkspaceConversationRow(
            workspace: workspace,
            node: node,
            isSelected: isSelected
        )
    }
}

private struct WorkspaceFilterMenu: View {
    @Binding var filter: CmxWorkspaceVisibilityFilter
    @Binding var scope: WorkspaceListScope
    let nodes: [CmxHiveNode]

    var body: some View {
        Menu {
            Section {
                ForEach(CmxWorkspaceVisibilityFilter.allCases, id: \.self) { option in
                    Button {
                        filter = option
                    } label: {
                        Label(option.localizedTitle, systemImage: filter == option ? "checkmark" : option.symbolName)
                    }
                }
            } header: {
                Text(String(localized: "home.filter.availability", defaultValue: "Availability"))
            }

            Section {
                Button {
                    scope = .recent
                } label: {
                    Label(
                        String(localized: "home.filter.scope.recent", defaultValue: "Recent"),
                        systemImage: scope == .recent ? "checkmark" : "clock"
                    )
                }
                Button {
                    scope = .groupedByNode
                } label: {
                    Label(
                        String(localized: "home.filter.scope.grouped", defaultValue: "Group by Mac"),
                        systemImage: scope == .groupedByNode ? "checkmark" : "rectangle.3.group"
                    )
                }
            } header: {
                Text(String(localized: "home.filter.view", defaultValue: "View"))
            }

            if !nodes.isEmpty {
                Section {
                    ForEach(nodes) { node in
                        Button {
                            scope = .node(node.id)
                        } label: {
                            Label(
                                node.name,
                                systemImage: scope == .node(node.id) ? "checkmark" : node.symbolName
                            )
                        }
                    }
                } header: {
                    Text(String(localized: "home.filter.machines", defaultValue: "Machines"))
                }
            }
        } label: {
            Image(systemName: menuSymbolName)
        }
        .accessibilityLabel(String(localized: "home.filter.button", defaultValue: "Filter Workspaces"))
    }

    private var menuSymbolName: String {
        switch scope {
        case .recent:
            return filter == .all ? "line.3.horizontal.decrease.circle" : filter.symbolName
        case .groupedByNode:
            return "rectangle.3.group"
        case .node:
            return "desktopcomputer"
        }
    }
}

private struct WorkspaceNodeSectionHeader: View {
    let node: CmxHiveNode
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: node.symbolName)
                .foregroundStyle(.secondary)
            Text(node.name)
                .font(.caption.weight(.semibold))
            Spacer()
            Text(
                String(
                    format: String(localized: "home.filter.machine_count", defaultValue: "%d"),
                    count
                )
            )
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .textCase(nil)
    }
}

private struct WorkspaceSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(String(localized: "home.search.prompt", defaultValue: "Search"), text: $text)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("workspace.search")
    }
}

private struct WorkspaceConversationRow: View {
    let workspace: CmxWorkspace
    let node: CmxHiveNode
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(avatarGradient)
                    .frame(width: 48, height: 48)

                Image(systemName: node.symbolName)
                    .font(.headline)
                    .foregroundStyle(.white)

                if workspace.unread {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                        .offset(x: 2, y: 2)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if workspace.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(secondaryForeground)
                    }

                    Text(workspace.title)
                        .font(.headline)
                        .foregroundStyle(primaryForeground)
                        .lineLimit(1)

                    Spacer(minLength: 10)

                    Text(relativeTimestamp)
                        .font(.subheadline)
                        .foregroundStyle(secondaryForeground)
                        .lineLimit(1)
                }

                Text(workspace.preview)
                    .font(.subheadline)
                    .foregroundStyle(secondaryForeground)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Circle()
                        .fill(statusIndicatorColor)
                        .frame(width: 7, height: 7)
                    Text(node.name)
                        .font(.caption)
                        .foregroundStyle(secondaryForeground)
                        .lineLimit(1)

                    Text(
                        String(
                            format: String(localized: "workspace.row.detail", defaultValue: "%d spaces, %d terminals"),
                            workspace.spaces.count,
                            workspace.spaces.reduce(0) { $0 + $1.terminals.count }
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(secondaryForeground)
                    .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(WorkspaceConversationSelectionStyle.background)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var primaryForeground: Color {
        isSelected ? WorkspaceConversationSelectionStyle.primaryForeground : Color.primary
    }

    private var secondaryForeground: Color {
        isSelected ? WorkspaceConversationSelectionStyle.secondaryForeground : Color.secondary
    }

    private var statusIndicatorColor: Color {
        return node.isOnline ? Color.green : Color.orange
    }

    private var avatarGradient: LinearGradient {
        let colors: [Color]
        switch node.id % 3 {
        case 0:
            colors = [Color.blue, Color.cyan]
        case 1:
            colors = [Color.green, Color.teal]
        default:
            colors = [Color.indigo, Color.orange]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var relativeTimestamp: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(workspace.lastActivity) {
            return workspace.lastActivity.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(workspace.lastActivity) {
            return String(localized: "home.timestamp.yesterday", defaultValue: "Yesterday")
        }
        return workspace.lastActivity.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits))
    }
}

private enum WorkspaceConversationSelectionStyle {
    static let background = Color.accentColor
    static let primaryForeground = Color.white
    static let secondaryForeground = Color.white.opacity(0.82)
}

private struct EmptyWorkspaceSearch: View {
    let isSearching: Bool
    let isLoading: Bool

    var body: some View {
        VStack(spacing: 8) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(.bottom, 2)
            }
            Text(title)
                .font(.headline)
            Text(bodyText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var title: String {
        if isLoading {
            return String(localized: "home.workspaces.loading.title", defaultValue: "Loading Sessions")
        }
        return String(localized: "home.search.empty.title", defaultValue: "No Sessions")
    }

    private var bodyText: String {
        if isLoading {
            return String(localized: "home.workspaces.loading.body", defaultValue: "Waiting for cmux to send the list.")
        }
        if isSearching {
            return String(localized: "home.search.empty.body", defaultValue: "No matching session is available on your signed-in nodes.")
        }
        return String(localized: "home.workspaces.empty.body", defaultValue: "No connected cmux session is available.")
    }
}

private struct TerminalDetailView: View {
    @EnvironmentObject private var store: CmxConnectionStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var keyboardOverlap: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let visibleHeight = CmxTerminalVisibleBounds.height(
                    totalHeight: proxy.size.height,
                    keyboardOverlap: keyboardOverlap
                )

                VStack(spacing: 0) {
                    switch store.terminalDetailPresentation {
                    case .notConnected:
                        TerminalEmptyPane(
                            title: String(localized: "terminal.not_connected.title", defaultValue: "Not Connected"),
                            bodyText: String(
                                localized: "terminal.not_connected.body",
                                defaultValue: "Connect to a session to view terminals."
                            ),
                            revision: store.terminalAppearanceRevision
                        )
                        .frame(width: proxy.size.width, height: visibleHeight)
                    case .terminal:
                        TerminalPane(terminal: store.selectedTerminal)
                            .id(terminalSurfaceIdentity)
                            .frame(width: proxy.size.width, height: visibleHeight)
                    case .loadingTerminal:
                        TerminalLoadingPane(
                            statusText: store.statusText,
                            revision: store.terminalAppearanceRevision
                        )
                        .frame(width: proxy.size.width, height: visibleHeight)
                    case .loadingWorkspaces:
                        TerminalLoadingPane(
                            title: String(
                                localized: "home.workspaces.loading.title",
                                defaultValue: "Loading Sessions"
                            ),
                            statusText: String(
                                localized: "home.workspaces.loading.body",
                                defaultValue: "Waiting for cmux to send the list."
                            ),
                            revision: store.terminalAppearanceRevision
                        )
                        .frame(width: proxy.size.width, height: visibleHeight)
                    case .noWorkspaces:
                        TerminalEmptyPane(
                            title: String(localized: "home.search.empty.title", defaultValue: "No Sessions"),
                            bodyText: String(
                                localized: "home.workspaces.empty.body",
                                defaultValue: "No connected cmux session is available."
                            ),
                            revision: store.terminalAppearanceRevision
                        )
                        .frame(width: proxy.size.width, height: visibleHeight)
                    case .noTerminal:
                        TerminalEmptyPane(
                            title: String(localized: "terminal.empty.title", defaultValue: "No Terminal"),
                            bodyText: String(
                                localized: "terminal.empty.body",
                                defaultValue: "This session does not have a visible terminal."
                            ),
                            revision: store.terminalAppearanceRevision
                        )
                        .frame(width: proxy.size.width, height: visibleHeight)
                    }

                    Color.clear
                        .frame(height: proxy.size.height - visibleHeight)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                .background {
                    CmxKeyboardOverlapReader(overlap: $keyboardOverlap)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TerminalThemeChrome.background(revision: store.terminalAppearanceRevision).ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .bottom)
        .navigationTitle(store.selectedWorkspace.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(TerminalThemeChrome.background(revision: store.terminalAppearanceRevision), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(TerminalThemeChrome.toolbarColorScheme(revision: store.terminalAppearanceRevision), for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if store.terminalDetailPresentation == .notConnected {
                    Text(String(localized: "terminal.not_connected.title", defaultValue: "Not Connected"))
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(TerminalThemeChrome.foreground(revision: store.terminalAppearanceRevision))
                } else {
                    TerminalPickerMenu(
                        workspaces: store.workspaces,
                        selectedWorkspace: store.selectedWorkspace,
                        selectedWorkspaceID: store.selectedWorkspaceID,
                        selectedSpaceID: store.selectedSpaceID,
                        selectedTerminalID: store.selectedTerminalID,
                        latencyText: store.latencyText,
                        revision: store.terminalAppearanceRevision,
                        selectWorkspace: { store.select(workspace: $0) },
                        selectSpace: { store.select(space: $0) },
                        selectTerminal: { space, terminal in store.select(space: space); store.select(terminal: terminal) }
                    )
                }
            }
        }
        .onAppear {
            store.refreshTerminalAppearance(colorPreference: CmxTerminalColorPreference(colorScheme: colorScheme))
            store.terminalScreenDidAppear()
        }
        .onDisappear {
            store.terminalScreenDidDisappear()
        }
        .onChange(of: colorScheme) { _, newValue in
            store.refreshTerminalAppearance(colorPreference: CmxTerminalColorPreference(colorScheme: newValue))
        }
    }

    private var terminalSurfaceIdentity: String {
        "\(store.selectedWorkspaceID)-\(store.selectedSpaceID)-\(store.selectedTerminal.id)"
    }
}

private struct CmxKeyboardOverlapReader: UIViewRepresentable {
    @Binding var overlap: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(overlap: $overlap)
    }

    func makeUIView(context: Context) -> CmxKeyboardOverlapReaderView {
        let view = CmxKeyboardOverlapReaderView()
        view.onOverlapChange = { [weak coordinator = context.coordinator] overlap in
            coordinator?.setOverlap(overlap)
        }
        return view
    }

    func updateUIView(_ uiView: CmxKeyboardOverlapReaderView, context: Context) {
        context.coordinator.overlap = $overlap
        uiView.onOverlapChange = { [weak coordinator = context.coordinator] overlap in
            coordinator?.setOverlap(overlap)
        }
        uiView.reportCurrentOverlap()
    }

    final class Coordinator {
        var overlap: Binding<CGFloat>

        init(overlap: Binding<CGFloat>) {
            self.overlap = overlap
        }

        @MainActor
        func setOverlap(_ nextOverlap: CGFloat) {
            guard abs(overlap.wrappedValue - nextOverlap) > 0.5 else { return }
            overlap.wrappedValue = nextOverlap
        }
    }
}

@MainActor
private final class CmxKeyboardOverlapReaderView: UIView {
    var onOverlapChange: ((CGFloat) -> Void)?
    private let guideTracker = UIView(frame: .zero)
    private var lastOverlap: CGFloat = -1
    private var pendingOverlap: CGFloat?
    private var deliveryScheduled = false
    private var notificationObservers: [NSObjectProtocol] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        keyboardLayoutGuide.followsUndockedKeyboard = true
        guideTracker.translatesAutoresizingMaskIntoConstraints = false
        guideTracker.isUserInteractionEnabled = false
        guideTracker.accessibilityElementsHidden = true
        addSubview(guideTracker)
        NSLayoutConstraint.activate([
            guideTracker.topAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
            guideTracker.leadingAnchor.constraint(equalTo: leadingAnchor),
            guideTracker.widthAnchor.constraint(equalToConstant: 0),
            guideTracker.heightAnchor.constraint(equalToConstant: 0),
        ])
        startKeyboardFrameNotifications()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportCurrentOverlap()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportCurrentOverlap()
    }

    func reportCurrentOverlap() {
        reportOverlap(
            CmxKeyboardOverlap.visibleHeight(containerBounds: bounds, keyboardFrame: keyboardLayoutGuide.layoutFrame)
        )
    }

    private func reportOverlap(_ nextOverlap: CGFloat) {
        guard abs(lastOverlap - nextOverlap) > 0.5 else { return }
        lastOverlap = nextOverlap
        pendingOverlap = nextOverlap
        guard !deliveryScheduled else { return }
        deliveryScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            deliveryScheduled = false
            guard let overlap = pendingOverlap else { return }
            pendingOverlap = nil
            onOverlapChange?(overlap)
        }
    }

    private func startKeyboardFrameNotifications() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            UIResponder.keyboardWillChangeFrameNotification,
            UIResponder.keyboardDidChangeFrameNotification,
            UIResponder.keyboardWillHideNotification,
            UIResponder.keyboardDidHideNotification,
        ]
        notificationObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let hidesKeyboard = notification.name == UIResponder.keyboardWillHideNotification
                    || notification.name == UIResponder.keyboardDidHideNotification
                let screenFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                MainActor.assumeIsolated {
                    self?.handleKeyboardFrameNotification(hidesKeyboard: hidesKeyboard, screenFrame: screenFrame)
                }
            }
        }
    }

    private func handleKeyboardFrameNotification(hidesKeyboard: Bool, screenFrame: CGRect?) {
        if hidesKeyboard {
            reportOverlap(0)
            return
        }
        guard let screenFrame else {
            reportCurrentOverlap()
            return
        }
        let windowFrame = window?.convert(screenFrame, from: nil) ?? screenFrame
        let localFrame = convert(windowFrame, from: window)
        let localOverlap = CmxKeyboardOverlap.visibleHeight(containerBounds: bounds, keyboardFrame: localFrame)
        if localOverlap > 0 {
            reportOverlap(localOverlap)
            return
        }
        let screenBounds = window?.windowScene?.screen.bounds
            ?? window?.screen.bounds
            ?? CGRect(x: 0, y: 0, width: screenFrame.width, height: screenFrame.maxY)
        let fallbackContainerHeight = bounds.height > 0 ? bounds.height : (window?.bounds.height ?? 0)
        reportOverlap(
            CmxKeyboardOverlap.screenAnchoredVisibleHeight(
                containerHeight: fallbackContainerHeight,
                screenBounds: screenBounds,
                keyboardScreenFrame: screenFrame
            )
        )
    }
}

private struct TerminalPickerMenu: View {
    let workspaces: [CmxWorkspace]
    let selectedWorkspace: CmxWorkspace
    let selectedWorkspaceID: UInt64
    let selectedSpaceID: UInt64
    let selectedTerminalID: UInt64
    let latencyText: String?
    let revision: Int
    let selectWorkspace: (CmxWorkspace) -> Void
    let selectSpace: (CmxSpace) -> Void
    let selectTerminal: (CmxSpace, CmxTerminal) -> Void

    var body: some View {
        Menu {
            ForEach(workspaces) { workspace in
                Button {
                    selectWorkspace(workspace)
                } label: {
                    Label(
                        workspace.title,
                        systemImage: workspace.id == selectedWorkspaceID ? "checkmark" : "rectangle.stack"
                    )
                }
            }

            Divider()

            ForEach(selectedWorkspace.spaces) { space in
                Menu {
                    Button {
                        selectSpace(space)
                    } label: {
                        Label(
                            space.title,
                            systemImage: space.id == selectedSpaceID ? "checkmark" : "rectangle.split.1x2"
                        )
                    }

                    if !space.terminals.isEmpty {
                        Divider()
                    }

                    ForEach(space.terminals) { terminal in
                        Button {
                            selectTerminal(space, terminal)
                        } label: {
                            Label(
                                terminal.title,
                                systemImage: terminal.id == selectedTerminalID ? "terminal.fill" : "terminal"
                            )
                        }
                    }
                } label: {
                    Label(
                        space.title,
                        systemImage: space.id == selectedSpaceID ? "checkmark.circle" : "rectangle.split.1x2"
                    )
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(selectedWorkspace.title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                if let latencyText {
                    Text(latencyText)
                        .font(.caption.monospacedDigit())
                        .lineLimit(1)
                        .foregroundStyle(TerminalThemeChrome.foreground(revision: revision).opacity(0.72))
                }
            }
            .foregroundStyle(TerminalThemeChrome.foreground(revision: revision))
            .accessibilityIdentifier("terminal.selector")
        }
    }
}

private struct TerminalPane: View {
    @EnvironmentObject private var store: CmxConnectionStore
    @State private var visibleGridSize: TerminalGridSize?
    @State private var surfaceResetNonce = 0
    let terminal: CmxTerminal
    private let showsBoundsOverlay = CmxLaunchConfiguration.showsTerminalBoundsOverlay()

    private var surfaceIdentity: String {
        "\(store.selectedWorkspaceID)-\(store.selectedSpaceID)-\(terminal.id)-\(surfaceResetNonce)"
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                CmxGhosttyTerminalView(
                    store: store,
                    terminalID: terminal.id,
                    renderSize: store.renderSize(for: terminal.id),
                    outputRevision: store.terminalOutputRevision,
                    hostPlatform: store.selectedHostPlatform,
                    visibleGridSize: $visibleGridSize,
                    surfaceResetNonce: $surfaceResetNonce
                )
                    .id(surfaceIdentity)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                if showsBoundsOverlay {
                    TerminalVisibleBoundsOverlay(
                        gridSize: visibleGridSize,
                        renderSize: store.renderSize(for: terminal.id),
                        pointSize: proxy.size,
                        revision: store.terminalAppearanceRevision
                    )
                }

            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TerminalThemeChrome.background(revision: store.terminalAppearanceRevision))
    }
}

private struct TerminalEmptyPane: View {
    let title: String
    let bodyText: String
    let revision: Int

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.callout.weight(.semibold))
            Text(bodyText)
                .font(.caption)
                .multilineTextAlignment(.center)
                .opacity(0.72)
        }
        .foregroundStyle(TerminalThemeChrome.foreground(revision: revision))
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TerminalThemeChrome.background(revision: revision))
        .accessibilityIdentifier("terminal.empty")
    }
}

private struct TerminalLoadingPane: View {
    var title = String(localized: "terminal.loading.title", defaultValue: "Loading terminal")
    let statusText: String
    let revision: Int

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(TerminalThemeChrome.foreground(revision: revision))
            Text(title)
                .font(.callout.weight(.semibold))
            Text(statusText)
                .font(.caption.monospacedDigit())
                .opacity(0.72)
        }
        .foregroundStyle(TerminalThemeChrome.foreground(revision: revision))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TerminalThemeChrome.background(revision: revision))
        .accessibilityIdentifier("terminal.loading")
    }
}

private struct TerminalVisibleBoundsOverlay: View {
    @Environment(\.displayScale) private var displayScale
    let gridSize: TerminalGridSize?
    let renderSize: CmxTerminalSize?
    let pointSize: CGSize
    let revision: Int

    var body: some View {
        let borderSize = TerminalVisibleBoundsOverlayStyle.borderSize(
            pointSize: pointSize,
            gridSize: gridSize,
            renderSize: renderSize,
            displayScale: displayScale
        )
        let labelOrigin = TerminalVisibleBoundsOverlayStyle.labelOrigin(
            pointSize: pointSize,
            borderSize: borderSize
        )

        ZStack(alignment: .topLeading) {
            if TerminalVisibleBoundsOverlayStyle.showsBorder(pointSize: borderSize) {
                Rectangle()
                    .strokeBorder(
                        TerminalVisibleBoundsOverlayStyle.borderColor(revision: revision),
                        lineWidth: TerminalVisibleBoundsOverlayStyle.borderWidth
                    )
                    .frame(width: borderSize.width, height: borderSize.height)
                    .accessibilityIdentifier("terminal.bounds.border")
            }

            if let labelOrigin {
                Text(verbatim: label)
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .foregroundStyle(TerminalThemeChrome.foreground(revision: revision))
                    .background(TerminalThemeChrome.background(revision: revision).opacity(0.84))
                    .offset(x: labelOrigin.x, y: labelOrigin.y)
                    .accessibilityIdentifier("terminal.bounds.overlay")
            }
        }
        .frame(width: pointSize.width, height: pointSize.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private var label: String {
        let points = "\(Int(pointSize.width.rounded()))x\(Int(pointSize.height.rounded())) pt"
        guard let gridSize else {
            return "visible pending | \(points)"
        }
        if let renderSize {
            return "visible \(renderSize.cols)x\(renderSize.rows) cells | \(points)"
        }
        return "visible \(gridSize.columns)x\(gridSize.rows) cells | \(gridSize.pixelWidth)x\(gridSize.pixelHeight) px | \(points)"
    }
}

enum TerminalVisibleBoundsOverlayStyle {
    static let borderWidth: CGFloat = 1
    private static let minimumBorderLength: CGFloat = 12
    private static let minimumLabelWidth: CGFloat = 168
    private static let labelHeight: CGFloat = 18
    private static let labelGap: CGFloat = 4

    static func showsBorder(pointSize: CGSize) -> Bool {
        pointSize.width >= minimumBorderLength && pointSize.height >= minimumBorderLength
    }

    static func borderSize(
        pointSize: CGSize,
        gridSize: TerminalGridSize?,
        renderSize: CmxTerminalSize? = nil,
        displayScale: CGFloat
    ) -> CGSize {
        guard pointSize.width > 0, pointSize.height > 0 else { return .zero }
        guard let gridSize,
              gridSize.pixelWidth > 0,
              gridSize.pixelHeight > 0,
              gridSize.columns > 0,
              gridSize.rows > 0 else {
            return .zero
        }

        let scale = max(displayScale, 1)
        guard let renderSize else {
            return CGSize(
                width: min(pointSize.width, ceil(CGFloat(gridSize.pixelWidth) / scale)),
                height: min(pointSize.height, ceil(CGFloat(gridSize.pixelHeight) / scale))
            )
        }
        let columns = max(1, renderSize.cols)
        let rows = max(1, renderSize.rows)
        let cellWidth = CGFloat(gridSize.pixelWidth) / CGFloat(gridSize.columns)
        let cellHeight = CGFloat(gridSize.pixelHeight) / CGFloat(gridSize.rows)
        return CGSize(
            width: min(pointSize.width, ceil(cellWidth * CGFloat(columns) / scale)),
            height: min(pointSize.height, ceil(cellHeight * CGFloat(rows) / scale))
        )
    }

    static func labelOrigin(pointSize: CGSize, borderSize: CGSize) -> CGPoint? {
        guard showsBorder(pointSize: borderSize) else { return nil }
        let trailingSpace = pointSize.width - borderSize.width
        if trailingSpace >= minimumLabelWidth + labelGap {
            return CGPoint(x: borderSize.width + labelGap, y: 0)
        }
        let bottomSpace = pointSize.height - borderSize.height
        if bottomSpace >= labelHeight + labelGap {
            return CGPoint(x: 0, y: borderSize.height + labelGap)
        }
        return nil
    }

    @MainActor
    static func borderColor(revision: Int) -> Color {
        TerminalThemeChrome.foreground(revision: revision)
    }
}

private enum TerminalThemeChrome {
    @MainActor
    static func background(revision _: Int) -> Color {
        Color(
            GhosttyRuntime.configuredUIColor(
                named: "background",
                fallback: .black
            )
        )
    }

    @MainActor
    static func foreground(revision _: Int) -> Color {
        Color(
            GhosttyRuntime.configuredUIColor(
                named: "foreground",
                fallback: .white
            )
        )
    }

    @MainActor
    static func toolbarColorScheme(revision _: Int) -> ColorScheme {
        GhosttyRuntime.configuredUIColor(
            named: "background",
            fallback: .black
        ).cmxIsDark ? .dark : .light
    }
}

private extension CmxTerminalColorPreference {
    init(colorScheme: ColorScheme) {
        self = colorScheme == .light ? .light : .dark
    }
}

enum CmxKeyboardOverlap {
    static func visibleHeight(containerBounds: CGRect, keyboardFrame: CGRect) -> CGFloat {
        guard !containerBounds.isNull,
              !containerBounds.isEmpty,
              !keyboardFrame.isNull,
              !keyboardFrame.isEmpty else { return 0 }
        guard keyboardFrame.minY > containerBounds.minY else { return 0 }
        guard keyboardFrame.maxY >= containerBounds.maxY - 80 else { return 0 }
        guard keyboardFrame.height >= 80 else { return 0 }
        let overlap = containerBounds.maxY - max(containerBounds.minY, keyboardFrame.minY)
        return max(0, min(containerBounds.height, overlap))
    }

    static func screenAnchoredVisibleHeight(
        containerHeight: CGFloat,
        screenBounds: CGRect,
        keyboardScreenFrame: CGRect
    ) -> CGFloat {
        guard containerHeight > 0,
              !screenBounds.isNull,
              !screenBounds.isEmpty,
              !keyboardScreenFrame.isNull,
              !keyboardScreenFrame.isEmpty else { return 0 }
        guard keyboardScreenFrame.minY > screenBounds.minY else { return 0 }
        guard keyboardScreenFrame.maxY >= screenBounds.maxY - 80 else { return 0 }
        guard keyboardScreenFrame.height >= 80 else { return 0 }
        let overlap = screenBounds.maxY - max(screenBounds.minY, keyboardScreenFrame.minY)
        return max(0, min(containerHeight, overlap))
    }
}

enum CmxTerminalVisibleBounds {
    static func height(totalHeight: CGFloat, keyboardOverlap: CGFloat) -> CGFloat {
        guard totalHeight > 0 else { return 0 }
        return max(0, totalHeight - max(0, min(totalHeight, keyboardOverlap)))
    }
}

private extension UIColor {
    var cmxIsDark: Bool {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return true }
        let luminance = (0.299 * red) + (0.587 * green) + (0.114 * blue)
        return luminance < 0.55
    }
}
