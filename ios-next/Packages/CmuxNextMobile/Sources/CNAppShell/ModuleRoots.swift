#if os(iOS)
import CNDesign
import CNSettingsUI
import CNTransport
import SwiftUI

/// The one place the shells reach into the feature modules. Each module owns a
/// public root (`ConversationsRoot(connection:)` and so on); until a module
/// lands, its slot shows a placeholder so the app keeps compiling.
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

    func conversations() -> some View { ModulePlaceholder(destination: .home) }
    func agents() -> some View { ModulePlaceholder(destination: .agents) }
    func terminals() -> some View { ModulePlaceholder(destination: .terminals) }
    func browser() -> some View { ModulePlaceholder(destination: .browser) }

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
