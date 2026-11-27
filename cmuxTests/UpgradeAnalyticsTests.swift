import AppKit
import CMUXMobileCore
import CmuxCloud
import CmuxProductAnalytics
import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Records the events a ``ProductAnalytics`` sends, for app-level analytics tests.
private final class RecordingSink: AnalyticsEmitting {
    // Written by the pipeline actor, read by the test after `drain()`.
    private let state = OSAllocatedUnfairLock<[(String, [String: AnalyticsValue])]>(initialState: [])
    var events: [(name: String, properties: [String: AnalyticsValue])] { state.withLock { $0.map { (name: $0.0, properties: $0.1) } } }
    func named(_ name: String) -> [[String: AnalyticsValue]] { events.filter { $0.name == name }.map(\.properties) }

    func capture(_ event: String, _ properties: [String: AnalyticsValue]) { state.withLock { $0.append((event, properties)) } }
    func identify(userId: String?, alias: String?, properties: [String: AnalyticsValue]) {}
    func setSuperProperties(_ properties: [String: AnalyticsValue]) {}
    func flush() async {}
}

private enum TestAnalytics {
    static let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    /// An emitter with its own ledger suite. Remove the suite with
    /// ``remove(_:)`` once the test has drained the emitter.
    static func make(enabled: Bool = true) -> (ProductAnalytics, RecordingSink, String) {
        let sink = RecordingSink()
        let suiteName = "UpgradeAnalyticsTests.\(UUID().uuidString)"
        let analytics = ProductAnalytics(
            isEnabled: enabled,
            sink: sink,
            ledger: ProductAnalyticsLedger(defaults: UserDefaults(suiteName: suiteName)!),
            context: ProductAnalyticsContext(appVersion: "0.66.0", appBuild: "1", channel: "dev", osVersion: "15.5"),
            isPreexistingInstall: true
        )
        return (analytics, sink, suiteName)
    }

    static func remove(_ suiteName: String) {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
@Suite("Upgrade analytics", .serialized, .exclusiveAppContext)
struct UpgradeAnalyticsTests {
    @Test("the sidebar Upgrade badge records its impression, click and dismiss with its source")
    func sidebarBadge() async {
        let (analytics, sink, ledgerSuite) = TestAnalytics.make()
        defer { TestAnalytics.remove(ledgerSuite) }
        var opened: [ProUpgradeSource] = []
        let actions = ProBadgeActions(analytics: analytics, openPricing: { opened.append($0) })
        actions.appeared()
        actions.appeared()
        actions.upgrade()
        actions.dismissed()
        await analytics.drain()

        #expect(opened == [.sidebarBadge])
        #expect(sink.named("cmux_upgrade_prompt_shown").compactMap { $0["source"] } == [AnalyticsValue.string("mac_sidebar_badge")])
        let click = sink.named("cmux_upgrade_entrypoint_opened")
        #expect(click.count == 1)
        #expect(click.first?["source"] == .string("mac_sidebar_badge"))
        #expect(click.first?["destination"] == .string("pricing_page"))
        #expect(click.first?["plan"] == .string("pro"))
        #expect(click.first?["client"] == .string("mac"))
        #expect(click.first?["account_plan"] != nil)
        #expect(sink.named("cmux_upgrade_badge_dismissed").compactMap { $0["source"] } == [AnalyticsValue.string("mac_sidebar_badge")])
    }

    @Test("the welcome card's Upgrade records shown, click, close and the checkout source",
          arguments: [CloudWelcomeTrigger.launchAnnouncement, .newCloudWorkspace, .newCloudMachine])
    func welcomeUpgrade(trigger: CloudWelcomeTrigger) async throws {
        let (analytics, sink, ledgerSuite) = TestAnalytics.make()
        defer { TestAnalytics.remove(ledgerSuite) }
        let suite = "UpgradeAnalyticsTests.welcome.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var performed: [CloudWelcomeNextStep] = []
        let controller = CloudWelcomeWindowController(
            defaults: defaults,
            nextStep: { .upgrade },
            performNextStep: { step, _ in
                performed.append(step)
                // What the real `.upgrade` step does, minus opening pricing.
                ProUpgradePresenter.present(source: .cloudWelcome, analytics: analytics, open: { _ in })
            },
            analytics: analytics,
            now: { TestAnalytics.fixedNow }
        )
        defer { controller.dismiss() }
        controller.present(over: nil, trigger: trigger)
        controller.handleNext(.upgrade)
        await analytics.drain()

        #expect(performed == [.upgrade])
        let shown = try #require(sink.named("cmux_cloud_welcome_shown").first)
        #expect(shown["trigger"] == .string(trigger.rawValue))
        #expect(shown["next_step"] == .string("upgrade"))
        #expect(sink.named("cmux_upgrade_prompt_shown").compactMap { $0["source"] } == [AnalyticsValue.string("mac_cloud_welcome")])
        let click = try #require(sink.named("cmux_cloud_welcome_button_clicked").first)
        #expect(click["button"] == .string("upgrade"))
        #expect(click["trigger"] == .string(trigger.rawValue))
        let closed = sink.named("cmux_cloud_welcome_closed")
        #expect(closed.count == 1)
        #expect(closed.first?["outcome"] == .string("upgrade"))
        #expect(sink.named("cmux_upgrade_entrypoint_opened").compactMap { $0["source"] } == [AnalyticsValue.string("mac_cloud_welcome")])
        let order = sink.events.map(\.name).filter { $0.hasPrefix("cmux_cloud_welcome") || $0 == "cmux_upgrade_entrypoint_opened" }
        #expect(order == [
            "cmux_cloud_welcome_shown",
            "cmux_cloud_welcome_button_clicked",
            "cmux_cloud_welcome_closed",
            "cmux_upgrade_entrypoint_opened",
        ])
    }

