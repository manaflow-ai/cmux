import SwiftUI

/// Signed-in root: the sidebar container plus the app-level sheets
/// (Settings, pairing, sign-out confirmation) the sidebar opens.
struct SidebarRoot: View {
    let app: AppModel
    @State private var navigator = AppNavigator()

    var body: some View {
        SidebarContainer(
            navigator: navigator,
            sidebar: SidebarPanel(app: app, navigator: navigator),
            content: MainContent(app: app, navigator: navigator)
        )
        .ignoresSafeArea()
        .sheet(isPresented: $navigator.showSettings) { SettingsScreen(app: app) }
        .sheet(isPresented: $navigator.showPairing) { PairingFlow(app: app, entry: navigator.pairingEntry) }
        .confirmationDialog(String(localized: "Sign out of cmux?"), isPresented: $navigator.confirmSignOut, titleVisibility: .visible) {
            Button(String(localized: "Sign Out"), role: .destructive) {
                navigator.closeSidebar()
                app.signOut()
            }
        } message: {
            Text(String(localized: "Your paired Macs stay paired. Sign in again to reconnect."))
        }
    }
}

/// The card's content: Home, the Feed, or one terminal, each in its own
/// NavigationStack so pushes and swipe-back keep working.
struct MainContent: View {
    let app: AppModel
    let navigator: AppNavigator

    var body: some View {
        Group {
            switch navigator.destination {
            case .home:
                NavigationStack {
                    SessionsScreen(app: app, navigator: navigator)
                        .toolbar { sidebarButton }
                }
            case .feed:
                NavigationStack {
                    FeedScreen(app: app)
                        .toolbar { sidebarButton }
                }
            case .terminal(let surface):
                NavigationStack {
                    if let connection = app.connection, let tab = connection.tab(surface: surface) {
                        TerminalScreen(connection: connection, tab: tab)
                            .toolbar { sidebarButton }
                    } else {
                        ConnectingState(hostName: app.connection?.host.name, path: nil)
                            .toolbar { sidebarButton }
                    }
                }
                .id(surface)
            }
        }
        .task(id: restoreKey) {
            if let connection = app.connection { navigator.restore(connection: connection) }
        }
        .onChange(of: terminalMissing) { _, missing in
            if missing { navigator.terminalVanished() }
        }
    }

    private var sidebarButton: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { navigator.openSidebar() } label: {
                Image(systemName: "line.3.horizontal")
            }
            .accessibilityLabel(String(localized: "Open sidebar"))
            .accessibilityIdentifier("sidebar.open")
        }
    }

    /// Restore runs again once the live tree arrives (the cached one may be stale).
    private var restoreKey: String {
        guard let connection = app.connection else { return "" }
        return "\(connection.host.id)|\(connection.phase == .connected)|\(connection.workspaces.count)"
    }

    /// The open terminal is gone from the live tree (closed here or on the Mac).
    private var terminalMissing: Bool {
        guard case .terminal(let surface) = navigator.destination,
              let connection = app.connection, connection.phase == .connected, connection.tree != nil else { return false }
        return connection.tab(surface: surface) == nil
    }
}
