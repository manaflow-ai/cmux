#if os(iOS)
import Foundation

/// The terminal text size setting. Settings (CNSettingsUI `AppPreferences.terminalFontSize`)
/// writes the same key and range; pinch writes it too.
enum TerminalFontSize {
    static let key = "cmuxNext.terminalFontSize"
    static let defaultSize: Double = 13
    static let range: ClosedRange<Double> = 9...24

    static var stored: Double {
        let value = UserDefaults.standard.double(forKey: key)
        return value > 0 ? clamp(value) : defaultSize
    }

    static func store(_ size: Double) {
        UserDefaults.standard.set(clamp(size), forKey: key)
    }

    /// Clamped to the range and rounded to half points.
    static func clamp(_ size: Double) -> Double {
        (min(max(size, range.lowerBound), range.upperBound) * 2).rounded() / 2
    }
}
#endif
