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
        // XCUI frames are top-left origin. The bottom pane's tab strip sits
        // between the two terminals, so the divider is just below the top
        // terminal, not halfway between them.
        let dividerY = topBefore.maxY + 1
        let dividerX = topBefore.midX
        attach(window.screenshot(), name: "01 before divider drag")

        let start = point(in: window, x: dividerX, y: dividerY)
        let end = start.withOffset(CGVector(dx: 0, dy: -70))
        start.press(forDuration: 0.3, thenDragTo: end)

        let resized = poll(timeout: 5) {
            top.frame.height < topBefore.height - 30
                && bottom.frame.height > bottomBefore.height + 30
        }
        attach(window.screenshot(), name: "02 after divider drag")
        XCTAssertTrue(
            resized,
            "Expected dragging the divider 70 pt up to resize both panes. " +
                "before top=\(topBefore) bottom=\(bottomBefore) " +
                "after top=\(top.frame) bottom=\(bottom.frame) divider=(\(dividerX), \(dividerY))"
        )
    }

    func testDraggingPaneTabReordersTabsInStandardMode() throws {
        try assertTabDragReorders(cloudWorkspace: false, dragSelectedTab: true)
    }

    func testDraggingUnselectedPaneTabReordersTabsInStandardMode() throws {
        try assertTabDragReorders(cloudWorkspace: false, dragSelectedTab: false)
    }

    /// Lawrence's report: in a Cloud workspace, pressing a tab and dragging it
    /// over its neighbour neither showed a drag nor reordered the tabs.
    func testDraggingPaneTabReordersTabsInCloudWorkspace() throws {
        try assertTabDragReorders(cloudWorkspace: true, dragSelectedTab: true)
    }

    func testDraggingUnselectedPaneTabReordersTabsInCloudWorkspace() throws {
        try assertTabDragReorders(cloudWorkspace: true, dragSelectedTab: false)
    }

    /// Two tabs, Alpha then Beta, with Beta selected. Drags Beta before Alpha,
    /// or the unselected Alpha after Beta; both end as Beta|Alpha.
    private func assertTabDragReorders(cloudWorkspace: Bool, dragSelectedTab: Bool) throws {
        let dataPath = "/tmp/cmux-ui-test-split-drag-tabs-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: dataPath)
        let app = XCUIApplication.cmuxTestApplication()
        app.launchArguments += settingsLaunchArguments
        app.launchArguments += ["-workspacePresentationMode", "standard"]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = "ui-split-drag-\(UUID().uuidString.prefix(8))"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH"] = dataPath
        if cloudWorkspace {
            app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_CLOUD_WORKSPACE"] = "1"
        }
        // The app's drag log explains a drag that never started.
        let logPath = "/tmp/cmux-ui-test-split-drag-log-\(UUID().uuidString).log"
        app.launchEnvironment["CMUX_DEBUG_LOG"] = logPath
        launchAndActivate(app)
        defer {
            app.terminate()
            try? FileManager.default.removeItem(atPath: dataPath)
            try? FileManager.default.removeItem(atPath: logPath)
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
        if cloudWorkspace {
            XCTAssertEqual(ready["cloudWorkspace"], "1", "Expected the workspace to be bound to a Cloud machine")
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

        if dragSelectedTab {
            let source = betaTab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let target = alphaTab.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
            source.press(forDuration: 0.25, thenDragTo: target)
        } else {
            let source = alphaTab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let target = betaTab.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            source.press(forDuration: 0.25, thenDragTo: target)
        }

        let reordered = poll(timeout: 5) {
            loadJSON(atPath: dataPath)["trackedPaneTabTitles"] == "\(betaTitle)|\(alphaTitle)"
        }
        attach(window.screenshot(), name: "02 after tab drag")
        let dragLog = ((try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .filter { $0.contains("drag") || $0.contains("tab.") || $0.contains("Drag") }
            .suffix(80)
            .joined(separator: "\n")
        let logAttachment = XCTAttachment(string: dragLog)
        logAttachment.name = "app drag log"
        logAttachment.lifetime = .keepAlways
        add(logAttachment)
        XCTAssertTrue(
            reordered,
            "Expected the tab drag to reorder the pane's tabs to Beta|Alpha. " +
                "order=\(loadJSON(atPath: dataPath)["trackedPaneTabTitles"] ?? "") " +
                "alpha=\(alphaTab.frame) beta=\(betaTab.frame)\nDRAGLOG:\n\(dragLog)"
        )
    }

    // MARK: - Drag to split

    func testDraggingPaneTabOntoPaneEdgeSplits() throws {
        try assertTabDragOntoPaneEdgeSplits(rightSidebarMode: nil)
    }

    /// Reported regression: with the right sidebar's Cloud panel open, a pane tab
    /// dropped on a pane edge did not split, in a local workspace.
    func testDraggingPaneTabOntoPaneEdgeSplitsWithCloudPanelOpen() throws {
        try assertTabDragOntoPaneEdgeSplits(rightSidebarMode: "machines")
    }

    func testDraggingSidebarToolOntoPaneEdgeCreatesSplit() throws {
        try assertSidebarToolDragSplits(rightSidebarMode: "files")
    }

    func testDraggingSidebarToolOntoPaneEdgeCreatesSplitWithCloudPanelOpen() throws {
        try assertSidebarToolDragSplits(rightSidebarMode: "machines")
    }

    /// Two tabs, Alpha and Beta (selected), in one pane. Dropping Beta on the
    /// pane's right edge must leave Alpha's pane with one tab and two
    /// terminals side by side.
    private func assertTabDragOntoPaneEdgeSplits(rightSidebarMode: String?) throws {
        let session = try launchTabDragSetup(rightSidebarMode: rightSidebarMode)
        let app = session.app
        defer { session.finish() }
        let window = app.windows.firstMatch
        let betaTab = app.buttons[session.ready["betaTitle"] ?? "UITest Beta"]
        XCTAssertTrue(betaTab.waitForExistence(timeout: 5), "Expected the beta tab")
        var terminal: XCUIElement?
        XCTAssertTrue(
            poll(timeout: 10) {
                terminal = visibleTerminals(in: app).max { $0.frame.width < $1.frame.width }
                return terminal != nil
            },
            "Expected the workspace terminal; textViews=\(terminalFrames(in: app))"
        )
        guard let terminal else { return }
        let before = terminal.frame
        attach(window.screenshot(), name: "01 before tab drag to pane edge")

        let source = betaTab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let target = point(in: window, x: before.maxX - 24, y: before.midY)
        source.press(forDuration: 0.3, thenDragTo: target)

        let split = poll(timeout: 6) {
            loadJSON(atPath: session.dataPath)["trackedPaneTabCount"] == "1"
                && sideBySideTerminals(in: app) != nil
        }
        attach(window.screenshot(), name: "02 after tab drag to pane edge")
        session.attachDragLog(to: self)
        XCTAssertTrue(
            split,
            "Expected dropping the Beta tab on the pane's right edge to split the pane. " +
                "tabs=\(loadJSON(atPath: session.dataPath)["trackedPaneTabTitles"] ?? "") " +
                "terminals=\(terminalFrames(in: app))"
        )
    }

    /// Dragging a right sidebar tool (its mode bar button) onto a pane's edge
    /// opens the tool as a split beside that pane.
    private func assertSidebarToolDragSplits(rightSidebarMode: String) throws {
        let session = try launchTabDragSetup(rightSidebarMode: rightSidebarMode)
        let app = session.app
        defer { session.finish() }
        let window = app.windows.firstMatch
        let tool = app.descendants(matching: .any)["RightSidebarModeButton.find"]
        XCTAssertTrue(tool.waitForExistence(timeout: 10), "Expected the Find mode button in the right sidebar")
        var terminal: XCUIElement?
        XCTAssertTrue(
            poll(timeout: 10) {
                terminal = visibleTerminals(in: app).max { $0.frame.width < $1.frame.width }
                return terminal != nil
            },
            "Expected the workspace terminal; textViews=\(terminalFrames(in: app))"
        )
        guard let terminal else { return }
        let before = terminal.frame
        attach(window.screenshot(), name: "01 before sidebar tool drag")

        let source = tool.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let target = point(in: window, x: before.maxX - 24, y: before.midY)
        source.press(forDuration: 0.3, thenDragTo: target)

        let findField = app.descendants(matching: .any)["TerminalFindSearchTextField"]
        var findFrame = CGRect.zero
        let split = poll(timeout: 6) {
            findFrame = findField.frame
            let terminalFrame = terminal.frame
            let terminalResized = terminalFrame.width < before.width * 0.75
            let findPaneIsAdjacent = findField.exists
                && findFrame.width > 20
                && findFrame.minX >= terminalFrame.maxX - 8
                && findFrame.maxY >= terminalFrame.minY
                && findFrame.minY <= terminalFrame.maxY
            return terminalResized && findPaneIsAdjacent
        }
        attach(window.screenshot(), name: "02 after sidebar tool drag")
        session.attachDragLog(to: self)
        XCTAssertTrue(
            split,
            "Expected dropping the Find tool on the pane's right edge to split it and expose an adjacent Find pane. " +
                "before=\(before) terminal=\(terminal.frame) findField=\(findFrame)"
        )
    }

    private struct TabDragSession {
        let app: XCUIApplication
        let dataPath: String
        let logPath: String
        let ready: [String: String]

        func finish() {
            app.terminate()
            try? FileManager.default.removeItem(atPath: dataPath)
            try? FileManager.default.removeItem(atPath: logPath)
        }

        func attachDragLog(to test: XCTestCase) {
            let log = ((try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "")
                .split(separator: "\n")
                .filter { line in
                    ["drag", "drop", "Drag", "Drop", "route", "portal", "rightSidebar", "hitTest"]
                        .contains { line.contains($0) }
                }
                .suffix(150)
                .joined(separator: "\n")
            let attachment = XCTAttachment(string: log)
            attachment.name = "app drag log"
            attachment.lifetime = .keepAlways
            test.add(attachment)
        }
    }

    private func launchTabDragSetup(rightSidebarMode: String?) throws -> TabDragSession {
        let id = UUID().uuidString
        let dataPath = "/tmp/cmux-ui-test-split-drag-\(id).json"
        let logPath = "/tmp/cmux-ui-test-split-drag-\(id).log"
        let app = XCUIApplication.cmuxTestApplication()
        app.launchArguments += settingsLaunchArguments
        app.launchArguments += ["-workspacePresentationMode", "standard"]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = "ui-split-drag-\(id.prefix(8))"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH"] = dataPath
        app.launchEnvironment["CMUX_DEBUG_LOG"] = logPath
        if let rightSidebarMode {
            app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_SHOW_RIGHT_SIDEBAR"] = "1"
            app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_RIGHT_SIDEBAR_MODE"] = rightSidebarMode
        }
        launchAndActivate(app)
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
        }
        return TabDragSession(app: app, dataPath: dataPath, logPath: logPath, ready: ready)
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
