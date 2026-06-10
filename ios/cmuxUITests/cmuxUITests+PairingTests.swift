import CMUXMobileCore
import Network
import UIKit
import XCTest


// MARK: - Sign-in & Add Device Pairing Tests
extension cmuxUITests {
    @MainActor
    func testStackAuthEntryUsesStableIdentifiers() throws {
        let app = launchApp(mockData: false, clearAuth: true)

        XCTAssertTrue(app.buttons["signin.apple"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["signin.google"].exists)

        let emailField = app.textFields["Email"]
        XCTAssertTrue(emailField.exists)

        let emailCodeButton = app.buttons["signin.emailCode"]
        XCTAssertTrue(emailCodeButton.exists)
        XCTAssertFalse(emailCodeButton.isEnabled)

        try typeText("dogfood@example.com", into: emailField, in: app)
        XCTAssertTrue(emailCodeButton.isEnabled)
    }

    @MainActor
    func testAddDeviceManualHostValidationUsesStableIdentifiers() throws {
        let invalidHostApp = launchAddDeviceApp(environment: [
            "CMUX_UITEST_ADD_DEVICE_HOST": "dev/path.local"
        ])

        XCTAssertTrue(invalidHostApp.otherElements["MobileAddDeviceForm"].waitForExistence(timeout: 8))
        XCTAssertTrue(invalidHostApp.textFields["MobileAddDeviceNameField"].exists)
        XCTAssertTrue(invalidHostApp.textFields["MobileAddDeviceHostField"].exists)
        XCTAssertTrue(invalidHostApp.textFields["MobileAddDevicePortField"].exists)
        XCTAssertTrue(invalidHostApp.staticTexts["MobileAddDeviceSignedInAccount"].exists)
        XCTAssertTrue(invalidHostApp.staticTexts["MobileAddDeviceSignedInAccount"].label.contains("uitest@cmux.local"))
        XCTAssertTrue(invalidHostApp.buttons["MobileScanQRCodeButton"].exists)

        let invalidHostPairButton = invalidHostApp.buttons["MobilePairButton"]
        XCTAssertTrue(invalidHostPairButton.exists)
        XCTAssertTrue(invalidHostPairButton.isEnabled)

        tap(invalidHostPairButton, in: invalidHostApp)
        assertPairingError(contains: "Enter a host or IP address", in: invalidHostApp)
        invalidHostApp.terminate()

        let invalidPortApp = launchAddDeviceApp(environment: [
            "CMUX_UITEST_ADD_DEVICE_HOST": "127.0.0.1",
            "CMUX_UITEST_ADD_DEVICE_PORT": "70000",
        ])
        defer { invalidPortApp.terminate() }
        let invalidPortPairButton = invalidPortApp.buttons["MobilePairButton"]
        XCTAssertTrue(invalidPortPairButton.exists)
        XCTAssertTrue(invalidPortPairButton.isEnabled)

        tap(invalidPortPairButton, in: invalidPortApp)
        assertPairingError(contains: "Enter a port from 1 to 65535", in: invalidPortApp)
    }

    @MainActor
    func testManualHostConnectsAndNavigatesToWorkspace() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)

        try openSelectedWorkspaceIfNeeded(app)
        XCTAssertTrue(app.otherElements["MobileTerminalSurface"].waitForExistence(timeout: 6))
        assertTerminalRow(0, label: "$ cmux ios status", in: app)
        assertTerminalRow(1, label: "Mobile Core: connected", in: app)
        assertTerminalRow(2, label: "host: UI Test Mac", in: app)
    }

    /// Tapping a text field opens the system keyboard; the floating Pair
    /// button (via `.safeAreaInset(edge: .bottom)` with a gradient backdrop)
    /// must remain in the hierarchy and not jump below the keyboard. We can't
    /// reliably XCUI-test the swipe-to-dismiss path against SwiftUI's Form
    /// (the keyboard return key labels differ between iOS versions and
    /// XCUI's keyboard button lookup is fragile), so we cover the visible
    /// invariant instead and rely on manual dogfood for the dismiss gesture.
    @MainActor
    func testAddDevicePairButtonStaysVisibleWhenKeyboardOpens() throws {
        let app = launchAddDeviceApp()

        let hostField = app.textFields["MobileAddDeviceHostField"]
        XCTAssertTrue(hostField.waitForExistence(timeout: 4))
        let pairButton = app.buttons["MobilePairButton"]
        XCTAssertTrue(pairButton.waitForExistence(timeout: 4))

        hostField.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4),
                      "Tapping the host field should bring up the keyboard")

        // The pair button stays in the hierarchy when the keyboard is up,
        // proving the .safeAreaInset placement survives keyboard avoidance.
        XCTAssertTrue(pairButton.exists, "Pair button must remain in the hierarchy with keyboard up")
        XCTAssertGreaterThan(pairButton.frame.height, 30,
                             "Pair button should retain a tappable height when the keyboard is up")
    }

    @MainActor
    private func launchAddDeviceApp(environment: [String: String] = [:]) -> XCUIApplication {
        let app = launchApp(mockData: true, environment: environment)
        XCTAssertTrue(app.otherElements["MobileAddDeviceForm"].waitForExistence(timeout: 8))
        return app
    }

    @MainActor
    private func assertPairingError(
        contains expectedText: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let error = app.staticTexts["MobilePairingError"]
        if !error.waitForExistence(timeout: 4) {
            app.swipeUp()
        }
        XCTAssertTrue(error.waitForExistence(timeout: 4), file: file, line: line)
        XCTAssertTrue(error.label.contains(expectedText), file: file, line: line)
    }

}
