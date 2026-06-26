import XCTest
import UIKit

/// App Store screenshot capture, driven by `fastlane snapshot` (see
/// ios/fastlane/Snapfile / Fastfile). Runs against a DEBUG build using the app's
/// standalone preview hooks, which render real UI deterministically with no
/// sign-in, Mac pairing, or network. The terminal shots replay REAL recorded
/// agent sessions (see TerminalPreviewTranscripts). Each shot is a separate
/// launch with a fresh environment; `snapshot()` is called after the screen
/// settles. fastlane `frameit` later adds the real device frame, background, and
/// localized title.
final class SnapshotUITests: XCTestCase {
    private let app = XCUIApplication()
    private lazy var springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testCaptureAppStoreScreenshots() throws {
        setupSnapshot(app)

        // 1) Workspace list.
        shoot("01-Workspaces", [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
        ])

        // 2) A REAL agent push notification over the workspace list: the app
        // requests authorization and schedules a genuine local notification, so
        // the system renders the actual banner (real icon, "cmux" display name).
        shoot("02-Notifications", [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
            "CMUX_UITEST_NOTIFICATION_BANNER": "1",
        ], waitForRealNotification: true)

        // 3-6) Each agent, full terminal showing its real recorded session.
        // TARGET_COLS auto-fits the font so the 76-col fixtures fill the width
        // edge-to-edge on both iPhone and iPad.
        // Believable workspace/session name per agent, shown in the nav bar
        // titlebar (mirrors the real terminal screen).
        let titles = ["claude": "App entry point", "codex": "Readability pass",
                      "opencode": "String catalogs", "pi": "Ship improvements"]
        // OpenCode's TUI paints its content on its own near-black background, so
        // render that shot with a matching terminal default background (#0a0a0a)
        // — otherwise reset / unpadded cells fall back to Monokai #272822 and
        // show as olive boxes.
        let backgrounds = ["opencode": "#0a0a0a"]
        for (idx, agent) in ["claude", "codex", "opencode", "pi"].enumerated() {
            var env = [
                "CMUX_UITEST_TERMINAL_PREVIEW": "1",
                "CMUX_UITEST_TERMINAL_PREVIEW_CONTENT": "1",
                "CMUX_UITEST_TERMINAL_TRANSCRIPT": agent,
                "CMUX_UITEST_TERMINAL_TARGET_COLS": "76",
                "CMUX_UITEST_TERMINAL_TITLE": titles[agent] ?? "cmux",
            ]
            if let bg = backgrounds[agent] {
                env["CMUX_UITEST_TERMINAL_BG"] = bg
            }
            shoot(String(format: "%02d-%@", idx + 3, agent.capitalized), env)
        }
    }

    @MainActor
    private func shoot(_ name: String, _ env: [String: String], waitForRealNotification: Bool = false) {
        var full = env
        full["CMUX_UITEST_MOCK_DATA"] = "1"
        app.launchEnvironment = full
        app.launch()
        // iPad screenshots are captured in landscape.
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        if waitForRealNotification {
            settleForNotification()
        } else {
            settle()
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
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 8) {
            allow.tap()
        }
        // The scheduled local notification fires ~1.5s later; wait for the real
        // banner and leave it up for the snapshot (do NOT swipe it away).
        let banner = springboard.otherElements["NotificationShortLookView"]
        _ = banner.waitForExistence(timeout: 12)
        Thread.sleep(forTimeInterval: 1.0)
    }
}
