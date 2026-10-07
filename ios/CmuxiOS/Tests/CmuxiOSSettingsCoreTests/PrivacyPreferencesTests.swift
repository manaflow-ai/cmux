import CmuxiOSSettingsCore
import Testing

@MainActor
@Suite struct PrivacyPreferencesTests {
    @Test func missingValueMeansOnAndChangesPersistToTheSharedKey() {
        let suite = TestDefaults()
        let key = "sendAnonymousTelemetry"
        let privacy = PrivacyPreferences(defaults: suite.defaults, consentKey: key)
        #expect(privacy.shareCrashReports)
        privacy.shareCrashReports = false
        #expect(suite.defaults.object(forKey: key) as? Bool == false)
        #expect(!PrivacyPreferences(defaults: suite.defaults, consentKey: key).shareCrashReports)
    }

    @Test func existingOptOutCarriesOver() {
        let suite = TestDefaults()
        suite.defaults.set(false, forKey: "consent")
        #expect(!PrivacyPreferences(defaults: suite.defaults, consentKey: "consent").shareCrashReports)
    }
}
