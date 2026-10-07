import Foundation

/// Localized strings of the tunnel browser screens.
enum WebText {
    static var portsTitle: String { String(localized: "web.ports.title", defaultValue: "Dev Servers", bundle: .module) }
    static var portsSection: String { String(localized: "web.ports.section", defaultValue: "Ports on This Mac", bundle: .module) }
    static var portsEmpty: String {
        String(localized: "web.ports.empty",
               defaultValue: "No dev servers found. Start one in a workspace, or allow a port in cmux on the Mac.",
               bundle: .module)
    }
    static var portsFailed: String {
        String(localized: "web.ports.failed", defaultValue: "Could not reach this Mac. Pull to try again.", bundle: .module)
    }
    static var sshFooter: String {
        String(localized: "web.ssh.footer", defaultValue: "Pages load from localhost on this host through SSH.", bundle: .module)
    }
    static var openPort: String { String(localized: "web.open_port", defaultValue: "Open a localhost Port…", bundle: .module) }
    static var openPortTitle: String { String(localized: "web.open_port.title", defaultValue: "Open localhost", bundle: .module) }
    static var openPortMessage: String {
        String(localized: "web.open_port.message", defaultValue: "Enter a port, or an address such as localhost:3000/app.",
               bundle: .module)
    }
    static var open: String { String(localized: "web.open", defaultValue: "Open", bundle: .module) }
    static var cancel: String { String(localized: "web.cancel", defaultValue: "Cancel", bundle: .module) }
    static var simulatorsSection: String { String(localized: "web.simulators.section", defaultValue: "Simulators", bundle: .module) }
    static var simulatorsEmpty: String {
        String(localized: "web.simulators.empty", defaultValue: "No booted simulators on this Mac.", bundle: .module)
    }
    static var detected: String { String(localized: "web.port.detected", defaultValue: "Running in a workspace", bundle: .module) }
    static var allowed: String { String(localized: "web.port.allowed", defaultValue: "Allowed on the Mac", bundle: .module) }
    static var back: String { String(localized: "web.back", defaultValue: "Back", bundle: .module) }
    static var forward: String { String(localized: "web.forward", defaultValue: "Forward", bundle: .module) }
    static var reload: String { String(localized: "web.reload", defaultValue: "Reload", bundle: .module) }
    static var addressPlaceholder: String {
        String(localized: "web.address.placeholder", defaultValue: "localhost:port", bundle: .module)
    }
    static var notLocal: String {
        String(localized: "web.not_local", defaultValue: "Only localhost addresses open here.", bundle: .module)
    }
    static var loadFailed: String { String(localized: "web.load_failed", defaultValue: "This page could not load.", bundle: .module) }
    static var offline: String {
        String(localized: "web.offline", defaultValue: "No connection to this machine.", bundle: .module)
    }
    static var retry: String { String(localized: "web.retry", defaultValue: "Try Again", bundle: .module) }
}
