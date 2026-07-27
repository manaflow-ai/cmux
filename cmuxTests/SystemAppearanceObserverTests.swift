import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct AppearanceEffectiveColorSchemeTests {
    @Test
    func effectiveColorSchemeExplicitModesShortCircuit() {
        #expect(AppearanceSettings.effectiveColorScheme(for: AppearanceMode.light.rawValue, fallback: .dark) == .light)
        #expect(AppearanceSettings.effectiveColorScheme(for: AppearanceMode.dark.rawValue, fallback: .light) == .dark)
    }

    @Test
    func effectiveColorSchemeSystemModeUsesFallbackBeforeLaunchWithoutReadingEffectiveAppearance() {
        var effectiveAppearanceReadCount = 0

        let scheme = AppearanceSettings.effectiveColorScheme(
            for: AppearanceMode.system.rawValue,
            fallback: .light,
            isApplicationFinishedLaunching: { false },
            effectivePrefersDark: {
                effectiveAppearanceReadCount += 1
                return true
            }
        )

        #expect(scheme == .light)
        #expect(effectiveAppearanceReadCount == 0)
    }

    @Test
    func effectiveColorSchemeSystemModeUsesEffectiveAppearanceAfterLaunch() {
        let scheme = AppearanceSettings.effectiveColorScheme(
            for: AppearanceMode.system.rawValue,
            fallback: .light,
            isApplicationFinishedLaunching: { true },
            effectivePrefersDark: { true }
        )

        #expect(scheme == .dark)
    }
}

@MainActor
@Suite
struct GhosttyAppearanceSyncColorSchemeTests {
    @Test
    func nilSystemAppearanceUsesLiveEffectiveAppearanceAfterLaunchWhenDefaultsAreStale() throws {
        let suiteName = "GhosttyAppearanceSyncColorSchemeTests.Live.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppearanceMode.system.rawValue, forKey: AppearanceSettings.appearanceModeKey)
        defaults.set("Dark", forKey: "AppleInterfaceStyle")
        var liveAppearanceReadCount = 0

        let result = GhosttyConfig.appearanceSyncColorSchemePreference(
            passedAppearance: nil,
            defaults: defaults,
            isApplicationFinishedLaunching: { true },
            liveEffectiveAppearance: {
                liveAppearanceReadCount += 1
                return NSAppearance(named: .aqua)
            }
        )

        #expect(result.preference == .light)
        #expect(result.source == "liveEffectiveAppearance")
        #expect(liveAppearanceReadCount == 1)
    }

    @Test
    func nilSystemAppearanceFallsBackBeforeLaunchWithoutReadingLiveEffectiveAppearance() throws {
        let suiteName = "GhosttyAppearanceSyncColorSchemeTests.BeforeLaunch.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppearanceMode.system.rawValue, forKey: AppearanceSettings.appearanceModeKey)
        defaults.set("Dark", forKey: "AppleInterfaceStyle")
        var liveAppearanceReadCount = 0

        let result = GhosttyConfig.appearanceSyncColorSchemePreference(
            passedAppearance: nil,
            defaults: defaults,
            isApplicationFinishedLaunching: { false },
            liveEffectiveAppearance: {
                liveAppearanceReadCount += 1
                return NSAppearance(named: .aqua)
            }
        )

        #expect(result.preference == .dark)
        #expect(result.source == "currentPreference")
        #expect(liveAppearanceReadCount == 0)
    }

    @Test
    func explicitAppearanceModeIgnoresPassedAndLiveEffectiveAppearance() throws {
        let suiteName = "GhosttyAppearanceSyncColorSchemeTests.Explicit.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppearanceMode.light.rawValue, forKey: AppearanceSettings.appearanceModeKey)
        defaults.set("Dark", forKey: "AppleInterfaceStyle")

        let result = GhosttyConfig.appearanceSyncColorSchemePreference(
            passedAppearance: NSAppearance(named: .darkAqua),
            defaults: defaults,
            isApplicationFinishedLaunching: { true },
            liveEffectiveAppearance: {
                NSAppearance(named: .darkAqua)
            }
        )

        #expect(result.preference == .light)
        #expect(result.source == "currentPreference")
    }
}

