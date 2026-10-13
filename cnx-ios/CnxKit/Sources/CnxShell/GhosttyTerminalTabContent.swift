#if os(iOS)
import CnxModel
import CnxTerminal
import CnxWorkspaces
import SwiftUI

/// Plugs CnxTerminal into the workspace tabs. One terminal model per tab, kept
/// alive while the workspace is open so scrollback survives tab switches.
/// The page currently hosts the full TerminalScreen; an embedded variant that
/// hands its key bar and composer to the tabs accessory is still to come.
@MainActor
final class GhosttyTerminalTabContent: TerminalTabContent {
    private var models: [String: TerminalModel] = [:]

    private func model(for tab: WorkspaceTab) -> TerminalModel {
        if let model = models[tab.id] { return model }
        let model = TerminalModel(session: MockTerminalSession(), artifactSource: MockArtifactSource(), title: tab.title)
        models[tab.id] = model
        return model
    }

    func page(for tab: WorkspaceTab, in workspace: Workspace, context: TerminalTabContext) -> AnyView {
        AnyView(TerminalNavigationHost(root: TerminalScreen(model: model(for: tab))).ignoresSafeArea())
    }

    func card(for tab: WorkspaceTab, in workspace: Workspace) -> AnyView {
        AnyView(TerminalNavigationHost(root: TerminalScreen(model: model(for: tab))).ignoresSafeArea().allowsHitTesting(false))
    }
}
/// TerminalScreen wants its own navigation bar. A SwiftUI NavigationStack
/// nested in the pushed workspace joined the Workspaces stack's navigation
/// state: after leaving a workspace that was on a terminal tab, the next push
/// crashed in SwiftUI (`AnyNavigationPath.Error.comparisonTypeMismatch`, the
/// typed `[Workspace]` path compared with the inner stack's path). A UIKit
/// navigation controller gives the terminal its bar without that link.
private struct TerminalNavigationHost<Root: View>: UIViewControllerRepresentable {
    let root: Root

    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: UIHostingController(rootView: root))
    }

    func updateUIViewController(_ navigation: UINavigationController, context: Context) {
        (navigation.viewControllers.first as? UIHostingController<Root>)?.rootView = root
    }
}
#endif
