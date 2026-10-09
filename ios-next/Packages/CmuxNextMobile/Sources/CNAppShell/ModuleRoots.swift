#if os(iOS)
import CNDesign
import CNTransport
import SwiftUI

/// The one place the shells reach into the feature modules. Each module owns a
/// public root (`ConversationsRoot(connection:)` and so on); until a module
/// lands, its slot shows a placeholder so the app keeps compiling.
@MainActor
struct ModuleRoots {
    let connection: HostConnection

    func conversations() -> some View { ModulePlaceholder(title: "Home", symbol: "bubble.left.and.bubble.right") }
    func agents() -> some View { ModulePlaceholder(title: "Agents", symbol: "sparkles") }
    func terminals() -> some View { ModulePlaceholder(title: "Terminals", symbol: "apple.terminal") }
    func browser() -> some View { ModulePlaceholder(title: "Browser", symbol: "safari") }
}

/// Stand-in for a module root that has not landed yet.
struct ModulePlaceholder: View {
    let title: String
    let symbol: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView(title, systemImage: symbol, description: Text("This module has not landed yet."))
                .navigationTitle(title)
                .cnShellLeadingBarItem()
        }
    }
}
#endif
