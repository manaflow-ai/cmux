import Foundation

/// Strings for the conversation screen and the composer.
extension HomeText {
    static var composerPlaceholder: String { String(localized: "home.composer.placeholder", defaultValue: "Message", bundle: .module) }
    static var composerA11y: String { String(localized: "home.composer.a11y", defaultValue: "Message", bundle: .module) }
    static var composerOffline: String { String(localized: "home.composer.offline", defaultValue: "Offline. Your draft stays here.", bundle: .module) }
    static var composerNeedsRecipient: String { String(localized: "home.composer.needsRecipient", defaultValue: "Add someone in To: first", bundle: .module) }
    static var composerCheckRecipients: String { String(localized: "home.composer.checkRecipients", defaultValue: "Check the To: field", bundle: .module) }
    static var sendButton: String { String(localized: "home.composer.send", defaultValue: "Send", bundle: .module) }
    static var notDeliveredMenuTitle: String { String(localized: "home.message.notDeliveredMenu", defaultValue: "This message wasn't delivered.", bundle: .module) }
    static var retry: String { String(localized: "home.message.retry", defaultValue: "Try Again", bundle: .module) }
    static var discard: String { String(localized: "home.message.discard", defaultValue: "Delete Message", bundle: .module) }
    static var transcriptA11y: String { String(localized: "home.transcript.a11y", defaultValue: "Messages", bundle: .module) }
    static var copy: String { String(localized: "home.message.copy", defaultValue: "Copy", bundle: .module) }

    /// VoiceOver announcement for a new incoming message.
    static func announcement(author: String, text: String) -> String {
        String(localized: "home.announcement.message", defaultValue: "\(author) says: \(text)", bundle: .module)
    }
}
