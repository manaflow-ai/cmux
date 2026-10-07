import CMUXMobileCore
import CmuxiOSPlatform
import CmuxiOSPlatformUI
import CmuxiOSShell
import Foundation
import SwiftUI
import UIKit

/// Builds the platform screens (c16-platform.md) from the container: the
/// Settings rows and the screens routes open.
@MainActor
enum PlatformComposition {
    static func settingsLinks(container: AppContainer) -> [ShellSettingsLink] {
        var links = [
            ShellSettingsLink(id: "whatsNew", title: whatsNewTitle, systemImage: "sparkles") {
                AnyView(WhatsNewArchiveView(entries: whatsNewPolicy().visibleEntries(WhatsNewCatalog().entries)))
            },
            ShellSettingsLink(id: "diagnostics", title: PlatformComposition.diagnosticsTitle,
                              systemImage: "stethoscope") {
                AnyView(DiagnosticsView(model: diagnosticsModel(container: container)))
            },
        ]
        if container.isDemo {
            links.append(ShellSettingsLink(id: "demo", title: demoTitle, systemImage: "theatermasks") {
                AnyView(DemoContentView())
            })
        }
        return links
    }

    static func whatsNewPolicy() -> WhatsNewPolicy {
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        return WhatsNewPolicy(channel: BuildChannel(bundleID: Bundle.main.bundleIdentifier ?? "", isDebug: isDebug))
    }

    static var currentVersion: AppVersion? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
    }

    /// The post-update sheet, once per update; nil on first install or when
    /// nothing new is visible on this channel.
    static func launchWhatsNew() -> UIViewController? {
        guard let current = currentVersion,
              let entry = whatsNewPolicy().entryToPresent(WhatsNewCatalog().entries, current: current) else { return nil }
        return whatsNewSheet(entry)
    }

    /// `cmux://whats-new`: the newest visible page, or the archive.
    static func whatsNewScreen() -> UIViewController {
        let entries = whatsNewPolicy().visibleEntries(WhatsNewCatalog().entries)
        if let newest = entries.first { return whatsNewSheet(newest) }
        return UIHostingController(rootView: NavigationStack { WhatsNewArchiveView(entries: entries) })
    }

    private static func whatsNewSheet(_ entry: WhatsNewEntry) -> UIViewController {
        let box = WeakControllerBox()
        let controller = UIHostingController(rootView: WhatsNewView(entry: entry) { box.controller?.dismiss(animated: true) })
        box.controller = controller
        return controller
    }

    /// DEV preview of the Mac update gate over the mock capabilities.
    static func macGatePreview(container: AppContainer) async -> UIViewController? {
        var updates = await container.makeMacCapabilitiesSource().updates().makeAsyncIterator()
        let policy = container.macCompatibility
        guard let macs = await updates.next()?.value.values,
              let mac = macs.first(where: { !policy.verdict(for: $0).isCompatible }) else { return nil }
        return UIHostingController(rootView: MacUpdateGateView(mac: mac, verdict: policy.verdict(for: mac)))
    }

    static func diagnosticsModel(container: AppContainer) -> DiagnosticsModel {
        DiagnosticsModel(
            sink: container.diagnostics,
            supportInfo: { supportInfo(container: container) },
            consentKey: UserDefaultsAnalyticsConsentProvider.telemetryKey
        )
    }

    /// The diagnostics screen in its own navigation stack, for a sheet.
    static func diagnosticsScreen(container: AppContainer) -> UIViewController {
        UIHostingController(rootView: NavigationStack {
            DiagnosticsView(model: diagnosticsModel(container: container))
        })
    }

    static func supportInfo(container: AppContainer) -> DiagnosticSupportInfo {
        let flags = ShellFeatureFlag.allCases.filter(container.flags.isEnabled).map(\.rawValue)
        return DiagnosticSupportInfo(
            bundle: .main,
            deviceModel: deviceModel(),
            extra: [.init("Flags", flags.joined(separator: ", "))]
        )
    }

    private static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return machine.isEmpty ? UIDevice.current.model : machine
    }

    private static var whatsNewTitle: String {
        String(localized: "platform.settings.whatsNew", defaultValue: "What's New", bundle: .module)
    }

    private static var demoTitle: String {
        String(localized: "platform.settings.demo", defaultValue: "Demo Content", bundle: .module)
    }

    private static var diagnosticsTitle: String {
        String(localized: "platform.settings.diagnostics", defaultValue: "Diagnostics", bundle: .module)
    }
}
