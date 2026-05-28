import SwiftUI

public struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedWorkspaceID: String?
    @State private var selectedTerminalID: String?
    @StateObject private var liveTerminalStore: ComeupLiveTerminalStore

    private let snapshot: CmuxMobileHomeSnapshot

    public init(
        snapshot: CmuxMobileHomeSnapshot = .fixture,
        liveTerminalStore: ComeupLiveTerminalStore = ComeupLiveTerminalStore()
    ) {
        self.snapshot = snapshot
        _selectedWorkspaceID = State(initialValue: snapshot.workspaces.first?.id)
        _selectedTerminalID = State(initialValue: snapshot.workspaces.first?.terminalTree.first?.terminal.id)
        _liveTerminalStore = StateObject(wrappedValue: liveTerminalStore)
    }

    public var body: some View {
        if horizontalSizeClass == .regular {
            NavigationSplitView {
                WorkspaceHomeView(
                    snapshot: snapshot,
                    selectedWorkspaceID: $selectedWorkspaceID,
                    selectedTerminalID: $selectedTerminalID,
                    liveTerminalStore: liveTerminalStore,
                    compactNavigation: false
                )
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 460)
            } detail: {
                WorkspaceDetailView(
                    snapshot: snapshot,
                    workspaceID: selectedWorkspaceID,
                    selectedTerminalID: $selectedTerminalID,
                    liveTerminalStore: liveTerminalStore
                )
            }
        } else {
            NavigationStack {
                WorkspaceHomeView(
                    snapshot: snapshot,
                    selectedWorkspaceID: $selectedWorkspaceID,
                    selectedTerminalID: $selectedTerminalID,
                    liveTerminalStore: liveTerminalStore,
                    compactNavigation: true
                )
            }
        }
    }
}

private struct WorkspaceHomeView: View {
    let snapshot: CmuxMobileHomeSnapshot
    @Binding var selectedWorkspaceID: String?
    @Binding var selectedTerminalID: String?
    @ObservedObject var liveTerminalStore: ComeupLiveTerminalStore
    let compactNavigation: Bool

