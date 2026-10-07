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
}
