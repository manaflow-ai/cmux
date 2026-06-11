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
    /// policy must write the override only when it actually needs to — this
    /// counter guards that contract. The decision input (the app-domain value)
    /// is injected separately, so this fake only models the write side.
    private final class RecordingDefaults: UserDefaults {
        private var store: [String: Any] = [:]
        var setCount = 0

        override func object(forKey defaultName: String) -> Any? { store[defaultName] }

        override func string(forKey defaultName: String) -> String? {
            store[defaultName] as? String
        }

        override func set(_ value: Any?, forKey defaultName: String) {
            setCount += 1
            store[defaultName] = value
        }
    }

    private let key = AppScrollerStylePolicy.scrollBarsDefaultsKey
    private let overlay = AppScrollerStylePolicy.overlayValue

    @Test func forcesOverlayWhenAppDomainUnset() {
        // The app domain has no value of its own — true for a fresh install
        // regardless of the system-wide setting (Always, Automatic with a mouse,
        // or even a global WhenScrolling). Because the decision reads cmux's app
        // domain *only*, the override is written deterministically in every one
        // of those #3241 environments.
        let defaults = RecordingDefaults()

        AppScrollerStylePolicy.applyAtLaunch(
            defaults: defaults,
            bundleIdentifier: "com.cmux.test",
            appDomainValue: { _, _ in nil }
        )

        #expect(defaults.string(forKey: key) == overlay)
        #expect(defaults.setCount == 1)
    }

    @Test func passesScrollBarsKeyAndBundleToAppDomainLookup() {
        // The decision must query the AppleShowScrollBars key in cmux's own
        // bundle domain, not some other key/domain.
        let defaults = RecordingDefaults()
        var queried: (key: String, bundle: String)?

        AppScrollerStylePolicy.applyAtLaunch(
            defaults: defaults,
            bundleIdentifier: "com.cmux.test",
            appDomainValue: { k, b in queried = (k, b); return nil }
        )

        #expect(queried?.key == key)
        #expect(queried?.bundle == "com.cmux.test")
    }

    @Test func honorsExplicitPerAppOptOut() {
        // A user who deliberately sets a per-app value in cmux's own domain
        // (`defaults write <cmux-bundle-id> AppleShowScrollBars Always`) keeps
        // it — the override only writes when the app domain has no value.
        let defaults = RecordingDefaults()

        AppScrollerStylePolicy.applyAtLaunch(
            defaults: defaults,
            bundleIdentifier: "com.cmux.test",
            appDomainValue: { _, _ in "Always" }
        )

        #expect(defaults.setCount == 0)
    }

    @Test func reapplyIsNoOpWhenOverrideAlreadyPresent() {
        // A later launch (or re-run) where cmux's app domain already holds the
        // override must not re-write the key.
        let defaults = RecordingDefaults()

        AppScrollerStylePolicy.applyAtLaunch(
            defaults: defaults,
            bundleIdentifier: "com.cmux.test",
            appDomainValue: { _, _ in overlay }
        )

        #expect(defaults.setCount == 0)
    }
}
