import AppKit
import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Sidebar Cloud button routing", .serialized, .exclusiveAppContext)
struct SidebarCloudButtonActionTests {
    @Test("enabled Cloud reveals Machines on every press without opening welcome")
    func enabledCloudKeepsMachinesOpen() {
        var visible = false
        var mode: RightSidebarMode = .files
        var introductions = 0
        let action = SidebarCloudButtonAction(
            isAvailable: { true },
            isEnabled: { true },
            revealMachines: { visible = true; mode = .machines },
            presentIntroduction: { introductions += 1 }
        )
        action.perform()
        #expect(visible)
        #expect(mode == .machines)
        action.perform()
        #expect(visible)
        #expect(mode == .machines)
        #expect(introductions == 0)
    }

    @Test("disabled Cloud reopens welcome despite the seen marker for every account route",
          arguments: [CloudWelcomeNextStep.signIn, .upgrade, .enable, .openCloud])
    func disabledCloudAlwaysIntroduces(step: CloudWelcomeNextStep) throws {
        let suite = "SidebarCloudButtonActionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        CloudWelcomeWindowController.markCampaignSeen(in: defaults)
        var nextSteps: [CloudWelcomeNextStep] = []
        let welcome = CloudWelcomeWindowController(
            defaults: defaults,
            nextStep: { step },
            performNextStep: { step, _ in nextSteps.append(step) }
        )
        defer { welcome.dismiss() }
        var revealed = 0
        let action = SidebarCloudButtonAction(
            isAvailable: { true },
            isEnabled: { false },
            revealMachines: { revealed += 1 },
            presentIntroduction: {
                #expect(revealed > 0)
                welcome.presentIntroduction(over: nil)
            }
        )
        for _ in 0..<2 {
            action.perform()
            #expect(NSApp.windows.contains {
                $0.identifier?.rawValue == "cmux.cloud.welcome" && $0.isVisible
            })
            welcome.dismiss()
        }
        #expect(revealed == 2)
        #expect(nextSteps.isEmpty)
        #expect(CloudWelcomeWindowController.hasSeenWelcome(in: defaults))
    }

    @Test("an explicit introduction records the seen marker so launch does not repeat it")
    func introductionMarksWelcomeSeen() throws {
        let suite = "SidebarCloudButtonActionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let welcome = CloudWelcomeWindowController(defaults: defaults)
        defer { welcome.dismiss() }
        #expect(!CloudWelcomeWindowController.hasSeenWelcome(in: defaults))
        welcome.presentIntroduction(over: nil)
        #expect(CloudWelcomeWindowController.hasSeenWelcome(in: defaults))
        #expect(!welcome.claimLaunchPresentation(appVersion: "0.65.1", policy: ManagedDevicePolicy(defaults: defaults)))
    }

    @Test("managed Cloud restrictions do not reveal or introduce Cloud")
    func unavailableCloudDoesNothing() {
        var events = 0
        SidebarCloudButtonAction(
            isAvailable: { false },
            isEnabled: { false },
            revealMachines: { events += 1 },
            presentIntroduction: { events += 1 }
        ).perform()
        #expect(events == 0)
    }
}
