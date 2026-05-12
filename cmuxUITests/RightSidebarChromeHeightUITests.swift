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

final class TerminalViewportUITests: XCTestCase {
    func testTerminalSurfaceUsesAvailableViewportAndTracksWindowResize() {
        let dataPath = "/tmp/cmux-ui-test-terminal-viewport-\(UUID().uuidString).json"
        let commandPath = "/tmp/cmux-ui-test-terminal-viewport-command-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: dataPath)
        try? FileManager.default.removeItem(atPath: commandPath)

        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_VIEWPORT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_VIEWPORT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_VIEWPORT_COMMAND_PATH"] = commandPath
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_VIEWPORT_WINDOW_SIZE"] = "900x620"
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_VIEWPORT_HIDE_SIDEBAR"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_VIEWPORT_HIDE_RIGHT_SIDEBAR"] = "1"
        app.launchArguments += ["-workspacePresentationMode", "minimal"]
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }
        defer { app.terminate() }
        defer {
            try? FileManager.default.removeItem(atPath: dataPath)
            try? FileManager.default.removeItem(atPath: commandPath)
        }

        if app.state == .runningBackground {
            app.activate()
        }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20) || app.windows.firstMatch.waitForExistence(timeout: 6))

        guard let small = waitForViewportGeometry(atPath: dataPath, timeout: 20, matching: { geometry in
            geometry.windowWidth >= 560 &&
                geometry.panelWidth > 300 &&
                geometry.panelHeight > 220 &&
                geometry.fillsAvailableViewport
        }) else {
            XCTFail("Timed out waiting for small terminal viewport geometry. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }
        assertTerminalViewportFillsAvailableSpace(small)

        guard let large = waitForViewportGeometry(atPath: dataPath, timeout: 10, matching: { geometry in
            geometry.requestedWindowSize == "1180x780" &&
                geometry.windowWidth > small.windowWidth + 180 &&
                geometry.windowHeight > small.windowHeight + 120 &&
                geometry.panelWidth > small.panelWidth + 180 &&
                geometry.panelHeight > small.panelHeight + 120 &&
                geometry.fillsAvailableViewport
        }, beforeEachPoll: {
            self.writeViewportResizeRequest("1180x780", atPath: commandPath)
            self.writeViewportResizeRequest("1180x780", atPath: dataPath)
        }) else {
            XCTFail("Timed out waiting for resized terminal viewport geometry. data=\(loadJSON(atPath: dataPath) ?? [:])")
            return
        }
        assertTerminalViewportFillsAvailableSpace(large)
    }

    private struct ViewportGeometry {
        let data: [String: String]
        let requestedWindowSize: String
        let windowWidth: CGFloat
        let windowHeight: CGFloat
        let windowContentWidth: CGFloat
        let windowContentHeight: CGFloat
        let panelWidth: CGFloat
        let panelHeight: CGFloat
        let hostedFrameMinX: CGFloat
        let hostedFrameMinY: CGFloat
        let hostedFrameWidth: CGFloat
        let hostedFrameHeight: CGFloat
        let hostedBoundsWidth: CGFloat
        let hostedBoundsHeight: CGFloat

        var fillsAvailableViewport: Bool {
            windowContentWidth > 300 &&
                windowContentHeight > 240 &&
                abs(hostedFrameMinX) <= 3 &&
                abs(hostedFrameMinY) <= 3 &&
                abs(hostedFrameWidth - panelWidth) <= 3 &&
                abs(hostedFrameHeight - panelHeight) <= 3 &&
                abs(hostedBoundsWidth - hostedFrameWidth) <= 3 &&
                abs(hostedBoundsHeight - hostedFrameHeight) <= 3 &&
                panelWidth >= windowContentWidth - 24 &&
                panelHeight >= windowContentHeight - 130
        }

        init?(data: [String: String]) {
            guard data["terminalViewportReady"] == "1",
                  data["terminalViewportSidebarVisible"] == "0",
                  data["terminalViewportRightSidebarVisible"] == "0" else {
                return nil
            }
            self.data = data
            requestedWindowSize = data["terminalViewportRequestedWindowSize"] ?? ""
            guard let windowWidth = Self.number("terminalViewportWindowWidth", in: data),
                  let windowHeight = Self.number("terminalViewportWindowHeight", in: data),
                  let windowContentWidth = Self.number("terminalViewportWindowContentWidth", in: data),
                  let windowContentHeight = Self.number("terminalViewportWindowContentHeight", in: data),
                  let panelWidth = Self.number("terminalViewportPanelWidth", in: data),
                  let panelHeight = Self.number("terminalViewportPanelHeight", in: data),
                  let hostedFrameMinX = Self.number("terminalViewportHostedFrameMinX", in: data),
                  let hostedFrameMinY = Self.number("terminalViewportHostedFrameMinY", in: data),
                  let hostedFrameWidth = Self.number("terminalViewportHostedFrameWidth", in: data),
                  let hostedFrameHeight = Self.number("terminalViewportHostedFrameHeight", in: data),
                  let hostedBoundsWidth = Self.number("terminalViewportHostedBoundsWidth", in: data),
                  let hostedBoundsHeight = Self.number("terminalViewportHostedBoundsHeight", in: data) else {
                return nil
            }
            self.windowWidth = windowWidth
            self.windowHeight = windowHeight
            self.windowContentWidth = windowContentWidth
            self.windowContentHeight = windowContentHeight
            self.panelWidth = panelWidth
            self.panelHeight = panelHeight
            self.hostedFrameMinX = hostedFrameMinX
            self.hostedFrameMinY = hostedFrameMinY
            self.hostedFrameWidth = hostedFrameWidth
            self.hostedFrameHeight = hostedFrameHeight
            self.hostedBoundsWidth = hostedBoundsWidth
            self.hostedBoundsHeight = hostedBoundsHeight
        }

        private static func number(_ key: String, in data: [String: String]) -> CGFloat? {
            guard let rawValue = data[key], let value = Double(rawValue) else { return nil }
            return CGFloat(value)
        }
    }

    private func assertTerminalViewportFillsAvailableSpace(
        _ geometry: ViewportGeometry,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(geometry.hostedFrameMinX, 0, accuracy: 3, "geometry=\(geometry.data)", file: file, line: line)
        XCTAssertEqual(geometry.hostedFrameMinY, 0, accuracy: 3, "geometry=\(geometry.data)", file: file, line: line)
        XCTAssertEqual(geometry.hostedFrameWidth, geometry.panelWidth, accuracy: 3, "geometry=\(geometry.data)", file: file, line: line)
        XCTAssertEqual(geometry.hostedFrameHeight, geometry.panelHeight, accuracy: 3, "geometry=\(geometry.data)", file: file, line: line)
        XCTAssertEqual(geometry.hostedBoundsWidth, geometry.hostedFrameWidth, accuracy: 3, "geometry=\(geometry.data)", file: file, line: line)
        XCTAssertEqual(geometry.hostedBoundsHeight, geometry.hostedFrameHeight, accuracy: 3, "geometry=\(geometry.data)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(geometry.panelWidth, geometry.windowContentWidth - 24, "geometry=\(geometry.data)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(geometry.panelHeight, geometry.windowContentHeight - 130, "geometry=\(geometry.data)", file: file, line: line)
    }

    private func waitForViewportGeometry(
        atPath path: String,
        timeout: TimeInterval,
        matching predicate: (ViewportGeometry) -> Bool,
        beforeEachPoll: (() -> Void)? = nil
    ) -> ViewportGeometry? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            beforeEachPoll?()
            if let data = loadJSON(atPath: path),
               let geometry = ViewportGeometry(data: data),
               predicate(geometry) {
                return geometry
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let data = loadJSON(atPath: path),
           let geometry = ViewportGeometry(data: data),
           predicate(geometry) {
            return geometry
        }
        return nil
    }

    private func writeViewportResizeRequest(_ size: String, atPath path: String) {
        var payload = loadJSON(atPath: path) ?? [:]
        payload["terminalViewportRequestedWindowSize"] = size
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadJSON(atPath path: String) -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return object
    }
}