@MainActor
@Suite
struct SystemAppearanceObserverTests {
    private final class ObservationToken: EffectiveAppearanceObservation {
        private(set) var invalidateCallCount = 0

        func invalidate() {
            invalidateCallCount += 1
        }
    }

    private final class Harness {
        var modeRawValue: String? = AppearanceMode.system.rawValue
        var prefersDark = false
        var startObservationReturnsNil = false
        var startObservationCallCount = 0
        var events: [String] = []
        var onPostSystemAppearanceDidChange: (() -> Void)?
        private(set) var appearanceChangedHandler: (@MainActor () -> Void)?
        let observation = ObservationToken()

        lazy var environment = SystemAppearanceObserver.Environment(
            startEffectiveAppearanceObservation: { [unowned self] handler in
                self.startObservationCallCount += 1
                self.appearanceChangedHandler = handler
                return self.startObservationReturnsNil ? nil : self.observation
            },
            currentAppearanceModeRawValue: { [unowned self] in
                self.modeRawValue
            },
            effectivePrefersDark: { [unowned self] in
                self.events.append("effectivePrefersDark(\(self.prefersDark))")
                return self.prefersDark
            },
            synchronizeTerminalTheme: { [unowned self] in
                self.events.append("synchronizeTerminalTheme")
            },
            postSystemAppearanceDidChange: { [unowned self] in
                self.events.append("postSystemAppearanceDidChange")
                self.onPostSystemAppearanceDidChange?()
            }
        )

        @MainActor
        func fireEffectiveAppearanceChanged() {
            appearanceChangedHandler?()
        }
    }