    @Test("Enable, Not Now and a plain window close each end the card once")
    func welcomeOtherOutcomes() async throws {
        for (step, act, button, outcome) in [
            (CloudWelcomeNextStep.enable, "next", "enable", "enable"),
            (.signIn, "next", "sign_in", "sign_in"),
            (.upgrade, "notNow", "not_now", "not_now"),
            (.upgrade, "close", nil, "window_closed"),
        ] as [(CloudWelcomeNextStep, String, String?, String)] {
            let (analytics, sink, ledgerSuite) = TestAnalytics.make()
            defer { TestAnalytics.remove(ledgerSuite) }
            let suite = "UpgradeAnalyticsTests.outcome.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let controller = CloudWelcomeWindowController(
                defaults: defaults,
                nextStep: { step },
                performNextStep: { _, _ in },
                analytics: analytics,
                now: { TestAnalytics.fixedNow }
            )
            controller.present(over: nil, trigger: .newCloudMachine)
            switch act {
            case "next": controller.handleNext(step)
            case "notNow": controller.handleNotNow()
            default: controller.dismiss()
            }
            controller.dismiss()
            await analytics.drain()

            let buttons = sink.named("cmux_cloud_welcome_button_clicked").compactMap { $0["button"] }
            let expectedButtons: [AnalyticsValue] = button.map { [AnalyticsValue.string($0)] } ?? []
            #expect(buttons == expectedButtons)
            let closed = sink.named("cmux_cloud_welcome_closed")
            #expect(closed.count == 1, "\(outcome)")
            #expect(closed.first?["outcome"] == .string(outcome))
            #expect(closed.first?["visible_for"] == .string("lt_1s"))
        }
    }

    @Test("the sidebar Cloud button records its route; while Cloud is off the welcome follows with its trigger")
    func sidebarCloudButton() async throws {
        let (analytics, sink, ledgerSuite) = TestAnalytics.make()
        defer { TestAnalytics.remove(ledgerSuite) }
        let suite = "UpgradeAnalyticsTests.cloudButton.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let welcome = CloudWelcomeWindowController(
            defaults: defaults,
            nextStep: { .upgrade },
            performNextStep: { _, _ in },
            analytics: analytics,
            now: { TestAnalytics.fixedNow }
        )
        defer { welcome.dismiss() }

        SidebarCloudButtonAction(
            isAvailable: { true }, isEnabled: { true }, revealMachines: {}, presentIntroduction: {},
            analytics: analytics
        ).perform()
        SidebarCloudButtonAction(
            isAvailable: { true }, isEnabled: { false }, revealMachines: {},
            presentIntroduction: { welcome.presentIntroduction(over: nil) },
            analytics: analytics
        ).perform()
        SidebarCloudButtonAction(
            isAvailable: { false }, isEnabled: { false }, revealMachines: {}, presentIntroduction: {},
            analytics: analytics
        ).perform()
        await analytics.drain()

        #expect(sink.named("cmux_cloud_button_clicked").compactMap { $0["action"] }
            == [AnalyticsValue.string("open_cloud"), .string("introduce_cloud")])
        let shown = try #require(sink.named("cmux_cloud_welcome_shown").first)
        #expect(shown["trigger"] == .string("sidebar_cloud_button"))
        #expect(shown["next_step"] == .string("upgrade"))
        let order = sink.events.map(\.name).filter { $0 == "cmux_cloud_button_clicked" || $0 == "cmux_cloud_welcome_shown" }
        #expect(order == ["cmux_cloud_button_clicked", "cmux_cloud_button_clicked", "cmux_cloud_welcome_shown"])
    }

    @Test("a card that turns into Upgrade after the plan loads records the Upgrade impression once")
    func welcomeUpgradeImpressionAfterPlanLoads() async throws {
        let (analytics, sink, ledgerSuite) = TestAnalytics.make()
        defer { TestAnalytics.remove(ledgerSuite) }
        let suite = "UpgradeAnalyticsTests.planLoads.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var step = CloudWelcomeNextStep.openCloud
        let controller = CloudWelcomeWindowController(
            defaults: defaults,
            nextStep: { step },
            performNextStep: { _, _ in },
            analytics: analytics,
            now: { TestAnalytics.fixedNow }
        )
        defer { controller.dismiss() }
        controller.present(over: nil, trigger: .newCloudWorkspace)
        await analytics.drain()
        #expect(sink.named("cmux_upgrade_prompt_shown").isEmpty)

        step = .upgrade
        controller.analyticsSession?.stepDisplayed(.upgrade)
        controller.analyticsSession?.stepDisplayed(.upgrade)
        controller.handleNotNow()
        await analytics.drain()
        #expect(sink.named("cmux_upgrade_prompt_shown").compactMap { $0["source"] } == [AnalyticsValue.string("mac_cloud_welcome")])
        #expect(sink.named("cmux_cloud_welcome_shown").first?["next_step"] == .string("open_cloud"))
        #expect(sink.named("cmux_cloud_welcome_closed").first?["next_step"] == .string("upgrade"))
    }

    @Test("with telemetry off, no upgrade surface records anything")
    func optOut() async throws {
        let (analytics, sink, ledgerSuite) = TestAnalytics.make(enabled: false)
        defer { TestAnalytics.remove(ledgerSuite) }
        let actions = ProBadgeActions(analytics: analytics, openPricing: { _ in })
        actions.appeared()
        actions.upgrade()
        actions.dismissed()
        let suite = "UpgradeAnalyticsTests.optout.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = CloudWelcomeWindowController(
            defaults: defaults,
            nextStep: { .upgrade },
            performNextStep: { _, _ in },
            analytics: analytics,
            now: { TestAnalytics.fixedNow }
        )
        controller.present(over: nil, trigger: .launchAnnouncement)
        controller.handleNotNow()
        await analytics.drain()
        #expect(sink.events.isEmpty)
    }
}

