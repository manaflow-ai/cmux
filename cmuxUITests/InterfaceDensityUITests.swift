import XCTest

/// Renders the real titlebar and sidebar footer at each `app.density` and
/// checks the geometry and hover folding the setting promises.
///
/// Screenshots are kept on the result bundle so reviewers compare the actual
/// app, not a mockup.
final class InterfaceDensityUITests: XCTestCase {
    private var dataPath = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        dataPath = "/tmp/cmux-ui-test-density-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: dataPath)
    }

    @MainActor
    func testComfortableTitlebarAndFooter() {
        checkVisibleDensity("comfortable", buttonSize: 24, footerButtonSize: 26)
    }

    @MainActor
    func testStandardTitlebarAndFooter() {
        checkVisibleDensity("standard", buttonSize: 20, footerButtonSize: 22)
    }

    @MainActor
    func testComfortableMinimalModeSidebarHeader() {
        let app = launch(density: "comfortable", presentationMode: "minimal")
        defer { app.terminate() }
        // Minimal mode reveals its sidebar-header controls on hover.
        let bell = titlebarButton("titlebarControl.showNotifications", in: app)
        bell.hover()
        attachScreenshot(of: app, name: "comfortable, minimal mode, pointer over sidebar header")
    }

    @MainActor
    func testCompactFoldsTitlebarAndFooterActionsUntilHover() {
        let app = launch(density: "compact", presentationMode: "standard", seedsUnread: false)
        defer { app.terminate() }

        let bell = titlebarButton("titlebarControl.showNotifications", in: app)
        let help = app.buttons["SidebarHelpMenuButton"]
        XCTAssertTrue(help.waitForExistence(timeout: 5))

        moveMouseToTerminal(in: app)
        attachScreenshot(of: app, name: "compact, at rest, no unread")
        XCTAssertFalse(bell.isHittable, "Compact titlebar controls stay hidden until the pointer reaches them.")

        bell.hover()
        XCTAssertTrue(waitForHittable(bell), "Hovering the titlebar row reveals the compact controls.")
        attachScreenshot(of: app, name: "compact, pointer over titlebar")
        XCTAssertEqual(bell.frame.width, 20, accuracy: 0.5, "Compact keeps the 20pt minimum hit target.")

        help.hover()
        attachScreenshot(of: app, name: "compact, pointer over sidebar footer")
    }

    @MainActor
    func testCompactKeepsTitlebarVisibleWithUnreadNotification() {
        let app = launch(density: "compact", presentationMode: "standard")
        defer { app.terminate() }

        let bell = titlebarButton("titlebarControl.showNotifications", in: app)
        moveMouseToTerminal(in: app)
        XCTAssertTrue(waitForHittable(bell), "An unread notification keeps the compact titlebar row visible.")
        attachScreenshot(of: app, name: "compact, at rest, unread notification")
    }

    // MARK: - Helpers

    @MainActor
    private func checkVisibleDensity(_ density: String, buttonSize: CGFloat, footerButtonSize: CGFloat) {
        let app = launch(density: density, presentationMode: "standard")
        defer { app.terminate() }

        let bell = titlebarButton("titlebarControl.showNotifications", in: app)
        let forward = titlebarButton("titlebarControl.focusHistoryForward", in: app)
        let help = app.buttons["SidebarHelpMenuButton"]
        XCTAssertTrue(help.waitForExistence(timeout: 5))
        moveMouseToTerminal(in: app)
        attachScreenshot(of: app, name: "\(density), standard titlebar")

        XCTAssertEqual(bell.frame.width, buttonSize, accuracy: 0.5)
        XCTAssertEqual(bell.frame.height, buttonSize, accuracy: 0.5)
        XCTAssertEqual(help.frame.width, footerButtonSize, accuracy: 0.5)

        // The controls row must end before the default 240pt sidebar edge.
        let window = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(
            forward.frame.maxX - window.minX,
            240 - 8,
            "The \(density) titlebar row crosses the sidebar edge."
        )
    }

    @MainActor
    private func launch(density: String, presentationMode: String, seedsUnread: Bool = true) -> XCUIApplication {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        if seedsUnread {
            // Adds a workspace with an unread notification so the badge renders.
            app.launchEnvironment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] = "1"
            app.launchEnvironment["CMUX_UI_TEST_JUMP_UNREAD_PATH"] = dataPath
        }
        app.launchArguments += [
            "-interfaceDensity", density,
            "-workspacePresentationMode", presentationMode,
            "-sidebarMinimumWidth", "240",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        if seedsUnread {
            XCTAssertTrue(waitForFile(atPath: dataPath, timeout: 8), "Unread notification setup did not run.")
        }
        return app
    }

    @MainActor
    private func titlebarButton(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 5), "Missing \(identifier)")
        return element
    }

    /// Parks the pointer over the terminal so hover-revealed chrome settles.
    @MainActor
    private func moveMouseToTerminal(in app: XCUIApplication) {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6)).hover()
        // Let the 0.14 s fade finish before capturing.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    }

    @MainActor
    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isHittable { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return element.isHittable
    }

    private func waitForFile(atPath path: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return FileManager.default.fileExists(atPath: path)
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, name: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
