import XCTest
import Foundation

final class BrowserImportProfilesUITests: XCTestCase {
    private var capturePath = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        capturePath = "/tmp/cmux-ui-test-browser-import-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: capturePath)
    }

    func testMultipleSourceProfilesDefaultToSeparateDestinations() throws {
        let app = launchApp()

        openImportWizard(app)
        app.buttons["Next"].click()
        app.buttons["Next"].click()

        XCTAssertTrue(
            app.radioButtons["Separate profiles"].waitForExistence(timeout: 5.0),
            "Expected Step 3 to show the separate-profiles default"
        )
        XCTAssertTrue(app.radioButtons["Merge into one"].exists)
        XCTAssertTrue(app.popUpButtons["BrowserImportDestinationPopup-you"].exists)
        XCTAssertTrue(app.popUpButtons["BrowserImportDestinationPopup-austin"].exists)

        app.buttons["Start Import"].click()

        let capture = try XCTUnwrap(waitForCapturedSelection(timeout: 5.0))
        XCTAssertEqual(capture["mode"] as? String, "separateProfiles")
        XCTAssertEqual(capture["scope"] as? String, "cookiesAndHistory")

        let entries = try XCTUnwrap(capture["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0]["sourceProfiles"] as? [String], ["You"])
        XCTAssertEqual(entries[0]["destinationKind"] as? String, "create")
        XCTAssertEqual(entries[0]["destinationName"] as? String, "You")
        XCTAssertEqual(entries[1]["sourceProfiles"] as? [String], ["austin"])
        XCTAssertEqual(entries[1]["destinationKind"] as? String, "create")
        XCTAssertEqual(entries[1]["destinationName"] as? String, "austin")
    }

    func testMergeModeCapturesSingleMergedDestination() throws {
        let app = launchApp()

        openImportWizard(app)
        app.buttons["Next"].click()
        app.buttons["Next"].click()

        let mergeRadio = app.radioButtons["Merge into one"]
        XCTAssertTrue(mergeRadio.waitForExistence(timeout: 5.0))
        mergeRadio.click()

        XCTAssertTrue(
            app.popUpButtons["BrowserImportDestinationPopup-merge"].waitForExistence(timeout: 5.0),
            "Expected merge mode to show the single destination popup"
        )

        app.buttons["Start Import"].click()

        let capture = try XCTUnwrap(waitForCapturedSelection(timeout: 5.0))
        XCTAssertEqual(capture["mode"] as? String, "mergeIntoOne")

        let entries = try XCTUnwrap(capture["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["sourceProfiles"] as? [String], ["You", "austin"])
        XCTAssertEqual(entries[0]["destinationKind"] as? String, "existing")
        XCTAssertEqual(entries[0]["destinationName"] as? String, "Default")
    }

    func testAdditionalDataSelectionCapturesEverythingScope() throws {
        let app = launchApp()

        openImportWizard(app)
        app.buttons["Next"].click()
        app.buttons["Next"].click()

        let cookiesCheckbox = app.checkBoxes["BrowserImportCookiesCheckbox"]
        XCTAssertTrue(cookiesCheckbox.waitForExistence(timeout: 5.0))
        cookiesCheckbox.click()

        let historyCheckbox = app.checkBoxes["BrowserImportHistoryCheckbox"]
        XCTAssertTrue(historyCheckbox.waitForExistence(timeout: 5.0))
        historyCheckbox.click()

        let additionalDataCheckbox = app.checkBoxes["BrowserImportAdditionalDataCheckbox"]
        XCTAssertTrue(
            additionalDataCheckbox.waitForExistence(timeout: 5.0),
            "Expected Step 3 to expose the additional data checkbox"
        )
        additionalDataCheckbox.click()

        app.buttons["Start Import"].click()

        let capture = try XCTUnwrap(waitForCapturedSelection(timeout: 5.0))
        XCTAssertEqual(capture["scope"] as? String, "everything")
    }

    func testWaitForCapturedSelectionReadsCaptureWrittenAtTimeoutBoundary() throws {
        let payload: [String: Any] = [
            "mode": "boundary-write",
            "entries": []
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let captureURL = URL(fileURLWithPath: capturePath)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.19) {
            try? payloadData.write(to: captureURL)
        }

        let capture = try XCTUnwrap(waitForCapturedSelection(timeout: 0.2))
        XCTAssertEqual(capture["mode"] as? String, "boundary-write")
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BROWSER_IMPORT_FIXTURE"] = #"{"browserName":"Helium","profiles":["You","austin"]}"#
        app.launchEnvironment["CMUX_UI_TEST_BROWSER_IMPORT_DESTINATIONS"] = #"["Default"]"#
        app.launchEnvironment["CMUX_UI_TEST_BROWSER_IMPORT_MODE"] = "capture-only"
        app.launchEnvironment["CMUX_UI_TEST_BROWSER_IMPORT_CAPTURE_PATH"] = capturePath
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch in the foreground for browser import UI tests"
        )
        return app
    }

    private func openImportWizard(_ app: XCUIApplication) {
        let viewMenu = app.menuBars.menuBarItems["View"].firstMatch
        XCTAssertTrue(viewMenu.waitForExistence(timeout: 5.0), "Expected View menu to exist")
        viewMenu.click()

        let importItem = app.menuItems["Import From Browser…"].firstMatch
        XCTAssertTrue(importItem.waitForExistence(timeout: 5.0), "Expected Import From Browser menu item to exist")
        importItem.click()

        XCTAssertTrue(
            app.staticTexts["Import Browser Data"].waitForExistence(timeout: 5.0),
            "Expected the import wizard to open"
        )
    }

    private func waitForCapturedSelection(timeout: TimeInterval) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        let url = URL(fileURLWithPath: capturePath)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return object
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        return nil
    }

    private func ensureForegroundAfterLaunch(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if app.wait(for: .runningForeground, timeout: timeout) {
            return true
        }
        if app.state == .runningBackground {
            app.activate()
            return app.wait(for: .runningForeground, timeout: 6.0)
        }
        return false
    }
}
