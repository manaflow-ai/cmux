import XCTest

/// App Store screenshot capture, driven by `fastlane snapshot` (see
/// ios/fastlane/Snapfile / Fastfile). Runs against a DEBUG build using the app's
/// standalone preview hooks, which render real UI deterministically with no
/// sign-in, Mac pairing, or network:
///   - CMUX_UITEST_WORKSPACE_LIST_PREVIEW=1 -> workspace list fixture
///   - CMUX_UITEST_TERMINAL_PREVIEW=1        -> terminal surface fixture
/// (CMUX_UITEST_MOCK_DATA alone lands on the add-device/pairing screen, which is
/// signed-in-but-unpaired and not a useful store screenshot.)
///
/// `setupSnapshot(app)` injects the locale fastlane is capturing (en-US / ja),
/// so this test must NOT hardcode `-AppleLanguages`. Each screen is a separate
/// launch with the relevant preview env; `snapshot()` is called after the screen
/// settles.
final class SnapshotUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testCaptureAppStoreScreenshots() throws {
        let app = XCUIApplication()
        setupSnapshot(app)

        // The preview screens are the root view for their env flag, so they
        // render on launch; wait for the first window + a brief settle rather
        // than a specific identifier (the preview views don't expose one).
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func settle() {
            _ = app.wait(for: .runningForeground, timeout: 15)
            _ = app.windows.firstMatch.waitForExistence(timeout: 15)
            _ = app.staticTexts.firstMatch.waitForExistence(timeout: 8)
            // Fresh simulators show a one-time "Ready for Apple Intelligence"
            // banner that overlays the top of the first screen; swipe any
            // notification banner up off-screen, then let layout settle.
            let banner = springboard.otherElements["NotificationShortLookView"]
            if banner.waitForExistence(timeout: 3) {
                banner.swipeUp()
            }
            Thread.sleep(forTimeInterval: 2.0)
        }

        // 1) Workspace list.
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        app.launchEnvironment["CMUX_UITEST_WORKSPACE_LIST_PREVIEW"] = "1"
        app.launch()
        settle()
        snapshot("01-Workspaces")
        app.terminate()

        // 2) Terminal surface with a sample agent session (keyboard down).
        app.launchEnvironment["CMUX_UITEST_WORKSPACE_LIST_PREVIEW"] = nil
        app.launchEnvironment["CMUX_UITEST_TERMINAL_PREVIEW"] = "1"
        app.launchEnvironment["CMUX_UITEST_TERMINAL_PREVIEW_CONTENT"] = "1"
        app.launch()
        settle()
        snapshot("02-Terminal")

        // 3) Terminal with the software keyboard up (input layout).
        app.terminate()
        app.launchEnvironment["CMUX_UITEST_FAKE_KEYBOARD_HEIGHT"] = "336"
        app.launch()
        settle()
        snapshot("03-Terminal-Keyboard")
    }
}
