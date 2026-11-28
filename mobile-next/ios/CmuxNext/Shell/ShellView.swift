import CNMProtocol
import SwiftUI

/// What fills the main area. The drawer switches between these.
enum Destination: Hashable {
    case home
    case agent(host: String, session: String)
    case newAgent
    case terminals
    case macs
}

@MainActor
@Observable
final class ShellState {
    var destination: Destination = .home
    var drawerOpen = false
    /// Home's navigation path (conversation pushes).
    var homePath: [HomeRoute] = []
    var terminalsPath: [TerminalRoute] = []
    var showSettings = false
    var showAddMac = false

    /// The drawer may be dragged open only on a root screen; deeper screens
    /// keep the edge swipe for back navigation.
    var drawerGestureEnabled: Bool {
        switch destination {
        case .home: homePath.isEmpty
        case .terminals: terminalsPath.isEmpty
        default: true
        }
    }

    /// Lists with swipe actions keep horizontal swipes for their rows; the
    /// drawer opens from the screen edge there (and from anywhere elsewhere).
    var drawerEdgeWidth: CGFloat? {
        switch destination {
        case .home, .terminals, .macs: 28
        default: nil
        }
    }

    func go(_ destination: Destination) {
        if self.destination == destination {
            if destination == .home { homePath = [] }
            if destination == .terminals { terminalsPath = [] }
        }
        self.destination = destination
        drawerOpen = false
    }
}

struct ShellView: View {
    @Environment(AppModel.self) private var model
    @State private var shell = ShellState()

    var body: some View {
        DrawerContainer(isOpen: $shell.drawerOpen, gestureEnabled: shell.drawerGestureEnabled, edgeWidth: shell.drawerEdgeWidth) {
            SidebarView()
        } content: {
            // Swap screens instantly; only the drawer animates (as in ChatGPT).
            mainContent
                .id(shell.destination)
                .transition(.identity)
        }
        // Sheets read the shell too, so it goes on after them.
        .sheet(isPresented: $shell.showSettings) { SettingsView() }
        .sheet(isPresented: $shell.showAddMac) { AddMacView() }
        .environment(shell)
    }

    @ViewBuilder
    private var mainContent: some View {
        switch shell.destination {
        case .home:
            HomeView()
        case .agent(let host, let session):
            if let connection = model.host(host) {
                AgentChatView(host: connection, sessionID: session)
                    .id(session)
            } else {
                NewAgentView()
            }
        case .newAgent:
            NewAgentView()
        case .terminals:
            TerminalsView()
        case .macs:
            MacsView()
        }
    }
}

/// The hamburger button every root screen puts at its leading edge.
struct DrawerButton: View {
    @Environment(ShellState.self) private var shell

    var body: some View {
        Button {
            shell.drawerOpen.toggle()
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 17, weight: .medium))
        }
        .accessibilityLabel("Menu")
        .accessibilityIdentifier("shell.menu")
    }
}
