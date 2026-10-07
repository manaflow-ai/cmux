import Foundation

/// Localized strings of the C11 Settings screens (c11-settings.md).
extension SettingsText {
    static var preferences: String { String(localized: "shell.settings.preferences", defaultValue: "Preferences", bundle: .module) }
    static var terminal: String { String(localized: "shell.settings.terminal", defaultValue: "Terminal", bundle: .module) }
    static var notifications: String { String(localized: "shell.settings.notifications", defaultValue: "Notifications", bundle: .module) }
    static var privacy: String { String(localized: "shell.settings.privacy", defaultValue: "Privacy", bundle: .module) }
    static var help: String { String(localized: "shell.settings.help", defaultValue: "Help", bundle: .module) }
    static var teamChangeFailed: String { String(localized: "shell.settings.teamChangeFailed", defaultValue: "Couldn't switch teams. Check your connection and try again.", bundle: .module) }
    static var accountFooter: String { String(localized: "shell.settings.accountFooter", defaultValue: "Use the same cmux account as the Macs you connect to.", bundle: .module) }
    static var team: String { String(localized: "shell.settings.team", defaultValue: "Team", bundle: .module) }
    static var teamChanging: String { String(localized: "shell.settings.teamChanging", defaultValue: "Switching team", bundle: .module) }
    static var deleteAccount: String { String(localized: "shell.settings.deleteAccount", defaultValue: "Delete Account", bundle: .module) }
    static var deletingAccount: String { String(localized: "shell.settings.deletingAccount", defaultValue: "Deleting Account…", bundle: .module) }
    static var deleteAccountFooter: String { String(localized: "shell.settings.deleteAccountFooter", defaultValue: "Permanently deletes your cmux account and its data.", bundle: .module) }
    static var deleteAccountTitle: String { String(localized: "shell.settings.deleteAccountTitle", defaultValue: "Delete Account?", bundle: .module) }
    static var deleteAccountMessage: String { String(localized: "shell.settings.deleteAccountMessage", defaultValue: "This permanently deletes your cmux account and cmux data. You will be signed out on this device.", bundle: .module) }
    static var cancel: String { String(localized: "shell.settings.cancel", defaultValue: "Cancel", bundle: .module) }
    static var ok: String { String(localized: "shell.settings.ok", defaultValue: "OK", bundle: .module) }
    static var deletionFailedTitle: String { String(localized: "shell.settings.deletion.failedTitle", defaultValue: "Couldn't Delete Account", bundle: .module) }
    static var deletionCleanupTitle: String { String(localized: "shell.settings.deletion.cleanupTitle", defaultValue: "Account Deleted", bundle: .module) }
    static var deletionGeneric: String { String(localized: "shell.settings.deletion.generic", defaultValue: "Try again later or contact support.", bundle: .module) }
    static var deletionConnection: String { String(localized: "shell.settings.deletion.connection", defaultValue: "Could not reach the server. Check your internet connection and try again.", bundle: .module) }
    static var deletionUnauthorized: String { String(localized: "shell.settings.deletion.unauthorized", defaultValue: "Your session is no longer valid. You will be signed out on this device. Sign in again if the account still exists.", bundle: .module) }
    static var deletionStackIncomplete: String { String(localized: "shell.settings.deletion.stackIncomplete", defaultValue: "Your cmux data was deleted, but account sign-in cleanup did not finish. Try Delete Account again to complete deletion.", bundle: .module) }
    static var deletionCleanupIncomplete: String { String(localized: "shell.settings.deletion.cleanupIncomplete", defaultValue: "Your account sign-in was deleted, but some cmux cleanup did not finish. You will be signed out. Contact support if cmux data is still visible.", bundle: .module) }
    static var deletionTimedOut: String { String(localized: "shell.settings.deletion.timedOut", defaultValue: "Account deletion timed out. Check your connection and try again.", bundle: .module) }
    static var deletionUnknown: String { String(localized: "shell.settings.deletion.unknown", defaultValue: "We couldn't confirm whether account deletion finished. Wait a moment, then try Delete Account again.", bundle: .module) }
    static var noDevices: String { String(localized: "shell.settings.noDevices", defaultValue: "No devices yet.", bundle: .module) }
    static var sectionThisDevice: String { String(localized: "shell.settings.section.thisDevice", defaultValue: "This Device", bundle: .module) }
    static var sectionMacs: String { String(localized: "shell.settings.section.macs", defaultValue: "Macs & Cloud", bundle: .module) }
    static var sectionOther: String { String(localized: "shell.settings.section.other", defaultValue: "Other Devices", bundle: .module) }
    static var pathDirect: String { String(localized: "shell.settings.path.direct", defaultValue: "Direct", bundle: .module) }
    static var pathP2P: String { String(localized: "shell.settings.path.p2p", defaultValue: "Peer-to-Peer", bundle: .module) }
    static var pathTurn: String { String(localized: "shell.settings.path.turn", defaultValue: "TURN Relay", bundle: .module) }
    static var pathRelay: String { String(localized: "shell.settings.path.relay", defaultValue: "Relay", bundle: .module) }
    static var pathSummaryFormat: String { String(localized: "shell.settings.path.summaryFormat", defaultValue: "%@ · %@", bundle: .module) }
    static var pathSpokenFormat: String { String(localized: "shell.settings.path.spokenFormat", defaultValue: "%@ path, %@", bundle: .module) }
    static var millisecondsFormat: String { String(localized: "shell.settings.millisecondsFormat", defaultValue: "%lld ms", bundle: .module) }
    static var seenFormat: String { String(localized: "shell.settings.seenFormat", defaultValue: "%@ · seen %@", bundle: .module) }
    static var deviceRemoved: String { String(localized: "shell.settings.deviceRemoved", defaultValue: "Device removed", bundle: .module) }
    static var deviceActionFailed: String { String(localized: "shell.settings.deviceActionFailed", defaultValue: "Couldn't Change Device", bundle: .module) }
    static var errorOffline: String { String(localized: "shell.settings.error.offline", defaultValue: "The device list is offline. Nothing was changed.", bundle: .module) }
    static var errorNotFound: String { String(localized: "shell.settings.error.notFound", defaultValue: "This device is no longer on your account.", bundle: .module) }
    static var errorThisDevice: String { String(localized: "shell.settings.error.thisDevice", defaultValue: "Sign out to remove this device.", bundle: .module) }
    static var errorEmptyName: String { String(localized: "shell.settings.error.emptyName", defaultValue: "Enter a name.", bundle: .module) }
    static var errorLongNameFormat: String { String(localized: "shell.settings.error.longNameFormat", defaultValue: "Use %lld characters or fewer.", bundle: .module) }
    static var errorControlName: String { String(localized: "shell.settings.error.controlName", defaultValue: "The name contains characters that can't be shown.", bundle: .module) }
    static var deviceName: String { String(localized: "shell.settings.deviceName", defaultValue: "Name", bundle: .module) }
    static var kind: String { String(localized: "shell.settings.kind", defaultValue: "Kind", bundle: .module) }
    static var statusLabel: String { String(localized: "shell.settings.statusLabel", defaultValue: "Status", bundle: .module) }
    static var lastSeen: String { String(localized: "shell.settings.lastSeen", defaultValue: "Last Seen", bundle: .module) }
    static var never: String { String(localized: "shell.settings.never", defaultValue: "Never", bundle: .module) }
    static var connection: String { String(localized: "shell.settings.connection", defaultValue: "Connection", bundle: .module) }
    static var path: String { String(localized: "shell.settings.path", defaultValue: "Path", bundle: .module) }
    static var carrier: String { String(localized: "shell.settings.carrier", defaultValue: "Carrier", bundle: .module) }
    static var roundTrip: String { String(localized: "shell.settings.roundTrip", defaultValue: "Round Trip", bundle: .module) }
    static var unknownValue: String { String(localized: "shell.settings.unknownValue", defaultValue: "Unknown", bundle: .module) }
    static var notConnected: String { String(localized: "shell.settings.notConnected", defaultValue: "Not connected", bundle: .module) }
    static var signOutToRemove: String { String(localized: "shell.settings.signOutToRemove", defaultValue: "Sign out to remove this device.", bundle: .module) }
    static var removeDevice: String { String(localized: "shell.settings.removeDevice", defaultValue: "Remove Device", bundle: .module) }
    static var removeDeviceFooter: String { String(localized: "shell.settings.removeDeviceFooter", defaultValue: "The device loses access to your Macs and must pair again.", bundle: .module) }
    static var removeDeviceConfirmFormat: String { String(localized: "shell.settings.removeDeviceConfirmFormat", defaultValue: "Remove “%@” from your account?", bundle: .module) }
    static var platformMac: String { String(localized: "shell.settings.platform.mac", defaultValue: "Mac", bundle: .module) }
    static var platformIPhone: String { String(localized: "shell.settings.platform.iPhone", defaultValue: "iPhone", bundle: .module) }
    static var platformIPad: String { String(localized: "shell.settings.platform.iPad", defaultValue: "iPad", bundle: .module) }
    static var platformCloud: String { String(localized: "shell.settings.platform.cloud", defaultValue: "Cloud Machine", bundle: .module) }
    static var matchMacFooter: String { String(localized: "shell.settings.matchMacFooter", defaultValue: "Match Mac uses the theme of the Mac you connect to. The preview shows the default colors.", bundle: .module) }
    static var theme: String { String(localized: "shell.settings.theme", defaultValue: "Theme", bundle: .module) }
    static var themeMatchMac: String { String(localized: "shell.settings.theme.matchMac", defaultValue: "Match Mac", bundle: .module) }
    static var themeGhostty: String { String(localized: "shell.settings.theme.ghostty", defaultValue: "Ghostty Default", bundle: .module) }
    static var themeMonokai: String { String(localized: "shell.settings.theme.monokai", defaultValue: "Monokai", bundle: .module) }
    static var themePaper: String { String(localized: "shell.settings.theme.paper", defaultValue: "Paper", bundle: .module) }
    static var themeInk: String { String(localized: "shell.settings.theme.ink", defaultValue: "Ink", bundle: .module) }
    static var font: String { String(localized: "shell.settings.font", defaultValue: "Font", bundle: .module) }
    static var fontFamily: String { String(localized: "shell.settings.fontFamily", defaultValue: "Family", bundle: .module) }
    static var fontStandard: String { String(localized: "shell.settings.font.standard", defaultValue: "JetBrains Mono (Default)", bundle: .module) }
    static var fontMenlo: String { String(localized: "shell.settings.font.menlo", defaultValue: "Menlo", bundle: .module) }
    static var fontCourier: String { String(localized: "shell.settings.font.courier", defaultValue: "Courier New", bundle: .module) }
    static var fontSize: String { String(localized: "shell.settings.fontSize", defaultValue: "Size", bundle: .module) }
    static var pointsFormat: String { String(localized: "shell.settings.pointsFormat", defaultValue: "%lld pt", bundle: .module) }
    static var followDynamicType: String { String(localized: "shell.settings.followDynamicType", defaultValue: "Follow Text Size", bundle: .module) }
    static var fontFooter: String { String(localized: "shell.settings.fontFooter", defaultValue: "With Follow Text Size on, the size scales with the iOS text size. Pinch a terminal to zoom.", bundle: .module) }
    static var cursor: String { String(localized: "shell.settings.cursor", defaultValue: "Cursor", bundle: .module) }
    static var cursorShape: String { String(localized: "shell.settings.cursorShape", defaultValue: "Shape", bundle: .module) }
    static var cursorBlock: String { String(localized: "shell.settings.cursor.block", defaultValue: "Block", bundle: .module) }
    static var cursorBar: String { String(localized: "shell.settings.cursor.bar", defaultValue: "Bar", bundle: .module) }
    static var cursorUnderline: String { String(localized: "shell.settings.cursor.underline", defaultValue: "Underline", bundle: .module) }
    static var cursorBlink: String { String(localized: "shell.settings.cursorBlink", defaultValue: "Blink", bundle: .module) }
    static var keyBar: String { String(localized: "shell.settings.keyBar", defaultValue: "Key Bar", bundle: .module) }
    static var keyCountFormat: String { String(localized: "shell.settings.keyCountFormat", defaultValue: "%lld keys", bundle: .module) }
    static var resetTerminal: String { String(localized: "shell.settings.resetTerminal", defaultValue: "Reset Terminal Settings", bundle: .module) }
    static var resetTerminalConfirm: String { String(localized: "shell.settings.resetTerminalConfirm", defaultValue: "Reset theme, font, cursor and key bar to their defaults?", bundle: .module) }
    static var previewLabel: String { String(localized: "shell.settings.previewLabel", defaultValue: "Terminal preview", bundle: .module) }
    static var previewValueFormat: String { String(localized: "shell.settings.previewValueFormat", defaultValue: "%@, %@, %@ cursor", bundle: .module) }
    static var keyBarShown: String { String(localized: "shell.settings.keyBarShown", defaultValue: "Shown", bundle: .module) }
    static var keyBarHidden: String { String(localized: "shell.settings.keyBarHidden", defaultValue: "More Keys", bundle: .module) }
    static var keyBarFooter: String { String(localized: "shell.settings.keyBarFooter", defaultValue: "Drag to reorder. The bar appears above the software keyboard.", bundle: .module) }
    static var keyBarAddHint: String { String(localized: "shell.settings.keyBarAddHint", defaultValue: "Adds the key to the end of the bar.", bundle: .module) }
    static var keyBarReset: String { String(localized: "shell.settings.keyBarReset", defaultValue: "Reset Key Bar", bundle: .module) }
    static var keyEscape: String { String(localized: "shell.settings.key.escape", defaultValue: "Escape", bundle: .module) }
    static var keyTab: String { String(localized: "shell.settings.key.tab", defaultValue: "Tab", bundle: .module) }
    static var keyControl: String { String(localized: "shell.settings.key.control", defaultValue: "Control", bundle: .module) }
    static var keyAlternate: String { String(localized: "shell.settings.key.alternate", defaultValue: "Option", bundle: .module) }
    static var keyLeft: String { String(localized: "shell.settings.key.left", defaultValue: "Left Arrow", bundle: .module) }
    static var keyDown: String { String(localized: "shell.settings.key.down", defaultValue: "Down Arrow", bundle: .module) }
    static var keyUp: String { String(localized: "shell.settings.key.up", defaultValue: "Up Arrow", bundle: .module) }
    static var keyRight: String { String(localized: "shell.settings.key.right", defaultValue: "Right Arrow", bundle: .module) }
    static var keyTilde: String { String(localized: "shell.settings.key.tilde", defaultValue: "Tilde (~)", bundle: .module) }
    static var keySlash: String { String(localized: "shell.settings.key.slash", defaultValue: "Slash (/)", bundle: .module) }
    static var keyPipe: String { String(localized: "shell.settings.key.pipe", defaultValue: "Pipe (|)", bundle: .module) }
    static var keyDash: String { String(localized: "shell.settings.key.dash", defaultValue: "Dash (-)", bundle: .module) }
    static var keyPaste: String { String(localized: "shell.settings.key.paste", defaultValue: "Paste", bundle: .module) }
    static var keyHide: String { String(localized: "shell.settings.key.hide", defaultValue: "Hide Keyboard", bundle: .module) }
    static var notificationsDeniedFooter: String { String(localized: "shell.settings.notificationsDeniedFooter", defaultValue: "Notifications are off for cmux. Turn them on in iOS Settings to get alerts.", bundle: .module) }
    static var notifyAbout: String { String(localized: "shell.settings.notifyAbout", defaultValue: "Notify Me About", bundle: .module) }
    static var kindPermission: String { String(localized: "shell.settings.kind.permission", defaultValue: "Permission Requests", bundle: .module) }
    static var kindPermissionDetail: String { String(localized: "shell.settings.kind.permissionDetail", defaultValue: "An agent wants to run a command or edit files.", bundle: .module) }
    static var kindQuestion: String { String(localized: "shell.settings.kind.question", defaultValue: "Questions", bundle: .module) }
    static var kindQuestionDetail: String { String(localized: "shell.settings.kind.questionDetail", defaultValue: "An agent is waiting for your answer.", bundle: .module) }
    static var kindPlan: String { String(localized: "shell.settings.kind.plan", defaultValue: "Plan Approvals", bundle: .module) }
    static var kindPlanDetail: String { String(localized: "shell.settings.kind.planDetail", defaultValue: "An agent proposes a plan before it starts.", bundle: .module) }
    static var kindFinished: String { String(localized: "shell.settings.kind.finished", defaultValue: "Finished", bundle: .module) }
    static var kindFinishedDetail: String { String(localized: "shell.settings.kind.finishedDetail", defaultValue: "An agent finished its task.", bundle: .module) }
    static var kindTerminal: String { String(localized: "shell.settings.kind.terminal", defaultValue: "Terminal Alerts", bundle: .module) }
    static var kindTerminalDetail: String { String(localized: "shell.settings.kind.terminalDetail", defaultValue: "Bells and notifications from terminal programs.", bundle: .module) }
    static var syncLocal: String { String(localized: "shell.settings.sync.local", defaultValue: "Saved on this device.", bundle: .module) }
    static var syncSyncing: String { String(localized: "shell.settings.sync.syncing", defaultValue: "Saving…", bundle: .module) }
    static var syncSynced: String { String(localized: "shell.settings.sync.synced", defaultValue: "Saved for this device's notifications.", bundle: .module) }
    static var syncOffline: String { String(localized: "shell.settings.sync.offline", defaultValue: "Offline. Saved on this device; it applies after your next change while online.", bundle: .module) }
    static var syncRefusedFormat: String { String(localized: "shell.settings.sync.refusedFormat", defaultValue: "Not saved: %@", bundle: .module) }
    static var notifySound: String { String(localized: "shell.settings.notifySound", defaultValue: "Sound", bundle: .module) }
    static var timeSensitive: String { String(localized: "shell.settings.timeSensitive", defaultValue: "Time-Sensitive", bundle: .module) }
    static var timeSensitiveDetail: String { String(localized: "shell.settings.timeSensitiveDetail", defaultValue: "Approvals and questions can break through Focus.", bundle: .module) }
    static var systemNotifications: String { String(localized: "shell.settings.systemNotifications", defaultValue: "Notifications", bundle: .module) }
    static var allowed: String { String(localized: "shell.settings.allowed", defaultValue: "Allowed", bundle: .module) }
    static var off: String { String(localized: "shell.settings.off", defaultValue: "Off", bundle: .module) }
    static var openIOSSettings: String { String(localized: "shell.settings.openIOSSettings", defaultValue: "Open iOS Settings", bundle: .module) }
    static var turnOnNotifications: String { String(localized: "shell.settings.turnOnNotifications", defaultValue: "Turn On Notifications", bundle: .module) }
    static var shareCrashReports: String { String(localized: "shell.settings.shareCrashReports", defaultValue: "Share Crash Reports", bundle: .module) }
    static var shareCrashReportsFooter: String { String(localized: "shell.settings.shareCrashReportsFooter", defaultValue: "Sends crash and hang reports with personal data removed. Terminal content is never included.", bundle: .module) }
    static var privacyPolicy: String { String(localized: "shell.settings.privacyPolicy", defaultValue: "Privacy Policy", bundle: .module) }
    static var termsOfService: String { String(localized: "shell.settings.termsOfService", defaultValue: "Terms of Service", bundle: .module) }
    static var support: String { String(localized: "shell.settings.support", defaultValue: "Support", bundle: .module) }
    static var supportSubject: String { String(localized: "shell.settings.supportSubject", defaultValue: "cmux iOS support", bundle: .module) }
    static var acknowledgements: String { String(localized: "shell.settings.acknowledgements", defaultValue: "Acknowledgements", bundle: .module) }
}
