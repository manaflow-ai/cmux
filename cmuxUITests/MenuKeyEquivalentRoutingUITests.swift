import XCTest
import Foundation
import CoreGraphics
import ImageIO
import Darwin

final class MenuKeyEquivalentRoutingUITests: XCTestCase {
    private var gotoSplitPath = ""
    private var keyequivPath = ""
    private var socketPath = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        gotoSplitPath = "/tmp/cmux-ui-test-goto-split-\(UUID().uuidString).json"
        keyequivPath = "/tmp/cmux-ui-test-keyequiv-\(UUID().uuidString).json"
        socketPath = "/tmp/cmux-ui-test-socket-\(UUID().uuidString).sock"

        try? FileManager.default.removeItem(atPath: gotoSplitPath)
        try? FileManager.default.removeItem(atPath: keyequivPath)
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    func testCmdNWorksWhenWebViewFocusedAfterTabSwitch() {
        let app = launchWithBrowserSetup()

        // Simulate the repro: switch away and back.
        app.typeKey("[", modifierFlags: [.command, .shift])
        app.typeKey("]", modifierFlags: [.command, .shift])

        // Force WebKit to become first responder again (Cmd+L then Escape).
        refocusWebView(app: app)

        let baseline = loadKeyequiv()["addTabInvocations"].flatMap(Int.init) ?? 0
        app.typeKey("n", modifierFlags: [.command])

        XCTAssertTrue(
            waitForKeyequivInt(key: "addTabInvocations", toBeAtLeast: baseline + 1, timeout: 5.0),
            "Expected Cmd+N to reach app menu and create a new tab even when WKWebView is first responder"
        )
    }

    func testCmdWWorksWhenWebViewFocusedAfterTabSwitch() {
        let app = launchWithBrowserSetup()

        // Simulate the repro: switch away and back.
        app.typeKey("[", modifierFlags: [.command, .shift])
        app.typeKey("]", modifierFlags: [.command, .shift])

        // Force WebKit to become first responder again (Cmd+L then Escape).
        refocusWebView(app: app)

        let baseline = loadKeyequiv()["closePanelInvocations"].flatMap(Int.init) ?? 0
        app.typeKey("w", modifierFlags: [.command])

        XCTAssertTrue(
            waitForKeyequivInt(key: "closePanelInvocations", toBeAtLeast: baseline + 1, timeout: 5.0),
            "Expected Cmd+W to reach app menu and close the focused tab even when WKWebView is first responder"
        )
    }

    func testCmdShiftWWorksWhenWebViewFocusedAfterTabSwitch() {
        let app = launchWithBrowserSetup()

        // Simulate the repro: switch away and back.
        app.typeKey("[", modifierFlags: [.command, .shift])
        app.typeKey("]", modifierFlags: [.command, .shift])

        // Force WebKit to become first responder again (Cmd+L then Escape).
        refocusWebView(app: app)

        let baseline = loadKeyequiv()["closeTabInvocations"].flatMap(Int.init) ?? 0
        app.typeKey("w", modifierFlags: [.command, .shift])

        XCTAssertTrue(
            waitForKeyequivInt(key: "closeTabInvocations", toBeAtLeast: baseline + 1, timeout: 6.0),
            "Expected Cmd+Shift+W to reach app menu and close the current workspace even when WKWebView is first responder"
        )
    }

    private func launchWithBrowserSetup() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = gotoSplitPath
        app.launchEnvironment["CMUX_UI_TEST_KEYEQUIV_PATH"] = keyequivPath
        app.launch()
        app.activate()

        XCTAssertTrue(
            waitForGotoSplit(keys: ["browserPanelId", "webViewFocused"], timeout: 10.0),
            "Expected goto_split setup data to be written"
        )

        if let setup = loadGotoSplit() {
            XCTAssertEqual(setup["webViewFocused"], "true", "Expected WKWebView to be first responder for this test setup")
        }

