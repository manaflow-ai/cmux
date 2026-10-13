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
        AnyView(NavigationStack { TerminalScreen(model: model(for: tab)) })
    }

    func card(for tab: WorkspaceTab, in workspace: Workspace) -> AnyView {
        AnyView(NavigationStack { TerminalScreen(model: model(for: tab)) }.allowsHitTesting(false))
    }
}
#endif
