import XCTest

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

        // 2) Agent push notification.
        shoot("02-Notifications", [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
            "CMUX_UITEST_NOTIFICATION_BANNER": "1",
        ])

        // 3-6) Each agent, full terminal showing its real recorded session.
        for (idx, agent) in ["claude", "codex", "opencode", "pi"].enumerated() {
            shoot(String(format: "%02d-%@", idx + 3, agent.capitalized), [
                "CMUX_UITEST_TERMINAL_PREVIEW": "1",
                "CMUX_UITEST_TERMINAL_PREVIEW_CONTENT": "1",
                "CMUX_UITEST_TERMINAL_TRANSCRIPT": agent,
            ])
        }
    }

    @MainActor
    private func shoot(_ name: String, _ env: [String: String]) {
        var full = env
        full["CMUX_UITEST_MOCK_DATA"] = "1"
        app.launchEnvironment = full
        app.launch()
        settle()
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
}
