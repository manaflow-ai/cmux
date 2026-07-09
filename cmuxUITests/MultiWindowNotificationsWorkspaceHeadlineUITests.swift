import XCTest

extension MultiWindowNotificationsUITests {
    func testNotificationsPopoverShowsWorkspaceAsHeadline() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_PATH"] = dataPath
        app.launchEnvironment["CMUX_TAG"] = launchTag
        launchAllowingHeadlessBackgroundActivation(app)
        XCTAssertTrue(
            ensureAppRunningAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for notification workspace-title test. state=\(app.state.rawValue)"
        )

        XCTAssertTrue(
            waitForData(keys: ["notifId1", "workspaceTitle1"], timeout: 15.0),
            "Expected notification and workspace-title setup data"
        )
        guard let setup = loadData(),
              let notificationId = setup["notifId1"],
              let workspaceTitle = setup["workspaceTitle1"],
              !notificationId.isEmpty,
              !workspaceTitle.isEmpty else {
            XCTFail("Missing notification workspace-title setup data")
            return
        }

        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 6.0))
        XCTAssertTrue(
            ensureAppForegroundForInteraction(app, timeout: 6.0),
            "Expected cmux to be foreground before opening notifications popover. state=\(app.state.rawValue)"
        )

        app.typeKey("i", modifierFlags: [.command])

        let workspaceHeadline = app.descendants(matching: .any)
            .matching(identifier: "NotificationPopoverRow.\(notificationId).workspaceTitle")
            .firstMatch
        XCTAssertTrue(
            workspaceHeadline.waitForExistence(timeout: 6.0),
            "Expected the notification row to expose its workspace as the headline"
        )
        XCTAssertEqual(workspaceHeadline.label, workspaceTitle)
    }
}
