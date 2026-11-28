import Foundation

/// Every user-facing string of the prototype. Keys live in
/// Resources/Localizable.xcstrings (en, ja). The synthetic desktop's own
/// content (terminal output, file names, the mock host menu bar) is fixture
/// data drawn as pixels, so it is not localized.
enum L10n {
    // Session controls
    static var modeView: String { String(localized: "rd.mode.view", defaultValue: "View", bundle: .module) }
    static var modeControl: String { String(localized: "rd.mode.control", defaultValue: "Control", bundle: .module) }
    static func display(_ index: Int) -> String {
        String(localized: "rd.toolbar.display", defaultValue: "Display \(index)", bundle: .module)
    }
    static var qualityAuto: String { String(localized: "rd.toolbar.quality.auto", defaultValue: "Auto", bundle: .module) }
    static var stop: String { String(localized: "rd.toolbar.stop", defaultValue: "Stop", bundle: .module) }

    // Path badge
    static var pathDirect: String { String(localized: "rd.path.direct", defaultValue: "direct", bundle: .module) }
    static var pathRelayed: String { String(localized: "rd.path.relayed", defaultValue: "relayed", bundle: .module) }
    static func milliseconds(_ value: Int) -> String {
        String(localized: "rd.metric.ms", defaultValue: "\(value) ms", bundle: .module)
    }
    static func loss(_ percent: String) -> String {
        String(localized: "rd.strip.loss", defaultValue: "Loss \(percent)", bundle: .module)
    }
    static func glassToGlass(_ value: Int) -> String {
        String(localized: "rd.strip.g2g", defaultValue: "Glass to glass \(value) ms", bundle: .module)
    }
    static var statusConnecting: String { String(localized: "rd.status.connecting", defaultValue: "connecting", bundle: .module) }
    static var statusEnded: String { String(localized: "rd.status.ended", defaultValue: "ended", bundle: .module) }

    // Tab context menu (variant C)
    static var menuSwitchToView: String { String(localized: "rd.menu.switchToView", defaultValue: "Switch to View Only", bundle: .module) }
    static var menuDisplay: String { String(localized: "rd.menu.display", defaultValue: "Display", bundle: .module) }
    static var menuQuality: String { String(localized: "rd.menu.quality", defaultValue: "Quality", bundle: .module) }
    static var menuFillWindow: String { String(localized: "rd.menu.fillWindow", defaultValue: "Fill Window", bundle: .module) }
    static var menuReleaseKeyboard: String { String(localized: "rd.menu.releaseKeyboard", defaultValue: "Release Keyboard", bundle: .module) }
    static var menuCopyHost: String { String(localized: "rd.menu.copyHost", defaultValue: "Copy Host Name", bundle: .module) }
    static var menuStopSession: String { String(localized: "rd.menu.stopSession", defaultValue: "Stop Session", bundle: .module) }
    static var menuPaletteHint: String {
        String(localized: "rd.menu.paletteHint", defaultValue: "Every action is also in the command palette.", bundle: .module)
    }

    // Pane states
    static var cancel: String { String(localized: "rd.action.cancel", defaultValue: "Cancel", bundle: .module) }
    static var reconnect: String { String(localized: "rd.action.reconnect", defaultValue: "Reconnect", bundle: .module) }
    static var close: String { String(localized: "rd.action.close", defaultValue: "Close", bundle: .module) }
    static var controlAnyway: String { String(localized: "rd.action.controlAnyway", defaultValue: "Control Anyway", bundle: .module) }
    static func connectingTitle(_ host: String) -> String {
        String(localized: "rd.state.connecting.title", defaultValue: "Connecting to \(host)…", bundle: .module)
    }
    static var connectingDetail: String {
        String(localized: "rd.state.connecting.detail", defaultValue: "Finding the fastest path to this machine.", bundle: .module)
    }
    static var latencyTitle: String {
        String(localized: "rd.state.latency.title", defaultValue: "View only: high latency", bundle: .module)
    }
    static func latencyDetail(rtt: Int, path: String, limit: Int) -> String {
        String(localized: "rd.state.latency.detail",
               defaultValue: "\(rtt) ms, \(path). Control turns off above \(limit) ms.", bundle: .module)
    }
    static func consentTitle(_ host: String) -> String {
        String(localized: "rd.state.consent.title", defaultValue: "Waiting for consent on \(host)…", bundle: .module)
    }
    static func consentDetail(host: String, seconds: Int) -> String {
        String(localized: "rd.state.consent.detail",
               defaultValue: "Someone at \(host) must allow this session. It ends in \(seconds) s without an answer.",
               bundle: .module)
    }
    static func kickedTitle(_ name: String) -> String {
        String(localized: "rd.state.kicked.title", defaultValue: "Disconnected by \(name)", bundle: .module)
    }
    static func kickedDetail(name: String, host: String) -> String {
        String(localized: "rd.state.kicked.detail", defaultValue: "\(name) ended your session on \(host).", bundle: .module)
    }
    static var stoppedTitle: String {
        String(localized: "rd.state.stopped.title", defaultValue: "Host stopped sharing", bundle: .module)
    }
    static func stoppedDetail(_ host: String) -> String {
        String(localized: "rd.state.stopped.detail",
               defaultValue: "\(host) turned off Remote Desktop. The last frame is shown.", bundle: .module)
    }

    // Host indicator
    static func controlledBy(_ name: String) -> String {
        String(localized: "rd.host.controlledBy", defaultValue: "Controlled by \(name)", bundle: .module)
    }
    static var hostMenuTitle: String { String(localized: "rd.host.menu.title", defaultValue: "Remote Desktop", bundle: .module) }
    static var hostStopAll: String { String(localized: "rd.host.menu.stopAll", defaultValue: "Stop All Sessions", bundle: .module) }
    static var hostSettings: String { String(localized: "rd.host.menu.settings", defaultValue: "Remote Desktop Settings…", bundle: .module) }

    // Consent sheet
    static func consentRequestControl(_ name: String) -> String {
        String(localized: "rd.consent.title.control", defaultValue: "\(name) wants to control this Mac", bundle: .module)
    }
    static var consentDevice: String { String(localized: "rd.consent.device", defaultValue: "Device", bundle: .module) }
    static var consentPath: String { String(localized: "rd.consent.path", defaultValue: "Path", bundle: .module) }
    static var consentAccount: String { String(localized: "rd.consent.account", defaultValue: "Account", bundle: .module) }
    static var consentNote: String {
        String(localized: "rd.consent.note",
               defaultValue: "Password and sign-in windows stay hidden. Stop works at any time from the menu bar.",
               bundle: .module)
    }
    static var consentAllowView: String { String(localized: "rd.consent.allowView", defaultValue: "Allow View", bundle: .module) }
    static var consentAllowControl: String { String(localized: "rd.consent.allowControl", defaultValue: "Allow Control", bundle: .module) }
    static var consentDeny: String { String(localized: "rd.consent.deny", defaultValue: "Deny", bundle: .module) }
    static func consentCountdown(_ seconds: Int) -> String {
        String(localized: "rd.consent.countdown", defaultValue: "Denies in \(seconds) s", bundle: .module)
    }
}
