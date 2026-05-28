import XCTest

final class ComeupSimulatorHarnessUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testWorkspaceHomeOpensTerminalDetail() throws {
        let app = XCUIApplication()
        let environment = ProcessInfo.processInfo.environment
        if let port = environment["COMEUP_TEXT_PORT"] ?? environment["TEST_RUNNER_COMEUP_TEXT_PORT"] {
            app.launchEnvironment["COMEUP_TEXT_PORT"] = port
        }
        if let sendOnConnect = environment["COMEUP_SEND_ON_CONNECT"] ?? environment["TEST_RUNNER_COMEUP_SEND_ON_CONNECT"] {
            app.launchEnvironment["COMEUP_SEND_ON_CONNECT"] = sendOnConnect
        }
        app.launch()

        XCTAssertTrue(app.collectionViews["cmux.mobile.home"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.cmuxElement("auth.status.row").waitForExistence(timeout: 4))
        XCTAssertTrue(app.cmuxElement("hive.node.node-macbook").waitForExistence(timeout: 4))

        let workspace = app.cmuxElement("workspace.row.workspace-ios-port")
        XCTAssertTrue(workspace.waitForExistence(timeout: 4))
        workspace.tap()

        XCTAssertTrue(app.cmuxElement("workspace.detail.workspace-ios-port").waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["main / pane 1 / shell"].waitForExistence(timeout: 4))
        let terminalSurface = app.cmuxElement("terminal.surface")
        XCTAssertTrue(terminalSurface.waitForExistence(timeout: 4))
        XCTAssertTrue(terminalSurface.waitForValue(containing: "CMX_SENTINEL_TO_SIM", timeout: 8))
    }
}

private extension XCUIApplication {
    func cmuxElement(_ identifier: String) -> XCUIElement {
        descendants(matching: .any)[identifier]
    }
}

private extension XCUIElement {
    func waitForValue(containing needle: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (value as? String)?.contains(needle) == true {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return (value as? String)?.contains(needle) == true
    }
}
