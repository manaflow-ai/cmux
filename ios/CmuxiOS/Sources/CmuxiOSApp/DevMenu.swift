#if DEBUG
import CmuxHomeUI
import CmuxiOSDesign
import SwiftUI
import CmuxiOSTerminal
import UIKit

/// DEV switcher for the Home prototypes, opened by shaking the phone.
@MainActor
enum DevMenu {
    static func make(options: DevOptions, presenter: UIViewController) -> UIAlertController {
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
        // DEBUG-only: a ghostty-next terminal fed by the mock session host.
        sheet.addAction(UIAlertAction(title: "Terminal (mock host)", style: .default) { [weak presenter] _ in
            let terminal = UINavigationController(rootViewController: DevTerminal.make())
            presenter?.present(terminal, animated: true)
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
