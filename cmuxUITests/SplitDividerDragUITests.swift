import CoreGraphics
import Foundation
import XCTest

/// Click-and-drag on the split system must keep working: a press on the
/// divider between two terminal panes resizes them, and a press-and-drag on a
/// pane tab reorders the pane's tabs.
///
/// Both gestures go through the real pointer path (the terminal portal's hit
/// testing, bonsplit's split view, and the tab strip), so an overlay or event
/// monitor that swallows the press shows up here as "nothing moved".
final class SplitDividerDragUITests: SettingsUITestCase {
    func testDraggingVerticalSplitDividerResizesPanes() throws {
        let app = launchSplitApp()
        defer { app.terminate() }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "Expected the main window")
        let launchTerminal = app.textViews.firstMatch
        XCTAssertTrue(launchTerminal.waitForExistence(timeout: 15), "Expected the launch terminal")
        launchTerminal.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        app.typeKey("d", modifierFlags: [.command])
        var panes: (leading: XCUIElement, trailing: XCUIElement)?
        XCTAssertTrue(
            poll(timeout: 10) {
                panes = sideBySideTerminals(in: app)
                return panes != nil
            },
            "Expected Cmd+D to leave two side-by-side terminals; textViews=\(terminalFrames(in: app))"
        )
        guard let (leading, trailing) = panes else { return }
        // Let the split settle before measuring.
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))

        let leadingBefore = leading.frame
        let trailingBefore = trailing.frame
        let dividerX = (leadingBefore.maxX + trailingBefore.minX) / 2
        let dividerY = leadingBefore.midY
        attach(window.screenshot(), name: "01 before divider drag")

        let start = point(in: window, x: dividerX, y: dividerY)
        let end = start.withOffset(CGVector(dx: -160, dy: 0))
        start.press(forDuration: 0.3, thenDragTo: end)

        let resized = poll(timeout: 5) {
            leading.frame.width < leadingBefore.width - 80
                && trailing.frame.width > trailingBefore.width + 80
        }
        attach(window.screenshot(), name: "02 after divider drag")
        XCTAssertTrue(
            resized,
            "Expected dragging the divider 160 pt left to resize both panes. " +
                "before leading=\(leadingBefore) trailing=\(trailingBefore) " +
                "after leading=\(leading.frame) trailing=\(trailing.frame) divider=(\(dividerX), \(dividerY))"
        )
    }

    func testDraggingHorizontalSplitDividerResizesPanes() throws {
        let app = launchSplitApp()
        defer { app.terminate() }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "Expected the main window")
        let launchTerminal = app.textViews.firstMatch
        XCTAssertTrue(launchTerminal.waitForExistence(timeout: 15), "Expected the launch terminal")
        launchTerminal.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        app.typeKey("d", modifierFlags: [.command, .shift])
        var panes: (top: XCUIElement, bottom: XCUIElement)?
        XCTAssertTrue(
            poll(timeout: 10) {
                panes = stackedTerminals(in: app)
                return panes != nil
            },
            "Expected Cmd+Shift+D to leave two stacked terminals; textViews=\(terminalFrames(in: app))"
        )
        guard let (top, bottom) = panes else { return }
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))

        let topBefore = top.frame
        let bottomBefore = bottom.frame
        // XCUI frames are top-left origin: the top pane ends where the
        // divider starts.
        let dividerY = (topBefore.maxY + bottomBefore.minY) / 2
        let dividerX = topBefore.midX
        attach(window.screenshot(), name: "01 before divider drag")

        let start = point(in: window, x: dividerX, y: dividerY)
        let end = start.withOffset(CGVector(dx: 0, dy: -120))
        start.press(forDuration: 0.3, thenDragTo: end)

        let resized = poll(timeout: 5) {
            top.frame.height < topBefore.height - 60
                && bottom.frame.height > bottomBefore.height + 60
        }
        attach(window.screenshot(), name: "02 after divider drag")
        XCTAssertTrue(
            resized,
            "Expected dragging the divider 120 pt up to resize both panes. " +
                "before top=\(topBefore) bottom=\(bottomBefore) " +
                "after top=\(top.frame) bottom=\(bottom.frame) divider=(\(dividerX), \(dividerY))"
        )
    }

    func testDraggingPaneTabReordersTabsInStandardMode() throws {
        let dataPath = "/tmp/cmux-ui-test-split-drag-tabs-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: dataPath)
        let app = XCUIApplication.cmuxTestApplication()
        app.launchArguments += settingsLaunchArguments
        app.launchArguments += ["-workspacePresentationMode", "standard"]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = "ui-split-drag-\(UUID().uuidString.prefix(8))"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH"] = dataPath
        launchAndActivate(app)
        defer {
            app.terminate()
            try? FileManager.default.removeItem(atPath: dataPath)
        }

        var ready: [String: String] = [:]
        XCTAssertTrue(
            poll(timeout: 25) {
                ready = loadJSON(atPath: dataPath)
                return ready["ready"] == "1"
            },
            "Timed out waiting for the tab-drag setup. data=\(ready)"
        )
        if let setupError = ready["setupError"], !setupError.isEmpty {
            XCTFail("Setup failed: \(setupError)")
            return
        }
        let alphaTitle = ready["alphaTitle"] ?? "UITest Alpha"
        let betaTitle = ready["betaTitle"] ?? "UITest Beta"
        let window = app.windows.firstMatch
        let alphaTab = app.buttons[alphaTitle]
        let betaTab = app.buttons[betaTitle]
        XCTAssertTrue(alphaTab.waitForExistence(timeout: 5), "Expected the alpha tab")
        XCTAssertTrue(betaTab.waitForExistence(timeout: 5), "Expected the beta tab")
        XCTAssertTrue(
            poll(timeout: 5) { loadJSON(atPath: dataPath)["trackedPaneTabTitles"] == "\(alphaTitle)|\(betaTitle)" },
            "Expected the initial tab order. data=\(loadJSON(atPath: dataPath))"
        )
        attach(window.screenshot(), name: "01 before tab drag")

        let source = betaTab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let target = alphaTab.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        source.press(forDuration: 0.25, thenDragTo: target)

        let reordered = poll(timeout: 5) {
            loadJSON(atPath: dataPath)["trackedPaneTabTitles"] == "\(betaTitle)|\(alphaTitle)"
        }
        attach(window.screenshot(), name: "02 after tab drag")
        XCTAssertTrue(
            reordered,
            "Expected dragging the beta tab onto alpha to reorder the pane's tabs. " +
                "data=\(loadJSON(atPath: dataPath)) alpha=\(alphaTab.frame) beta=\(betaTab.frame)"
        )
    }

    // MARK: - Helpers

    private func launchSplitApp() -> XCUIApplication {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchArguments += settingsLaunchArguments
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = "ui-split-drag-\(UUID().uuidString.prefix(8))"
        launchAndActivate(app)
        return app
    }

    private func visibleTerminals(in app: XCUIApplication) -> [XCUIElement] {
        app.textViews.allElementsBoundByIndex.filter {
            $0.exists && $0.frame.width > 80 && $0.frame.height > 80
        }
    }

    private func sideBySideTerminals(in app: XCUIApplication) -> (leading: XCUIElement, trailing: XCUIElement)? {
        let terminals = visibleTerminals(in: app).sorted { $0.frame.minX < $1.frame.minX }
        guard terminals.count == 2 else { return nil }
        let (a, b) = (terminals[0], terminals[1])
        guard a.frame.maxX <= b.frame.minX + 1, abs(a.frame.midY - b.frame.midY) < 40 else { return nil }
        return (a, b)
    }

    private func stackedTerminals(in app: XCUIApplication) -> (top: XCUIElement, bottom: XCUIElement)? {
        let terminals = visibleTerminals(in: app).sorted { $0.frame.minY < $1.frame.minY }
        guard terminals.count == 2 else { return nil }
        let (a, b) = (terminals[0], terminals[1])
        guard a.frame.maxY <= b.frame.minY + 1, abs(a.frame.midX - b.frame.midX) < 40 else { return nil }
        return (a, b)
    }

    private func terminalFrames(in app: XCUIApplication) -> [CGRect] {
        app.textViews.allElementsBoundByIndex.filter(\.exists).map(\.frame)
    }

    private func point(in window: XCUIElement, x: CGFloat, y: CGFloat) -> XCUICoordinate {
        window.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: x - window.frame.minX, dy: y - window.frame.minY)
        )
    }

    private func loadJSON(atPath path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    private func attach(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
