import XCTest
import Foundation

final class RightSidebarModeBarNarrowUITests: XCTestCase {
    func testNarrowModeBarKeepsEveryTabWithoutClippedLabels() {
        let app = XCUIApplication.cmuxTestApplication()
        let dataPath = "/tmp/cmux-ui-test-right-sidebar-modebar-narrow-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: dataPath)
        defer { try? FileManager.default.removeItem(atPath: dataPath) }

        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_SHOW_RIGHT_SIDEBAR"] = "1"
        app.launchArguments += ["-workspacePresentationMode", "minimal", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += ["-rightSidebar.beta.feed.enabled", "YES"]
        app.launch()
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
            XCTFail("Setup failed: \(setupError). data=\(ready)")
            return
        }

        let alphaTitle = loadJSON(atPath: dataPath)?["alphaTitle"] ?? "UITest Alpha"
        XCTAssertTrue(app.buttons[alphaTitle].waitForExistence(timeout: 5))
        guard let initialGeometry = waitForJSONNumbers(["rightSidebarModeBarWidth"], greaterThan: 1, atPath: dataPath, timeout: 5),
              let modeBarWidth = Double(initialGeometry["rightSidebarModeBarWidth"] ?? "") else {
            XCTFail("Timed out waiting for mode bar geometry. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }
        XCTAssertLessThan(modeBarWidth, 320, "Expected the default sidebar to exercise the narrow mode bar. geometry=\(initialGeometry)")
        guard modeBarWidth < 320 else { return }

        let modeIDs = ["files", "find", "sessions", "feed", "dock", "machines", "custom-sidebar"]
        let existingModeIDs = modeIDs.filter { app.buttons["RightSidebarModeButton.\($0)"].exists }
        XCTAssertFalse(existingModeIDs.isEmpty, "Expected accessible mode buttons. geometry=\(initialGeometry)")
        let reportedModeIDs = modeIDs.filter {
            initialGeometry["rightSidebarModeControl_\($0)Width"] != nil || initialGeometry["rightSidebarModeIcon_\($0)Width"] != nil
        }
        XCTAssertFalse(reportedModeIDs.isEmpty, "Expected mode pill and icon geometry. geometry=\(initialGeometry)")
        guard !reportedModeIDs.isEmpty else { return }

        let widthKeys = reportedModeIDs.flatMap {
            ["rightSidebarModeControl_\($0)Width", "rightSidebarModeIcon_\($0)Width"]
        }
        guard let geometry = waitForJSONNumbers(widthKeys, greaterThan: 1, atPath: dataPath, timeout: 5) else {
            XCTFail("Timed out waiting for mode pill and icon geometry. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }
        for modeID in reportedModeIDs {
            guard let controlWidth = Double(geometry["rightSidebarModeControl_\(modeID)Width"] ?? ""),
                  let iconWidth = Double(geometry["rightSidebarModeIcon_\(modeID)Width"] ?? "") else {
                XCTFail("Missing widths for \(modeID). geometry=\(geometry)")
                continue
            }
            XCTAssertEqual(controlWidth, iconWidth + 16, accuracy: 1, "Expected \(modeID) pill to hold only its icon and 16pt horizontal padding. geometry=\(geometry)")
            XCTAssertTrue(app.buttons["RightSidebarModeButton.\(modeID)"].exists, "Expected reported \(modeID) tab to remain accessible. geometry=\(geometry)")
        }
        for modeID in existingModeIDs {
            let button = app.buttons["RightSidebarModeButton.\(modeID)"]
            XCTAssertTrue(button.exists, "Expected \(modeID) tab to remain accessible at the default width. geometry=\(geometry)")
            print("RightSidebarModeButton.\(modeID) accessibility label: \(button.label)")
        }
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

    private func loadJSON(atPath path: String) -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return object
    }
}
