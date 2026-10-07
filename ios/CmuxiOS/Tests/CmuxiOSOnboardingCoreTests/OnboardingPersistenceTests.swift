import CmuxiOSOnboardingCore
import Foundation
import Testing

@Suite("Onboarding persistence and launch")
@MainActor
struct OnboardingPersistenceTests {
    private func suite() -> UserDefaults {
        let name = "onboarding-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("Progress round-trips through UserDefaults")
    func roundTrip() {
        let defaults = suite()
        let store = OnboardingProgressStore(defaults: defaults)
        #expect(store.load() == nil)
        let progress = OnboardingProgress(current: .pair, outcomes: [.welcome: .completed, .approve: .skipped])
        store.save(progress)
        #expect(OnboardingProgressStore(defaults: defaults).load() == progress)
        store.reset()
        #expect(store.load() == nil)
    }

    @Test("An unreadable or other-version value reads as no progress")
    func unreadable() throws {
        let defaults = suite()
        defaults.set(Data("nope".utf8), forKey: OnboardingProgressStore.key)
        #expect(OnboardingProgressStore(defaults: defaults).load() == nil)
        var future = OnboardingProgress(current: .pair)
        future.version = 99
        defaults.set(try JSONEncoder().encode(future), forKey: OnboardingProgressStore.key)
        #expect(OnboardingProgressStore(defaults: defaults).load() == nil)
    }

    @Test("Automated DEBUG launches skip unless onboarding is forced")
    func launchPolicy() {
        #expect(OnboardingLaunchPolicy(environment: ["CMUX_DOGFOOD_READINESS_NONCE": "n"], isDebug: true).decision == .skip)
        #expect(OnboardingLaunchPolicy(environment: ["CMUX_UITEST_STACK_EMAIL": "a@b"], isDebug: true).decision == .skip)
        #expect(OnboardingLaunchPolicy(environment: ["CMUX_IOS_HOME_PREVIEW": "1"], isDebug: true).decision == .skip)
        #expect(OnboardingLaunchPolicy(environment: ["CMUX_IOS_ONBOARDING": "0"], isDebug: true).decision == .skip)
        let forced = OnboardingLaunchPolicy(
            environment: ["CMUX_UITEST_STACK_EMAIL": "a@b", "CMUX_IOS_ONBOARDING": "1", "CMUX_IOS_ONBOARDING_STEP": "pair"],
            isDebug: true
        )
        #expect(forced.decision == .fresh(start: .pair))
        #expect(OnboardingLaunchPolicy(environment: [:], isDebug: true).decision == .stored(start: nil))
        #expect(OnboardingLaunchPolicy(environment: ["CMUX_IOS_ONBOARDING": "0"], isDebug: false).decision == .stored(start: nil))
    }

    @Test("A signed-in install without stored progress predates onboarding and is not interrupted")
    func shouldPresent() {
        let policy = OnboardingLaunchPolicy(environment: [:], isDebug: false)
        #expect(policy.shouldPresent(stored: nil, isSignedIn: false))
        #expect(!policy.shouldPresent(stored: nil, isSignedIn: true))
        #expect(policy.shouldPresent(stored: OnboardingProgress(current: .pair), isSignedIn: true))
        #expect(!policy.shouldPresent(stored: OnboardingProgress(current: .celebrate, finished: true), isSignedIn: false))
        let fresh = OnboardingLaunchPolicy(environment: ["CMUX_IOS_ONBOARDING": "1"], isDebug: true)
        #expect(fresh.shouldPresent(stored: OnboardingProgress(finished: true), isSignedIn: true))
        let skip = OnboardingLaunchPolicy(environment: ["CMUX_IOS_ONBOARDING": "0"], isDebug: true)
        #expect(!skip.shouldPresent(stored: nil, isSignedIn: false))
    }

    @Test("The in-memory store never touches defaults")
    func inMemory() {
        let store = InMemoryProgressStore()
        store.save(OnboardingProgress(current: .reply))
        #expect(store.load()?.current == .reply)
        store.reset()
        #expect(store.load() == nil)
    }
}
