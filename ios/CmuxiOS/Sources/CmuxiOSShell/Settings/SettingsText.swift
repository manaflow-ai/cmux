import Foundation

/// Localized strings of the Settings and Developer screens.
enum SettingsText {
    static var account: String { String(localized: "shell.settings.account", defaultValue: "Account", bundle: .module) }
    static var name: String { String(localized: "shell.settings.name", defaultValue: "Name", bundle: .module) }
    static var email: String { String(localized: "shell.settings.email", defaultValue: "Email", bundle: .module) }
    static var devices: String { String(localized: "shell.settings.devices", defaultValue: "Devices", bundle: .module) }
    static var devicesOffline: String {
        String(localized: "shell.settings.devicesOffline", defaultValue: "Device list is offline; changes are paused.", bundle: .module)
    }
    static var thisDevice: String { String(localized: "shell.settings.thisDevice", defaultValue: "This device", bundle: .module) }
    static var trusted: String { String(localized: "shell.settings.trusted", defaultValue: "Paired", bundle: .module) }
    static var notPaired: String { String(localized: "shell.settings.notPaired", defaultValue: "Not paired", bundle: .module) }
    static var revoked: String { String(localized: "shell.settings.revoked", defaultValue: "Removed", bundle: .module) }
    static var developer: String { String(localized: "shell.settings.developer", defaultValue: "Developer", bundle: .module) }
    static var about: String { String(localized: "shell.settings.about", defaultValue: "About", bundle: .module) }
    static var version: String { String(localized: "shell.settings.version", defaultValue: "Version", bundle: .module) }
    static var signOut: String { String(localized: "shell.settings.signOut", defaultValue: "Sign Out", bundle: .module) }
    static var signOutConfirm: String {
        String(localized: "shell.settings.signOutConfirm", defaultValue: "Sign out of cmux on this device?", bundle: .module)
    }
    static var sources: String { String(localized: "shell.dev.sources", defaultValue: "Feature Sources", bundle: .module) }
    static var sourcesFooter: String {
        String(localized: "shell.dev.sourcesFooter", defaultValue: "Real uses the lane's implementation once registered; until then the mock serves.", bundle: .module)
    }
    static var flags: String { String(localized: "shell.dev.flags", defaultValue: "Feature Flags", bundle: .module) }
    static var flagsFooter: String {
        String(localized: "shell.dev.flagsFooter", defaultValue: "Launch environment values win and lock the toggle.", bundle: .module)
    }
    static var mockOwner: String { String(localized: "shell.dev.mockOwner", defaultValue: "Mock Owners", bundle: .module) }
    static var mockOffline: String { String(localized: "shell.dev.mockOffline", defaultValue: "Simulate Offline", bundle: .module) }
    static var mock: String { String(localized: "shell.dev.mock", defaultValue: "Mock", bundle: .module) }
    static var real: String { String(localized: "shell.dev.real", defaultValue: "Real", bundle: .module) }
    static var notRegistered: String {
        String(localized: "shell.dev.notRegistered", defaultValue: "Not registered, serving mock", bundle: .module)
    }
}
