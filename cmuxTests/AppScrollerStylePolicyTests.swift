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
    /// In-memory `UserDefaults` that models two layers of the search list: the
    /// app's own persistent domain (what `persistentDomain(forName:)` returns
    /// and what `set(_:forKey:)` writes) and a simulated `NSGlobalDomain` value
    /// that is only visible through cross-domain `string(forKey:)` resolution.
    ///
    /// The split lets the tests prove the policy decides from the *app domain
    /// specifically*: a global `WhenScrolling` must not suppress the app-domain
    /// write. `setCount` guards the no-redundant-write contract — a same-value
    /// write to `AppleShowScrollBars` posts `UserDefaults.didChangeNotification`
    /// and can prompt AppKit to re-evaluate the scroller style mid-fade.
    private final class RecordingDefaults: UserDefaults {
        private var appDomain: [String: Any] = [:]
        private var globalValue: String?
        var setCount = 0

        // `init()` returns an instance backed by the standard search list, but
        // every primitive accessor below is overridden to use the in-memory
        // layers, so the real on-disk domains are never touched.
        convenience init(appDomain: [String: Any] = [:], global: String? = nil) {
            self.init()
            self.appDomain = appDomain
            self.globalValue = global
        }

        override func persistentDomain(forName domainName: String) -> [String: Any]? { appDomain }

        override func object(forKey defaultName: String) -> Any? {
            if let value = appDomain[defaultName] { return value }
            return defaultName == AppScrollerStylePolicy.scrollBarsDefaultsKey ? globalValue : nil
        }

        override func string(forKey defaultName: String) -> String? {
            object(forKey: defaultName) as? String
        }

        override func set(_ value: Any?, forKey defaultName: String) {
            setCount += 1
            appDomain[defaultName] = value
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
        // System-wide "Show scroll bars: Always" (legacy), app domain empty —
        // the #3241 reproduction environment.
        let defaults = RecordingDefaults(global: "Always")

        AppScrollerStylePolicy.applyAtLaunch(defaults: defaults)

        #expect(defaults.string(forKey: AppScrollerStylePolicy.scrollBarsDefaultsKey)
            == AppScrollerStylePolicy.overlayValue)
        #expect(defaults.setCount == 1)
    }

    @Test func applyOverridesAutomaticPreference() {
        // The "Automatic" setting with a mouse connected — the other #3241
        // reproduction path. AppKit draws legacy scrollers whenever the
        // input-device heuristic fires; forcing WhenScrolling removes that.
        let defaults = RecordingDefaults(global: "Automatic")

        AppScrollerStylePolicy.applyAtLaunch(defaults: defaults)

        #expect(defaults.string(forKey: AppScrollerStylePolicy.scrollBarsDefaultsKey)
            == AppScrollerStylePolicy.overlayValue)
        #expect(defaults.setCount == 1)
    }

    @Test func persistsOverrideEvenWhenGlobalAlreadyResolvesWhenScrolling() {
        // Regression guard: the global preference already resolves WhenScrolling,
        // but the app domain is empty. A cross-domain check would skip the write
        // and leave cmux with no app-domain override — so a later switch to
        // "Always" would revert cmux to legacy scrollers mid-session. The policy
        // must still persist the override to the app domain.
        let defaults = RecordingDefaults(global: AppScrollerStylePolicy.overlayValue)

        AppScrollerStylePolicy.applyAtLaunch(defaults: defaults)

        #expect(defaults.persistentDomain(forName: "any")?[AppScrollerStylePolicy.scrollBarsDefaultsKey] as? String
            == AppScrollerStylePolicy.overlayValue)
        #expect(defaults.setCount == 1)
    }

    @Test func reapplyWritesNothing() {
        // Launch runs this once per process; a re-run (or any later launch with
        // the app-domain override already in place) must not re-write the key.
        let defaults = RecordingDefaults()
        AppScrollerStylePolicy.applyAtLaunch(defaults: defaults)

        defaults.setCount = 0
        AppScrollerStylePolicy.applyAtLaunch(defaults: defaults)

        #expect(defaults.setCount == 0)
    }
}
