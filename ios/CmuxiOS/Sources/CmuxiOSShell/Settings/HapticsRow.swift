import CmuxiOSSettingsCore
import SwiftUI

/// Settings > Preferences > Haptics (one owner: `HapticsPreference`).
struct HapticsRow: View {
    @Bindable var haptics: HapticsSettings

    var body: some View {
        Toggle(isOn: $haptics.isEnabled) {
            Label(SettingsText.haptics, systemImage: "hand.tap")
        }
        .accessibilityIdentifier("shell.settings.haptics")
    }
}
