import AppKit
import CmuxProductAnalytics
import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud welcome presentation gate", .serialized, .exclusiveAppContext)
struct CloudWelcomePresentationTests {
    private var isVisible: Bool {
        NSApp.windows.contains { $0.identifier?.rawValue == "cmux.cloud.welcome" && $0.isVisible }
    }

    @Test("a direct action shows and marks once, then continues without the card")
    func directActionMarksSeenAndContinues() throws {
        let suite = "CloudWelcomePresentationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var steps: [CloudWelcomeNextStep] = []
        var resumed = 0
        let controller = CloudWelcomeWindowController(
            defaults: defaults,
            nextStep: { .enable },
            performNextStep: { step, resume in steps.append(step); resume?() }
        )
        defer { controller.dismiss() }

        controller.present(over: nil, trigger: .newCloudMachine, onEnabled: { resumed += 1 })
        #expect(isVisible)
        #expect(defaults.string(forKey: CloudWelcomeWindowController.seenVersionDefaultsKey) == "0.65.1")
        #expect(steps.isEmpty)
        #expect(resumed == 0)
        controller.dismiss()
        controller.present(over: nil, trigger: .newCloudMachine, onEnabled: { resumed += 1 })
        #expect(!isVisible)
        #expect(steps == [.enable])
        #expect(resumed == 1)

        let relaunchedDefaults = try #require(UserDefaults(suiteName: suite))
        let relaunched = CloudWelcomeWindowController(defaults: relaunchedDefaults)
        let policy = ManagedDevicePolicy(defaults: relaunchedDefaults, releaseDomainDefaults: nil, forcedObject: { _, _ in nil })
        #expect(!relaunched.claimLaunchPresentation(appVersion: "0.65.2", policy: policy))
    }

    @Test("a launch viewer takes the current next step on every later Cloud action",
          arguments: [CloudWelcomeNextStep.signIn, .enable, .upgrade, .openCloud])
    func launchViewerSkipsCard(step: CloudWelcomeNextStep) throws {
        let suite = "CloudWelcomePresentationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let policy = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil, forcedObject: { _, _ in nil })
        let launch = CloudWelcomeWindowController(defaults: defaults)
        #expect(launch.claimLaunchPresentation(appVersion: "0.65.1", policy: policy))
        var steps: [CloudWelcomeNextStep] = []
        var resumed = 0
        let controller = CloudWelcomeWindowController(
            defaults: defaults,
            nextStep: { step },
            performNextStep: { step, resume in steps.append(step); resume?() }
        )
        defer { controller.dismiss() }
        for _ in 0..<2 {
            controller.present(over: nil, trigger: .newCloudMachine, onEnabled: { resumed += 1 })
            #expect(!isVisible)
        }
        #expect(steps == [step, step])
        #expect(resumed == 2)
        #expect(!controller.claimLaunchPresentation(appVersion: "0.65.2", policy: policy))
    }

    #if DEBUG
    @Test("debug force-show marks seen and reset permits another first presentation")
    func debugForceAndReset() throws {
        let suite = "CloudWelcomePresentationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = CloudWelcomeWindowController(defaults: defaults, performNextStep: { _, _ in })
        defer { controller.dismiss() }
        let policy = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil, forcedObject: { _, _ in nil })
        controller.presentForDebug(over: nil)
        #expect(isVisible)
        #expect(CloudWelcomeWindowController.hasSeenWelcome(in: defaults))
        controller.dismiss()
        #expect(!controller.claimLaunchPresentation(appVersion: "0.65.1", policy: policy))
        controller.presentForDebug(over: nil)
        #expect(isVisible)
        controller.dismiss()
        controller.present(over: nil, trigger: .newCloudMachine)
        #expect(!isVisible)
        controller.resetForDebug()
        #expect(!CloudWelcomeWindowController.hasSeenWelcome(in: defaults))
        controller.present(over: nil, trigger: .newCloudMachine)
        #expect(isVisible)
        #expect(CloudWelcomeWindowController.hasSeenWelcome(in: defaults))
        controller.resetForDebug()
        #expect(controller.claimLaunchPresentation(appVersion: "0.65.1", policy: policy))
    }
    #endif
}
