import XCTest
import Foundation
import CoreGraphics
import ImageIO
import Darwin


// MARK: - Split-close regression tests
extension SplitCloseRightBlankRegressionUITests {
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
        XCTAssertTrue(waitForVisualDone(timeout: 90.0), "Expected visual repro loop to finish. path=\(dataPath)")

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

        XCTAssertTrue(waitForVisualDone(timeout: 90.0), "Expected visual repro loop to finish. path=\(dataPath)")

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

        XCTAssertTrue(waitForVisualDone(timeout: 90.0), "Expected visual repro loop to finish. path=\(dataPath)")

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

        XCTAssertTrue(waitForVisualDone(timeout: 90.0), "Expected visual repro loop to finish. path=\(dataPath)")

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

        XCTAssertTrue(waitForVisualDone(timeout: 90.0), "Expected visual repro loop to finish. path=\(dataPath)")

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

        XCTAssertTrue(waitForVisualDone(timeout: 90.0), "Expected visual repro loop to finish. path=\(dataPath)")

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

}
