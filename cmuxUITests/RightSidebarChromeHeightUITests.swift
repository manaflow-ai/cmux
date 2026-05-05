import XCTest
import Foundation
import CoreGraphics

final class RightSidebarChromeHeightUITests: XCTestCase {
    func testSecondaryBarMatchesModeBarAndPaneTabs() {
        let app = XCUIApplication()
        let dataPath = "/tmp/cmux-ui-test-right-sidebar-chrome-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: dataPath)

        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_SHOW_RIGHT_SIDEBAR"] = "1"
        app.launchArguments += ["-workspacePresentationMode", "minimal"]
        app.launchArguments += ["-rightSidebar.beta.feed.enabled", "YES"]
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }
        defer { app.terminate() }

        if app.state == .runningBackground {
            app.activate()
        }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20) || app.windows.firstMatch.waitForExistence(timeout: 6))
        guard let ready = waitForJSONKey("ready", equals: "1", atPath: dataPath, timeout: 25) else {
            XCTFail("Timed out waiting for setup data. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }
        if let setupError = ready["setupError"], !setupError.isEmpty {
            XCTFail("Setup failed: \(setupError)")
            return
        }

        let alphaTitle = loadJSON(atPath: dataPath)?["alphaTitle"] ?? "UITest Alpha"
        let alphaTab = app.buttons[alphaTitle]
        XCTAssertTrue(alphaTab.waitForExistence(timeout: 5))
        XCTAssertNotNil(waitForJSONNumber("rightSidebarModeBarWidth", greaterThan: 1, atPath: dataPath, timeout: 5))

        let sessionsButton = app.buttons["RightSidebarModeButton.sessions"]
        XCTAssertTrue(sessionsButton.waitForExistence(timeout: 5))
        sessionsButton.click()

        guard let geometry = waitForJSONNumber("rightSidebarSecondaryBarWidth", greaterThan: 1, atPath: dataPath, timeout: 5),
              let modeBarHeight = Double(geometry["rightSidebarModeBarHeight"] ?? ""),
              let secondaryBarHeight = Double(geometry["rightSidebarSecondaryBarHeight"] ?? "") else {
            XCTFail("Timed out waiting for right sidebar secondary bar geometry. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }
        XCTAssertEqual(secondaryBarHeight, modeBarHeight, accuracy: 0.5, "Expected secondary bar to match the right sidebar mode bar. geometry=\(geometry)")
        XCTAssertEqual(secondaryBarHeight, 28, accuracy: 0.5, "Expected right sidebar chrome to use the standard minimal-mode lane height. geometry=\(geometry)")
        XCTAssertEqual(CGFloat(secondaryBarHeight), alphaTab.frame.height, accuracy: 2, "Expected secondary bar to match Bonsplit pane tab height. geometry=\(geometry) alphaTab=\(alphaTab.frame)")

        let controlHeightKeys = [
            "rightSidebarModeControl_sessionsHeight",
            "rightSidebarSecondaryControl_directoryHeight",
            "rightSidebarSecondaryControl_agentHeight",
            "rightSidebarSecondaryControl_scopeHeight",
        ]
        guard let controlGeometry = waitForJSONNumbers(controlHeightKeys, greaterThan: 1, atPath: dataPath, timeout: 5),
              let modeControlHeight = Double(controlGeometry["rightSidebarModeControl_sessionsHeight"] ?? ""),
              let directoryControlHeight = Double(controlGeometry["rightSidebarSecondaryControl_directoryHeight"] ?? ""),
              let agentControlHeight = Double(controlGeometry["rightSidebarSecondaryControl_agentHeight"] ?? ""),
              let scopeControlHeight = Double(controlGeometry["rightSidebarSecondaryControl_scopeHeight"] ?? "") else {
            XCTFail("Timed out waiting for right sidebar control geometry. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }
        XCTAssertEqual(directoryControlHeight, modeControlHeight, accuracy: 0.5, "Expected By folder pill to match mode button height. geometry=\(controlGeometry)")
        XCTAssertEqual(agentControlHeight, modeControlHeight, accuracy: 0.5, "Expected By agent pill to match mode button height. geometry=\(controlGeometry)")
        XCTAssertEqual(scopeControlHeight, modeControlHeight, accuracy: 0.5, "Expected This folder only control to match mode button height. geometry=\(controlGeometry)")

        let feedButton = app.buttons["RightSidebarModeButton.feed"]
        XCTAssertTrue(feedButton.waitForExistence(timeout: 5))
        feedButton.click()

        let feedControlHeightKeys = [
            "rightSidebarSecondaryControl_feed_actionableHeight",
        ]
        guard let feedGeometry = waitForJSONNumbers(feedControlHeightKeys, greaterThan: 1, atPath: dataPath, timeout: 5),
              let feedSecondaryBarHeight = Double(feedGeometry["rightSidebarSecondaryBarHeight"] ?? ""),
              let actionableControlHeight = Double(feedGeometry["rightSidebarSecondaryControl_feed_actionableHeight"] ?? "") else {
            XCTFail("Timed out waiting for feed secondary bar geometry. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }
        XCTAssertEqual(feedSecondaryBarHeight, modeBarHeight, accuracy: 0.5, "Expected feed secondary bar to match the mode bar. geometry=\(feedGeometry)")
        XCTAssertEqual(actionableControlHeight, modeControlHeight, accuracy: 0.5, "Expected Feed Actionable pill to match mode button height. geometry=\(feedGeometry)")
    }

    private func waitForJSONNumbers(_ keys: [String], greaterThan threshold: Double, atPath path: String, timeout: TimeInterval) -> [String: String]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = loadJSON(atPath: path), containsNumbers(data, keys: keys, greaterThan: threshold) {
                return data
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return loadJSON(atPath: path).flatMap {
            containsNumbers($0, keys: keys, greaterThan: threshold) ? $0 : nil
        }
    }

    private func containsNumbers(_ data: [String: String], keys: [String], greaterThan threshold: Double) -> Bool {
        keys.allSatisfy { key in
            guard let rawValue = data[key], let value = Double(rawValue) else { return false }
            return value > threshold
        }
    }

    private func waitForJSONKey(_ key: String, equals expected: String, atPath path: String, timeout: TimeInterval) -> [String: String]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = loadJSON(atPath: path), data[key] == expected { return data }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return loadJSON(atPath: path).flatMap { $0[key] == expected ? $0 : nil }
    }

    private func waitForJSONNumber(_ key: String, greaterThan threshold: Double, atPath path: String, timeout: TimeInterval) -> [String: String]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = loadJSON(atPath: path), let rawValue = data[key], let value = Double(rawValue), value > threshold { return data }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return loadJSON(atPath: path).flatMap {
            guard let rawValue = $0[key], let value = Double(rawValue), value > threshold else { return nil }
            return $0
        }
    }

    private func loadJSON(atPath path: String) -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return object
    }
}
