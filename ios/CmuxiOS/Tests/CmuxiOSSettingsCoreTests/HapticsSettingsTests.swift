import CmuxiOSFeatureKit
import CmuxiOSSettingsCore
import Foundation
import Testing

@MainActor
struct HapticsSettingsTests {
    @Test func toggleWritesThroughTheOneOwner() {
        let name = "haptics-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = HapticsSettings(preference: HapticsPreference(defaults: defaults))
        #expect(settings.isEnabled)
        settings.isEnabled = false
        #expect(!HapticsPreference(defaults: defaults).isEnabled)
        #expect(!HapticsSettings(preference: HapticsPreference(defaults: defaults)).isEnabled)
    }
}
