import Foundation

/// Localized onboarding copy (c10-onboarding.md section 5).
enum OnboardingText {
    static var continueTitle: String { String(localized: "onboarding.common.continue", defaultValue: "Continue", bundle: .module) }
    static var skip: String { String(localized: "onboarding.common.skip", defaultValue: "Skip", bundle: .module) }
    static var back: String { String(localized: "onboarding.common.back", defaultValue: "Back", bundle: .module) }
    static var close: String { String(localized: "onboarding.common.close", defaultValue: "Close", bundle: .module) }
    static var notNow: String { String(localized: "onboarding.common.notNow", defaultValue: "Not Now", bundle: .module) }
    static func progress(_ index: Int, _ total: Int) -> String {
        String(localized: "onboarding.common.progress", defaultValue: "Step \(index) of \(total)", bundle: .module)
    }
    static var welcomeTitle: String { String(localized: "onboarding.welcome.title", defaultValue: "Your agents, in your pocket.", bundle: .module) }
    static var welcomeBody: String { String(localized: "onboarding.welcome.body", defaultValue: "cmux runs your terminals and coding agents on your Mac. Watch them, answer them, and keep them moving from anywhere.", bundle: .module) }
    static var getStarted: String { String(localized: "onboarding.welcome.getStarted", defaultValue: "Get Started", bundle: .module) }
    static var haveAccount: String { String(localized: "onboarding.welcome.haveAccount", defaultValue: "I Have an Account", bundle: .module) }
    static var vignetteLabel: String { String(localized: "onboarding.welcome.vignette", defaultValue: "Animation: an agent asks to run tests and is approved from a phone.", bundle: .module) }
    static var approveTitle: String { String(localized: "onboarding.approve.title", defaultValue: "Approve from anywhere.", bundle: .module) }
    static var approveBody: String { String(localized: "onboarding.approve.body", defaultValue: "When an agent needs permission, decide in one tap. Try it.", bundle: .module) }
    static var approveCardTitle: String { String(localized: "onboarding.approve.cardTitle", defaultValue: "Run swift test?", bundle: .module) }
    static var approveCardBody: String { String(localized: "onboarding.approve.cardBody", defaultValue: "Run the test suite to check the fix.", bundle: .module) }
    static var allow: String { String(localized: "onboarding.approve.allow", defaultValue: "Allow", bundle: .module) }
    static var deny: String { String(localized: "onboarding.approve.deny", defaultValue: "Deny", bundle: .module) }
    static var allowedReceipt: String { String(localized: "onboarding.approve.allowed", defaultValue: "Allowed", bundle: .module) }
    static var deniedReceipt: String { String(localized: "onboarding.approve.denied", defaultValue: "Denied", bundle: .module) }
    static var resultAllowed: String { String(localized: "onboarding.approve.resultAllowed", defaultValue: "128 tests passed", bundle: .module) }
    static var resultDenied: String { String(localized: "onboarding.approve.resultDenied", defaultValue: "Okay, skipping the tests.", bundle: .module) }
    static var approveHint: String { String(localized: "onboarding.approve.tryIt", defaultValue: "Tap Allow or Deny to continue.", bundle: .module) }
    static var replyTitle: String { String(localized: "onboarding.reply.title", defaultValue: "Answer in a tap.", bundle: .module) }
    static var replyBody: String { String(localized: "onboarding.reply.body", defaultValue: "Agents ask questions. Reply without opening your laptop.", bundle: .module) }
    static var replyQuestion: String { String(localized: "onboarding.reply.question", defaultValue: "I found an existing migration. Keep it or replace it?", bundle: .module) }
    static var keep: String { String(localized: "onboarding.reply.keep", defaultValue: "Keep", bundle: .module) }
    static var replace: String { String(localized: "onboarding.reply.replace", defaultValue: "Replace", bundle: .module) }
    static var followKeep: String { String(localized: "onboarding.reply.followKeep", defaultValue: "Keeping it. Writing the handler next.", bundle: .module) }
    static var followReplace: String { String(localized: "onboarding.reply.followReplace", defaultValue: "Replacing it. Writing a new migration.", bundle: .module) }
    static var replyHint: String { String(localized: "onboarding.reply.tryIt", defaultValue: "Pick an answer to continue.", bundle: .module) }
    static var signInTitle: String { String(localized: "onboarding.signIn.title", defaultValue: "Sign in to connect your Mac.", bundle: .module) }
    static var signInBody: String { String(localized: "onboarding.signIn.body", defaultValue: "Use the same account as cmux on your Mac.", bundle: .module) }
    static var notificationsTitle: String { String(localized: "onboarding.notifications.title", defaultValue: "Know when an agent needs you.", bundle: .module) }
    static var notificationsBody: String { String(localized: "onboarding.notifications.body", defaultValue: "Get a notification when an agent asks for approval or finishes. You choose which ones in Settings.", bundle: .module) }
    static var enableNotifications: String { String(localized: "onboarding.notifications.enable", defaultValue: "Turn On Notifications", bundle: .module) }
    static var previewTitle: String { String(localized: "onboarding.notifications.previewTitle", defaultValue: "Claude Code needs approval", bundle: .module) }
    static var previewBody: String { String(localized: "onboarding.notifications.previewBody", defaultValue: "Run swift test in cmux?", bundle: .module) }
    static var previewTime: String { String(localized: "onboarding.notifications.previewTime", defaultValue: "now", bundle: .module) }
    static var installTitle: String { String(localized: "onboarding.installMac.title", defaultValue: "Install cmux on your Mac.", bundle: .module) }
    static var installBody: String { String(localized: "onboarding.installMac.body", defaultValue: "Download it from cmux.com and sign in with this account. Your phone finds it automatically.", bundle: .module) }
    static var installed: String { String(localized: "onboarding.installMac.installed", defaultValue: "It's Installed", bundle: .module) }
    static var shareLink: String { String(localized: "onboarding.installMac.share", defaultValue: "Send Link to Mac", bundle: .module) }
    static var orTerminal: String { String(localized: "onboarding.installMac.terminal", defaultValue: "Or in Terminal", bundle: .module) }
    static var copy: String { String(localized: "onboarding.installMac.copy", defaultValue: "Copy", bundle: .module) }
    static var copied: String { String(localized: "onboarding.installMac.copied", defaultValue: "Copied", bundle: .module) }
    static var localNetworkTitle: String { String(localized: "onboarding.localNetwork.title", defaultValue: "Find your Mac nearby.", bundle: .module) }
    static var localNetworkBody: String { String(localized: "onboarding.localNetwork.body", defaultValue: "cmux looks for your Mac on this network for the fastest connection. Nothing leaves your network.", bundle: .module) }
    static var allowLocalNetwork: String { String(localized: "onboarding.localNetwork.allow", defaultValue: "Allow", bundle: .module) }
    static var pairTitle: String { String(localized: "onboarding.pair.title", defaultValue: "Connect your Mac.", bundle: .module) }
    static var pairBody: String { String(localized: "onboarding.pair.body", defaultValue: "Open cmux on your Mac, signed in to the same account.", bundle: .module) }
    static var searching: String { String(localized: "onboarding.pair.searching", defaultValue: "Looking for Macs on your account…", bundle: .module) }
    static var found: String { String(localized: "onboarding.pair.found", defaultValue: "Found on your account", bundle: .module) }
    static var connect: String { String(localized: "onboarding.pair.connect", defaultValue: "Connect", bundle: .module) }
    static var connecting: String { String(localized: "onboarding.pair.connecting", defaultValue: "Connecting…", bundle: .module) }
    static func paired(_ name: String) -> String {
        String(localized: "onboarding.pair.paired", defaultValue: "Connected to \(name)", bundle: .module)
    }
    static func failed(_ reason: String) -> String {
        String(localized: "onboarding.pair.failed", defaultValue: "Couldn't connect: \(reason)", bundle: .module)
    }
    static var retry: String { String(localized: "onboarding.pair.retry", defaultValue: "Try Again", bundle: .module) }
    static var pairOffline: String { String(localized: "onboarding.pair.offline", defaultValue: "You're offline. Connect to the internet to find your Mac.", bundle: .module) }
    static var pairHelp: String { String(localized: "onboarding.pair.help", defaultValue: "Don't see it? Open cmux on your Mac, or scan the QR code from Settings > Pair iPhone.", bundle: .module) }
    static var scanQR: String { String(localized: "onboarding.pair.scan", defaultValue: "Scan QR Code", bundle: .module) }
    static var setUpLater: String { String(localized: "onboarding.pair.later", defaultValue: "Set Up Later", bundle: .module) }
    static var offlineError: String { String(localized: "onboarding.pair.offlineError", defaultValue: "You're offline.", bundle: .module) }
    static var cameraTitle: String { String(localized: "onboarding.camera.title", defaultValue: "Scan the code on your Mac.", bundle: .module) }
    static var cameraBody: String { String(localized: "onboarding.camera.body", defaultValue: "cmux uses the camera only to read the pairing code.", bundle: .module) }
    static var cameraDenied: String { String(localized: "onboarding.camera.denied", defaultValue: "Camera access is off. Turn it on in Settings to scan.", bundle: .module) }
    static var openSettings: String { String(localized: "onboarding.camera.openSettings", defaultValue: "Open Settings", bundle: .module) }
    static var scannerTitle: String { String(localized: "onboarding.scanner.title", defaultValue: "Scan the pairing code", bundle: .module) }
    static var scannerBody: String { String(localized: "onboarding.scanner.body", defaultValue: "Point your camera at the QR code in cmux on your Mac.", bundle: .module) }
    static var scannerPending: String { String(localized: "onboarding.scanner.pending", defaultValue: "The camera scanner arrives with Mac pairing. Use discovery on your account for now.", bundle: .module) }
    static var sampleCode: String { String(localized: "onboarding.scanner.sample", defaultValue: "Use Sample Code", bundle: .module) }
    static var sshTitle: String { String(localized: "onboarding.ssh.title", defaultValue: "Have a server too?", bundle: .module) }
    static var sshBody: String { String(localized: "onboarding.ssh.body", defaultValue: "Add an SSH host now, or later from Hosts.", bundle: .module) }
    static var hostField: String { String(localized: "onboarding.ssh.host", defaultValue: "Host", bundle: .module) }
    static var hostPrompt: String { String(localized: "onboarding.ssh.hostPrompt", defaultValue: "server.example.com", bundle: .module) }
    static var userField: String { String(localized: "onboarding.ssh.user", defaultValue: "User", bundle: .module) }
    static var portField: String { String(localized: "onboarding.ssh.port", defaultValue: "Port", bundle: .module) }
    static var addHost: String { String(localized: "onboarding.ssh.add", defaultValue: "Add Host", bundle: .module) }
    static var sshInvalid: String { String(localized: "onboarding.ssh.invalid", defaultValue: "Enter a host name or address, and a port from 1 to 65535.", bundle: .module) }
    static var celebratePairedTitle: String { String(localized: "onboarding.celebrate.pairedTitle", defaultValue: "You're connected.", bundle: .module) }
    static func celebratePairedBody(_ name: String) -> String {
        String(localized: "onboarding.celebrate.pairedBody", defaultValue: "\(name) is ready. Your agents can reach you now.", bundle: .module)
    }
    static var celebrateTitle: String { String(localized: "onboarding.celebrate.title", defaultValue: "You're all set.", bundle: .module) }
    static var celebrateBody: String { String(localized: "onboarding.celebrate.body", defaultValue: "Connect a Mac anytime from Hosts.", bundle: .module) }
    static var celebrateReadyBody: String { String(localized: "onboarding.celebrate.readyBody", defaultValue: "Your Mac is ready. Your agents can reach you now.", bundle: .module) }
    static var celebrateReplayBody: String { String(localized: "onboarding.celebrate.replayBody", defaultValue: "That's the tour. Your setup is unchanged.", bundle: .module) }
    static var openCmux: String { String(localized: "onboarding.celebrate.open", defaultValue: "Open cmux", bundle: .module) }
    static var done: String { String(localized: "onboarding.celebrate.done", defaultValue: "Done", bundle: .module) }
}
