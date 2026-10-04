import Foundation

/// Every user-facing Home string. Keys live in
/// Resources/Localizable.xcstrings (English, Japanese and every language
/// `scripts/cmux-next/check-l10n.sh` lists). One entry per line, so the
/// catalog generator can read key and English value from source.
// lint:allow namespace: the module's string table; each member is a catalog lookup with no owning type.
enum HomeText {
    // MARK: Home list

    static var homeTitle: String { String(localized: "home.title", defaultValue: "Home", bundle: .module) }
    static var composeButton: String { String(localized: "home.compose.button", defaultValue: "Compose", bundle: .module) }
    static var searchCommand: String { String(localized: "home.command.search", defaultValue: "Search Messages", bundle: .module) }
    static var backCommand: String { String(localized: "home.command.back", defaultValue: "Back", bundle: .module) }
    static var newMessage: String { String(localized: "home.compose.newMessage", defaultValue: "New Message", bundle: .module) }
    static var newGroup: String { String(localized: "home.compose.newGroup", defaultValue: "New Group", bundle: .module) }
    static var newChief: String { String(localized: "home.compose.newChief", defaultValue: "New Chief", bundle: .module) }
    static var inviteButton: String { String(localized: "home.invite.button", defaultValue: "Invite", bundle: .module) }
    static var inviteHint: String { String(localized: "home.invite.hint", defaultValue: "Invites someone to cmux by email or text message.", bundle: .module) }
    static var untitledConversation: String { String(localized: "home.row.untitled", defaultValue: "Conversation", bundle: .module) }
    static var noMessages: String { String(localized: "home.row.noMessages", defaultValue: "No messages yet", bundle: .module) }
    static var invitedNoMessages: String { String(localized: "home.row.invitedNoMessages", defaultValue: "Invited. Waiting for them to join.", bundle: .module) }
    static var sending: String { String(localized: "home.status.sending", defaultValue: "Sending…", bundle: .module) }
    static var notDelivered: String { String(localized: "home.status.notDelivered", defaultValue: "Not Delivered", bundle: .module) }
    static var typingShort: String { String(localized: "home.status.typing", defaultValue: "typing…", bundle: .module) }
    static var a11yPinned: String { String(localized: "home.a11y.pinned", defaultValue: "Pinned", bundle: .module) }
    static var a11yMuted: String { String(localized: "home.a11y.muted", defaultValue: "Muted", bundle: .module) }
    static var you: String { String(localized: "home.you", defaultValue: "You", bundle: .module) }

    static func unreadCount(_ count: Int) -> String {
        String(localized: "home.a11y.unread", defaultValue: "\(count) unread", bundle: .module)
    }

    static func preview(author: String, text: String) -> String {
        String(localized: "home.row.previewAuthor", defaultValue: "\(author): \(text)", bundle: .module)
    }

    static func previewFromMe(_ text: String) -> String {
        String(localized: "home.row.previewMine", defaultValue: "You: \(text)", bundle: .module)
    }

    // MARK: Row actions

    static var actionPin: String { String(localized: "home.action.pin", defaultValue: "Pin", bundle: .module) }
    static var actionUnpin: String { String(localized: "home.action.unpin", defaultValue: "Unpin", bundle: .module) }
    static var actionMute: String { String(localized: "home.action.mute", defaultValue: "Mute", bundle: .module) }
    static var actionUnmute: String { String(localized: "home.action.unmute", defaultValue: "Unmute", bundle: .module) }
    static var actionMarkRead: String { String(localized: "home.action.markRead", defaultValue: "Mark as Read", bundle: .module) }
    static var tapbackFailedTitle: String { String(localized: "home.tapback.failedTitle", defaultValue: "Couldn't Add the Reaction", bundle: .module) }
    static var actionFailedTitle: String { String(localized: "home.action.failedTitle", defaultValue: "Couldn't Update the Conversation", bundle: .module) }
    static var ok: String { String(localized: "home.ok", defaultValue: "OK", bundle: .module) }

    // MARK: Offline and refusals

    static var offlineTitle: String { String(localized: "home.offline.title", defaultValue: "Offline", bundle: .module) }
    static var offlineBody: String { String(localized: "home.offline.body", defaultValue: "You can read saved messages. Sending, invites and new Chiefs come back when cmux reconnects.", bundle: .module) }
    static var updateRequiredTitle: String { String(localized: "home.updateRequired.title", defaultValue: "Update Required", bundle: .module) }
    static var updateRequiredBodyNoVersion: String { String(localized: "home.updateRequired.bodyNoVersion", defaultValue: "Your team requires a newer version of cmux. Update cmux to keep notifications and replies working.", bundle: .module) }
    static var rejectionNotAuthorized: String { String(localized: "home.rejection.notAuthorized", defaultValue: "You don't have permission to do that here.", bundle: .module) }
    static var rejectionInvalid: String { String(localized: "home.rejection.invalid", defaultValue: "cmux couldn't accept that. Check it and try again.", bundle: .module) }
    static var rejectionRateLimited: String { String(localized: "home.rejection.rateLimited", defaultValue: "Too many requests. Try again in a moment.", bundle: .module) }
    static var rejectionIndeterminate: String { String(localized: "home.rejection.indeterminate", defaultValue: "The connection dropped. cmux will check again when it reconnects.", bundle: .module) }

    // MARK: Search

    static var searchPlaceholder: String { String(localized: "home.search.placeholder", defaultValue: "Search Messages", bundle: .module) }
    static var searchOfflineTitle: String { String(localized: "home.search.offlineTitle", defaultValue: "Search Is Unavailable Offline", bundle: .module) }
    static var searchOfflineBody: String { String(localized: "home.search.offlineBody", defaultValue: "Search runs on cmux. Try again when you're back online.", bundle: .module) }

    /// The update-required banner body, naming the team's minimum when the owner sent it.
    static func updateRequiredBody(minimumVersion: String?) -> String {
        guard let minimumVersion, !minimumVersion.isEmpty else { return updateRequiredBodyNoVersion }
        return String(localized: "home.updateRequired.body", defaultValue: "Your team requires cmux \(minimumVersion) or newer. Update cmux to keep notifications and replies working.", bundle: .module)
    }

    static func searchNoResults(_ query: String) -> String {
        String(localized: "home.search.noResults", defaultValue: "No Results for “\(query)”", bundle: .module)
    }

    static func searchHitDetail(author: String, time: String) -> String {
        String(localized: "home.search.hitDetail", defaultValue: "\(author) · \(time)", bundle: .module)
    }

    static func searchHitA11y(author: String, text: String, time: String) -> String {
        String(localized: "home.search.hitA11y", defaultValue: "\(author), \(text), \(time)", bundle: .module)
    }
}
