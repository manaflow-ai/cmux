#if DEBUG
import CmuxFeedPushCore
import CmuxHomeUI
import CmuxMobileConnect
import CmuxiOSDesign
import CmuxiOSFeatureKit
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
        // DEBUG-only: the transfer list; + saves picked files to the first Mac's inbox (C4).
        sheet.addAction(UIAlertAction(title: "Files and Transfers", style: .default) { [weak presenter] _ in
            let list = container.currentFilesFeature.makeTransferList(host: MockFixtures.studio)
            presenter?.present(UINavigationController(rootViewController: list), animated: true)
        })
        // DEBUG-only: link layer switches (D1); they apply at the next launch.
        let link = LinkDevOptions()
        for transport in MobileTransportPreference.allCases {
            let mark = link.transport == transport ? "✓ " : ""
            sheet.addAction(UIAlertAction(title: mark + transportTitle(transport), style: .default) { _ in
                UserDefaults.standard.set(transport.rawValue, forKey: LinkDevOptions.transportKey)
            })
        }
        sheet.addAction(UIAlertAction(title: (link.wireGuardOverWebRTC ? "✓ " : "") + "Link: WireGuard over WebRTC (V2)",
                                      style: .default) { _ in
            UserDefaults.standard.set(!link.wireGuardOverWebRTC, forKey: LinkDevOptions.wireGuardKey)
        })
        sheet.addAction(UIAlertAction(title: (link.prediction ? "✓ " : "") + "Terminal: local echo prediction",
                                      style: .default) { _ in
            UserDefaults.standard.set(!link.prediction, forKey: LinkDevOptions.predictionKey)
        })
        // DEBUG-only: a ghostty-next terminal fed by the mock session host.
        sheet.addAction(UIAlertAction(title: "Terminal (mock host)", style: .default) { [weak presenter] _ in
            let terminal = UINavigationController(rootViewController: DevTerminal.make())
            presenter?.present(terminal, animated: true)
        })
        // DEBUG-only: the renderer benchmark (fixture replay with frame timing).
        sheet.addAction(UIAlertAction(title: "Terminal renderer benchmark", style: .default) { [weak presenter] _ in
            presenter?.present(UINavigationController(rootViewController: DevTerminal.makeBench()), animated: true)
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
        // DEBUG-only: Keep Mac Awake rows over the mock Macs (C16 stub).
        sheet.addAction(UIAlertAction(title: "Keep Mac Awake (mock)", style: .default) { [weak presenter] _ in
            presenter?.present(PlatformComposition.keepAwakePreview(container: container), animated: true)
        })
        // DEBUG-only: a Live Activity for a sample agent (C7); the feed owner
        // updates it once its token registers.
        sheet.addAction(UIAlertAction(title: "Start sample Live Activity", style: .default) { _ in
            let started = container.activities.start(
                subject: AgentActivitySubject(host: "h_dev", task: "task_dev"), agent: "Claude Code", place: "cmux",
                title: String(localized: "activity.dev.title", defaultValue: "Sample agent task", bundle: .module))
            container.toasts.show(Toast(started == nil ? .warning : .success, started ?? "Live Activities are off"))
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

    private static func transportTitle(_ transport: MobileTransportPreference) -> String {
        switch transport {
        case .automatic: return "Link transport: Automatic"
        case .direct: return "Link transport: Direct only"
        case .webrtc: return "Link transport: WebRTC only"
        }
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
