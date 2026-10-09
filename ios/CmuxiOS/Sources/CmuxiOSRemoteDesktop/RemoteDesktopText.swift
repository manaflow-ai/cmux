import Foundation

/// The remote desktop screen's strings (en, ja).
struct RemoteDesktopText {
    static var entryTitle: String { String(localized: "rd.entry.title", defaultValue: "Remote Desktop", bundle: .module) }
    static var entryScreen: String { String(localized: "rd.entry.screen", defaultValue: "Show Screen", bundle: .module) }
    static var entryVnc: String { String(localized: "rd.entry.vnc", defaultValue: "Connect to VNC Server…", bundle: .module) }
    static var entryMessage: String { String(localized: "rd.entry.message", defaultValue: "Your Mac streams its screen, or a VNC server it can reach.", bundle: .module) }
    static var cancel: String { String(localized: "rd.cancel", defaultValue: "Cancel", bundle: .module) }
    static var vncTitle: String { String(localized: "rd.vnc.title", defaultValue: "VNC Server", bundle: .module) }
    static var vncMessage: String { String(localized: "rd.vnc.message", defaultValue: "Your Mac connects to this server for you. Enter a hostname or IP address and a port.", bundle: .module) }
    static var vncHost: String { String(localized: "rd.vnc.host", defaultValue: "Host", bundle: .module) }
    static var vncPort: String { String(localized: "rd.vnc.port", defaultValue: "Port", bundle: .module) }
    static var vncConnect: String { String(localized: "rd.vnc.connect", defaultValue: "Connect", bundle: .module) }
    static var vncInvalid: String { String(localized: "rd.vnc.invalid", defaultValue: "Enter a hostname or IP address and a port from 1 to 65535.", bundle: .module) }
    static var authTitle: String { String(localized: "rd.auth.title", defaultValue: "VNC Password", bundle: .module) }
    static var authMessage: String { String(localized: "rd.auth.message", defaultValue: "%@ asks for a password.", bundle: .module) }
    static var authPassword: String { String(localized: "rd.auth.password", defaultValue: "Password", bundle: .module) }
    static var statusConnecting: String { String(localized: "rd.status.connecting", defaultValue: "Connecting…", bundle: .module) }
    static var statusWaiting: String { String(localized: "rd.status.waiting", defaultValue: "Approve on your Mac", bundle: .module) }
    static var statusWaitingDetail: String { String(localized: "rd.status.waiting.detail", defaultValue: "Allow this device in the panel on %@.", bundle: .module) }
    static var statusPaused: String { String(localized: "rd.status.paused", defaultValue: "Paused", bundle: .module) }
    static var close: String { String(localized: "rd.close", defaultValue: "Close", bundle: .module) }
    static var done: String { String(localized: "rd.done", defaultValue: "Done", bundle: .module) }
    static var failureUnreachable: String { String(localized: "rd.failure.unreachable", defaultValue: "Can't reach this Mac.", bundle: .module) }
    static var failureScreenRecording: String { String(localized: "rd.failure.screen-recording", defaultValue: "Allow Screen Recording for cmux in System Settings on your Mac.", bundle: .module) }
    static var failureConsentDenied: String { String(localized: "rd.failure.consent-denied", defaultValue: "Denied on the Mac.", bundle: .module) }
    static var failureStopped: String { String(localized: "rd.failure.stopped", defaultValue: "Stopped on the Mac.", bundle: .module) }
    static var failureDisplay: String { String(localized: "rd.failure.display", defaultValue: "That display is no longer connected.", bundle: .module) }
    static var failureWindow: String { String(localized: "rd.failure.window", defaultValue: "That window is closed.", bundle: .module) }
    static var failureVncNotAllowed: String { String(localized: "rd.failure.vnc-not-allowed", defaultValue: "This Mac doesn't connect to that VNC server.", bundle: .module) }
    static var failureVncUnreachable: String { String(localized: "rd.failure.vnc-unreachable", defaultValue: "The VNC server didn't answer.", bundle: .module) }
    static var failureVncAuthUnsupported: String { String(localized: "rd.failure.vnc-auth-unsupported", defaultValue: "This VNC server needs a sign-in the Mac doesn't support. Turn on VNC password access on the server.", bundle: .module) }
    static var failureVncAuthFailed: String { String(localized: "rd.failure.vnc-auth-failed", defaultValue: "Wrong VNC password.", bundle: .module) }
    static var failurePermissionRevoked: String { String(localized: "rd.failure.permission-revoked", defaultValue: "Screen Recording was turned off on the Mac.", bundle: .module) }
    static var failureEnded: String { String(localized: "rd.failure.ended", defaultValue: "The session ended.", bundle: .module) }
    static var failureRevoked: String { String(localized: "rd.failure.revoked", defaultValue: "This device is no longer paired with the Mac.", bundle: .module) }
    static var failureOther: String { String(localized: "rd.failure.other", defaultValue: "Remote desktop isn't available (%@).", bundle: .module) }
    static var modeControl: String { String(localized: "rd.mode.control", defaultValue: "Control", bundle: .module) }
    static var modeView: String { String(localized: "rd.mode.view", defaultValue: "View Only", bundle: .module) }
    static var modeAccessibility: String { String(localized: "rd.mode.accessibility", defaultValue: "Allow Accessibility for cmux on your Mac to control it.", bundle: .module) }
    static var inputTitle: String { String(localized: "rd.input.title", defaultValue: "Pointer", bundle: .module) }
    static var inputTrackpad: String { String(localized: "rd.input.trackpad", defaultValue: "Trackpad", bundle: .module) }
    static var inputDirect: String { String(localized: "rd.input.direct", defaultValue: "Direct Touch", bundle: .module) }
    static var displays: String { String(localized: "rd.displays", defaultValue: "Displays", bundle: .module) }
    static var clipboard: String { String(localized: "rd.clipboard", defaultValue: "Clipboard", bundle: .module) }
    static var pasteToMac: String { String(localized: "rd.clipboard.paste", defaultValue: "Paste to Mac", bundle: .module) }
    static var copyFromMac: String { String(localized: "rd.clipboard.copy", defaultValue: "Copy from Mac", bundle: .module) }
    static var copiedFromMac: String { String(localized: "rd.clipboard.copied", defaultValue: "Copied from the Mac", bundle: .module) }
    static var keyboard: String { String(localized: "rd.keyboard", defaultValue: "Keyboard", bundle: .module) }
    static var keyEscape: String { String(localized: "rd.key.escape", defaultValue: "Escape", bundle: .module) }
    static var keyTab: String { String(localized: "rd.key.tab", defaultValue: "Tab", bundle: .module) }
    static var keyControl: String { String(localized: "rd.key.control", defaultValue: "Control", bundle: .module) }
    static var keyOption: String { String(localized: "rd.key.option", defaultValue: "Option", bundle: .module) }
    static var keyCommand: String { String(localized: "rd.key.command", defaultValue: "Command", bundle: .module) }
    static var keyShift: String { String(localized: "rd.key.shift", defaultValue: "Shift", bundle: .module) }
    static var keyLeft: String { String(localized: "rd.key.left", defaultValue: "Left Arrow", bundle: .module) }
    static var keyUp: String { String(localized: "rd.key.up", defaultValue: "Up Arrow", bundle: .module) }
    static var keyDown: String { String(localized: "rd.key.down", defaultValue: "Down Arrow", bundle: .module) }
    static var keyRight: String { String(localized: "rd.key.right", defaultValue: "Right Arrow", bundle: .module) }
    static var screenLabel: String { String(localized: "rd.screen.label", defaultValue: "Remote screen", bundle: .module) }

    static func format(_ template: String, _ argument: String) -> String {
        String(format: template, argument)
    }
}
