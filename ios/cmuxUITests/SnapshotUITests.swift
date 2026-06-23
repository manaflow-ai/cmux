import XCTest

/// App Store screenshot capture, driven by `fastlane snapshot` (see
/// ios/fastlane/Snapfile). Runs against a DEBUG build with the existing
/// `CMUX_UITEST_MOCK_DATA` hook, which skips onboarding and lands on a
/// signed-in shell populated with the PreviewMobileHost sample workspaces, so no
/// Apple sign-in, Mac pairing, or network is required.
///
/// `setupSnapshot(app)` injects the locale fastlane is capturing (en-US / ja),
/// so this test must NOT hardcode `-AppleLanguages` the way the functional UI
/// tests do.
///
/// Selectors mirror the accessibility identifiers used in cmuxUITests.swift
/// (`MobileWorkspaceList`, `MobileTerminalSurface`, ...). Capture is best-effort
/// per screen so a layout change degrades to fewer screenshots rather than a
/// hard failure.
final class SnapshotUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testCaptureAppStoreScreenshots() throws {
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "1"
        app.launch()

        let workspaceList = app.otherElements["MobileWorkspaceList"]
        let terminalSurface = app.otherElements["MobileTerminalSurface"]

        // 1) Workspace list with sample workspaces.
        if workspaceList.waitForExistence(timeout: 30) {
            snapshot("01-Workspaces")

            // Drill into the first workspace to reach the terminal, unless the
            // shell already auto-opened one.
            if !terminalSurface.exists {
                let firstCell = workspaceList.buttons.firstMatch
                if firstCell.waitForExistence(timeout: 5), firstCell.isHittable {
                    firstCell.tap()
                }
            }
        }

        // 2) Terminal surface.
        if terminalSurface.waitForExistence(timeout: 30) {
            snapshot("02-Terminal")

            // 3) Composer / keyboard-up layout, if reachable.
            let composeButton = app.buttons["terminal.inputAccessory.composeButton"]
                .exists ? app.buttons["terminal.inputAccessory.composeButton"]
                        : app.buttons.matching(NSPredicate(format: "identifier CONTAINS 'compose'")).firstMatch
            if composeButton.exists, composeButton.isHittable {
                composeButton.tap()
                snapshot("03-Compose")
            }
        }
    }
}
