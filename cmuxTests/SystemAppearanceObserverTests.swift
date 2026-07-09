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
        // Only the explicit-mode short-circuit is covered here since it doesn't
        // touch NSApp. The "system" branch is covered by the
        // SystemAppearanceObserver tests via the injected `effectivePrefersDark`
        // closure, plus manual QA.
        #expect(AppearanceSettings.effectiveColorScheme(for: AppearanceMode.light.rawValue, fallback: .dark) == .light)
        #expect(AppearanceSettings.effectiveColorScheme(for: AppearanceMode.dark.rawValue, fallback: .light) == .dark)
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
