import XCTest

final class CloudAnnouncementPreviewUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testPreviewSwitchesTreatmentsInSidebarAndDismisses() {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_AUTO_ALLOW_PERMISSION"] = "1"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        app.activate()

        let help = app.buttons["SidebarHelpMenuButton"]
        XCTAssertTrue(help.waitForExistence(timeout: 15))
        app.menuBars.menuBarItems["Debug"].click()
        app.menuItems["Debug Windows"].hover()
        let previewMenu = app.menuItems["Cloud Announcement…"]
        XCTAssertTrue(previewMenu.waitForExistence(timeout: 5))
        previewMenu.click()

        let announcement = app.buttons["CloudAnnouncementOpen"]
        for style in ["row", "note", "pill", "hint"] {
            let choice = app.buttons["CloudAnnouncementChoose.\(style)"]
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            choice.click()
            XCTAssertTrue(announcement.waitForExistence(timeout: 5))
            XCTAssertTrue(announcement.isHittable)
            XCTAssertEqual(announcement.label, "cmux Cloud is here")

            // The pill sits immediately after help; the other treatments stay
            // above it, inside the sidebar, without covering the terminal.
            let bounds = announcement.frame
            let helpBounds = help.frame
            if style == "pill" {
                XCTAssertGreaterThanOrEqual(bounds.minX, helpBounds.maxX)
                XCTAssertEqual(bounds.midY, helpBounds.midY, accuracy: 2)
            } else {
                XCTAssertLessThanOrEqual(bounds.maxY, helpBounds.minY)
                XCTAssertLessThan(bounds.width, 320)
            }
            XCTAssertFalse(bounds.intersects(helpBounds))

            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Cloud announcement — \(style)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        app.buttons["CloudAnnouncementPreviewDismiss"].click()
        XCTAssertTrue(announcement.waitForNonExistence(timeout: 5))
        app.buttons["CloudAnnouncementReplay"].click()
        XCTAssertTrue(announcement.waitForExistence(timeout: 5))

        // Dismiss from the actual notification, then confirm help still works.
        announcement.hover()
        let dismiss = app.buttons["CloudAnnouncementDismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        dismiss.click()
        XCTAssertTrue(announcement.waitForNonExistence(timeout: 5))
        help.click()
        XCTAssertTrue(app.buttons["SidebarHelpMenuOptionChangelog"].waitForExistence(timeout: 5))
    }
}
