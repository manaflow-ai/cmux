import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("App scroller style policy")
struct AppScrollerStylePolicyTests {
    /// In-memory `UserDefaults` that records writes. A same-value or redundant
    /// write to `AppleShowScrollBars` posts `UserDefaults.didChangeNotification`
    /// and can prompt AppKit to re-evaluate the scroller style mid-fade, so the
    /// policy must write the override only when it actually changes — this
    /// counter guards that no-redundant-write contract.
    private final class RecordingDefaults: UserDefaults {
        private var store: [String: Any] = [:]
        var setCount = 0

        // `init()` returns an instance backed by the standard search list, but
        // every primitive accessor below is overridden to use `store`, so the
        // real on-disk domains are never touched.
        convenience init(seed: [String: Any] = [:]) {
            self.init()
            store = seed
        }

        override func object(forKey defaultName: String) -> Any? { store[defaultName] }

        override func string(forKey defaultName: String) -> String? {
            store[defaultName] as? String
        }

        override func set(_ value: Any?, forKey defaultName: String) {
            setCount += 1
            store[defaultName] = value
        }
    }

    @Test func applyForcesOverlayWhenUnset() {
        let defaults = RecordingDefaults()

        AppScrollerStylePolicy.applyAtLaunch(defaults: defaults)

        #expect(defaults.string(forKey: AppScrollerStylePolicy.scrollBarsDefaultsKey)
            == AppScrollerStylePolicy.overlayValue)
        #expect(defaults.setCount == 1)
    }

    @Test func applyOverridesLegacyAlwaysPreference() {
        // Simulates a user with the system-wide "Show scroll bars: Always"
        // (legacy) preference — the #3241 reproduction environment.
        let defaults = RecordingDefaults(seed: [
            AppScrollerStylePolicy.scrollBarsDefaultsKey: "Always"
        ])

        AppScrollerStylePolicy.applyAtLaunch(defaults: defaults)

        #expect(defaults.string(forKey: AppScrollerStylePolicy.scrollBarsDefaultsKey)
            == AppScrollerStylePolicy.overlayValue)
        #expect(defaults.setCount == 1)
    }

    @Test func applyOverridesAutomaticPreference() {
        // Simulates the "Automatic" setting with a mouse connected — the other
        // #3241 reproduction path. AppKit draws legacy scrollers whenever the
        // input-device heuristic fires; forcing WhenScrolling removes that.
        let defaults = RecordingDefaults(seed: [
            AppScrollerStylePolicy.scrollBarsDefaultsKey: "Automatic"
        ])

        AppScrollerStylePolicy.applyAtLaunch(defaults: defaults)

        #expect(defaults.string(forKey: AppScrollerStylePolicy.scrollBarsDefaultsKey)
            == AppScrollerStylePolicy.overlayValue)
        #expect(defaults.setCount == 1)
    }

    @Test func reapplyWritesNothing() {
        // Launch runs this once per process; a re-run (or any later launch with
        // the override already resolved) must not re-write the key.
        let defaults = RecordingDefaults()
        AppScrollerStylePolicy.applyAtLaunch(defaults: defaults)

        defaults.setCount = 0
        AppScrollerStylePolicy.applyAtLaunch(defaults: defaults)

        #expect(defaults.setCount == 0)
    }
}
