import Foundation

/// The composer bar's strings (en, ja and the catalog's other languages).
enum TerminalComposeText {
    static var placeholder: String {
        String(localized: "compose.placeholder", defaultValue: "Message the terminal", bundle: .module)
    }
    static var fieldLabel: String { String(localized: "compose.field", defaultValue: "Composer", bundle: .module) }
    static var send: String { String(localized: "compose.send", defaultValue: "Send", bundle: .module) }
    static var insertWithoutSending: String {
        String(localized: "compose.insert", defaultValue: "Insert Without Sending", bundle: .module)
    }
    static var history: String { String(localized: "compose.history", defaultValue: "History", bundle: .module) }
    static var attach: String { String(localized: "compose.attach", defaultValue: "Attach", bundle: .module) }
    static var dictate: String { String(localized: "compose.dictate", defaultValue: "Dictate", bundle: .module) }
    static var stopDictation: String { String(localized: "compose.dictate.stop", defaultValue: "Stop Dictation", bundle: .module) }
    static var dictationDenied: String {
        String(localized: "compose.dictate.denied", defaultValue: "Allow Microphone and Speech Recognition in Settings to dictate.",
               bundle: .module)
    }
    static var dictationUnavailable: String {
        String(localized: "compose.dictate.unavailable", defaultValue: "Dictation is not available right now.", bundle: .module)
    }
    static var notConnected: String {
        String(localized: "compose.offline", defaultValue: "Not connected. Your message is kept as a draft.", bundle: .module)
    }
    static var ok: String { String(localized: "compose.ok", defaultValue: "OK", bundle: .module) }
    static var removeAttachment: String { String(localized: "compose.chip.remove", defaultValue: "Remove", bundle: .module) }

    static func uploading(_ name: String) -> String {
        String(format: String(localized: "compose.chip.uploading", defaultValue: "Uploading %@", bundle: .module), name)
    }

    static func failed(_ name: String) -> String {
        String(format: String(localized: "compose.chip.failed", defaultValue: "%@ failed", bundle: .module), name)
    }
}
