public import Foundation

/// The one owner of the app-wide haptics setting (lane E5): Settings writes
/// it and every haptic checks it before playing. Same key as the shipping
/// app, so an existing choice carries over; a missing value means on and is
/// never written until the user changes it.
public struct HapticsPreference {
    public static let key = "cmux.mobile.hapticFeedbackEnabled"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isEnabled: Bool {
        defaults.object(forKey: Self.key) as? Bool ?? true
    }

    public func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.key)
    }

    /// Runs `play` only while haptics are on.
    public func perform(_ play: () -> Void) {
        guard isEnabled else { return }
        play()
    }
}