@Suite("Account analytics transitions")
struct AccountAnalyticsStateTests {
    @Test("restore identifies without a sign-in success; a started sign-in succeeds once")
    func signInLifecycle() {
        var state = AccountAnalyticsState()
        let restoring = state.observe(userID: nil, isSettling: true, failure: nil)
        let restored = state.observe(userID: "u1", isSettling: false, failure: nil)
        let signedOut = state.observe(userID: nil, isSettling: false, failure: nil)
        state.signInStarted()
        let waiting = state.observe(userID: nil, isSettling: true, failure: nil)
        let signedIn = state.observe(userID: "u2", isSettling: false, failure: nil)
        let unchanged = state.observe(userID: "u2", isSettling: false, failure: nil)
        #expect(restoring.isEmpty)
        #expect(restored == [.identify(userID: "u1")])
        #expect(signedOut == [.signedOut])
        #expect(waiting.isEmpty)
        #expect(signedIn == [.identify(userID: "u2"), .signInSucceeded])
        #expect(unchanged.isEmpty)
    }

    @Test("a failure is reported once per started sign-in")
    func signInFailure() {
        var state = AccountAnalyticsState()
        let unstarted = state.observe(userID: nil, isSettling: false, failure: .timedOut)
        state.signInStarted()
        let failed = state.observe(userID: nil, isSettling: false, failure: .timedOut)
        let repeated = state.observe(userID: nil, isSettling: false, failure: .timedOut)
        #expect(unstarted.isEmpty)
        #expect(failed == [.signInFailed(.timedOut)])
        #expect(repeated.isEmpty)
        #expect(AccountAnalyticsState.reason(.unknown) == .network)
        #expect(AccountAnalyticsState.reason(nil) == nil)
    }
}

@MainActor
@Suite("Machine create analytics", .serialized)
struct MachineCreateAnalyticsTests {
    @Test("a refused create reports its plan limit, and the retry that succeeds reports one create")
    func refusalThenRetry() async throws {
        let (analytics, sink, ledgerSuite) = TestAnalytics.make()
        defer { TestAnalytics.remove(ledgerSuite) }
        let launches = MachineCreateCoordinatorTests.LaunchRecorder()
        let coordinator = MachineCreateCoordinator(
            notifier: { _ in },
            notificationCenter: NotificationCenter(),
            analytics: analytics
        )
        coordinator.start(MachineCreateCoordinatorTests.newMachineRequest(), launch: launches.launch)
        let id = try #require(coordinator.operations.first?.id)
        launches.complete(status: 1, output: "Error: limit", refusalCode: "vm_active_limit_exceeded")
        #expect(coordinator.retry(id))
        launches.complete(status: 0, output: "OK machine=m1", machineID: "m1")
        await analytics.drain()

        let failed = sink.named("cmux_cloud_machine_create_failed")
        #expect(failed.count == 1)
        #expect(failed.first?["error_code"] == .string("vm_active_limit_exceeded"))
        #expect(failed.first?["error_class"] == .string("plan_limit"))
        #expect(sink.named("cmux_cloud_plan_limit_hit").compactMap { $0["limit"] } == [AnalyticsValue.string("active_machines")])
        #expect(sink.named("cmux_cloud_machine_create_succeeded").count == 1)
    }
}
