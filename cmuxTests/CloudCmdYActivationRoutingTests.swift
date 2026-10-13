import AppKit
import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Cmd-Shift-Y must introduce Cloud to a first-use user, through the welcome
/// card's Enable or Upgrade step, before any machine provisioning is admitted.
@MainActor
@Suite("Cloud Cmd-Shift-Y activation routing", .serialized, .exclusiveAppContext)
struct CloudCmdYActivationRoutingTests {
    @Test("Cloud activation-off opens the Cloud welcome")
    func commandShiftYOpensCloudWelcomeBeforeProvisioning() {
        let seenKey = CloudWelcomeWindowController.seenVersionDefaultsKey
        let previousSeen = UserDefaults.standard.object(forKey: seenKey)
        UserDefaults.standard.removeObject(forKey: seenKey)
        defer {
            if let previousSeen { UserDefaults.standard.set(previousSeen, forKey: seenKey) }
            else { UserDefaults.standard.removeObject(forKey: seenKey) }
        }
        let key = RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey
        let previousMarker = UserDefaults.standard.object(forKey: key)
        let previousDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer {
            if let previousMarker {
                UserDefaults.standard.set(previousMarker, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
            appDelegate.cloudWelcomeWindowController.dismiss()
            AppDelegate.shared = previousDelegate
        }

        UserDefaults.standard.set(false, forKey: key)
        AppDelegate.shared = appDelegate
        appDelegate.cloudWorkspaceOperationController = CloudWorkspaceOperationController(isAvailable: { false })

        #expect(appDelegate.performNewCloudMachineAction(debugSource: "test.cmdY.activationOff"))
        #expect(NSApp.windows.contains {
            $0.identifier?.rawValue == "cmux.cloud.welcome" && $0.isVisible
        })
    }
}
