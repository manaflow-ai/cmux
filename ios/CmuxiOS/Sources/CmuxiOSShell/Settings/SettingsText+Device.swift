import Foundation

/// Haptics, Erase All Data and the signed-out account rows (lane E5).
extension SettingsText {
    static var haptics: String { String(localized: "shell.settings.haptics", defaultValue: "Haptics", bundle: .module) }
    static var hapticsFooter: String {
        String(localized: "shell.settings.hapticsFooter", defaultValue: "Vibration feedback for approvals, toasts, pairing and text selection.", bundle: .module)
    }
    static var eraseAllData: String { String(localized: "shell.settings.erase", defaultValue: "Erase All Data", bundle: .module) }
    static var eraseFooter: String {
        String(localized: "shell.settings.erase.footer", defaultValue: "Removes everything cmux keeps on this iPhone. Your account and your Macs are not affected.", bundle: .module)
    }
    static var eraseIntro: String {
        String(localized: "shell.settings.erase.intro", defaultValue: "cmux signs out and deletes everything it stores on this iPhone:", bundle: .module)
    }
    static var eraseListAccount: String {
        String(localized: "shell.settings.erase.list.account", defaultValue: "Sign-in, device identity and pairing keys", bundle: .module)
    }
    static var eraseListSSH: String {
        String(localized: "shell.settings.erase.list.ssh", defaultValue: "SSH hosts, keys, passwords and trusted host keys", bundle: .module)
    }
    static var eraseListContent: String {
        String(localized: "shell.settings.erase.list.content", defaultValue: "Drafts, downloads, transfers, caches and logs", bundle: .module)
    }
    static var eraseListPreferences: String {
        String(localized: "shell.settings.erase.list.preferences", defaultValue: "Settings and onboarding progress", bundle: .module)
    }
    static var eraseWarning: String {
        String(localized: "shell.settings.erase.warning", defaultValue: "SSH keys made on this iPhone cannot be recovered. Remove them from your servers' authorized_keys if you no longer need them.", bundle: .module)
    }
    /// The word the user types; translated per language.
    static var eraseWord: String { String(localized: "shell.settings.erase.word", defaultValue: "Erase", bundle: .module) }
    static func eraseTypePrompt(_ word: String) -> String {
        String(format: String(localized: "shell.settings.erase.prompt", defaultValue: "Type “%@” to confirm", bundle: .module), word)
    }
    static var erasing: String { String(localized: "shell.settings.erase.running", defaultValue: "Erasing…", bundle: .module) }
    static var cancelErase: String { String(localized: "shell.settings.erase.cancel", defaultValue: "Cancel", bundle: .module) }
    static var notSignedIn: String { String(localized: "shell.settings.guest.title", defaultValue: "Not Signed In", bundle: .module) }
    static var guestFooter: String {
        String(localized: "shell.settings.guest.footer", defaultValue: "SSH hosts work without an account. Sign in to connect your Macs, see the feed and dispatch tasks.", bundle: .module)
    }
    static var signIn: String { String(localized: "shell.settings.guest.signIn", defaultValue: "Sign In", bundle: .module) }
}
