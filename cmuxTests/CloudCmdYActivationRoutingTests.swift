import AppKit
import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Cmd-Y must lead a first-use user to the Cloud Settings toggle before any
/// machine provisioning operation is admitted.
@MainActor
@Suite("Cloud Cmd-Y activation routing", .serialized, .exclusiveAppContext)
struct CloudCmdYActivationRoutingTests {
    @Test("rollout-on activation-off opens Cloud Settings")
    func commandYOpensCloudSettingsBeforeProvisioning() {
        let key = RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey
        let previousMarker = UserDefaults.standard.object(forKey: key)
        let flag = CmuxFeatureFlags.cloudMachinesFlag
        let previousOverride = CmuxFeatureFlags.shared.overrideValue(for: flag)
        let previousDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer {
            if let previousMarker {
                UserDefaults.standard.set(previousMarker, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
            CmuxFeatureFlags.shared.setOverride(previousOverride, for: flag)
            NSApp.windows.first {
                $0.identifier?.rawValue == SettingsWindowPresenter.windowIdentifier
            }?.close()
            AppDelegate.shared = previousDelegate
        }

        UserDefaults.standard.set(false, forKey: key)
        CmuxFeatureFlags.shared.setOverride(true, for: flag)
        AppDelegate.shared = appDelegate
        appDelegate.cloudWorkspaceOperationController = CloudWorkspaceOperationController(isAvailable: { false })

        #expect(appDelegate.performNewCloudMachineAction(debugSource: "test.cmdY.activationOff"))
        #expect(NSApp.windows.contains {
            $0.identifier?.rawValue == SettingsWindowPresenter.windowIdentifier
        })
    }
}
