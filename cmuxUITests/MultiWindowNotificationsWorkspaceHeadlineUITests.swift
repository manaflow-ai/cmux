import XCTest

extension MultiWindowNotificationsUITests {
    func runNotificationsPopoverShowsWorkspaceAsHeadline() {
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
            waitForData(
                keys: ["notifId1", "workspaceTitle1", "notifId2", "workspaceTitle2"],
                timeout: 15.0
            ),
            "Expected notification and workspace-title setup data"
        )
        guard let setup = loadData(),
              let notificationId1 = setup["notifId1"],
              let workspaceTitle1 = setup["workspaceTitle1"],
              let notificationId2 = setup["notifId2"],
              let workspaceTitle2 = setup["workspaceTitle2"],
              !notificationId1.isEmpty,
              !workspaceTitle1.isEmpty,
              !notificationId2.isEmpty,
              !workspaceTitle2.isEmpty else {
            XCTFail("Missing notification workspace-title setup data")
            return
        }

        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 6.0))
        XCTAssertTrue(
            ensureAppForegroundForInteraction(app, timeout: 6.0),
            "Expected cmux to be foreground before opening notifications popover. state=\(app.state.rawValue)"
        )

        app.typeKey("i", modifierFlags: [.command])

        for (notificationId, workspaceTitle) in [
            (notificationId1, workspaceTitle1),
            (notificationId2, workspaceTitle2),
        ] {
            let workspaceHeadline = app.descendants(matching: .any)
                .matching(identifier: "NotificationPopoverRow.\(notificationId).workspaceTitle")
                .firstMatch
            XCTAssertTrue(
                workspaceHeadline.waitForExistence(timeout: 6.0),
                "Expected notification \(notificationId) to expose workspace \(workspaceTitle) as its headline"
            )
            XCTAssertEqual(workspaceHeadline.label, workspaceTitle)
        }
    }

    func waitForWindowCount(atLeast count: Int, app: XCUIApplication, timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            app.windows.count >= count
        }
    }
}