        return app
    }

    private func refocusWebView(app: XCUIApplication) {
        // Cmd+L focuses the omnibar (so WebKit is no longer first responder).
        app.typeKey("l", modifierFlags: [.command])
        XCTAssertTrue(
            waitForGotoSplitMatch(timeout: 5.0) { data in
                data["webViewFocusedAfterAddressBarFocus"] == "false"
            },
            "Expected Cmd+L to focus omnibar (WebKit not first responder)"
        )

        // Escape should leave the omnibar and focus WebKit again.
        // Send Escape twice: the first may only clear suggestions/editing state
        // (Chrome-like two-stage escape), the second triggers blur to WebView.
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        if !waitForGotoSplitMatch(timeout: 2.0, predicate: { $0["webViewFocusedAfterAddressBarExit"] == "true" }) {
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        }
        XCTAssertTrue(
            waitForGotoSplitMatch(timeout: 5.0) { data in
                data["webViewFocusedAfterAddressBarExit"] == "true"
            },
            "Expected Escape to return focus to WebKit"
        )
    }

    private func waitForGotoSplit(keys: [String], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = loadGotoSplit(), keys.allSatisfy({ data[$0] != nil }) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let data = loadGotoSplit(), keys.allSatisfy({ data[$0] != nil }) {
            return true
        }
        return false
    }

    private func waitForGotoSplitMatch(timeout: TimeInterval, predicate: ([String: String]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = loadGotoSplit(), predicate(data) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let data = loadGotoSplit(), predicate(data) {
            return true
        }
        return false
    }

    private func waitForKeyequivInt(key: String, toBeAtLeast expected: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let value = loadKeyequiv()[key].flatMap(Int.init) ?? 0
            if value >= expected {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let value = loadKeyequiv()[key].flatMap(Int.init) ?? 0
        return value >= expected
    }

    private func loadGotoSplit() -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: gotoSplitPath)) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }

    private func loadKeyequiv() -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: keyequivPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }
}

