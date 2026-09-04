import XCTest
import UIKit

/// App Store screenshot capture, driven by `fastlane snapshot` (see
/// ios/fastlane/Snapfile / Fastfile). Runs against a DEBUG build using the app's
/// standalone preview hooks, which render real UI deterministically with no
/// sign-in, Mac pairing, or network. The terminal shots replay REAL recorded
/// agent sessions (see TerminalPreviewTranscripts). Each shot is a separate
/// launch with a fresh environment; `snapshot()` is called after the screen
/// settles.
///
/// The shot roster mirrors the live App Store listing 1:1 (see
/// ios/fastlane/appstore-shots-plan.json; `ios/scripts/appstore-shots.sh`
/// post-processes captures to exact ASC pixel dimensions and stages uploads).
/// Numbering matches the listing order. 05 (lock-screen inline reply) cannot be
/// driven from XCUITest and is produced by `appstore-shots.sh lockshot`.
final class SnapshotUITests: XCTestCase {
    private let app = XCUIApplication()
    private lazy var springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testCaptureAppStoreScreenshots() throws {
        setupSnapshot(app)

        // 01/02) Claude + Codex, full terminal showing a real recorded session.
        // TARGET_COLS auto-fits the font so the 76-col fixtures fill the width
        // edge-to-edge on both iPhone and iPad. The believable workspace name
        // shown in the nav title pill belongs to each recorded transcript
        // (re-record with ios/fastlane/frame_assets/record_sessions.sh). The
        // terminal background is auto-derived from each transcript's own
        // dominant background (TerminalPreviewTranscripts.dominantBackgroundHex).
        shootTerminal("01-Claude", transcript: "claude", title: "App entry point")
        shootTerminal("02-Codex", transcript: "codex", title: "Readability pass")

        // 03) Workspace list.
        shoot("03-Workspaces", [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
        ])

        // 04) Notifications feed tab.
        shoot("04-Notifications", [
            "CMUX_UITEST_NOTIFICATION_FEED_PREVIEW": "1",
        ])

        // 06) Per-file diff: ChangesPreviewView mode "diff" opens directly on
        // the Sources/SessionStore.swift fixture.
        shoot("06-DiffFile", [
            "CMUX_UITEST_CHANGES_PREVIEW": "diff",
        ])

        // 07) OpenCode session.
        shootTerminal("07-Opencode", transcript: "opencode", title: "String catalogs")

        // 08) Task Composer.
        shoot("08-Composer", [
            "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
        ])

        // 09) A REAL agent push notification over the workspace list: the app
        // requests authorization and schedules a genuine local notification, so
        // the system renders the actual banner (real icon, "cmux" display name).
        // Source for the framed marketing pages; excluded from the 6.9" store
        // set by the plan.
        shoot("09-Banner", [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
            "CMUX_UITEST_NOTIFICATION_BANNER": "1",
        ], waitForRealNotification: true)

        // 10) Pi session (kept out of the store set by the plan).
        shootTerminal("10-Pi", transcript: "pi", title: "Ship improvements")
    }

    @MainActor
    private func shootTerminal(_ name: String, transcript: String, title: String) {
        shoot(name, [
            "CMUX_UITEST_TERMINAL_PREVIEW": "1",
            "CMUX_UITEST_TERMINAL_PREVIEW_CONTENT": "1",
            "CMUX_UITEST_TERMINAL_TRANSCRIPT": transcript,
            "CMUX_UITEST_TERMINAL_TARGET_COLS": "76",
            "CMUX_UITEST_TERMINAL_TITLE": title,
        ])
    }

    @MainActor
    private func shoot(_ name: String, _ env: [String: String], waitForRealNotification: Bool = false) {
        var full = env
        full["CMUX_UITEST_MOCK_DATA"] = "1"
        // Workspace detail can show a one-time educational changes hint over
        // the content. It is not listing content, so keep it out of every
        // store capture and assert that the fixture honors the contract.
        full["CMUX_UITEST_HIDE_WORKSPACE_CHANGES_HINT"] = "1"
        app.launchEnvironment = full
        app.launch()
        // The live App Store 13" iPad set is portrait full-bleed; landscape
        // remains available for framed marketing compositions via
        // SNAPSHOT_IPAD_LANDSCAPE=1 (see Fastfile).
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation =
                ProcessInfo.processInfo.environment["SNAPSHOT_IPAD_LANDSCAPE"] == "1"
                    ? .landscapeLeft : .portrait
        }
        if waitForRealNotification {
            settleForNotification()
        } else {
            settle()
        }
        if full["CMUX_UITEST_HIDE_WORKSPACE_CHANGES_HINT"] == "1" {
            let hint = app.descendants(matching: .any)
                .matching(identifier: "MobileChangesHint")
                .firstMatch
            XCTAssertFalse(
                hint.waitForExistence(timeout: 1),
                "workspace changes education banner must not be present in screenshots"
            )
        }
        snapshot(name)
        app.terminate()
    }

    @MainActor
    private func settle() {
        _ = app.wait(for: .runningForeground, timeout: 15)
        _ = app.windows.firstMatch.waitForExistence(timeout: 15)
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: 8)
        // Fresh simulators show a one-time "Ready for Apple Intelligence" banner
        // that overlays the top; swipe any notification banner off-screen, then
        // let layout/terminal output settle.
        let banner = springboard.otherElements["NotificationShortLookView"]
        if banner.waitForExistence(timeout: 3) {
            banner.swipeUp()
        }
        Thread.sleep(forTimeInterval: 2.5)
    }

    /// Settle path for the notification shot: grant the authorization prompt,
    /// then wait for the app's real local notification banner to appear (and
    /// leave it on screen for the snapshot).
    @MainActor
    private func settleForNotification() {
        _ = app.wait(for: .runningForeground, timeout: 15)
        _ = app.windows.firstMatch.waitForExistence(timeout: 15)
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: 8)
        // The app requests notification authorization on appear; approve the
        // springboard system alert so the banner can be delivered.
        let allowLabels = ["Allow", "許可", "許可する"]
        for label in allowLabels {
            let allow = springboard.buttons[label]
            if allow.waitForExistence(timeout: 4) {
                allow.tap()
                break
            }
        }
        // The scheduled local notification fires ~0.6s after the grant and the
        // foreground banner is on screen for ~5s. Querying the banner element is
        // unreliable (it's a system-process overlay, and waiting past its
        // lifetime captures an empty screen), so snapshot at a fixed time inside
        // the banner's visible window.
        Thread.sleep(forTimeInterval: 2.5)
    }
}
