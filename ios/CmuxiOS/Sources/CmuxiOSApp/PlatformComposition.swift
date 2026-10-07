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
        [
            ShellSettingsLink(id: "diagnostics", title: PlatformComposition.diagnosticsTitle,
                              systemImage: "stethoscope") {
                AnyView(DiagnosticsView(model: diagnosticsModel(container: container)))
            },
        ]
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

    private static var diagnosticsTitle: String {
        String(localized: "platform.settings.diagnostics", defaultValue: "Diagnostics", bundle: .module)
    }
}
