import Foundation

/// Localized strings of the platform screens.
enum PlatformText {
    static var diagnosticsTitle: String {
        String(localized: "platform.diagnostics.title", defaultValue: "Diagnostics", bundle: .module)
    }
    static var crashReports: String {
        String(localized: "platform.diagnostics.crashReports", defaultValue: "Share Crash Reports", bundle: .module)
    }
    static var crashReportsFooter: String {
        String(localized: "platform.diagnostics.crashReportsFooter",
               defaultValue: "Sends crash and hang reports without your name, email or terminal contents.", bundle: .module)
    }
    static var logSection: String {
        String(localized: "platform.diagnostics.logSection", defaultValue: "Log", bundle: .module)
    }
    static var logLines: String {
        String(localized: "platform.diagnostics.lines", defaultValue: "Lines", bundle: .module)
    }
    static var shareDiagnostics: String {
        String(localized: "platform.diagnostics.share", defaultValue: "Share Diagnostics", bundle: .module)
    }
    static var copySupportInfo: String {
        String(localized: "platform.diagnostics.copy", defaultValue: "Copy Support Info", bundle: .module)
    }
    static var supportInfoCopied: String {
        String(localized: "platform.diagnostics.copied", defaultValue: "Support Info Copied", bundle: .module)
    }
    static var clearLog: String {
        String(localized: "platform.diagnostics.clear", defaultValue: "Clear Log", bundle: .module)
    }
    static var clearLogConfirm: String {
        String(localized: "platform.diagnostics.clearConfirm",
               defaultValue: "Clear the diagnostic log on this device?", bundle: .module)
    }
    static var logFooter: String {
        String(localized: "platform.diagnostics.logFooter",
               defaultValue: "Secrets, emails and file paths are removed before anything is saved.", bundle: .module)
    }
    static var toastDismissHint: String {
        String(localized: "platform.toast.dismissHint", defaultValue: "Double-tap to dismiss.", bundle: .module)
    }

    // MARK: What's New
    static var whatsNewTitle: String {
        String(localized: "platform.whatsNew.title", defaultValue: "What's New", bundle: .module)
    }
    static func version(_ version: String) -> String {
        String(format: String(localized: "platform.whatsNew.version", defaultValue: "Version %@", bundle: .module), version)
    }
    static var continueLabel: String {
        String(localized: "platform.whatsNew.continue", defaultValue: "Continue", bundle: .module)
    }
    static var whatsNewEmpty: String {
        String(localized: "platform.whatsNew.empty", defaultValue: "No release notes for this version.", bundle: .module)
    }
    static var whatsNewShellTitle: String {
        String(localized: "platform.whatsNew.shell.title", defaultValue: "A New App", bundle: .module)
    }
    static var whatsNewShellDetail: String {
        String(localized: "platform.whatsNew.shell.detail",
               defaultValue: "Home, Feed, Workspaces, Compose and Hosts in one place.", bundle: .module)
    }
    static var whatsNewLinksTitle: String {
        String(localized: "platform.whatsNew.links.title", defaultValue: "Links Open in cmux", bundle: .module)
    }
    static var whatsNewLinksDetail: String {
        String(localized: "platform.whatsNew.links.detail",
               defaultValue: "A cmux link opens the right screen, even if you sign in first.", bundle: .module)
    }
    static var whatsNewDiagnosticsTitle: String {
        String(localized: "platform.whatsNew.diagnostics.title", defaultValue: "Diagnostics", bundle: .module)
    }
    static var whatsNewDiagnosticsDetail: String {
        String(localized: "platform.whatsNew.diagnostics.detail",
               defaultValue: "Share a log with secrets removed from Settings.", bundle: .module)
    }

    // MARK: Mac update gate
    static func gateMacTitle(_ mac: String) -> String {
        String(format: String(localized: "platform.gate.mac.title", defaultValue: "Update cmux on %@", bundle: .module), mac)
    }
    static func gateMacMessage(_ mac: String, _ version: String) -> String {
        String(format: String(localized: "platform.gate.mac.message",
                              defaultValue: "%1$@ runs cmux %2$@, which this app can no longer connect to.",
                              bundle: .module), mac, version)
    }
    static var gateMacSteps: String {
        String(localized: "platform.gate.mac.steps",
               defaultValue: "On the Mac, choose cmux > Check for Updates.", bundle: .module)
    }
    static var gatePhoneTitle: String {
        String(localized: "platform.gate.phone.title", defaultValue: "Update This App", bundle: .module)
    }
    static func gatePhoneMessage(_ mac: String) -> String {
        String(format: String(localized: "platform.gate.phone.message",
                              defaultValue: "%@ runs a newer cmux than this app supports.", bundle: .module), mac)
    }
    static var gatePhoneSteps: String {
        String(localized: "platform.gate.phone.steps",
               defaultValue: "Update cmux from the App Store or TestFlight.", bundle: .module)
    }

    // MARK: Demo content
    static var demoTitle: String {
        String(localized: "platform.demo.title", defaultValue: "Demo Content", bundle: .module)
    }
    static var demoActive: String {
        String(localized: "platform.demo.active", defaultValue: "Showing sample data", bundle: .module)
    }
    static var demoFooter: String {
        String(localized: "platform.demo.footer",
               defaultValue: "This account shows sample Macs, workspaces and feed items. Nothing you do here reaches a real Mac.",
               bundle: .module)
    }
}
