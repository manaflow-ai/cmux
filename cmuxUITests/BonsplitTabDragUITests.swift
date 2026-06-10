import XCTest
import Foundation
import CoreGraphics

final class BonsplitTabDragUITests: XCTestCase {
    let launchTimeout: TimeInterval = 20.0
    let setupTimeout: TimeInterval = 25.0

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        let cleanup = XCUIApplication()
        cleanup.terminate()
        _ = cleanup.wait(for: .notRunning, timeout: 2.0)
    }

    enum WorkspacePresentationMode: String {
        case standard
        case minimal
    }

    func launchConfiguredApp(
        startWithHiddenSidebar: Bool = false,
        presentationMode: WorkspacePresentationMode = .minimal,
        showRightSidebar: Bool = false,
        alwaysShowShortcutHints: Bool = false,
        windowSize: String? = nil,
        actionButtonCount: Int? = nil
    ) -> (XCUIApplication, String) {
        let app = XCUIApplication()
        let dataPath = "/tmp/cmux-ui-test-bonsplit-tab-drag-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: dataPath)

        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH"] = dataPath
        if startWithHiddenSidebar {
            app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_START_WITH_HIDDEN_SIDEBAR"] = "1"
        }
        if let windowSize {
            app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_WINDOW_SIZE"] = windowSize
        }
        if let actionButtonCount {
            app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_ACTION_BUTTON_COUNT"] = String(actionButtonCount)
        }
        if showRightSidebar {
            app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_SHOW_RIGHT_SIDEBAR"] = "1"
        }
        if alwaysShowShortcutHints {
            app.launchEnvironment["CMUX_UI_TEST_SHORTCUT_HINTS_ALWAYS_SHOW"] = "1"
        }
        app.launchArguments += ["-workspacePresentationMode", presentationMode.rawValue]
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }
        return (app, dataPath)
    }

    func ensureAppRunningAfterLaunch(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let launched = waitForCondition(timeout: timeout) {
            app.state == .runningForeground ||
                app.state == .runningBackground ||
                app.windows.firstMatch.exists
        }
        guard launched else { return false }
        return ensureAppReadyForBonsplitInteraction(app, timeout: 6.0)
    }

    private func ensureAppReadyForBonsplitInteraction(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if app.state == .runningForeground {
            return true
        }
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App foreground activation may fail on headless CI runners", options: options) {
            app.activate()
        }
        let reachedForeground = waitForCondition(timeout: timeout) {
            app.state == .runningForeground
        }
        if reachedForeground {
            return true
        }
        // Bonsplit gestures target realized windows; headless runners can keep reporting
        // .unknown after launch even when the window is queryable and ready for coordinates.
        return app.windows.firstMatch.waitForExistence(timeout: timeout)
    }

    func ensureAppForegroundForKeyboardInteraction(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if app.state == .runningForeground {
            return true
        }
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App foreground activation may fail on headless CI runners", options: options) {
            app.activate()
        }
        return waitForCondition(timeout: timeout) {
            app.state == .runningForeground
        }
    }

    func waitForAnyJSON(atPath path: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if loadJSON(atPath: path) != nil { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return loadJSON(atPath: path) != nil
    }

    func waitForJSONKey(_ key: String, equals expected: String, atPath path: String, timeout: TimeInterval) -> [String: String]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = loadJSON(atPath: path), data[key] == expected {
                return data
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let data = loadJSON(atPath: path), data[key] == expected {
            return data
        }
        return nil
    }

    func waitForJSONNumber(
        _ key: String,
        greaterThan threshold: Double,
        atPath path: String,
        timeout: TimeInterval
    ) -> [String: String]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = loadJSON(atPath: path),
               let rawValue = data[key],
               let value = Double(rawValue),
               value > threshold {
                return data
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let data = loadJSON(atPath: path),
           let rawValue = data[key],
           let value = Double(rawValue),
           value > threshold {
            return data
        }
        return nil
    }

    func waitForJSONNumbers(
        _ keys: [String],
        atPath path: String,
        timeout: TimeInterval
    ) -> [String: String]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = loadJSON(atPath: path),
               keys.allSatisfy({ key in
                   guard let rawValue = data[key],
                         Double(rawValue) != nil else {
                       return false
                   }
                   return true
               }) {
                return data
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let data = loadJSON(atPath: path),
           keys.allSatisfy({ key in
               guard let rawValue = data[key],
                     Double(rawValue) != nil else {
                   return false
               }
               return true
           }) {
            return data
        }
        return nil
    }

    func loadJSON(atPath path: String) -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return object
    }

    func waitForCondition(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    func hover(in window: XCUIElement, at point: CGPoint) {
        let origin = window.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(
            CGVector(
                dx: point.x - window.frame.minX,
                dy: point.y - window.frame.minY
            )
        ).hover()
    }

    func distanceToTopEdge(of element: XCUIElement, in window: XCUIElement) -> CGFloat {
        let gapIfOriginIsBottomLeft = abs(window.frame.maxY - element.frame.maxY)
        let gapIfOriginIsTopLeft = abs(element.frame.minY - window.frame.minY)
        return min(gapIfOriginIsBottomLeft, gapIfOriginIsTopLeft)
    }

    func doubleClick(in window: XCUIElement, atAccessibilityPoint point: CGPoint) {
        let target = window.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(
                dx: point.x - window.frame.minX,
                dy: point.y - window.frame.minY
            )
        )
        target.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        target.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    func dragTab(_ sourceTab: XCUIElement, before targetTab: XCUIElement) {
        let source = sourceTab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let target = targetTab.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        source.press(forDuration: 0.25, thenDragTo: target)
    }
}
