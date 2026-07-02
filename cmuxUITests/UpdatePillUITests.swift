import XCTest
import Foundation

// UI runners can adjust wall clock time mid-test; use monotonic uptime for polling deadlines.
private func pollUntil(
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

final class UpdatePillUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testUpdatePillShowsForAvailableUpdate() {
        let systemSettings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        systemSettings.terminate()
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_UPDATE_STATE"] = "available"
        app.launchEnvironment["CMUX_UI_TEST_UPDATE_VERSION"] = "9.9.9"
        launchAndActivate(app)

        let pill = pillButton(app: app, expectedLabel: "Update Available: 9.9.9")
        XCTAssertTrue(pill.waitForExistence(timeout: 6.0))
        XCTAssertEqual(pill.label, "Update Available: 9.9.9")
        assertVisibleSize(pill)
        attachScreenshot(name: "update-available")
        // Element screenshots are flaky on the UTM VM (image creation fails intermittently).
        // Keep a stable attachment with element state instead.
        attachElementDebug(name: "update-available-pill", element: pill)
    }

    func testDetectedBackgroundUpdateShowsPillWithoutManualCheck() {
        let systemSettings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        systemSettings.terminate()
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_DETECTED_UPDATE_VERSION"] = "9.9.9"
        launchAndActivate(app)

        let pill = pillButton(app: app, expectedLabel: "Update Available: 9.9.9")
        XCTAssertTrue(pill.waitForExistence(timeout: 6.0))
        XCTAssertEqual(pill.label, "Update Available: 9.9.9")
        assertVisibleSize(pill)
        attachScreenshot(name: "background-detected-update-available")
    }

    func testDetectedBackgroundUpdateFirstClickOpensPopover() {
        let systemSettings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        systemSettings.terminate()

        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_DETECTED_UPDATE_VERSION"] = "9.9.9"
        app.launchEnvironment["CMUX_UI_TEST_FEED_URL"] = "https://cmux.test/appcast.xml"
        app.launchEnvironment["CMUX_UI_TEST_FEED_MODE"] = "none"
        launchAndActivate(app)

        let pill = pillButton(app: app, expectedLabel: "Update Available: 9.9.9")
        XCTAssertTrue(pill.waitForExistence(timeout: 6.0))
        assertVisibleSize(pill)

        pill.click()

        XCTAssertTrue(
            app.staticTexts["Update Available"].waitForExistence(timeout: 8.0),
            "Expected the first click on a background-detected update pill to open the popover"
        )
        XCTAssertTrue(
            app.buttons["Install and Relaunch"].waitForExistence(timeout: 2.0),
            "Expected cached update info to show the install action without running a new update check"
        )
    }

    func testUpdatePillShowsForNoUpdateThenDismisses() {
        let systemSettings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        systemSettings.terminate()
        let timingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ui-test-timing-\(UUID().uuidString).json")
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_UPDATE_STATE"] = "notFound"
        app.launchEnvironment["CMUX_UI_TEST_TIMING_PATH"] = timingPath.path
        launchAndActivate(app)

        let pill = pillButton(app: app, expectedLabel: "No Updates Available")
        XCTAssertTrue(pill.waitForExistence(timeout: 6.0))
        XCTAssertEqual(pill.label, "No Updates Available")
        assertVisibleSize(pill)
        attachScreenshot(name: "no-updates")
        attachElementDebug(name: "no-updates-pill", element: pill)

        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: pill
        )
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 7.0), .completed)

        let payload = loadTimingPayload(from: timingPath)
        let shownAt = payload["noUpdateShownAt"] ?? 0
        let hiddenAt = payload["noUpdateHiddenAt"] ?? 0
        XCTAssertGreaterThan(shownAt, 0)
        XCTAssertGreaterThan(hiddenAt, shownAt)
        XCTAssertGreaterThanOrEqual(hiddenAt - shownAt, 4.8)
    }

    func testCheckForUpdatesUsesMockFeedWithUpdate() {
        let systemSettings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        systemSettings.terminate()
        let app = launchAppWithMockFeed(mode: "available", version: "9.9.9")

        let pill = pillButton(app: app, expectedLabel: "Update Available: 9.9.9")
        XCTAssertTrue(pill.waitForExistence(timeout: 6.0))
        XCTAssertEqual(pill.label, "Update Available: 9.9.9")
        assertVisibleSize(pill)
        attachScreenshot(name: "mock-update-available")
    }

    func testCheckForUpdatesUsesMockFeedWithNoUpdate() {
        let systemSettings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        systemSettings.terminate()
        let timingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ui-test-timing-\(UUID().uuidString).json")
        let app = launchAppWithMockFeed(mode: "none", version: "9.9.9", timingPath: timingPath)

        let pill = pillButton(app: app, expectedLabel: "No Updates Available")
        XCTAssertTrue(pill.waitForExistence(timeout: 6.0))
        XCTAssertEqual(pill.label, "No Updates Available")
        assertVisibleSize(pill)
        attachScreenshot(name: "mock-no-updates")
    }

    func testCheckForUpdatesShowsLoadingThenNoUpdateInSidebarFooter() {
        let systemSettings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        systemSettings.terminate()
        let app = launchAppWithMockFeed(
            mode: "none",
            version: "9.9.9",
            extraEnvironment: [
                "CMUX_UI_TEST_MOCK_FEED_DELAY_MS": "7000",
            ]
        )

        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 6.0))

        let checkingPill = pillButton(app: app, expectedLabel: "Checking for Updates…")
        XCTAssertTrue(checkingPill.waitForExistence(timeout: 6.0))
        assertVisibleSize(checkingPill)

        let noUpdatePill = pillButton(app: app, expectedLabel: "No Updates Available")
        XCTAssertTrue(noUpdatePill.waitForExistence(timeout: 8.0))
        assertVisibleSize(noUpdatePill)
    }

    func testBackgroundDetectedUpdateKeepsOnlyBottomUpdatePill() {
        let systemSettings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        systemSettings.terminate()
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_DETECTED_UPDATE_VERSION"] = "9.9.9"
        app.launchEnvironment["CMUX_UI_TEST_UPDATE_STATE"] = "available"
        app.launchEnvironment["CMUX_UI_TEST_UPDATE_VERSION"] = "9.9.9"
        launchAndActivate(app)

        let pill = pillButton(app: app, expectedLabel: "Update Available: 9.9.9")
        XCTAssertTrue(pill.waitForExistence(timeout: 6.0))
        assertVisibleSize(pill)
        XCTAssertFalse(app.otherElements["SidebarUpdateBanner"].exists)
        XCTAssertFalse(app.buttons["SidebarUpdateBannerAction"].exists)
    }

    func testNoSparklePermissionDialogIsShown() {
        let systemSettings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        systemSettings.terminate()

        let app = XCUIApplication()
        // Make Sparkle re-request permission on startup, but we should auto-handle it with no UI.
        app.launchEnvironment["CMUX_UI_TEST_RESET_SPARKLE_PERMISSION"] = "1"
        launchAndActivate(app)

        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 6.0))

        // Sparkle's default permission prompt is an NSAlert with these labels.
        XCTAssertFalse(app.staticTexts["Check for updates automatically?"].waitForExistence(timeout: 2.0))
        XCTAssertFalse(app.buttons["Don't Check"].exists)
        XCTAssertFalse(app.buttons["Check Automatically"].exists)
    }

    func testUpdatePillShowsDownloadingState() {
        let systemSettings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        systemSettings.terminate()
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_UPDATE_STATE"] = "downloading"
        launchAndActivate(app)

        let pill = pillButton(app: app, expectedLabel: "Downloading: 50%")
        XCTAssertTrue(pill.waitForExistence(timeout: 6.0))
        XCTAssertEqual(pill.label, "Downloading: 50%")
        assertVisibleSize(pill)
        attachScreenshot(name: "update-downloading")
    }

    func testUpdatePillShowsExtractingState() {
        let systemSettings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        systemSettings.terminate()
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_UPDATE_STATE"] = "extracting"
        launchAndActivate(app)

        let pill = pillButton(app: app, expectedLabel: "Preparing: 50%")
        XCTAssertTrue(pill.waitForExistence(timeout: 6.0))
        XCTAssertEqual(pill.label, "Preparing: 50%")
        assertVisibleSize(pill)
        attachScreenshot(name: "update-extracting")
    }

    func testUpdatePillShowsInstallingStateAndRestartPopover() {
        let systemSettings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        systemSettings.terminate()
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_UPDATE_STATE"] = "installing"
        launchAndActivate(app)

        let pill = pillButton(app: app, expectedLabel: "Installing…")
        XCTAssertTrue(pill.waitForExistence(timeout: 6.0))
        XCTAssertEqual(pill.label, "Installing…")
        assertVisibleSize(pill)
        attachScreenshot(name: "update-installing")

        pill.click()
        XCTAssertTrue(
            app.buttons["Restart Now"].waitForExistence(timeout: 8.0),
            "Expected the installing popover to offer Restart Now"
        )
        XCTAssertTrue(app.buttons["Restart Later"].waitForExistence(timeout: 2.0), "Expected a Restart Later button")
    }

    func testUpdatePillShowsErrorStateWithRetryAndDetails() {
        let systemSettings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        systemSettings.terminate()
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_UPDATE_STATE"] = "error"
        launchAndActivate(app)

        // A generic update error surfaces the "Update Failed" pill title.
        let pill = pillButton(app: app, expectedLabel: "Update Failed")
        XCTAssertTrue(pill.waitForExistence(timeout: 6.0))
        XCTAssertEqual(pill.label, "Update Failed")
        assertVisibleSize(pill)
        attachScreenshot(name: "update-error")
        attachElementDebug(name: "update-error-pill", element: pill)

        pill.click()

        XCTAssertTrue(
            app.staticTexts["Update Failed"].waitForExistence(timeout: 8.0),
            "Expected the error popover title to appear"
        )
        XCTAssertTrue(
            app.buttons["Retry"].waitForExistence(timeout: 2.0),
            "Expected a Retry button in the error popover"
        )
        XCTAssertTrue(
            app.buttons["Copy Details"].waitForExistence(timeout: 2.0),
            "Expected a Copy Details button in the error popover"
        )
    }

    private func pillButton(app: XCUIApplication, expectedLabel: String) -> XCUIElement {
        // On macOS, SwiftUI accessibility identifiers are not always reliably surfaced for titlebar-style
        // UI across OS/Xcode versions. Prefer the pill's accessibility label, but keep an identifier
        // fallback for local runs.
        return app.buttons[expectedLabel]
    }

    private func waitForWindowCount(atLeast count: Int, app: XCUIApplication, timeout: TimeInterval) -> Bool {
        pollUntil(timeout: timeout) {
            app.windows.count >= count
        }
    }

    private func assertVisibleSize(_ element: XCUIElement, timeout: TimeInterval = 2.0) {
        let pollInterval: TimeInterval = 0.05
        var size = element.frame.size
        var exists = element.exists
        var hittable = element.isHittable

        let visible = pollUntil(timeout: timeout, pollInterval: pollInterval) {
            size = element.frame.size
            exists = element.exists
            hittable = element.isHittable
            return size.width > 20 && size.height > 10
        }
        if !visible {
            XCTFail(
                "Expected UpdatePill to have visible size, got \(size), exists=\(exists), hittable=\(hittable)"
            )
        }
    }

    private func attachScreenshot(name: String, screenshot: XCUIScreenshot = XCUIScreen.main.screenshot()) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachElementDebug(name: String, element: XCUIElement) {
        let payload = """
        label: \(element.label)
        exists: \(element.exists)
        hittable: \(element.isHittable)
        frame: \(element.frame)
        """
        let attachment = XCTAttachment(string: payload)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launchAppWithMockFeed(
        mode: String,
        version: String,
        timingPath: URL? = nil,
        extraEnvironment: [String: String] = [:]
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_FEED_URL"] = "https://cmux.test/appcast.xml"
        app.launchEnvironment["CMUX_UI_TEST_FEED_MODE"] = mode
        app.launchEnvironment["CMUX_UI_TEST_UPDATE_VERSION"] = version
        app.launchEnvironment["CMUX_UI_TEST_AUTO_ALLOW_PERMISSION"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_TRIGGER_UPDATE_CHECK"] = "1"
        if let timingPath {
            app.launchEnvironment["CMUX_UI_TEST_TIMING_PATH"] = timingPath.path
        }
        for (key, value) in extraEnvironment {
            app.launchEnvironment[key] = value
        }
        launchAndActivate(app)
        return app
    }

    private func launchAndActivate(_ app: XCUIApplication, activateTimeout: TimeInterval = 2.0) {
        app.launch()
        let activated = pollUntil(timeout: activateTimeout) {
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

    private func loadTimingPayload(from url: URL) -> [String: Double] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Double] else {
            return [:]
        }
        return object
    }
}

final class TitlebarShortcutHintsUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testTitlebarShortcutHintsAlignWithoutShiftingControls() {
        let (baselineApp, baselineDataPath) = launchApp()
        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: baselineApp, timeout: 8.0))
        XCTAssertTrue(waitForBonsplitSetupReady(atPath: baselineDataPath, timeout: 8.0))

        let baselineToggle = element(in: baselineApp, identifier: "titlebarControl.toggleSidebar")
        let baselineNotifications = element(in: baselineApp, identifier: "titlebarControl.showNotifications")
        let baselineNewTab = element(in: baselineApp, identifier: "titlebarControl.newTab")

        XCTAssertTrue(waitForElementVisible(baselineToggle, timeout: 6.0))
        XCTAssertTrue(waitForElementVisible(baselineNotifications, timeout: 6.0))
        XCTAssertTrue(waitForElementVisible(baselineNewTab, timeout: 6.0))

        let baselineToggleFrame = baselineToggle.frame
        let baselineNotificationsFrame = baselineNotifications.frame
        let baselineNewTabFrame = baselineNewTab.frame

        baselineApp.terminate()

        let (hintedApp, hintedDataPath) = launchApp(alwaysShowShortcutHints: true)
        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: hintedApp, timeout: 8.0))
        XCTAssertTrue(waitForBonsplitSetupReady(atPath: hintedDataPath, timeout: 8.0))

        let hintedToggle = element(in: hintedApp, identifier: "titlebarControl.toggleSidebar")
        let hintedNotifications = element(in: hintedApp, identifier: "titlebarControl.showNotifications")
        let hintedNewTab = element(in: hintedApp, identifier: "titlebarControl.newTab")

        XCTAssertTrue(waitForElementVisible(hintedToggle, timeout: 6.0))
        XCTAssertTrue(waitForElementVisible(hintedNotifications, timeout: 6.0))
        XCTAssertTrue(waitForElementVisible(hintedNewTab, timeout: 6.0))

        let sidebarHint = element(in: hintedApp, identifier: "titlebarShortcutHint.toggleSidebar")
        let notificationsHint = element(in: hintedApp, identifier: "titlebarShortcutHint.showNotifications")
        let newTabHint = element(in: hintedApp, identifier: "titlebarShortcutHint.newTab")

        XCTAssertTrue(waitForElementVisible(sidebarHint, timeout: 6.0))
        XCTAssertTrue(waitForElementVisible(notificationsHint, timeout: 6.0))
        XCTAssertTrue(waitForElementVisible(newTabHint, timeout: 6.0))

        let hintedToggleFrame = hintedToggle.frame
        let hintedNotificationsFrame = hintedNotifications.frame
        let hintedNewTabFrame = hintedNewTab.frame

        XCTAssertEqual(hintedToggleFrame.minY, baselineToggleFrame.minY, accuracy: 1.0)
        XCTAssertEqual(hintedNotificationsFrame.minY, baselineNotificationsFrame.minY, accuracy: 1.0)
        XCTAssertEqual(hintedNewTabFrame.minY, baselineNewTabFrame.minY, accuracy: 1.0)

        let sidebarHintFrame = sidebarHint.frame
        let notificationsHintFrame = notificationsHint.frame
        let newTabHintFrame = newTabHint.frame

        XCTAssertEqual(sidebarHintFrame.minY, notificationsHintFrame.minY, accuracy: 1.0)
        XCTAssertEqual(notificationsHintFrame.minY, newTabHintFrame.minY, accuracy: 1.0)
        XCTAssertEqual(sidebarHintFrame.midX, hintedToggleFrame.midX, accuracy: 1.0)
        XCTAssertEqual(notificationsHintFrame.midX, hintedNotificationsFrame.midX, accuracy: 1.0)
        XCTAssertEqual(newTabHintFrame.midX, hintedNewTabFrame.midX, accuracy: 1.0)
        // Keep the sidebar hint lane to the right of the sidebar icon so it cannot clip into the traffic-light backdrop.
        XCTAssertGreaterThanOrEqual(sidebarHintFrame.minX, hintedToggleFrame.minX - 4.0)
    }

    private func launchApp(alwaysShowShortcutHints: Bool = false) -> (XCUIApplication, String) {
        let app = XCUIApplication()
        let dataPath = "/tmp/cmux-ui-test-titlebar-shortcut-hints-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: dataPath)
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH"] = dataPath
        if alwaysShowShortcutHints {
            app.launchEnvironment["CMUX_UI_TEST_SHORTCUT_HINTS_ALWAYS_SHOW"] = "1"
        }
        app.launchArguments += ["-workspacePresentationMode", "standard"]
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }

        _ = pollUntil(timeout: 2.0) {
            guard app.state != .runningForeground else {
                return true
            }
            app.activate()
            return app.state == .runningForeground
        }

        return (app, dataPath)
    }

    private func element(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitForWindowCount(atLeast count: Int, app: XCUIApplication, timeout: TimeInterval) -> Bool {
        pollUntil(timeout: timeout) {
            app.windows.count >= count
        }
    }

    private func waitForBonsplitSetupReady(atPath path: String, timeout: TimeInterval) -> Bool {
        pollUntil(timeout: timeout) {
            loadBonsplitSetupData(atPath: path)?["ready"] == "1"
        }
    }

    private func loadBonsplitSetupData(atPath path: String) -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return object
    }

    private func waitForElementVisible(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        pollUntil(timeout: timeout) {
            if element.exists {
                let frame = element.frame
                if frame.width > 1, frame.height > 1 {
                    return true
                }
            }
            return false
        }
    }
}

