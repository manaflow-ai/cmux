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
        AnyView(IsolatedTerminalStack(model: model(for: tab)))
    }

    func card(for tab: WorkspaceTab, in workspace: Workspace) -> AnyView {
        AnyView(IsolatedTerminalStack(model: model(for: tab)).allowsHitTesting(false))
    }
}

/// The terminal page's own navigation bar (title menu, keyboard toggle,
/// More), from a plain UIKit navigation controller around a hosting
/// controller. A SwiftUI NavigationStack here would sit inside the
/// Workspaces stack's pushed page: SwiftUI merges nested stacks (the
/// workspace push resolved to the missing-destination placeholder, and with
/// a typed path it trapped with `comparisonTypeMismatch`), and a stack in a
/// child hosting controller adopts the enclosing UINavigationController and
/// pops the workspace. SwiftUI fills this controller's navigation item from
/// TerminalScreen's `.toolbar`, so the bar looks the same.
private struct IsolatedTerminalStack: UIViewControllerRepresentable {
    let model: TerminalModel

    func makeUIViewController(context: Context) -> UINavigationController {
        let host = UIHostingController(rootView: TerminalScreen(model: model))
        host.view.backgroundColor = .black
        let navigation = UINavigationController(rootViewController: host)
        navigation.overrideUserInterfaceStyle = .dark
        return navigation
    }

    func updateUIViewController(_ navigation: UINavigationController, context: Context) {}
}
#endif
