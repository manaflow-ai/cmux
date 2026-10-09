import Foundation

/// The composer bar's strings (en, ja and the catalog's other languages).
/// Each view of the bar holds one.
struct TerminalComposeText {
    var placeholder: String {
        String(localized: "compose.placeholder", defaultValue: "Message the terminal", bundle: .module)
    }
    var fieldLabel: String { String(localized: "compose.field", defaultValue: "Composer", bundle: .module) }
    var send: String { String(localized: "compose.send", defaultValue: "Send", bundle: .module) }
    var insertWithoutSending: String {
        String(localized: "compose.insert", defaultValue: "Insert Without Sending", bundle: .module)
    }
    var history: String { String(localized: "compose.history", defaultValue: "History", bundle: .module) }
    var attach: String { String(localized: "compose.attach", defaultValue: "Attach", bundle: .module) }
    var dictate: String { String(localized: "compose.dictate", defaultValue: "Dictate", bundle: .module) }
    var stopDictation: String { String(localized: "compose.dictate.stop", defaultValue: "Stop Dictation", bundle: .module) }
    var dictationDenied: String {
        String(localized: "compose.dictate.denied", defaultValue: "Allow Microphone and Speech Recognition in Settings to dictate.",
               bundle: .module)
    }
    var dictationUnavailable: String {
        String(localized: "compose.dictate.unavailable", defaultValue: "Dictation is not available right now.", bundle: .module)
    }
    var notConnected: String {
        String(localized: "compose.offline", defaultValue: "Not connected. Your message is kept as a draft.", bundle: .module)
    }
    var ok: String { String(localized: "compose.ok", defaultValue: "OK", bundle: .module) }
    var removeAttachment: String { String(localized: "compose.chip.remove", defaultValue: "Remove", bundle: .module) }

    func uploading(_ name: String) -> String {
        String(format: String(localized: "compose.chip.uploading", defaultValue: "Uploading %@", bundle: .module), name)
    }

    func failed(_ name: String) -> String {
        String(format: String(localized: "compose.chip.failed", defaultValue: "%@ failed", bundle: .module), name)
    }
}
