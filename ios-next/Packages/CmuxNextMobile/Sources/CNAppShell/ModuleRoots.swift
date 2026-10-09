#if os(iOS)
import CNAgentUI
import CNBrowserUI
import CNConversationsUI
import CNDesign
import CNSettingsUI
import CNTerminalUI
import CNTransport
import SwiftUI

/// The one place the shells reach into the feature modules. Each module owns a
/// public root (`ConversationsRoot(connection:)` and so on); until a module
/// lands, its slot can show `ModulePlaceholder`.
@MainActor
struct ModuleRoots {
    let model: AppModel
    var connection: HostConnection { model.connection }

    @ViewBuilder
    func root(for destination: ShellDestination) -> some View {
        switch destination {
        case .home: conversations()
        case .agents: agents()
        case .terminals: terminals()
        case .browser: browser()
        case .settings: settings()
        }
    }

    func conversations() -> some View { ConversationsRoot(connection: connection) }
    func agents() -> some View { AgentsRoot(connection: connection) }
    func terminals() -> some View { TerminalsRoot(connection: connection) }
    func browser() -> some View { BrowserRoot(connection: connection) }

    func settings() -> some View {
        SettingsRoot(auth: model.auth, hosts: model.hosts, connection: model.connection,
                     preferences: model.preferences, onSelectHost: { model.selectHost($0) })
    }
}

/// Stand-in for a module root that has not landed yet.
struct ModulePlaceholder: View {
    let destination: ShellDestination

    var body: some View {
        NavigationStack {
            ScrollView {
                ContentUnavailableView(destination.title, systemImage: destination.symbol,
                                       description: Text("This module has not landed yet."))
                    .padding(.top, 120)
            }
            .navigationTitle(destination.title)
            .cnShellLeadingBarItem()
        }
    }
}
#endif
