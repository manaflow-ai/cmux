import CmuxiOSFeatureKit
import CmuxiOSPlatform
import CmuxiOSSearchCore
import CmuxiOSShell
import SwiftUI
import UIKit

/// Lane C15: opening search (Cmd-K, `cmux://search`) and its results.
extension RootViewController {
    /// Selects the Search tab and focuses its field; presents search as a
    /// sheet when the tab is hidden.
    func openSearch(query: String?) {
        guard let shell, let search = shellFeatures?.search else { return }
        dismissPresentedIfNeeded()
        if shell.select(.search) {
            search.focus(query: query)
        } else {
            presentOnTop(search.makeModalSearch(query: query))
        }
    }

    func openSearchDestination(_ destination: SearchDestination) {
        let router = container.router
        switch destination {
        case .workspace(let host, let workspace, let surface):
            _ = router.open(.workspace(host: host, workspace: workspace, surface: surface))
        case .feedItem(let id):
            _ = router.open(.feed(item: id))
        case .host(let id, let kind):
            switch kind {
            case .pairedMac: _ = router.open(.workspaces)
            case .direct: _ = router.open(.hosts)
            case .ssh:
                select(.hosts)
                shellFeatures?.ssh.openHost(id)
            }
        case .settings(let page):
            openSettings(page)
        case .action(.newTask):
            _ = router.open(.compose(host: nil, workspace: nil))
        case .action(.pairMac):
            presentPairScanner()
        case .action(.addSSHHost):
            select(.hosts)
            shellFeatures?.ssh.presentAddHost()
        }
    }

    private func openSettings(_ page: SearchSettingsPage) {
        let router = container.router
        switch page {
        case .diagnostics: _ = router.open(.diagnostics)
        case .whatsNew: _ = router.open(.whatsNew)
        case .main, .account, .devices: _ = router.open(.settings)
        case .terminal, .notifications, .privacy:
            _ = router.open(.settings)
            shellFeatures?.settings.openedPage = switch page {
            case .terminal: .terminal
            case .notifications: .notifications
            default: .privacy
            }
        }
    }

    private func presentPairScanner() {
        weak var sheet: UIViewController?
        let view = PairMacScannerView(
            onLink: { [weak self] url in
                sheet?.dismiss(animated: true) { _ = self?.container.router.open(url) }
            },
            onCancel: { sheet?.dismiss(animated: true) })
        let hosting = UIHostingController(rootView: view)
        sheet = hosting
        presentOnTop(hosting)
    }

    private func dismissPresentedIfNeeded() {
        if presentedViewController != nil { dismiss(animated: true) }
    }
}
