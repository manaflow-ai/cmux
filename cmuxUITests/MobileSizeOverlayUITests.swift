import Foundation
import XCTest

final class MobileSizeOverlayUITests: XCTestCase {
    private var diagnosticsPath = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        diagnosticsPath = "/tmp/cmux-ui-mobile-size-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
        super.tearDown()
    }

    func testLaunchHookShowsActiveAreaOverlay() throws {
        let app = XCUIApplication()
        addTeardownBlock { app.terminate() }
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_MOBILE_SIZE_OVERLAY_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_MOBILE_SIZE_OVERLAY_COLUMNS"] = "80"
        app.launchEnvironment["CMUX_UI_TEST_MOBILE_SIZE_OVERLAY_ROWS"] = "24"
        app.launchEnvironment["CMUX_UI_TEST_MOBILE_SIZE_OVERLAY_LOCAL_COLUMNS"] = "120"
        app.launchEnvironment["CMUX_UI_TEST_MOBILE_SIZE_OVERLAY_LOCAL_ROWS"] = "40"
        app.launchEnvironment["CMUX_UI_TEST_MOBILE_SIZE_OVERLAY_KIND"] = "iPad"
        app.launchEnvironment["CMUX_UI_TEST_MOBILE_SIZE_OVERLAY_DEVICE_NAME"] = "iPad"
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        app.launchEnvironment["CMUX_TAG"] = "uiiosm"
        launchAndAllowBackground(app)

        XCTAssertTrue(
            waitForDiagnostics(timeout: 12.0) { diagnostics in
                diagnostics["mobileSizeOverlayApplied"] == "1" &&
                    diagnostics["mobileSizeOverlayVisible"] == "1" &&
                    diagnostics["mobileSizeOverlayGeometryVisible"] == "1" &&
                    diagnostics["mobileSizeOverlayLabelText"]?.contains("iPad") == true
            },
            "Expected launch hook to apply the mobile active-area overlay. diagnostics=\(loadDiagnostics() ?? [:])"
        )

        let overlayLabel = app.staticTexts.matching(identifier: "terminal.mobileSizeOverlay.label").firstMatch
        let fallbackLabel = app.staticTexts["Sized for iPad"]
        if overlayLabel.waitForExistence(timeout: 2.0) || fallbackLabel.waitForExistence(timeout: 1.0) {
            let visibleLabel = overlayLabel.exists ? overlayLabel : fallbackLabel
            let labelText = visibleLabel.label.isEmpty ? (visibleLabel.value as? String ?? "") : visibleLabel.label
            XCTAssertTrue(labelText.contains("iPad"), "Expected overlay label to name the remote device, saw \(labelText)")
        }
    }

    private func launchAndAllowBackground(_ app: XCUIApplication) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }

        if app.state == .runningForeground || app.state == .runningBackground {
            return
        }

        XCTFail("App failed to start for mobile size overlay test. state=\(app.state.rawValue)")
    }

    private func loadDiagnostics() -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: diagnosticsPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return json
    }

    private func waitForDiagnostics(
        timeout: TimeInterval,
        predicate: ([String: String]) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let diagnostics = loadDiagnostics(), predicate(diagnostics) {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return false
    }
}
