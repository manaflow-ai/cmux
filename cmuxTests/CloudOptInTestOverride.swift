import CmuxSettings
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Turns local Cloud activation on for a fixture's lifetime. Cloud creation
/// actions open the Cloud welcome instead of creating while Cloud is off
/// (#19876), and that answer reads the standard defaults, so fixtures that
/// drive the real actions must opt in and put the user's value back after.
@MainActor
struct CloudOptInTestOverride {
    private static let key = BetaFeaturesCatalogSection().cloudMachines.userDefaultsKey
    private let original: Any?

    init() {
        original = UserDefaults.standard.object(forKey: Self.key)
        UserDefaults.standard.set(true, forKey: Self.key)
    }

    func restore() {
        if let original {
            UserDefaults.standard.set(original, forKey: Self.key)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.key)
        }
    }
}