    // (a) System-mode appearance flip posts the notification exactly once.
    @Test
    func systemModeAppearanceFlipPostsNotificationExactlyOnce() {
        let harness = Harness()
        let observer = SystemAppearanceObserver(environment: harness.environment)

        observer.startObserving()
        #expect(harness.startObservationCallCount == 1)
        #expect(harness.events == ["effectivePrefersDark(false)"])

        harness.prefersDark = true
        harness.fireEffectiveAppearanceChanged()

        #expect(harness.events == [
            "effectivePrefersDark(false)",
            "effectivePrefersDark(true)",
            "synchronizeTerminalTheme",
            "postSystemAppearanceDidChange",
        ])
        #expect(harness.events.filter { $0 == "postSystemAppearanceDidChange" }.count == 1)
    }

    // (b) Explicit (non-system) mode: a KVO fire produces no notification and
    // does not even read effectivePrefersDark — the guard short-circuits
    // before the read.
    @Test
    func explicitModeIgnoresEffectiveAppearanceChangesWithoutReadingEffectivePrefersDark() {
        let harness = Harness()
        harness.modeRawValue = AppearanceMode.dark.rawValue
        let observer = SystemAppearanceObserver(environment: harness.environment)

        observer.startObserving()
        let eventsAfterStart = harness.events

        harness.fireEffectiveAppearanceChanged()

        #expect(harness.events == eventsAfterStart)
    }

    @Test
    func explicitModeFireInvalidatesCachedBaselineBeforeReturningToSystem() {
        let harness = Harness()
        harness.prefersDark = true
        let observer = SystemAppearanceObserver(environment: harness.environment)

        observer.startObserving()
        #expect(harness.events == ["effectivePrefersDark(true)"])

        harness.modeRawValue = AppearanceMode.light.rawValue
        harness.prefersDark = false
        harness.fireEffectiveAppearanceChanged()

        #expect(harness.events == ["effectivePrefersDark(true)"])

        harness.modeRawValue = AppearanceMode.system.rawValue
        harness.prefersDark = true
        harness.fireEffectiveAppearanceChanged()

        #expect(harness.events == [
            "effectivePrefersDark(true)",
            "effectivePrefersDark(true)",
            "synchronizeTerminalTheme",
            "postSystemAppearanceDidChange",
        ])
    }

    // (c) An unchanged value is coalesced (no duplicate post) — including
    // immediately after a real prior transition.
    @Test
    func unchangedResolvedAppearanceIsCoalesced() {
        let harness = Harness()
        let observer = SystemAppearanceObserver(environment: harness.environment)

        observer.startObserving()
        harness.fireEffectiveAppearanceChanged()
        harness.fireEffectiveAppearanceChanged()

        #expect(harness.events.filter { $0 == "postSystemAppearanceDidChange" }.count == 0)

        harness.prefersDark = true
        harness.fireEffectiveAppearanceChanged()

        #expect(harness.events.filter { $0 == "postSystemAppearanceDidChange" }.count == 1)
        #expect(harness.events.filter { $0 == "synchronizeTerminalTheme" }.count == 1)

        // Pins that lastResolvedPrefersDark is updated on every apply, not just
        // seeded at startObserving() — fire the same (now-current) value again
        // immediately after a real transition and confirm it's a no-op.
        harness.fireEffectiveAppearanceChanged()

        #expect(harness.events.filter { $0 == "postSystemAppearanceDidChange" }.count == 1)
    }

    // (f) Re-entrant fire during postSystemAppearanceDidChange() does not loop.
    @Test
    func reentrantFireDuringPostDoesNotLoop() {
        let harness = Harness()
        let observer = SystemAppearanceObserver(environment: harness.environment)

        // Simulate a notification observer re-triggering the KVO handler
        // synchronously from within the post; bound the re-entrancy so a
        // regression cannot hang the suite.
        var reentrantFireCount = 0
        harness.onPostSystemAppearanceDidChange = { [unowned harness] in
            guard reentrantFireCount < 1 else { return }
            reentrantFireCount += 1
            harness.fireEffectiveAppearanceChanged()
        }

        observer.startObserving()
        harness.prefersDark = true
        harness.fireEffectiveAppearanceChanged()

        #expect(harness.events == [
            "effectivePrefersDark(false)",
            "effectivePrefersDark(true)",
            "synchronizeTerminalTheme",
            "postSystemAppearanceDidChange",
            "effectivePrefersDark(true)",
        ])
        #expect(reentrantFireCount == 1)
        #expect(harness.events.filter { $0 == "postSystemAppearanceDidChange" }.count == 1)
    }

    // (d) Firing after stopObserving() produces nothing.
    @Test
    func fireAfterStopObservingProducesNoEvents() {
        let harness = Harness()
        let observer = SystemAppearanceObserver(environment: harness.environment)

        observer.startObserving()
        observer.stopObserving()
        let eventsAfterStop = harness.events

        harness.prefersDark = true
        harness.fireEffectiveAppearanceChanged()

        #expect(harness.events == eventsAfterStop)
    }

    @Test
    func startObservingIsIdempotentAndStopTearsDown() {
        let harness = Harness()
        let observer = SystemAppearanceObserver(environment: harness.environment)

        observer.startObserving()
        observer.startObserving()

        #expect(harness.startObservationCallCount == 1)

        observer.stopObserving()

        #expect(harness.observation.invalidateCallCount == 1)

        observer.startObserving()

        #expect(harness.startObservationCallCount == 2)
    }

    @Test
    func startObservingWithNilObservationIsNotIdempotent() {
        let harness = Harness()
        harness.startObservationReturnsNil = true
        let observer = SystemAppearanceObserver(environment: harness.environment)

        observer.startObserving()
        observer.startObserving()

        // Documents current behavior: an observation-less start does not latch, so repeated startObserving() calls re-invoke the start closure.
        #expect(harness.startObservationCallCount == 2)
    }
}
