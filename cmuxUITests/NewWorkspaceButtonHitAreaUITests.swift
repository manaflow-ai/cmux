import XCTest

/// Verifies workspace creation through mouse clicks across the actual titlebar button.
final class NewWorkspaceButtonHitAreaUITests: XCTestCase {
    /// Transparent corners and edges must create exactly one workspace, just like the glyph.
    @MainActor
    func testPrimaryButtonAcceptsClicksAcrossItsFullFrame() {
        continueAfterFailure = false
        let app = XCUIApplication.cmuxTestApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchArguments += [
            "-workspacePresentationMode", "standard",
            "-newWorkspacePlacement", "end",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(workspaceRow(in: app, count: 1).waitForExistence(timeout: 10))

        let button = app.descendants(matching: .any)
            .matching(identifier: "titlebarControl.newTab").firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertTrue(button.isHittable)
        let frame = button.frame
        XCTAssertGreaterThan(frame.width, 10)
        XCTAssertGreaterThan(frame.height, 10)
        attachScreenshot(of: app, name: "Before full-frame clicks: one workspace")

        var expectedCount = 1
        for x in [CGFloat(1), frame.width / 2, frame.width - 1] {
            for y in [CGFloat(1), frame.height / 2, frame.height - 1] {
                XCTContext.runActivity(named: "Click primary frame at (\(x), \(y))") { _ in
                    // Coordinate clicks exercise hit testing; an accessibility press would bypass it.
                    button.coordinate(withNormalizedOffset: .zero)
                        .withOffset(CGVector(dx: x, dy: y)).click()
                    expectedCount += 1
                    XCTAssertTrue(
                        workspaceRow(in: app, count: expectedCount).waitForExistence(timeout: 5),
                        "A click at (\(x), \(y)) must create exactly one workspace (total \(expectedCount))."
                    )
                    XCTAssertEqual(app.windows.count, 1, "The action must stay in the current window.")
                }
            }
        }
        attachScreenshot(of: app, name: "After nine full-frame clicks: ten workspaces")
    }

    /// Uses the sidebar's accessible position/count so virtualization cannot hide the result.
    @MainActor
    private func workspaceRow(in app: XCUIApplication, count: Int) -> XCUIElement {
        app.descendants(matching: .other)
            .matching(NSPredicate(format: "label ENDSWITH %@", "workspace \(count) of \(count)"))
            .firstMatch
    }

    /// Keeps before/after app evidence with the hosted UI test result.
    @MainActor
    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
