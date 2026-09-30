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
        // Minimal mode reveals its sidebar-header controls on hover, and hidden
        // controls leave the accessibility tree, so hover by position first.
        hoverTitlebarRow(in: app)
        let bell = titlebarButton("titlebarControl.showNotifications", in: app)
        // Minimal mode's clickable layer is an AppKit proxy with its own
        // accessibility frame, so check reveal here, not the drawn width.
        XCTAssertTrue(revealed(bell, in: app, after: "hovering the sidebar header"), "Hovering the sidebar header reveals its controls.")
        attachScreenshot(of: app, name: "comfortable, minimal mode, pointer over sidebar header")
    }

    @MainActor
    func testCompactFoldsTitlebarAndFooterActionsUntilHover() {
        let app = launch(density: "compact", presentationMode: "standard", seedsUnread: false)
        defer { app.terminate() }

        moveMouseToTerminal(in: app)
        let bell = element("titlebarControl.showNotifications", in: app)
        XCTAssertTrue(
            waitForNotHittable(bell),
            "Compact titlebar controls stay hidden until the pointer reaches them."
        )
        attachScreenshot(of: app, name: "compact, at rest, no unread")

        hoverTitlebarRow(in: app)
        XCTAssertTrue(revealed(bell, in: app, after: "hovering the titlebar row"), "Hovering the titlebar row reveals the compact controls.")
        attachScreenshot(of: app, name: "compact, pointer over titlebar")
        XCTAssertEqual(bell.frame.width, 20, accuracy: 0.5, "Compact keeps the 20pt minimum hit target.")

        // The footer fold is a fade, not a removal: folded footer buttons stay
        // hit-testable on purpose, because hover is the only way to reveal them
        // and VoiceOver cannot hover. So accessibility cannot tell folded from
        // shown here, and a hittable check after the hover would pass even if
        // the footer never folded. What this step can pin is the reachability
        // contract, before and after the hover; the fade itself is covered by
        // `compactDensityFoldsOnlySidebarFooterActions` and by the screenshots.
        let help = sidebarHelpButton(in: app)
        XCTAssertTrue(
            waitForHittable(help),
            "Folded footer actions stay reachable for people who cannot hover."
        )
        hoverSidebarFooter(in: app)
        XCTAssertTrue(
            waitForHittable(help),
            "Hovering the sidebar footer keeps its actions reachable."
        )
        attachScreenshot(of: app, name: "compact, pointer over sidebar footer")
    }

    @MainActor
    func testCompactKeepsTitlebarVisibleWithUnreadNotification() {
        let app = launch(density: "compact", presentationMode: "standard")
        defer { app.terminate() }

        let bell = titlebarButton("titlebarControl.showNotifications", in: app)
        moveMouseToTerminal(in: app)
        XCTAssertTrue(waitForHittable(bell), "An unread notification keeps the compact titlebar row visible.")
        // The folded footer buttons stay in the accessibility tree on purpose
        // (VoiceOver cannot hover to reveal them), so accessibility cannot
        // tell folded from shown; the capture below shows the footer folded.
        attachScreenshot(of: app, name: "compact, at rest, unread notification")
    }

    // MARK: - Helpers

    @MainActor
    private func checkVisibleDensity(_ density: String, buttonSize: CGFloat, footerButtonSize: CGFloat) {
        let app = launch(density: density, presentationMode: "standard")
        defer { app.terminate() }

        let bell = titlebarButton("titlebarControl.showNotifications", in: app)
        let forward = titlebarButton("titlebarControl.focusHistoryForward", in: app)
        let help = sidebarHelpButton(in: app)
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
        // The pointer keeps its position between tests; start away from chrome
        // so a previous test's hover does not carry over.
        moveMouseToTerminal(in: app)
        if seedsUnread {
            XCTAssertTrue(waitForFile(atPath: dataPath, timeout: 8), "Unread notification setup did not run.")
        }
        return app
    }

    /// Looks an element up by identifier regardless of its accessibility role.
    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The sidebar footer's help button. Its accessibility identifier is
    /// replaced by the enclosing sidebar's, so match the label instead.
    @MainActor
    private func sidebarHelpButton(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .other)
            .matching(NSPredicate(format: "label == %@", "Help"))
            .firstMatch
    }

    @MainActor
    private func titlebarButton(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let element = element(identifier, in: app)
        XCTAssertTrue(element.waitForExistence(timeout: 5), "Missing \(identifier)")
        return element
    }

    /// Points at the bell's slot in the titlebar row (window coordinates).
    @MainActor
    private func hoverTitlebarRow(in app: XCUIApplication) {
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 110, dy: 14)).hover()
    }

    /// Points at the help button's slot in the sidebar footer.
    @MainActor
    private func hoverSidebarFooter(in app: XCUIApplication) {
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 36, dy: window.frame.height - 37)).hover()
    }

    /// Parks the pointer over the terminal, away from hover-revealed chrome.
    @MainActor
    private func moveMouseToTerminal(in app: XCUIApplication) {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6)).hover()
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

    /// Waits until the element is absent or no longer hittable; folded
    /// controls leave the accessibility tree entirely.
    @MainActor
    private func waitForNotHittable(_ element: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !(element.exists && element.isHittable) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !(element.exists && element.isHittable)
    }

    /// Waits for a hover to reveal `element`. On a miss it attaches where the
    /// pointer went and what accessibility reports for the window, so a CI
    /// failure shows the state the reveal missed, not only the assertion.
    @MainActor
    private func revealed(_ element: XCUIElement, in app: XCUIApplication, after action: String) -> Bool {
        if waitForHittable(element) { return true }
        let window = app.windows.firstMatch
        let controls = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "titlebarControl."))
            .allElementsBoundByIndex
            .map { "\($0.identifier) frame=\($0.frame) hittable=\($0.isHittable)" }
        let summary = [
            "Not revealed after \(action).",
            "window frame=\(window.frame)",
            "element exists=\(element.exists) frame=\(element.frame)",
            "titlebar controls in the tree: \(controls.isEmpty ? "none" : controls.joined(separator: "; "))",
        ].joined(separator: "\n")
        let notes = XCTAttachment(string: summary + "\n\n" + window.debugDescription)
        notes.name = "not revealed after \(action)"
        notes.lifetime = .keepAlways
        add(notes)
        return false
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
        // Assertions wait on state; the capture alone waits out the 0.14 s
        // fade so it shows the settled chrome, not a frame mid-animation.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
