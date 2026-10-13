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
            ConversationsHome(store: shell.store) {
                SidebarToolbarItem(sidebar: shell.sidebar)
            }
            .agentChatDestinations()
        }
    }
}

struct WorkspacesScreen: View {
    let shell: ShellModel

    var body: some View {
        @Bindable var shell = shell
        NavigationStack(path: $shell.workspacesPath) {
            WorkspacesList(store: shell.store)
                .background(theme.colors.bg.color.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: Workspace.self) { ws in
                    WorkspaceScreen(store: shell.store, workspaceID: ws.id, terminal: shell.terminalTabs)
                }
                .toolbar {
                    SidebarToolbarItem(sidebar: shell.sidebar)
                    ScreenTitle(title: "Workspaces")
                }
                .cnxBanner(shell.store.isOffline ? .offline : nil)
        }
    }
}

#endif