final class SplitCloseRightBlankRegressionUITests: XCTestCase {
    private var dataPath = ""
    private var socketPath = ""
    private var diagnosticsPath = ""
    private var screenshotDir = ""
    private var socketClient: ControlSocketClient?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        // Ensure a fresh app instance per test; otherwise shutdown races from a prior test can
        // overlap with split setup and cause transient "initial terminal not ready" failures.
        let cleanup = XCUIApplication()
        cleanup.terminate()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        dataPath = "/tmp/cmux-ui-test-split-close-right-\(UUID().uuidString).json"
        socketPath = "/tmp/cmux-ui-test-socket-\(UUID().uuidString).sock"
        diagnosticsPath = "/tmp/cmux-ui-test-diagnostics-\(UUID().uuidString).json"
        // Prefer a globally accessible dir so we can pull screenshots from the VM for debugging.
        // If sandbox rules prevent this, fall back to the runner's container temp dir.
        let leaf = "cmux-ui-test-split-close-right-shots-\(UUID().uuidString)"
        let preferredURL = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(leaf)
        let fallbackURL = FileManager.default.temporaryDirectory.appendingPathComponent(leaf)
        // Attempt to create the preferred dir; if it fails, use fallback.
        if (try? FileManager.default.createDirectory(at: preferredURL, withIntermediateDirectories: true)) != nil {
            screenshotDir = preferredURL.path
        } else {
            screenshotDir = fallbackURL.path
        }
        try? FileManager.default.removeItem(atPath: dataPath)
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
        try? FileManager.default.removeItem(atPath: screenshotDir)
        try? FileManager.default.createDirectory(atPath: screenshotDir, withIntermediateDirectories: true)
    }

    func testClosingBothRightSplitsDoesNotLeaveBlankPane() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_PATH"] = dataPath
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        app.launch()
        app.activate()

        XCTAssertTrue(waitForAnyData(timeout: 12.0), "Expected split-close-right test data to be written at \(dataPath)")

        guard let data = waitForSettledData(timeout: 10.0) else {
            XCTFail("Missing split-close-right test data after waiting for settle")
            return
        }

        if let setupError = data["setupError"], !setupError.isEmpty {
            XCTFail("Test setup failed: \(setupError)")
            return
        }

        let finalPaneCount = Int(data["finalPaneCount"] ?? "") ?? -1
        let missingSelected = Int(data["missingSelectedTabCount"] ?? "") ?? -1
        let missingMapping = Int(data["missingPanelMappingCount"] ?? "") ?? -1
        let emptyPanels = Int(data["emptyPanelAppearCount"] ?? "") ?? -1
        let selectedTerminalCount = Int(data["selectedTerminalCount"] ?? "") ?? -1
        let selectedTerminalAttached = Int(data["selectedTerminalAttachedCount"] ?? "") ?? -1
        let selectedTerminalZeroSize = Int(data["selectedTerminalZeroSizeCount"] ?? "") ?? -1
        let selectedTerminalSurfaceNil = Int(data["selectedTerminalSurfaceNilCount"] ?? "") ?? -1
        let preTerminalAttached = Int(data["preTerminalAttached"] ?? "") ?? -1
        let preTerminalSurfaceNil = Int(data["preTerminalSurfaceNil"] ?? "") ?? -1

        // Expected correct behavior: after closing the two right panes, we should have a clean 1x2 stack,
        // and both panes should have a selected bonsplit tab that maps to an existing Panel.
        XCTAssertEqual(preTerminalAttached, 1, "Expected the initial terminal view to be attached to a window before the repro runs")
        XCTAssertEqual(preTerminalSurfaceNil, 0, "Expected the initial terminal to have a non-nil ghostty_surface before the repro runs")
        XCTAssertEqual(finalPaneCount, 2, "Expected 2 panes after closing both right splits")
        XCTAssertEqual(missingSelected, 0, "Expected no pane to have a nil selected tab")
        XCTAssertEqual(missingMapping, 0, "Expected no selected bonsplit tab to be missing its Panel mapping")
        XCTAssertEqual(emptyPanels, 0, "Expected no Empty Panel views to appear during the close sequence")
        XCTAssertEqual(selectedTerminalCount, 2, "Expected both remaining panes to be terminal panels")
        XCTAssertEqual(selectedTerminalAttached, 2, "Expected both remaining terminal views to be attached to a window")
        XCTAssertEqual(selectedTerminalZeroSize, 0, "Expected no remaining terminal view to have a zero-ish size")
        XCTAssertEqual(selectedTerminalSurfaceNil, 0, "Expected no remaining terminal to have a nil ghostty_surface")
    }

    func testReproBlankAfterClosingRightSplitsViaShortcuts() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_VISUAL"] = "1"
        // The regression can be a single compositor frame; capture enough post-close frames to
        // deterministically catch it.
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_ITERATIONS"] = "12"
        // Close quickly (closer to how a user can click two close buttons back-to-back).
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_CLOSE_DELAY_MS"] = "0"
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_BURST_FRAMES"] = "32"
        // Repro order that still flashes for users: split left/right first, then split top/down.
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_PATTERN"] = "close_right_lrtd"
        app.launch()
        app.activate()

        XCTAssertTrue(waitForAnyData(timeout: 12.0), "Expected split-close-right test data to be written at \(dataPath)")

        // Wait for the app-side repro loop to finish.
        let doneDeadline = Date().addingTimeInterval(90.0)
        while Date() < doneDeadline {
            if let data = loadData(), data["visualDone"] == "1" {
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.10))
        }

        guard let data = loadData() else {
            XCTFail("Missing split-close-right data after waiting. path=\(dataPath)")
            return
        }
        if let setupError = data["setupError"], !setupError.isEmpty {
            XCTFail("Test setup failed: \(setupError)")
            return
        }

        let lastIter = Int(data["visualLastIteration"] ?? "") ?? 0
        XCTAssertGreaterThan(lastIter, 0, "Expected at least one visual iteration. data=\(data)")

        let blankSeen = (data["blankFrameSeen"] ?? "") == "1"
        let sizeMismatchSeen = (data["sizeMismatchSeen"] ?? "") == "1"
        let trace = data["timelineTrace"] ?? ""

        XCTAssertFalse(
            blankSeen,
            "Transient blank frame detected. at=\(data["blankObservedAt"] ?? "") iter=\(data["blankObservedIteration"] ?? "") trace=\(trace)"
        )
        XCTAssertFalse(
            sizeMismatchSeen,
            "Transient IOSurface size mismatch detected (stretched text). at=\(data["sizeMismatchObservedAt"] ?? "") iter=\(data["sizeMismatchObservedIteration"] ?? "") trace=\(trace)"
        )
    }

    func testReproStretchAfterClosingSingleRightSplit() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_VISUAL"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_ITERATIONS"] = "16"
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_CLOSE_DELAY_MS"] = "0"
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_BURST_FRAMES"] = "36"
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_PATTERN"] = "close_right_single"
        app.launch()
        app.activate()

        XCTAssertTrue(waitForAnyData(timeout: 12.0), "Expected split-close-right test data to be written at \(dataPath)")

        let doneDeadline = Date().addingTimeInterval(90.0)
        while Date() < doneDeadline {
            if let data = loadData(), data["visualDone"] == "1" {
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.10))
        }

        guard let data = loadData() else {
            XCTFail("Missing split-close-right data after waiting. path=\(dataPath)")
            return
        }
        if let setupError = data["setupError"], !setupError.isEmpty {
            XCTFail("Test setup failed: \(setupError)")
            return
        }

        let lastIter = Int(data["visualLastIteration"] ?? "") ?? 0
        XCTAssertGreaterThan(lastIter, 0, "Expected at least one visual iteration. data=\(data)")

        let sizeMismatchSeen = (data["sizeMismatchSeen"] ?? "") == "1"
        let trace = data["timelineTrace"] ?? ""

        XCTAssertFalse(
            sizeMismatchSeen,
            "Transient IOSurface size mismatch detected (stretched text). at=\(data["sizeMismatchObservedAt"] ?? "") iter=\(data["sizeMismatchObservedIteration"] ?? "") trace=\(trace)"
        )
    }

    func testReproBlankAfterClosingBottomSplitsViaShortcuts() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_VISUAL"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_ITERATIONS"] = "12"
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_CLOSE_DELAY_MS"] = "0"
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_BURST_FRAMES"] = "32"
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_PATTERN"] = "close_bottom"
        app.launch()
        app.activate()

        XCTAssertTrue(waitForAnyData(timeout: 12.0), "Expected split-close-right test data to be written at \(dataPath)")

        let doneDeadline = Date().addingTimeInterval(90.0)
        while Date() < doneDeadline {
            if let data = loadData(), data["visualDone"] == "1" {
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.10))
        }

        guard let data = loadData() else {
            XCTFail("Missing split-close-right data after waiting. path=\(dataPath)")
            return
        }
        if let setupError = data["setupError"], !setupError.isEmpty {
            XCTFail("Test setup failed: \(setupError)")
            return
        }

        let lastIter = Int(data["visualLastIteration"] ?? "") ?? 0
        XCTAssertGreaterThan(lastIter, 0, "Expected at least one visual iteration. data=\(data)")

        let blankSeen = (data["blankFrameSeen"] ?? "") == "1"
        let sizeMismatchSeen = (data["sizeMismatchSeen"] ?? "") == "1"
        let trace = data["timelineTrace"] ?? ""

        XCTAssertFalse(
            blankSeen,
            "Transient blank frame detected. at=\(data["blankObservedAt"] ?? "") iter=\(data["blankObservedIteration"] ?? "") trace=\(trace)"
        )
        XCTAssertFalse(
            sizeMismatchSeen,
            "Transient IOSurface size mismatch detected (stretched text). at=\(data["sizeMismatchObservedAt"] ?? "") iter=\(data["sizeMismatchObservedIteration"] ?? "") trace=\(trace)"
        )
    }

    func testReproBlankAfterClosingRightSplitsTopFirstWithGap() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_VISUAL"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_ITERATIONS"] = "14"
        // Reproduce manual close cadence: close top-right, observe one frame, then close bottom-right.
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_CLOSE_DELAY_MS"] = "120"
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_BURST_FRAMES"] = "40"
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_PATTERN"] = "close_right_lrtd"
        app.launch()
        app.activate()

        XCTAssertTrue(waitForAnyData(timeout: 12.0), "Expected split-close-right test data to be written at \(dataPath)")

        let doneDeadline = Date().addingTimeInterval(90.0)
        while Date() < doneDeadline {
            if let data = loadData(), data["visualDone"] == "1" {
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.10))
        }

        guard let data = loadData() else {
            XCTFail("Missing split-close-right data after waiting. path=\(dataPath)")
            return
        }
        if let setupError = data["setupError"], !setupError.isEmpty {
            XCTFail("Test setup failed: \(setupError)")
            return
        }

        let lastIter = Int(data["visualLastIteration"] ?? "") ?? 0
        XCTAssertGreaterThan(lastIter, 0, "Expected at least one visual iteration. data=\(data)")

        let blankSeen = (data["blankFrameSeen"] ?? "") == "1"
        let sizeMismatchSeen = (data["sizeMismatchSeen"] ?? "") == "1"
        let trace = data["timelineTrace"] ?? ""

        XCTAssertFalse(
            blankSeen,
            "Transient blank frame detected. at=\(data["blankObservedAt"] ?? "") iter=\(data["blankObservedIteration"] ?? "") trace=\(trace)"
        )
        XCTAssertFalse(
            sizeMismatchSeen,
            "Transient IOSurface size mismatch detected (stretched text). at=\(data["sizeMismatchObservedAt"] ?? "") iter=\(data["sizeMismatchObservedIteration"] ?? "") trace=\(trace)"
        )
    }

    func testReproBlankAfterClosingRightSplitsBottomFirstViaShortcuts() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_VISUAL"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_ITERATIONS"] = "12"
        // Keep a short but non-zero delay so we sample the transient frame after BR closes
        // and before TR closes (the user-visible stretched-text repro window).
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_CLOSE_DELAY_MS"] = "120"
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_BURST_FRAMES"] = "40"
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_PATTERN"] = "close_right_lrtd_bottom_first"
        app.launch()
        app.activate()

        XCTAssertTrue(waitForAnyData(timeout: 12.0), "Expected split-close-right test data to be written at \(dataPath)")

        let doneDeadline = Date().addingTimeInterval(90.0)
        while Date() < doneDeadline {
            if let data = loadData(), data["visualDone"] == "1" {
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.10))
        }

        guard let data = loadData() else {
            XCTFail("Missing split-close-right data after waiting. path=\(dataPath)")
            return
        }
        if let setupError = data["setupError"], !setupError.isEmpty {
            XCTFail("Test setup failed: \(setupError)")
            return
        }

        let lastIter = Int(data["visualLastIteration"] ?? "") ?? 0
        XCTAssertGreaterThan(lastIter, 0, "Expected at least one visual iteration. data=\(data)")

        let blankSeen = (data["blankFrameSeen"] ?? "") == "1"
        let sizeMismatchSeen = (data["sizeMismatchSeen"] ?? "") == "1"
        let trace = data["timelineTrace"] ?? ""

        XCTAssertFalse(
            blankSeen,
            "Transient blank frame detected. at=\(data["blankObservedAt"] ?? "") iter=\(data["blankObservedIteration"] ?? "") trace=\(trace)"
        )
        XCTAssertFalse(
            sizeMismatchSeen,
            "Transient IOSurface size mismatch detected (stretched text). at=\(data["sizeMismatchObservedAt"] ?? "") iter=\(data["sizeMismatchObservedIteration"] ?? "") trace=\(trace)"
        )
    }

    func testReproBlankAfterClosingRightSplitsWithoutFocusingRightPanes() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_VISUAL"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_ITERATIONS"] = "16"
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_CLOSE_DELAY_MS"] = "0"
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_BURST_FRAMES"] = "36"
        app.launchEnvironment["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_PATTERN"] = "close_right_lrtd_unfocused"
        app.launch()
        app.activate()

        XCTAssertTrue(waitForAnyData(timeout: 12.0), "Expected split-close-right test data to be written at \(dataPath)")

        let doneDeadline = Date().addingTimeInterval(90.0)
        while Date() < doneDeadline {
            if let data = loadData(), data["visualDone"] == "1" {
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.10))
        }

        guard let data = loadData() else {
            XCTFail("Missing split-close-right data after waiting. path=\(dataPath)")
            return
        }
        if let setupError = data["setupError"], !setupError.isEmpty {
            XCTFail("Test setup failed: \(setupError)")
            return
        }

        let lastIter = Int(data["visualLastIteration"] ?? "") ?? 0
        XCTAssertGreaterThan(lastIter, 0, "Expected at least one visual iteration. data=\(data)")

        let blankSeen = (data["blankFrameSeen"] ?? "") == "1"
        let sizeMismatchSeen = (data["sizeMismatchSeen"] ?? "") == "1"
        let trace = data["timelineTrace"] ?? ""

        XCTAssertFalse(
            blankSeen,
            "Transient blank frame detected. at=\(data["blankObservedAt"] ?? "") iter=\(data["blankObservedIteration"] ?? "") trace=\(trace)"
        )
        XCTAssertFalse(
            sizeMismatchSeen,
            "Transient IOSurface size mismatch detected (stretched text). at=\(data["sizeMismatchObservedAt"] ?? "") iter=\(data["sizeMismatchObservedIteration"] ?? "") trace=\(trace)"
        )
    }

    // MARK: - Screenshot-Based Blank Detection

    private struct CropStats {
        let sampleCount: Int
        let uniqueQuantized: Int
        let lumaStdDev: Double
        let modeFraction: Double
        let fingerprint: UInt64

        var isProbablyBlank: Bool {
            // Tuned for "terminal went visually blank": near-uniform region, very low contrast.
            // (The exact thresholds are conservative; we also require consecutive blank samples below.)
            return lumaStdDev < 2.5 && modeFraction > 0.992
        }
    }

    private func assertPaneRendersAndUpdates(
        app: XCUIApplication,
        window: XCUIElement,
        paneCenter: CGVector,
        blankCrop: CGRect,
        updateCrop: CGRect,
        label: String
    ) {
        // We want to catch:
        // 1) pane visually blank (uniform background)
        // 2) pane visually frozen (doesn't update after printing)
        //
        // We deliberately avoid relying on "Empty Panel" accessibility text, since the regression
        // you're reporting is a blank terminal surface, not necessarily the EmptyPanelView.

        func takeStats(_ name: String, crop: CGRect) -> (String, CropStats)? {
            guard let path = writeScreenshot(window: window, name: name),
                  let png = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let stats = cropStats(pngData: png, normalizedCrop: crop) else {
                return nil
            }
            return (path, stats)
        }

        // Capture a baseline frame.
        guard let (preBlankPath, preBlankStats) = takeStats("\(label)-pre-blank", crop: blankCrop),
              let (preUpdatePath, preUpdateStats) = takeStats("\(label)-pre-update", crop: updateCrop) else {
            XCTFail("Failed to capture pre screenshot for \(label). shots=\(screenshotDir)")
            return
        }

        // Trigger a visible update in the pane.
        window.coordinate(withNormalizedOffset: paneCenter).click()
        // Print a lot of lines so the update is visible in a screenshot diff even with subsampling.
        let token = String(UUID().uuidString.prefix(8))
        app.typeText("yes CMUX_AFTER_CLOSE_\(label)_\(token) | head -n 30\n")
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))

        guard let (postBlankPath, postBlankStats) = takeStats("\(label)-post-blank", crop: blankCrop),
              let (postUpdatePath, postUpdateStats) = takeStats("\(label)-post-update", crop: updateCrop) else {
            XCTFail("Failed to capture post screenshot for \(label). shots=\(screenshotDir)")
            return
        }

        if postBlankStats.isProbablyBlank {
            addKeptScreenshot(path: preBlankPath, name: "\(label)-pre-blank")
            addKeptScreenshot(path: postBlankPath, name: "\(label)-post-blank")
            XCTFail("Pane looks blank after close. label=\(label) pre=\(preBlankStats) post=\(postBlankStats) shots=\(screenshotDir)")
            return
        }

        // Fingerprints can collide on terminal content (white glyphs on dark background with similar
        // layout). Use a mean absolute luma diff threshold to detect a truly frozen surface.
        // Compare only the pane area to avoid false positives from other UI movement.
        if let prePng = try? Data(contentsOf: URL(fileURLWithPath: preUpdatePath)),
           let postPng = try? Data(contentsOf: URL(fileURLWithPath: postUpdatePath)),
           let diff = meanAbsLumaDiff(pngA: prePng, pngB: postPng, normalizedCrop: updateCrop),
           diff < 1.0 {
            addKeptScreenshot(path: preUpdatePath, name: "\(label)-pre-update")
            addKeptScreenshot(path: postUpdatePath, name: "\(label)-post-update")
            XCTFail("Pane looks frozen (no visual change after printing). label=\(label) diff=\(diff) pre=\(preUpdateStats) post=\(postUpdateStats) shots=\(screenshotDir)")
            return
        }

        // Also guard against a delayed blanking: watch for ~1.5s and fail if it goes blank for sustained streak.
        let deadline = Date().addingTimeInterval(1.5)
        var blankStreak = 0
        var sampleIndex = 0
        while Date() < deadline {
            sampleIndex += 1
            guard let (path, stats) = takeStats("\(label)-watch-\(String(format: "%02d", sampleIndex))", crop: blankCrop) else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.17))
                continue
            }
            if stats.isProbablyBlank {
                blankStreak += 1
            } else {
                blankStreak = 0
            }
            if blankStreak >= 6 { // ~1s
                addKeptScreenshot(path: path, name: "\(label)-watch-last")
                XCTFail("Pane became blank for sustained period after close. label=\(label) stats=\(stats) shots=\(screenshotDir)")
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.17))
        }
    }

    @discardableResult
    private func writeScreenshot(window: XCUIElement, name: String) -> String? {
        let shot = window.screenshot()
        let path = "\(screenshotDir)/\(name).png"
        do {
            try shot.pngRepresentation.write(to: URL(fileURLWithPath: path))
            return path
        } catch {
            return nil
        }
    }

    private func addKeptScreenshot(path: String, name: String) {
        let attachment = XCTAttachment(contentsOfFile: URL(fileURLWithPath: path))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func meanAbsLumaDiff(pngA: Data, pngB: Data, normalizedCrop: CGRect) -> Double? {
        guard let imageA = cgImage(from: pngA),
              let imageB = cgImage(from: pngB) else {
            return nil
        }
        guard imageA.width == imageB.width, imageA.height == imageB.height else { return nil }
        let width = imageA.width
        let height = imageA.height
        if width <= 0 || height <= 0 { return nil }

        let cropPx = CGRect(
            x: max(0, min(CGFloat(width - 1), normalizedCrop.origin.x * CGFloat(width))),
            y: max(0, min(CGFloat(height - 1), normalizedCrop.origin.y * CGFloat(height))),
            width: max(1, min(CGFloat(width), normalizedCrop.width * CGFloat(width))),
            height: max(1, min(CGFloat(height), normalizedCrop.height * CGFloat(height)))
        ).integral

        let x0 = Int(cropPx.minX)
        let y0 = Int(cropPx.minY)
        let x1 = Int(min(CGFloat(width), cropPx.maxX))
        let y1 = Int(min(CGFloat(height), cropPx.maxY))
        if x1 <= x0 || y1 <= y0 { return nil }

        guard let bufA = decodeRGBA(imageA), let bufB = decodeRGBA(imageB) else { return nil }
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel

        let step = 3
        var total = 0.0
        var count = 0
        for y in stride(from: y0, to: y1, by: step) {
            let row = y * bytesPerRow
            for x in stride(from: x0, to: x1, by: step) {
                let i = row + x * bytesPerPixel
                let ar = Double(bufA[i])
                let ag = Double(bufA[i + 1])
                let ab = Double(bufA[i + 2])
                let br = Double(bufB[i])
                let bg = Double(bufB[i + 1])
                let bb = Double(bufB[i + 2])
                let al = 0.2126 * ar + 0.7152 * ag + 0.0722 * ab
                let bl = 0.2126 * br + 0.7152 * bg + 0.0722 * bb
                total += abs(al - bl)
                count += 1
            }
        }
        return count > 0 ? (total / Double(count)) : nil
    }

    private func cgImage(from pngData: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func decodeRGBA(_ image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var buf = [UInt8](repeating: 0, count: height * bytesPerRow)

        // Important: pass the *pixel buffer* pointer, not the Array object address.
        // Also pin the pixel format so our [r,g,b,a] indexing matches reality.
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }

            let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            guard let ctx = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            ) else { return false }

            // Note: do not flip the context here.
            // With CGImage decoded from XCUI screenshots, the bitmap memory we get from a plain
            // draw() already matches the "top-left origin" expectation used by our normalized crops.
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        return ok ? buf : nil
    }

    private func cropStats(pngData: Data, normalizedCrop: CGRect) -> CropStats? {
        guard let image = cgImage(from: pngData) else {
            return nil
        }

        let width = image.width
        let height = image.height
        if width <= 0 || height <= 0 { return nil }

        let cropPx = CGRect(
            x: max(0, min(CGFloat(width - 1), normalizedCrop.origin.x * CGFloat(width))),
            y: max(0, min(CGFloat(height - 1), normalizedCrop.origin.y * CGFloat(height))),
            width: max(1, min(CGFloat(width), normalizedCrop.width * CGFloat(width))),
            height: max(1, min(CGFloat(height), normalizedCrop.height * CGFloat(height)))
        ).integral

        // Render into a known RGBA8 buffer with top-left origin.
        guard let buf = decodeRGBA(image) else { return nil }
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel

        let x0 = Int(cropPx.minX)
        let y0 = Int(cropPx.minY)
        let x1 = Int(min(CGFloat(width), cropPx.maxX))
        let y1 = Int(min(CGFloat(height), cropPx.maxY))
        if x1 <= x0 || y1 <= y0 { return nil }

        // Sample every N pixels to keep this cheap and stable.
        let step = 3
        var lumas = [Double]()
        lumas.reserveCapacity(((x1 - x0) / step) * ((y1 - y0) / step))

        // Quantize RGB to 4 bits/channel and track uniqueness + mode.
        var hist = [UInt16: Int]()
        hist.reserveCapacity(256)

        var count = 0
        var fnv: UInt64 = 1469598103934665603 // FNV-1a offset basis
        for y in stride(from: y0, to: y1, by: step) {
            let rowBase = y * bytesPerRow
            for x in stride(from: x0, to: x1, by: step) {
                let i = rowBase + x * bytesPerPixel
                let r = Double(buf[i])
                let g = Double(buf[i + 1])
                let b = Double(buf[i + 2])
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                lumas.append(luma)

                let rq = UInt16(UInt8(buf[i]) >> 4)
                let gq = UInt16(UInt8(buf[i + 1]) >> 4)
                let bq = UInt16(UInt8(buf[i + 2]) >> 4)
                let key = (rq << 8) | (gq << 4) | bq
                hist[key, default: 0] += 1
                count += 1

                // Fingerprint based on quantized luma (coarse) plus position order.
                let lq = UInt8(max(0, min(63, Int(luma / 4.0)))) // ~6 bits
                fnv ^= UInt64(lq)
                fnv &*= 1099511628211
            }
        }

        guard count > 0 else { return nil }

        // stddev of luma
        let mean = lumas.reduce(0.0, +) / Double(lumas.count)
        let variance = lumas.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(lumas.count)
        let stddev = sqrt(variance)

        // mode fraction
        let modeCount = hist.values.max() ?? 0
        let modeFrac = Double(modeCount) / Double(count)

        return CropStats(
            sampleCount: count,
            uniqueQuantized: hist.count,
            lumaStdDev: stddev,
            modeFraction: modeFrac,
            fingerprint: fnv
        )
    }

    private func waitForData(keys: [String], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = loadData(), keys.allSatisfy({ data[$0] != nil }) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let data = loadData(), keys.allSatisfy({ data[$0] != nil }) {
            return true
        }
        return false
    }

    private func waitForAnyData(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if loadData() != nil {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return loadData() != nil
    }

    private func waitForSettledData(timeout: TimeInterval) -> [String: String]? {
        let deadline = Date().addingTimeInterval(timeout)
        var last: [String: String]?

        while Date() < deadline {
            if let data = loadData() {
                last = data

                if let setupError = data["setupError"], !setupError.isEmpty {
                    return data
                }

                let finalPaneCount = Int(data["finalPaneCount"] ?? "") ?? -1
                let missingSelected = Int(data["missingSelectedTabCount"] ?? "") ?? -1
                let missingMapping = Int(data["missingPanelMappingCount"] ?? "") ?? -1
                let emptyPanels = Int(data["emptyPanelAppearCount"] ?? "") ?? -1
                let selectedTerminalCount = Int(data["selectedTerminalCount"] ?? "") ?? -1
                let selectedTerminalAttached = Int(data["selectedTerminalAttachedCount"] ?? "") ?? -1
                let selectedTerminalZeroSize = Int(data["selectedTerminalZeroSizeCount"] ?? "") ?? -1
                let selectedTerminalSurfaceNil = Int(data["selectedTerminalSurfaceNilCount"] ?? "") ?? -1

                let settled =
                    finalPaneCount == 2 &&
                    missingSelected == 0 &&
                    missingMapping == 0 &&
                    emptyPanels == 0 &&
                    selectedTerminalCount == 2 &&
                    selectedTerminalAttached == 2 &&
                    selectedTerminalZeroSize == 0 &&
                    selectedTerminalSurfaceNil == 0

                if settled {
                    return data
                }

                // `recordSplitCloseRightFinalState` streams attempts; give it time to converge.
                // If the bug is present it will never converge to "settled".
                let attempt = Int(data["finalAttempt"] ?? "") ?? -1
                if attempt >= 20 {
                    return data
                }
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        return last
    }

    private func loadData() -> [String: String]? {
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: dataPath)) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: raw)) as? [String: String]
    }

    private func loadDiagnostics() -> [String: String]? {
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: diagnosticsPath)) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: raw)) as? [String: String]
    }

    // MARK: - Automation Socket Client (UI Tests)

    private func waitForSocketPong(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if socketCommand("ping") == "PONG" {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return socketCommand("ping") == "PONG"
    }

    private func socketCommand(_ cmd: String) -> String? {
        if socketClient == nil {
            socketClient = ControlSocketClient(path: socketPath)
        }
        if let v = socketClient?.sendLine(cmd) {
            return v
        }
        // Fallback: use `nc -U` (more tolerant of Darwin sockaddr_un quirks across OS versions).
        return socketCommandViaNetcat(cmd)
    }

    private func socketCommandViaNetcat(_ cmd: String) -> String? {
        let nc = "/usr/bin/nc"
        guard FileManager.default.isExecutableFile(atPath: nc) else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nc)
        proc.arguments = ["-U", socketPath, "-w", "2"]

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            return nil
        }

        if let data = (cmd + "\n").data(using: .utf8) {
            inPipe.fileHandleForWriting.write(data)
        }
        inPipe.fileHandleForWriting.closeFile()

        proc.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let outStr = String(data: outData, encoding: .utf8) else { return nil }
        if let first = outStr.split(separator: "\n", maxSplits: 1).first {
            return String(first).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let trimmed = outStr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private final class ControlSocketClient {
        private let path: String

        init(path: String) {
            self.path = path
        }

        func sendLine(_ line: String) -> String? {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }

            var addr = sockaddr_un()
            // Zero-init is important because we compute a variable sockaddr length and
            // the kernel may validate `sun_len` on some macOS versions.
            memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
            addr.sun_family = sa_family_t(AF_UNIX)

            let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
            let bytes = Array(path.utf8CString) // includes null terminator
            guard bytes.count <= maxLen else { return nil }
            withUnsafeMutablePointer(to: &addr.sun_path) { p in
                let raw = UnsafeMutableRawPointer(p).assumingMemoryBound(to: CChar.self)
                memset(raw, 0, maxLen)
                for i in 0..<bytes.count {
                    raw[i] = bytes[i]
                }
            }

            // Darwin expects a sockaddr length that includes only the fields up to the pathname.
            let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
            let addrLen = socklen_t(pathOffset + bytes.count)
#if os(macOS)
            // `sun_len` exists on Darwin/BSD.
            addr.sun_len = UInt8(min(Int(addrLen), 255))
#endif

            let ok = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    connect(fd, sa, addrLen)
                }
            }
            guard ok == 0 else { return nil }

            let payload = line + "\n"
            let wrote: Bool = payload.withCString { cstr in
                var remaining = strlen(cstr)
                var p = UnsafeRawPointer(cstr)
                while remaining > 0 {
                    let n = write(fd, p, remaining)
                    if n <= 0 { return false }
                    remaining -= n
                    p = p.advanced(by: n)
                }
                return true
            }
            guard wrote else { return nil }

            var buf = [UInt8](repeating: 0, count: 4096)
            var accum = ""
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                if let chunk = String(bytes: buf[0..<n], encoding: .utf8) {
                    accum.append(chunk)
                    if let idx = accum.firstIndex(of: "\n") {
                        return String(accum[..<idx])
                    }
                }
            }
            return accum.isEmpty ? nil : accum.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
