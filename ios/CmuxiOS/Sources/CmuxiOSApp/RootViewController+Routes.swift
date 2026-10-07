import CmuxiOSPlatform
import CmuxiOSShell
import UIKit

/// Route delivery: the router calls this once the route may open (signed in,
/// or account-free routes at any time).
extension RootViewController {
    func handle(_ route: ShellRoute) {
        switch route {
        case .home: select(.home)
        case .feed: select(.feed)
        // C5 pushes the workspace and surface once its screen lands.
        case .workspaces, .workspace: select(.workspaces)
        // C8 pre-fills host and workspace once its screen lands.
        case .compose: select(.compose)
        case .hosts: select(.hosts)
        case .settings: select(.settings)
        case .diagnostics:
            presentOnTop(PlatformComposition.diagnosticsScreen(container: container))
        case .whatsNew:
            container.diagnostics.info("router", "whats-new has no screen yet")
        case .pairing:
            // B6 owns the pair/attach grammar and installs its handler here.
            container.diagnostics.info("router", "pairing link waits for B6")
        }
    }

    /// Selects a tab; a tab hidden by its flag falls back to Home.
    private func select(_ tab: ShellTab) {
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
