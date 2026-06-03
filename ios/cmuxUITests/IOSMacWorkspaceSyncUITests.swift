import XCTest

final class IOSMacWorkspaceSyncUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testDesktopWorkspacesMirrorAndTerminalInputRoundTrips() {
        let env = ProcessInfo.processInfo.environment
        let port = requiredEnv("CMUX_IOS_MAC_SYNC_WS_PORT")
        let titles = requiredEnv("CMUX_IOS_MAC_SYNC_EXPECTED_TITLES")
            .split(separator: "|")
            .map(String.init)
        let token = requiredEnv("CMUX_IOS_MAC_SYNC_INPUT_TOKEN")
        XCTAssertFalse(titles.isEmpty, "Expected at least one desktop workspace title")

        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UITEST_DISCOVERY_HOST"] = env["CMUX_IOS_MAC_SYNC_HOST"] ?? "127.0.0.1"
        app.launchEnvironment["CMUX_UITEST_DISCOVERY_PORTS"] = port
        if let home = env["CMUX_IOS_MAC_SYNC_HOST_HOME"] ?? env["HOME"] {
            app.launchEnvironment["SIMULATOR_HOST_HOME"] = home
        }
        app.launch()

        XCTAssertTrue(
            app.otherElements["terminal.home"].waitForExistence(timeout: 30),
            "Expected iOS terminal home"
        )
        XCTAssertTrue(
            waitForWorkspaceRowCount(in: app, count: titles.count, timeout: 45),
            "Expected exactly \(titles.count) workspace rows, got \(workspaceRows(in: app).count)"
        )

        for title in titles {
            XCTAssertTrue(
                app.staticTexts[title].waitForExistence(timeout: 8),
                "Expected synced desktop workspace title \(title)"
            )
            let matches = app.staticTexts.matching(NSPredicate(format: "label == %@", title))
            XCTAssertEqual(matches.count, 1, "Expected one visible iOS row titled \(title)")
        }

        app.staticTexts[titles[0]].tap()

        let detail = app.otherElements["terminal.workspace.detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 20), "Expected terminal detail after opening synced workspace")
        TerminalUITestHarness.focusTerminal(in: app, fallback: detail)
        TerminalUITestHarness.typeText("printf '\(token)\\n'\n", in: app)
    }

    private func workspaceRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(
            format: "identifier MATCHES %@",
            #"^terminal\.workspace\.[0-9A-Fa-f-]{36}$"#
        ))
    }

    private func waitForWorkspaceRowCount(
        in app: XCUIApplication,
        count expectedCount: Int,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if workspaceRows(in: app).count == expectedCount {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return workspaceRows(in: app).count == expectedCount
    }

    private func requiredEnv(
        _ key: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        guard let value = ProcessInfo.processInfo.environment[key],
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            XCTFail("Missing required environment variable \(key)", file: file, line: line)
            return ""
        }
        return value
    }
}
