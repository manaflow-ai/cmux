import CmuxiOSSettingsCore
import SwiftUI

/// Settings > Privacy: crash reports and diagnostics consent (moved here
/// from Diagnostics), and the privacy policy.
struct PrivacySettingsView: View {
    @Bindable var privacy: PrivacyPreferences

    var body: some View {
        Form {
            Section {
                Toggle(SettingsText.shareCrashReports, isOn: $privacy.shareCrashReports)
                    .accessibilityIdentifier("shell.settings.privacy.crashReports")
            } footer: {
                Text(SettingsText.shareCrashReportsFooter)
            }
            Section {
                Link(destination: SettingsLinks.privacyPolicy) {
                    Label(SettingsText.privacyPolicy, systemImage: "hand.raised")
                }
            }
        }
        .navigationTitle(SettingsText.privacy)
    }
}
