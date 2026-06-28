import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression for the macOS App Management privacy dialog
/// ("X would like to access data from other apps") firing from the
/// phone-forwarding presence gate.
///
/// Why this dialog re-prompts every tagged DEV build: macOS keys the
/// App Management TCC category to bundle ID. `scripts/reload.sh --tag <name>`
/// derives a unique bundle ID per tag (line 519:
/// `BUNDLE_ID="com.cmuxterm.app.debug.${TAG_ID}"`), so the user grants
/// permission to `com.cmuxterm.app.debug.may.18`, opens a new tag
/// `fix-blur-effect`, and the prompt re-fires for
/// `com.cmuxterm.app.debug.fix.blur.effect`.
///
/// What triggered it: `MacPresenceMonitor.liveScreensaverRunning()` called
/// `NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.ScreenSaver.Engine" }`.
/// That enumeration is exactly what fires the App Management TCC prompt.
/// The chain that reaches it on the first notification after launch:
/// `PhonePushClient.forward()` → `presenceCache.decision(...)` →
/// `monitor.evaluate()` → `liveSignals()` → `liveScreensaverRunning()`.
///
/// The fix swaps the enumeration for a notification-driven singleton:
/// `ScreensaverStateTracker` subscribes to
/// `NSWorkspace.screensaverDidStartNotification` and
/// `NSWorkspace.screensaverDidStopNotification`, which are passive system
/// events. They never enumerate apps and never trigger TCC.
///
/// RED state: `ScreensaverStateTracker` does not exist, so this test file
/// does not compile and the cmuxTests target fails to build.
/// GREEN state: after the fix, the singleton exists, starts in the safe
/// "not running" default, and `MacPresenceMonitor.live()` reads from it.
@Suite struct MacPresenceMonitorScreensaverSourceTests {

    @MainActor
    @Test func screensaverStateTrackerSingletonStartsNotRunning() {
        // The fix introduces this singleton. If it does not exist, the test
        // target does not compile, which is the RED state of this
        // two-commit regression test.
        let tracker = ScreensaverStateTracker.shared
        #expect(tracker.isRunning == false)
    }

    @MainActor
    @Test func liveMonitorReadsScreensaverFromTrackerDefault() {
        // Construct the live monitor and evaluate it. Before the fix, this
        // would have called `NSWorkspace.shared.runningApplications` and
        // triggered the App Management dialog on the first notification for
        // any new bundle ID. After the fix, the screensaver signal is
        // sourced from the notifier-driven tracker (defaulting to false on
        // launch). The verdict therefore must NOT be `.awayScreensaverRunning`
        // at boot, regardless of how the rest of the heuristic resolves.
        let monitor = MacPresenceMonitor.live()
        let decision = monitor.evaluate()
        #expect(decision.verdict != .awayScreensaverRunning)
    }
}