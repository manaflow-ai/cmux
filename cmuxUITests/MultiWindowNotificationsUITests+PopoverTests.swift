import XCTest
import Foundation
import CoreGraphics


// MARK: - Notifications Popover Behavior Tests
extension MultiWindowNotificationsUITests {
    func testNotificationsPopoverCanCloseViaShortcutAndEscape() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_PATH"] = dataPath
        app.launchEnvironment["CMUX_TAG"] = launchTag
        launchAllowingHeadlessBackgroundActivation(app)
        XCTAssertTrue(
            ensureAppRunningAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for notifications popover shortcut test. state=\(app.state.rawValue)"
        )

        XCTAssertTrue(
            waitForData(keys: ["notifId1"], timeout: 15.0),
            "Expected multi-window notification setup data"
        )

        guard let notifId1 = loadData()?["notifId1"], !notifId1.isEmpty else {
            XCTFail("Missing setup notification id")
            return
        }

        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 6.0))
        XCTAssertTrue(
            ensureAppForegroundForInteraction(app, timeout: 6.0),
            "Expected cmux to be foreground before opening notifications popover. state=\(app.state.rawValue)"
        )

        app.typeKey("i", modifierFlags: [.command])
        let targetButton = app.buttons["NotificationPopoverRow.\(notifId1)"]
        XCTAssertTrue(targetButton.waitForExistence(timeout: 6.0), "Expected popover to open on Show Notifications shortcut")

        app.typeKey("i", modifierFlags: [.command])
        XCTAssertTrue(waitForElementToDisappear(targetButton, timeout: 3.0), "Expected popover to close on repeated Show Notifications shortcut")

        app.typeKey("i", modifierFlags: [.command])
        XCTAssertTrue(targetButton.waitForExistence(timeout: 6.0), "Expected popover to reopen on Show Notifications shortcut")

        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(waitForElementToDisappear(targetButton, timeout: 3.0), "Expected popover to close on Escape")
    }

    func testNotificationsPopoverJumpToLatestButtonShowsShortcut() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_PATH"] = dataPath
        app.launchEnvironment["CMUX_TAG"] = launchTag
        launchAllowingHeadlessBackgroundActivation(app)
        XCTAssertTrue(
            ensureAppRunningAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for jump-to-latest popover test. state=\(app.state.rawValue)"
        )

        XCTAssertTrue(waitForData(keys: ["notifId1"], timeout: 15.0), "Expected multi-window notification setup data")
        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 6.0))
        XCTAssertTrue(
            ensureAppForegroundForInteraction(app, timeout: 6.0),
            "Expected cmux to be foreground before opening notifications popover. state=\(app.state.rawValue)"
        )

        app.typeKey("i", modifierFlags: [.command])

        let jumpButton = app.buttons["notificationsPopover.jumpToLatest"]
        XCTAssertTrue(jumpButton.waitForExistence(timeout: 6.0), "Expected Jump to Latest button in notifications popover")
        let shortcutValue = jumpButton.value as? String
        XCTAssertNotNil(shortcutValue, "Expected Jump to Latest shortcut badge")
        XCTAssertTrue(shortcutValue?.contains("⌘") == true, "Expected Jump to Latest shortcut to include Command")
        XCTAssertTrue(shortcutValue?.contains("⇧") == true, "Expected Jump to Latest shortcut to include Shift")
        XCTAssertTrue(shortcutValue?.uppercased().contains("U") == true, "Expected Jump to Latest shortcut to include U")
    }

    func testEmptyNotificationsPopoverBlocksTerminalTyping() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-socketControlMode", "allowAll"]
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_TAG"] = launchTag
        launchAllowingHeadlessBackgroundActivation(app)
        XCTAssertTrue(
            ensureAppRunningAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for empty popover blocking test. state=\(app.state.rawValue)"
        )

        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 8.0))
        guard let resolvedPath = resolveSocketPath(timeout: 8.0) else {
            throw XCTSkip("Control socket unavailable in this test environment. requested=\(socketPath)")
        }
        socketPath = resolvedPath
        let pingResponse = waitForSocketPong(timeout: 8.0)
        guard pingResponse == "PONG" else {
            throw XCTSkip("Control socket did not respond in time. path=\(socketPath) response=\(pingResponse ?? "<nil>")")
        }

        _ = socketCommand("clear_notifications")

        XCTAssertTrue(
            ensureAppForegroundForInteraction(app, timeout: 6.0),
            "Expected cmux to be foreground before opening empty notifications popover. state=\(app.state.rawValue)"
        )
        app.typeKey("i", modifierFlags: [.command])
        XCTAssertTrue(app.staticTexts["No notifications yet"].waitForExistence(timeout: 6.0), "Expected empty notifications popover state")
        let jumpButton = app.buttons["notificationsPopover.jumpToLatest"]
        XCTAssertTrue(jumpButton.waitForExistence(timeout: 2.0), "Expected Jump to Latest button in empty notifications popover")
        XCTAssertFalse(jumpButton.isEnabled, "Expected Jump to Latest button to be disabled with no notifications")
        let clearAllButton = app.buttons["notificationsPopover.clearAll"]
        XCTAssertTrue(clearAllButton.waitForExistence(timeout: 2.0), "Expected Clear All button in empty notifications popover")
        XCTAssertFalse(clearAllButton.isEnabled, "Expected Clear All button to be disabled with no notifications")

        let marker = "cmux_notif_block_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))"
        let before = readCurrentTerminalText() ?? ""
        XCTAssertFalse(before.contains(marker), "Unexpected marker precondition collision")

        app.typeText(marker)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))

        guard let after = readCurrentTerminalText() else {
            XCTFail("Expected terminal text from control socket")
            return
        }
        XCTAssertFalse(after.contains(marker), "Expected typing to be blocked while empty notifications popover is open")
    }

}
