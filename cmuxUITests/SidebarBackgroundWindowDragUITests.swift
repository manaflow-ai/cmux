import Darwin
import XCTest

final class SidebarBackgroundWindowDragUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testDraggingEmptySidebarAreaMovesWindow() {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchArguments += [
            "-workspacePresentationMode", "standard",
            "-sidebarPreset", "nativeSidebar",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = "ui-sidebar-background-drag"
        defer { app.terminate() }

        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8), "Expected a main window")

        let sidebar = app.descendants(matching: .any)["Sidebar"].firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "Expected the native sidebar")

        let sidebarFrame = sidebar.frame
        XCTAssertGreaterThan(
            sidebarFrame.height,
            400,
            "Expected a tall sidebar with blank space below the single default workspace. sidebar=\(sidebarFrame)"
        )

        // UI-test mode disables session restore, leaving one default workspace.
        // The middle-lower sidebar is therefore safely below its row and above
        // the footer controls.
        let start = sidebar.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)
        )
        let end = start.withOffset(CGVector(dx: 80, dy: 50))
        let originalFrame = window.frame

        start.press(forDuration: 0.1, thenDragTo: end)

        XCTAssertTrue(
            pollUntil(timeout: 3) {
                let movedFrame = window.frame
                return hypot(
                    movedFrame.origin.x - originalFrame.origin.x,
                    movedFrame.origin.y - originalFrame.origin.y
                ) > 20
            },
            "Dragging empty sidebar background should move the window. before=\(originalFrame) after=\(window.frame)"
        )
    }

    private func pollUntil(
        timeout: TimeInterval,
        interval: TimeInterval = 0.05,
        condition: () -> Bool
    ) -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        while true {
            if condition() { return true }
            if ProcessInfo.processInfo.systemUptime - start >= timeout { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(interval))
        }
    }
}
