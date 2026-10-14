#if os(iOS)
import CnxAgentChat
import CnxChief
import CnxDesign
import CnxModel
import CnxWorkspaces
import CnxTerminal
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
            ConversationsHome(store: shell.store, open: { route in
                if let chief = route.chiefRoute {
                    shell.homePath.append(chief)
                } else if case let .agent(destination) = route {
                    shell.homePath.append(destination)
                }
            }) {
                SidebarToolbarItem(sidebar: shell.sidebar)
            }
            .agentChatDestinations()
        }
    }
}

struct WorkspacesScreen: View {
    let shell: ShellModel

    var body: some View {
        list
    }

    private var list: some View {
        @Bindable var shell = shell
        return NavigationStack(path: $shell.workspacesPath) {
            WorkspacesList(
                store: shell.store, creator: shell.creator, accountEmail: shell.auth.user?.email,
                reconnect: shell.live.map { live in
                    { macID in live.retry(macID: macID) }
                },
                linking: shell.live.map { live in
                    MacLinking(link: { live.select(macID: $0) }, canLink: { live.canLink(macID: $0) },
                               isLinkTarget: { live.link.target?.macID == $0 })
                },
                refresh: shell.live.map { live in { await live.workspaces.refresh() } },
                switchTeam: { shell.switchTeam(to: $0) },
                openAccount: {
                    shell.tab = .settings
                    shell.settingsPath = [.account]
                }
            ) { shell.workspacesPath.append($0) }
                .background(theme.colors.bg.color.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: Workspace.self) { ws in
                    WorkspaceScreen(store: shell.store, workspaceID: ws.id, terminal: shell.terminalTabs, creator: shell.creator)
                }
                .toolbar {
                    // WorkspacesList owns the title and the Mac chip row.
                    SidebarToolbarItem(sidebar: shell.sidebar)
                }
                .cnxBanner(shell.banner)
        }
    }
}

#endif
