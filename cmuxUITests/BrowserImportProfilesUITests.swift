import XCTest
import Foundation

private func browserImportPollUntil(
    timeout: TimeInterval,
    pollInterval: TimeInterval = 0.05,
    condition: () -> Bool
) -> Bool {
    let start = ProcessInfo.processInfo.systemUptime
    while true {
        if condition() {
            return true
        }
        if (ProcessInfo.processInfo.systemUptime - start) >= timeout {
            return false
        }
        RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
    }
}

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

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.18) {
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
        launchAndActivate(app)
        return app
    }

    private func openImportWizard(_ app: XCUIApplication) {
        let viewMenu = app.menuBars.menuBarItems["View"].firstMatch
        XCTAssertTrue(viewMenu.waitForExistence(timeout: 5.0), "Expected View menu to exist")
        viewMenu.click()

        let importItem = app.menuItems["Import From Browser…"].firstMatch
        XCTAssertTrue(importItem.waitForExistence(timeout: 5.0), "Expected Import From Browser menu item to exist")
        importItem.click()

        let wizardOpened = browserImportPollUntil(timeout: 5.0) {
            app.buttons["Next"].exists || app.windows["Import Browser Data"].exists
        }
        XCTAssertTrue(wizardOpened, "Expected the import wizard to open")
    }

    private func waitForCapturedSelection(timeout: TimeInterval) -> [String: Any]? {
        let url = URL(fileURLWithPath: capturePath)
        let foundCapture = browserImportPollUntil(timeout: timeout) {
            if let data = try? Data(contentsOf: url),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return !object.isEmpty
            }
            return false
        }
        if foundCapture,
           let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        return nil
    }

    private func launchAndActivate(_ app: XCUIApplication, activateTimeout: TimeInterval = 2.0) {
        app.launch()
        let activated = browserImportPollUntil(timeout: activateTimeout) {
            guard app.state != .runningForeground else {
                return true
            }
            app.activate()
            return app.state == .runningForeground
        }
        if !activated {
            app.activate()
        }
    }
}
