import XCTest
import Foundation

final class BrowserOmnibarImmediateTypingUITests: XCTestCase {
    private var dataPath = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        dataPath = "/tmp/cmux-ui-test-omnibar-immediate-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: dataPath)
        XCUIApplication().terminate()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    func testCmdLImmediateTypingPreservesCompleteURL() {
        let app = launchBrowserSplit()
        let omnibar = app.textFields["BrowserOmnibarTextField"].firstMatch
        XCTAssertTrue(omnibar.waitForExistence(timeout: 6.0))

        app.typeKey("l", modifierFlags: [.command])
        omnibar.typeText("example.com")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(
            waitForCondition(timeout: 8.0) {
                Self.containsExampleDomain(((omnibar.value as? String) ?? "").lowercased())
            },
            "Expected baseline navigation to load before Cmd+L fast-typing check."
        )

        assertImmediateTypingPreservesCompleteURL(app: app, shortcutFlags: [.command])
    }

    func testCmdShiftLImmediateTypingPreservesCompleteURL() {
        let app = launchBrowserSplit()
        let omnibar = app.textFields["BrowserOmnibarTextField"].firstMatch
        XCTAssertTrue(omnibar.waitForExistence(timeout: 6.0))
        app.typeKey("l", modifierFlags: [.command])
        omnibar.typeText("example.com")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(
            waitForCondition(timeout: 8.0) {
                Self.containsExampleDomain(((omnibar.value as? String) ?? "").lowercased())
            },
            "Expected baseline navigation to load before Cmd+Shift+L fast-typing check."
        )
        assertImmediateTypingPreservesCompleteURL(app: app, shortcutFlags: [.command, .shift])
    }

    private func assertImmediateTypingPreservesCompleteURL(
        app: XCUIApplication,
        shortcutFlags: XCUIElement.KeyModifierFlags
    ) {
        let typedURL = "github.com"
        app.typeKey("l", modifierFlags: shortcutFlags)
        app.typeText(typedURL)

        var observedValues = ""
        let preservedCompleteURL = waitForCondition(timeout: 7.0) {
            let values = app.textFields.matching(identifier: "BrowserOmnibarTextField")
                .allElementsBoundByIndex
                .compactMap { $0.value as? String }
                .map { $0.lowercased() }
            observedValues = values.joined(separator: " | ")
            return values.contains { $0.hasPrefix(typedURL) }
        }
        XCTAssertTrue(
            preservedCompleteURL,
            "Expected immediate typing after shortcut to preserve complete URL '\(typedURL)'. values=\(observedValues)"
        )
    }

    private func launchBrowserSplit(timeout: TimeInterval = 12.0) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_DISABLE_REMOTE_SUGGESTIONS"] = "1"
        app.launch()
        XCTAssertTrue(ensureForegroundAfterLaunch(app, timeout: timeout))
        return app
    }

    private func ensureForegroundAfterLaunch(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if app.wait(for: .runningForeground, timeout: timeout) {
            return true
        }
        if app.state == .runningBackground {
            app.activate()
            return app.wait(for: .runningForeground, timeout: 6.0)
        }
        return false
    }

    private static func containsExampleDomain(_ value: String) -> Bool {
        value.contains("example.com") || value.contains("example.org")
    }

    private func waitForCondition(timeout: TimeInterval, predicate: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in predicate() },
            object: nil
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