    var body: some View {
        List {
            Section {
                HomeStatusHeader(snapshot: snapshot)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }

            Section {
                ForEach(snapshot.workspaces) { workspace in
                    if compactNavigation {
                        NavigationLink {
                            WorkspaceDetailView(
                                snapshot: snapshot,
                                workspaceID: workspace.id,
                                selectedTerminalID: $selectedTerminalID,
                                liveTerminalStore: liveTerminalStore
                            )
                            .onAppear {
                                selectedWorkspaceID = workspace.id
                                selectedTerminalID = workspace.terminalTree.first?.terminal.id
                            }
                        } label: {
                            WorkspaceConversationRow(
                                workspace: workspace,
                                node: snapshot.node(id: workspace.nodeID),
                                isSelected: false,
                                showsDisclosureIndicator: false
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("workspace.row.\(workspace.id)")
                        .listRowInsets(EdgeInsets())
                    } else {
                        WorkspaceConversationRow(
                            workspace: workspace,
                            node: snapshot.node(id: workspace.nodeID),
                            isSelected: selectedWorkspaceID == workspace.id,
                            showsDisclosureIndicator: true
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedWorkspaceID = workspace.id
                            selectedTerminalID = workspace.terminalTree.first?.terminal.id
                        }
                        .accessibilityIdentifier("workspace.row.\(workspace.id)")
                        .listRowInsets(EdgeInsets())
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .navigationTitle(String(localized: "ios.home.title", defaultValue: "Workspaces"))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {} label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityIdentifier("workspace.compose")
            }
        }
        .accessibilityIdentifier("cmux.mobile.home")
    }
}

private struct HomeStatusHeader: View {
    let snapshot: CmuxMobileHomeSnapshot

    var body: some View {
        VStack(spacing: 10) {
            AuthStatusRow(auth: snapshot.auth)
                .padding(.horizontal, 16)
            NodeDiscoveryStrip(nodes: snapshot.nodes)
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color(.systemBackground))
    }
}

private struct AuthStatusRow: View {
    let auth: CmuxAuthSnapshot

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: authSymbol)
                .font(.title2)
                .foregroundStyle(authColor)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(auth.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(auth.primaryEmail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(authLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(authColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(authColor.opacity(0.12), in: Capsule())
        }
        .accessibilityIdentifier("auth.status.row")
    }

    private var authLabel: String {
        switch auth.state {
        case .signedOut:
            String(localized: "ios.auth.signedOut", defaultValue: "Signed out")
        case .restoring:
            String(localized: "ios.auth.restoring", defaultValue: "Restoring")
        case .signedIn:
            String(localized: "ios.auth.signedIn", defaultValue: "Signed in")
        }
    }

    private var authSymbol: String {
        switch auth.state {
        case .signedOut:
            "person.crop.circle.badge.xmark"
        case .restoring:
            "arrow.triangle.2.circlepath.circle"
        case .signedIn:
            "person.crop.circle.fill.badge.checkmark"
        }
    }

    private var authColor: Color {
        switch auth.state {
        case .signedOut:
            .orange
        case .restoring:
            .blue
        case .signedIn:
            .green
        }
    }
}

private struct NodeDiscoveryStrip: View {
    let nodes: [CmuxHiveNode]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(nodes) { node in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(color(for: node.status))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(node.name)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Text(node.route)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("hive.node.\(node.id)")
                }
            }
            .padding(.horizontal, 16)
        }
        .accessibilityIdentifier("hive.node.strip")
    }

    private func color(for status: CmuxHiveNode.Status) -> Color {
        switch status {
        case .online:
            .green
        case .connecting:
            .blue
        case .offline:
            .gray
        }
    }
}

private struct WorkspaceConversationRow: View {
    let workspace: CmuxMobileWorkspace
    let node: CmuxHiveNode?
    let isSelected: Bool
    let showsDisclosureIndicator: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                avatar

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(workspace.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(workspace.lastActivityLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if showsDisclosureIndicator {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    HStack(spacing: 6) {
                        statusDot
                        Text(node?.name ?? String(localized: "ios.node.unknown", defaultValue: "Unknown"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text("/")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(
                            String(
                                localized: "ios.workspace.terminalCount",
                                defaultValue: "\(workspace.terminalCount) terminals"
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(workspace.lastMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if workspace.unreadCount > 0 {
                            Text("\(workspace.unreadCount)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(minWidth: 22, minHeight: 22)
                                .background(Color.accentColor, in: Circle())
                                .accessibilityIdentifier("workspace.unread.\(workspace.id)")
                        }
                    }
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .padding(.leading, 80)
        }
        .background(isSelected ? Color(.tertiarySystemFill) : Color(.systemBackground))
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(avatarBackground)
            Text(initials)
                .font(.headline.weight(.semibold))
                .foregroundStyle(avatarForeground)
        }
        .frame(width: 52, height: 52)
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 7, height: 7)
    }

    private var statusColor: Color {
        switch node?.status {
        case .online:
            .green
        case .connecting:
            .blue
        case .offline, .none:
            .gray
        }
    }

    private var avatarBackground: Color {
        switch workspace.id {
        case "workspace-ios-port":
            Color.blue.opacity(0.16)
        case "workspace-auth":
            Color.green.opacity(0.16)
        default:
            Color.accentColor.opacity(0.16)
        }
    }

    private var avatarForeground: Color {
        switch workspace.id {
        case "workspace-ios-port":
            .blue
        case "workspace-auth":
            .green
        default:
            .accentColor
        }
    }

    private var initials: String {
        workspace.title
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()
    }
}

private struct WorkspaceDetailView: View {
    let snapshot: CmuxMobileHomeSnapshot
    let workspaceID: String?
    @Binding var selectedTerminalID: String?
    @ObservedObject var liveTerminalStore: ComeupLiveTerminalStore

    private var workspace: CmuxMobileWorkspace? {
        snapshot.workspace(id: workspaceID)
    }

    private var selectedTerminal: CmuxMobileTerminal? {
        workspace?.terminal(id: selectedTerminalID)
    }

    var body: some View {
        if let workspace {
            VStack(spacing: 0) {
                TerminalPicker(
                    workspace: workspace,
                    selectedTerminalID: $selectedTerminalID
                )
                if let selectedTerminal {
                    TerminalScreen(
                        terminal: selectedTerminal,
                        liveTerminalStore: liveTerminalStore
                    )
                } else {
                    EmptyTerminalState()
                }
            }
            .navigationTitle(workspace.title)
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("workspace.detail.\(workspace.id)")
        } else {
            EmptyWorkspaceState()
        }
    }
}

private struct TerminalPicker: View {
    let workspace: CmuxMobileWorkspace
    @Binding var selectedTerminalID: String?

    var body: some View {
        Menu {
            ForEach(workspace.terminalTree) { row in
                Button {
                    selectedTerminalID = row.terminal.id
                } label: {
                    Label(
                        "\(row.space.title) / \(row.pane.title) / \(row.terminal.title)",
                        systemImage: row.terminal.id == selectedTerminalID ? "checkmark.circle.fill" : "terminal"
                    )
                }
                .accessibilityIdentifier("terminal.option.\(row.terminal.id)")
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                Text(selectedTreeLabel)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
        .background(.bar)
        .accessibilityIdentifier("terminal.tree.menu")
    }

    private var selectedTreeLabel: String {
        guard let row = workspace.terminalTree.first(where: { $0.terminal.id == selectedTerminalID }) else {
            return workspace.terminalTree.first?.terminal.title
                ?? String(localized: "ios.terminal.empty.title", defaultValue: "No terminals")
        }
        return "\(row.space.title) / \(row.pane.title) / \(row.terminal.title)"
    }
}

private struct EmptyWorkspaceState: View {
    var body: some View {
        EmptyStateView(
            title: String(localized: "ios.workspace.empty.title", defaultValue: "No workspace selected"),
            description: String(localized: "ios.workspace.empty.description", defaultValue: "Create or select a workspace to show its terminals."),
            systemImage: "bubble.left.and.bubble.right"
        )
        .accessibilityIdentifier("workspace.empty")
    }
}

private struct EmptyTerminalState: View {
    var body: some View {
        EmptyStateView(
            title: String(localized: "ios.terminal.empty.title", defaultValue: "No terminals"),
            description: String(localized: "ios.terminal.empty.description", defaultValue: "This workspace has no active terminal yet."),
            systemImage: "terminal"
        )
        .accessibilityIdentifier("terminal.empty")
    }
}

private struct EmptyStateView: View {
    let title: String
    let description: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(description)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

private struct TerminalScreen: View {
    let terminal: CmuxMobileTerminal
    @ObservedObject var liveTerminalStore: ComeupLiveTerminalStore

    private var displaySize: CmuxTerminalSize {
        liveTerminalStore.isEnabled ? liveTerminalStore.size : terminal.size
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(terminal.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 8) {
                    Text(String(localized: "ios.terminal.renderer.libghostty", defaultValue: "libghostty"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text("\(displaySize.cols)x\(displaySize.rows)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("terminal.renderer.libghostty")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(.systemBackground))

            if liveTerminalStore.isEnabled {
                LiveGhosttyTerminalRepresentable(
                    store: liveTerminalStore,
                    initialSize: terminal.size
                )
                .background(Color.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "ios.terminal.surface", defaultValue: "Terminal"))
                .accessibilityValue(liveTerminalStore.accessibilityText)
                .accessibilityIdentifier("terminal.surface")
                .onAppear {
                    liveTerminalStore.connectIfNeeded()
                }
            } else {
                GhosttyTerminalRepresentable(terminal: terminal)
                    .background(Color.black)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(String(localized: "ios.terminal.surface", defaultValue: "Terminal"))
                    .accessibilityValue(terminal.rows.joined(separator: "\n"))
                    .accessibilityIdentifier("terminal.surface")
            }
        }
        .background(Color.black)
        .accessibilityIdentifier("terminal.screen.\(terminal.id)")
    }
}

#Preview {
    ContentView()
}
