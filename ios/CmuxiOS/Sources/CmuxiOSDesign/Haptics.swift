public import CmuxiOSFeatureKit
import UIKit

/// The only place cmux creates feedback generators (lane E5). Every call
/// site plays through `play(_:)`, which checks `HapticsPreference` first, so
/// the Settings toggle reaches feed, onboarding, toasts, pairing, terminal
/// selection and Home alike.
@MainActor
public struct Haptics {
    private let preference: HapticsPreference

    public init(preference: HapticsPreference = HapticsPreference()) {
        self.preference = preference
    }

    public func play(_ kind: HapticKind) {
        preference.perform {
            switch kind {
            case .selection: UISelectionFeedbackGenerator().selectionChanged()
            case .lightImpact: UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .warning: UINotificationFeedbackGenerator().notificationOccurred(.warning)
            case .error: UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}
