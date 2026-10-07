import CmuxiOSPlatform
import CmuxiOSShell
import UIKit

/// Route delivery: the router calls this once the route may open (signed in,
/// or account-free routes at any time).
extension RootViewController {
    func handle(_ route: ShellRoute) {
        switch route {
        case .home: select(.home)
        case .feed(let item):
            select(.feed)
            if let item { container.feedNavigator.open(item) }
        case .workspaces: select(.workspaces)
        case .workspace(let host, let workspace, _):
            // C5 has no surface push yet: the workspace detail opens.
            select(.workspaces)
            shellFeatures?.workspaces.open(hostID: host, workspaceID: workspace)
        // C8 pre-fills host and workspace once its screen lands.
        case .compose: select(.compose)
        case .hosts: select(.hosts)
        case .settings: select(.settings)
        case .diagnostics:
            presentOnTop(PlatformComposition.diagnosticsScreen(container: container))
        case .whatsNew:
            presentOnTop(PlatformComposition.whatsNewScreen())
        case .search(let query):
            openSearch(query: query)
        case .pairing(let url):
            // B6 owns the pair/attach grammar (RootViewController+Pairing.swift).
            handlePairingLink(url)
        }
    }

    /// Selects a tab; a tab hidden by its flag falls back to Home.
    func select(_ tab: ShellTab) {
        dismissPresented()
        guard let shell else { return }
        if !shell.select(tab) { _ = shell.select(.home) }
    }

    func presentOnTop(_ controller: UIViewController) {
        var top: UIViewController = self
        while let presented = top.presentedViewController { top = presented }
        top.present(controller, animated: true)
    }

    private func dismissPresented() {
        if presentedViewController != nil { dismiss(animated: true) }
    }
}
