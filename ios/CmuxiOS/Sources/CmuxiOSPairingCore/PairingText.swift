import Foundation

/// Localized strings of the pairing core (en, ja in Resources/Localizable.xcstrings).
struct PairingText {
    static var thisDevice: String { String(localized: "pairing.device.this", defaultValue: "This iPhone", bundle: .module) }
    static func guestName(device: String, user: String) -> String {
        String(format: String(localized: "pairing.device.guest", defaultValue: "%1$@ (%2$@)", bundle: .module), device, user)
    }
    static var offerUnknown: String { String(localized: "pairing.error.offer_unknown", defaultValue: "This pairing code expired. Show a new code on your Mac.", bundle: .module) }
    static var offerUsed: String { String(localized: "pairing.error.offer_used", defaultValue: "This pairing code was already used. Show a new code on your Mac.", bundle: .module) }
    static var keyMismatch: String { String(localized: "pairing.error.key_mismatch", defaultValue: "This code does not match the Mac's key. Scan the code shown in cmux on that Mac.", bundle: .module) }
    static var declined: String { String(localized: "pairing.error.declined", defaultValue: "The Mac's owner declined this iPhone.", bundle: .module) }
    static var updateRequired: String { String(localized: "pairing.error.update_required", defaultValue: "This pairing code needs a newer version of cmux. Update the app and scan again.", bundle: .module) }
    static var notPairingLink: String { String(localized: "pairing.error.not_link", defaultValue: "This is not a cmux pairing code.", bundle: .module) }
    static var invalidLink: String { String(localized: "pairing.error.invalid_link", defaultValue: "This pairing code is damaged. Show a new code on your Mac.", bundle: .module) }
    static var unknownDevice: String { String(localized: "pairing.error.unknown_device", defaultValue: "That device is no longer on your account.", bundle: .module) }
    static var cannotRename: String { String(localized: "pairing.error.cannot_rename", defaultValue: "Only your own devices can be renamed.", bundle: .module) }
    static var pending: String { String(localized: "pairing.status.pending", defaultValue: "Waiting for the Mac's owner to accept this iPhone.", bundle: .module) }
    static var offline: String { String(localized: "pairing.error.offline", defaultValue: "You're offline. Connect to the internet and try again.", bundle: .module) }
    static func paired(_ name: String) -> String {
        String(format: String(localized: "pairing.status.paired", defaultValue: "Paired with %@.", bundle: .module), name)
    }
    static func refused(_ message: String) -> String {
        String(format: String(localized: "pairing.error.refused", defaultValue: "Pairing failed: %@", bundle: .module), message)
    }

    /// A user-facing reason for an owner refusal code.
    static func reason(code: String, message: String) -> String {
        switch code {
        case "pairing.offer_unknown": offerUnknown
        case "pairing.offer_used": offerUsed
        case "pairing.key_mismatch": keyMismatch
        case "pairing.declined": declined
        default: refused(message)
        }
    }
}