final class UpdateReadyToastUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchWithStagedAutoUpdate(version: String = "9.9.9") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_UPDATE_STATE"] = "installingAuto"
        app.launchEnvironment["CMUX_UI_TEST_UPDATE_VERSION"] = version
        app.launch()
        _ = pollUntil(timeout: 2.0) {
            guard app.state != .runningForeground else { return true }
            app.activate()
            return app.state == .runningForeground
        }
        return app
    }

    func testStagedAutoUpdateShowsToastWithOneClickActions() {
        let app = launchWithStagedAutoUpdate()

        let toast = app.otherElements["UpdateReadyToast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 8.0), "Expected the update-ready toast for a staged auto-update")

        XCTAssertTrue(app.buttons["UpdateReadyToastRestart"].waitForExistence(timeout: 2.0), "Expected a one-click Restart button")
        XCTAssertTrue(app.buttons["UpdateReadyToastRestartWhenIdle"].exists, "Expected a Restart When Idle button")
        XCTAssertTrue(app.buttons["UpdateReadyToastSeeChanges"].exists, "Expected a See Changes button")
        XCTAssertTrue(app.staticTexts["cmux 9.9.9 is ready"].exists, "Expected the staged version in the toast title")

        // The sidebar pill still shows the staged install alongside the toast.
        XCTAssertTrue(app.buttons["Restart to Complete Update"].exists)
    }

    func testRestartWhenIdleArmsAndHidesToast() {
        let app = launchWithStagedAutoUpdate()

        let idleButton = app.buttons["UpdateReadyToastRestartWhenIdle"]
        XCTAssertTrue(idleButton.waitForExistence(timeout: 8.0))
        idleButton.click()

        let toastGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.otherElements["UpdateReadyToast"]
        )
        XCTAssertEqual(XCTWaiter().wait(for: [toastGone], timeout: 5.0), .completed, "Arming restart-when-idle should hide the toast")

        XCTAssertTrue(
            app.buttons["Restarting When Idle…"].waitForExistence(timeout: 5.0),
            "Expected the pill to reflect the armed deferred restart"
        )
    }

    func testDismissHidesToastButKeepsPill() {
        let app = launchWithStagedAutoUpdate()

        let dismiss = app.buttons["UpdateReadyToastDismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 8.0))
        dismiss.click()

        let toastGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.otherElements["UpdateReadyToast"]
        )
        XCTAssertEqual(XCTWaiter().wait(for: [toastGone], timeout: 5.0), .completed, "Dismiss should hide the toast")

        XCTAssertTrue(
            app.buttons["Restart to Complete Update"].waitForExistence(timeout: 5.0),
            "The pill must remain as the ambient affordance after the toast is dismissed"
        )
    }
}
