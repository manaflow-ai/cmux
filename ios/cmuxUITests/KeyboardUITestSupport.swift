import XCTest

/// Launch and geometry helpers for the keyboard UI tests
/// (plans/cmux-next/ios-keyboard.md). Every launch is the DEV preview: Home on
/// the mock owner, no account, no network.
@MainActor
enum KeyboardUITest {
    /// Launches the app on Home (mock owner); `conversation` opens the first
    /// conversation of that kind (`chief`, `group`, `direct`); `terminal`
    /// pushes the DEV terminal on the mock session host.
    static func launch(conversation: String? = nil, terminal: Bool = false,
                       extra: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_IOS_HOME_PREVIEW"] = "1"
        if let conversation { app.launchEnvironment["CMUX_IOS_OPEN_CONVERSATION"] = conversation }
        if terminal { app.launchEnvironment["CMUX_IOS_TERMINAL_PREVIEW"] = "1" }
        for (key, value) in extra { app.launchEnvironment[key] = value }
        app.launch()
        return app
    }

    /// The conversation's compose field (a UITextView labelled "Message").
    static func composer(_ app: XCUIApplication) -> XCUIElement {
        app.textViews["Message"].firstMatch
    }

    static func keyboard(_ app: XCUIApplication) -> XCUIElement {
        app.keyboards.firstMatch
    }

    /// The transcript's message elements, top to bottom (one per message part).
    static func messages(_ app: XCUIApplication) -> [XCUIElement] {
        let all = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'part:'")).allElementsBoundByIndex
        return all.filter { $0.frame.height > 0 }.sorted { $0.frame.minY < $1.frame.minY }
    }

    /// The lowest message element on screen.
    static func newestVisibleMessage(_ app: XCUIApplication) -> XCUIElement? {
        let screen = app.windows.firstMatch.frame
        return messages(app).filter { $0.frame.intersects(screen) }.max { $0.frame.maxY < $1.frame.maxY }
    }

    /// Waits until `condition` holds (re-evaluated about every 0.1 s) or `timeout` passes.
    @discardableResult
    static func wait(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    /// A measurement line the audit script collects from the test log.
    static func record(_ name: String, _ values: [String: CustomStringConvertible]) {
        let body = values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("KBD-AUDIT \(name) \(body)")
    }
}

extension CGRect {
    var short: String {
        String(format: "(%.1f,%.1f,%.1f,%.1f)", minX, minY, width, height)
    }
}
