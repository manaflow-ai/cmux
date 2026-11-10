import Foundation

/// Every user-facing Delete Account string. Keys live in
/// Resources/Localizable.xcstrings (every language
/// `scripts/cmux-next/check-l10n.sh` lists). One entry per line.
// lint:allow namespace: the module's string table; each member is a catalog lookup with no owning type.
enum AccountText {
    static var deleteButton: String { String(localized: "account.delete.button", defaultValue: "Delete Account", bundle: .module) }
    static var deleteHint: String { String(localized: "account.delete.hint", defaultValue: "Asks before deleting anything.", bundle: .module) }
    static var footer: String { String(localized: "account.delete.footer", defaultValue: "Permanently deletes your cmux account and its data.", bundle: .module) }
    static var confirmTitle: String { String(localized: "account.delete.confirm.title", defaultValue: "Delete your cmux account?", bundle: .module) }
    static var confirmMessage: String { String(localized: "account.delete.confirm.message", defaultValue: "Your account, Cloud machines, saved secrets and subscription are deleted, and you're signed out everywhere. This can't be undone.", bundle: .module) }
    static var cancel: String { String(localized: "account.delete.cancel", defaultValue: "Cancel", bundle: .module) }
    static var deleting: String { String(localized: "account.delete.progress", defaultValue: "Deleting Account…", bundle: .module) }
    static var retry: String { String(localized: "account.delete.retry", defaultValue: "Try Again", bundle: .module) }
    static var failedOffline: String { String(localized: "account.delete.failed.offline", defaultValue: "You're offline. Connect and try again.", bundle: .module) }
    static var failedUnconfirmed: String { String(localized: "account.delete.failed.unconfirmed", defaultValue: "Couldn't confirm the deletion. Try again.", bundle: .module) }
    static var failedSessionExpired: String { String(localized: "account.delete.failed.sessionExpired", defaultValue: "Your session ended. Sign in again, then delete.", bundle: .module) }
    static var failedRefused: String { String(localized: "account.delete.failed.refused", defaultValue: "Your account wasn't deleted. Try again.", bundle: .module) }
}
