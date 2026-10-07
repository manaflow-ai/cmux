#if DEBUG
import CmuxHomeUI
import CmuxiOSDesign
import CmuxiOSPlatform
import CmuxiOSShell
import SwiftUI
import CmuxiOSTerminal
import UIKit

/// DEV switcher for the Home prototypes, opened by shaking the phone.
@MainActor
enum DevMenu {
    static func make(container: AppContainer, presenter: UIViewController) -> UIAlertController {
        let options = container.devOptions
        let sheet = UIAlertController(
            title: String(localized: "dev.menu.title", defaultValue: "Prototypes", bundle: .module),
            message: String(localized: "dev.menu.message", defaultValue: "Pick a Home variant.", bundle: .module),
            preferredStyle: .actionSheet
        )
        for density in HomeListDensity.allCases {
            let mark = options.options.density == density ? "✓ " : ""
            sheet.addAction(UIAlertAction(title: mark + densityTitle(density), style: .default) { _ in
                options.set(density: density)
            })
        }
        for flow in HomeComposeFlow.allCases {
            let mark = options.options.composeFlow == flow ? "✓ " : ""
            sheet.addAction(UIAlertAction(title: mark + composeTitle(flow), style: .default) { _ in
                options.set(composeFlow: flow)
            })
        }
        // Feature seams (mock or real per lane) and feature flags.
        sheet.addAction(UIAlertAction(
            title: String(localized: "dev.menu.sources", defaultValue: "Feature Sources and Flags", bundle: .module),
            style: .default
        ) { [weak presenter] _ in
            presenter?.present(ShellComposition.devModel(container: container).makeScreen(), animated: true)
        })
        // DEBUG-only: a ghostty-next terminal fed by the mock session host.
        sheet.addAction(UIAlertAction(title: "Terminal (mock host)", style: .default) { [weak presenter] _ in
            let terminal = UINavigationController(rootViewController: DevTerminal.make())
            presenter?.present(terminal, animated: true)
        })
        // DEBUG-only: the text confirmation settings against the mock owner.
        sheet.addAction(UIAlertAction(title: "Text confirmation (mock owner)", style: .default) { [weak presenter] _ in
            presenter?.present(DevTextConfirm.make(), animated: true)
        })
        // DEBUG-only: one toast of each style through the toast center (C16).
        sheet.addAction(UIAlertAction(title: "Toasts (samples)", style: .default) { _ in
            container.toasts.show(Toast(.info, "Copied"))
            container.toasts.show(Toast(.success, "Task started", title: "Compose"))
            container.toasts.show(Toast(.warning, "Mac is asleep"))
            container.toasts.show(Toast(.failure, "Send failed", action: ToastAction(label: "Retry") {}))
        })
        // DEBUG-only: the Mac update gate for the mock Mac that needs an update (C16).
        sheet.addAction(UIAlertAction(title: "Mac update gate (mock)", style: .default) { [weak presenter] _ in
            Task { @MainActor in
                guard let gate = await PlatformComposition.macGatePreview(container: container) else { return }
                presenter?.present(gate, animated: true)
            }
        })
        // DEBUG-only lab for the transport lane's Wi-Fi to cellular test (no user strings).
        sheet.addAction(UIAlertAction(title: "Network Lab", style: .default) { [weak presenter] _ in
            let lab = UINavigationController(rootViewController: UIHostingController(rootView: NetLabView()))
            presenter?.present(lab, animated: true)
        })
        sheet.addAction(UIAlertAction(
            title: String(localized: "dev.menu.cancel", defaultValue: "Cancel", bundle: .module), style: .cancel))
        return sheet
    }

    private static func densityTitle(_ density: HomeListDensity) -> String {
        switch density {
        case .comfortable: String(localized: "dev.density.comfortable", defaultValue: "List: Comfortable", bundle: .module)
        case .compact: String(localized: "dev.density.compact", defaultValue: "List: Compact", bundle: .module)
        case .pinnedGrid: String(localized: "dev.density.pinnedGrid", defaultValue: "List: Pinned Grid", bundle: .module)
        }
    }

    private static func composeTitle(_ flow: HomeComposeFlow) -> String {
        switch flow {
        case .inlineTo: String(localized: "dev.compose.inlineTo", defaultValue: "Compose: To Field", bundle: .module)
        case .inviteSheet: String(localized: "dev.compose.inviteSheet", defaultValue: "Compose: Invite Sheet", bundle: .module)
        case .contactsFirst: String(localized: "dev.compose.contactsFirst", defaultValue: "Compose: Contacts First", bundle: .module)
        }
    }
}
#endif
