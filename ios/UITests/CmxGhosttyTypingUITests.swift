import XCTest

final class CmxGhosttyTypingUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchEnvironment = [
            "CMUX_IOS_BRIDGE_TICKET": Self.directTicket,
            "CMUX_IOS_AUTOCONNECT": "1",
            "CMUX_IOS_UI_TESTING_ECHO_SESSION": "1",
        ]
        app.launch()
    }

    func testTypingIntoGhosttyRendersEchoedOutput() throws {
        let terminal = try openTerminal()

        terminal.tap()
        let input = app.descendants(matching: .any)["terminal.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.typeText("echo UI_GHOSTTY_SYNC_OK\n")

        XCTAssertTrue(waitForTerminalValue(terminal, containing: "UI_GHOSTTY_SYNC_OK", timeout: 10))
    }

    func testRepeatedPinchZoomKeepsGhosttyResponsive() throws {
        let terminal = try openTerminal()

        for _ in 0..<16 {
            terminal.pinch(withScale: 0.55, velocity: -1)
            terminal.pinch(withScale: 1.8, velocity: 1)
        }

        terminal.tap()
        let input = app.descendants(matching: .any)["terminal.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.typeText("echo ZOOM_OK\n")

        XCTAssertTrue(waitForTerminalValue(terminal, containing: "ZOOM_OK", timeout: 10))
    }

    private func openTerminal() throws -> XCUIElement {
        let workspace = app.descendants(matching: .any)["workspace.row.1"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        workspace.tap()

        let terminal = app.descendants(matching: .any)["terminal.surface"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForTerminalValue(terminal, containing: "ui-test$", timeout: 10))
        return terminal
    }

    private func waitForTerminalValue(
        _ terminal: XCUIElement,
        containing expected: String,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate { element, _ in
            guard let terminal = element as? XCUIElement else { return false }
            return (terminal.value as? String)?.contains(expected) == true
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: terminal)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private static let directTicket = #"{"version":1,"alpn":"/cmux/cmx/3","endpoint":{"id":"ui-test-endpoint","addrs":[]},"auth":{"mode":"direct"},"node":{"id":"ui-test-node","name":"UI Test Mac","subtitle":"Ghostty echo session","kind":"macbook"}}"#
}
