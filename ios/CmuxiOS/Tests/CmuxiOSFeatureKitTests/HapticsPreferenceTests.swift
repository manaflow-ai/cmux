import CmuxiOSFeatureKit
import Foundation
import Testing

struct HapticsPreferenceTests {
    private func defaults() -> UserDefaults {
        let name = "haptics-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func missingMeansOnAndIsNotWritten() {
        let store = defaults()
        let preference = HapticsPreference(defaults: store)
        #expect(preference.isEnabled)
        var played = 0
        preference.perform { played += 1 }
        #expect(played == 1)
        #expect(store.object(forKey: HapticsPreference.key) == nil)
    }

    @Test func offStopsEveryPlay() {
        let store = defaults()
        HapticsPreference(defaults: store).setEnabled(false)
        let preference = HapticsPreference(defaults: store)
        var played = 0
        for _ in HapticKind.allCases { preference.perform { played += 1 } }
        #expect(!preference.isEnabled)
        #expect(played == 0)
    }

    @Test func usesTheShippingAppKey() {
        let store = defaults()
        store.set(false, forKey: "cmux.mobile.hapticFeedbackEnabled")
        #expect(!HapticsPreference(defaults: store).isEnabled)
    }
}
