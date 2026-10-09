public import CmuxiOSFeatureKit
public import Observation

/// Settings > Preferences > Haptics over the one `HapticsPreference` owner.
@MainActor
@Observable
public final class HapticsSettings {
    public var isEnabled: Bool {
        didSet { if isEnabled != oldValue { preference.setEnabled(isEnabled) } }
    }
    @ObservationIgnored private let preference: HapticsPreference

    public init(preference: HapticsPreference = HapticsPreference()) {
        self.preference = preference
        isEnabled = preference.isEnabled
    }
}
