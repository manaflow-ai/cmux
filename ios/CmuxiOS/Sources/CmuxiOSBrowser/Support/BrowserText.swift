import Foundation

/// Localized strings of the browser screens.
enum BrowserText {
    static var title: String { String(localized: "browser.title", defaultValue: "Browser", bundle: .module) }
    static var addressPlaceholder: String {
        String(localized: "browser.address.placeholder", defaultValue: "Enter a website address", bundle: .module)
    }
    static var back: String { String(localized: "browser.back", defaultValue: "Back", bundle: .module) }
    static var forward: String { String(localized: "browser.forward", defaultValue: "Forward", bundle: .module) }
    static var reload: String { String(localized: "browser.reload", defaultValue: "Reload", bundle: .module) }
    static var stop: String { String(localized: "browser.stop", defaultValue: "Stop", bundle: .module) }
    static var keyboard: String { String(localized: "browser.keyboard", defaultValue: "Keyboard", bundle: .module) }
    static var paste: String { String(localized: "browser.paste", defaultValue: "Paste on Mac", bundle: .module) }
    static var tabs: String { String(localized: "browser.tabs", defaultValue: "Tabs", bundle: .module) }
    static var tabsTitle: String { String(localized: "browser.tabs.title", defaultValue: "Browser Tabs", bundle: .module) }
    static var tabsEmpty: String {
        String(localized: "browser.tabs.empty", defaultValue: "No browser tabs on this Mac", bundle: .module)
    }
    static var done: String { String(localized: "browser.done", defaultValue: "Done", bundle: .module) }
    static var connecting: String { String(localized: "browser.state.connecting", defaultValue: "Connecting to the Mac…", bundle: .module) }
    static var paused: String { String(localized: "browser.state.paused", defaultValue: "Paused on the Mac", bundle: .module) }
    static var ended: String { String(localized: "browser.state.ended", defaultValue: "The stream ended", bundle: .module) }
    static var offline: String { String(localized: "browser.state.offline", defaultValue: "This Mac is not reachable", bundle: .module) }
    static var tabGone: String {
        String(localized: "browser.state.tabGone", defaultValue: "This tab is no longer open on the Mac", bundle: .module)
    }
    static var noVideo: String {
        String(localized: "browser.state.noVideo", defaultValue: "Sample data: no video", bundle: .module)
    }
    static var reconnect: String { String(localized: "browser.reconnect", defaultValue: "Reconnect", bundle: .module) }
    static var refusedTitle: String { String(localized: "browser.refused.title", defaultValue: "Can’t Open Page", bundle: .module) }
    static var refusedScheme: String {
        String(localized: "browser.refused.scheme", defaultValue: "Only http and https addresses can be opened.", bundle: .module)
    }
    static var refusedInvalid: String {
        String(localized: "browser.refused.invalid", defaultValue: "That is not a website address.", bundle: .module)
    }
    static var refusedFailed: String {
        String(localized: "browser.refused.failed", defaultValue: "The Mac could not open that page.", bundle: .module)
    }
    static var ok: String { String(localized: "browser.ok", defaultValue: "OK", bundle: .module) }
    static var page: String { String(localized: "browser.page", defaultValue: "Web page on the Mac", bundle: .module) }

    static func refusal(_ reason: String) -> String {
        switch reason {
        case "scheme": refusedScheme
        case "invalid", "empty": refusedInvalid
        default: refusedFailed
        }
    }
}
