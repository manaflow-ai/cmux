import Foundation

/// Localized strings of the scanner (en, ja in Resources/Localizable.xcstrings).
struct PairingScannerText {
    static var viewfinderLabel: String {
        String(localized: "pairing.scanner.viewfinder", defaultValue: "Camera viewfinder. Point it at the pairing code on your Mac.", bundle: .module)
    }
    static var unavailable: String {
        String(localized: "pairing.scanner.unavailable", defaultValue: "The camera is not available on this device.", bundle: .module)
    }
}
