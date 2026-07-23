import CoreGraphics
import XCTest

final class SidebarWorkspaceReorderUITests: XCTestCase {
    private let workspaceTitlePrefix = "reorder-ui-"
    private let debugLogPath = "/tmp/cmux-sidebar-reorder-xcui.log"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        try? FileManager.default.removeItem(atPath: debugLogPath)
    }

    func testReordersWhenDraggedRowCenterCrossesNeighborCenter() throws {
        let app = launchFixture()
        defer { app.terminate() }
        let titles = try createRootWorkspaces(count: 4, app: app)
        let targetTitle = titles[2]
        let draggedTitle = titles[3]
        let target = try workspaceRow(targetTitle, app: app)
        let dragged = try workspaceRow(draggedTitle, app: app)
        // Grab near the bottom. The pointer remains below the target midpoint,
        // while the floating row's midpoint has already crossed it.
        let targetPoint = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).screenPoint
        let destination = fixedCoordinate(at: targetPoint, app: app)
        let startPoint = dragged.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).screenPoint
        fixedCoordinate(at: startPoint, app: app)
            .press(forDuration: 0.25, thenDragTo: destination)

        addScreenshot(named: "center-crossing")
        XCTAssertTrue(
            waitForWorkspace(draggedTitle, immediatelyBefore: targetTitle, app: app),
            "Expected the dragged row to reorder when its center crossed the target center. order=\(workspaceOrder(app: app))"
        )
    }

    func testSlowHeldDragKeepsTheChosenSlot() throws {
        let app = launchFixture()
        defer { app.terminate() }
        let titles = try createRootWorkspaces(count: 5, app: app)
        let targetTitle = titles[1]
        let draggedTitle = titles[4]
        let target = try workspaceRow(targetTitle, app: app)
        let dragged = try workspaceRow(draggedTitle, app: app)
        let start = fixedCoordinate(
            at: dragged.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).screenPoint,
            app: app
        )
        let destination = fixedCoordinate(
            at: target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).screenPoint,
            app: app
        )

        // The one-second hold exposes any resolver/presentation feedback
        // loop: a stable implementation keeps the selected gap unchanged
        // while no new pointer movement arrives.
        start.press(
            forDuration: 0.25,
            thenDragTo: destination,
            withVelocity: .slow,
            thenHoldForDuration: 1.0
        )

        addScreenshot(named: "slow-held-drag")
        XCTAssertTrue(
            waitForWorkspace(draggedTitle, immediatelyBefore: targetTitle, app: app),
            "Expected a slow held drag to keep and commit its chosen slot. order=\(workspaceOrder(app: app))"
        )
    }

    func testCanEnterAndLeaveGroupAtLastMember() throws {
        let app = launchFixture()
        defer { app.terminate() }
        let titles = try createRootWorkspaces(count: 5, app: app)
        let memberTitle = titles[1]
        let draggedTitle = titles[3]
        // Workspace 3 is the first root after the newly created group. The
        // dragged workspace starts below it, then becomes the group's tail.
        let followingRootTitle = titles[2]

        let member = try workspaceRow(memberTitle, app: app)
        member.rightClick()
        let createGroup = member.menuItems["New Group from Workspace"].firstMatch
        XCTAssertTrue(createGroup.waitForExistence(timeout: 3), "Expected workspace group context-menu action")
        createGroup.click()
        XCTAssertTrue(isWorkspaceGrouped(memberTitle, app: app), "Expected the seed workspace to be in the new group")

        let groupedMember = try workspaceRow(memberTitle, app: app)
        let dragged = try workspaceRow(draggedTitle, app: app)
        let entryStart = fixedCoordinate(
            at: dragged.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).screenPoint,
            app: app
        )
        let entryDestination = fixedCoordinate(
            at: groupedMember.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.8)).screenPoint,
            app: app
        )
        entryStart
            .press(
                forDuration: 0.25,
                thenDragTo: entryDestination
            )

        XCTAssertTrue(
            isWorkspaceGrouped(draggedTitle, app: app),
            "Expected a root workspace dropped over the last member to join the group. order=\(workspaceOrder(app: app))"
        )

        let groupedDragged = try workspaceRow(draggedTitle, app: app)
        let followingRoot = try workspaceRow(followingRootTitle, app: app)
        let exitPoint = followingRoot.coordinate(
            withNormalizedOffset: CGVector(dx: 0.3, dy: 0.8)
        ).screenPoint
        let exitStart = fixedCoordinate(
            at: groupedDragged.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).screenPoint,
            app: app
        )
        exitStart
            .press(
                forDuration: 0.25,
                thenDragTo: fixedCoordinate(at: exitPoint, app: app)
            )

        addScreenshot(named: "group-tail-entry-exit")
        XCTAssertFalse(
            isWorkspaceGrouped(draggedTitle, app: app),
            "Expected dragging the last member across the following root's center to leave the group. order=\(workspaceOrder(app: app))"
        )
    }

    func testReordersWhilePointerIsOutsideSidebar() throws {
        let app = launchFixture()
        defer { app.terminate() }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "Expected main window")
        app.typeKey("f", modifierFlags: [.control, .command])
        XCTAssertTrue(
            pollUntil(timeout: 5) { window.frame.width > 600 },
            "Expected a wide full-screen window for the outside-sidebar gesture. frame=\(window.frame)"
        )
        let titles = try createRootWorkspaces(count: 4, app: app)
        let targetTitle = titles[2]
        let draggedTitle = titles[3]
        let target = try workspaceRow(targetTitle, app: app)
        let dragged = try workspaceRow(draggedTitle, app: app)
        let start = fixedCoordinate(
            at: dragged.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).screenPoint,
            app: app
        )
        let targetY = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).screenPoint.y - 3
        let normalizedY = (targetY - window.frame.minY) / window.frame.height
        // The destination is 100 points beyond the 240-point sidebar and
        // remains inside the source reorder corridor.
        let destination = window.coordinate(
            withNormalizedOffset: CGVector(dx: 340 / window.frame.width, dy: normalizedY)
        )
        start.press(forDuration: 0.25, thenDragTo: destination)

        addScreenshot(named: "outside-sidebar-drop")
        XCTAssertTrue(
            waitForWorkspace(draggedTitle, immediatelyBefore: targetTitle, app: app),
            "Expected the reorder to commit after the pointer left the sidebar. " +
                "start=\(start.screenPoint) destination=\(destination.screenPoint) " +
                "window=\(window.frame) order=\(workspaceOrder(app: app))"
        )
    }

    private func launchFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-newWorkspacePlacement", "end",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = "uisr-\(UUID().uuidString.prefix(8).lowercased())"
        app.launchEnvironment["CMUX_DEBUG_LOG"] = debugLogPath
        app.launch()
        if !app.wait(for: .runningForeground, timeout: 10) {
            app.activate()
        }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8), "Expected cmux window")
        XCTAssertTrue(
            app.descendants(matching: .any)["Sidebar"].firstMatch.waitForExistence(timeout: 5),
            "Expected workspace sidebar"
        )
        return app
    }

    private func createRootWorkspaces(count: Int, app: XCUIApplication) throws -> [String] {
        precondition(count > 0)
        var titles: [String] = []
        for index in 1...count {
            if index > 1 {
                app.typeKey("n", modifierFlags: [.command])
                XCTAssertTrue(waitForWorkspaceCount(index, app: app), "Expected \(index) workspace rows")
            } else {
                XCTAssertTrue(waitForWorkspaceCount(1, app: app), "Expected the initial workspace row")
            }
            let title = "\(workspaceTitlePrefix)\(index)"
            renameWorkspace(at: index, total: index, to: title, app: app)
            XCTAssertTrue(
                workspaceRowElement(title, app: app).waitForExistence(timeout: 6),
                "Expected the terminal title to update workspace \(index). rows=\(allWorkspaceLabels(app: app))"
            )
            titles.append(title)
        }
        return titles
    }

    private func renameWorkspace(at index: Int, total: Int, to title: String, app: XCUIApplication) {
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label ENDSWITH %@", "workspace \(index) of \(total)"))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6), "Expected workspace \(index) of \(total) before rename")
        let sheet = app.sheets.firstMatch
        for attempt in 0..<2 where !sheet.exists {
            row.rightClick()
            let renameItem = row.menuItems["Rename Workspace…"].firstMatch
            XCTAssertTrue(renameItem.waitForExistence(timeout: 4), "Expected Rename Workspace context-menu action")
            renameItem.click()
            if sheet.waitForExistence(timeout: 5) { break }
            if attempt == 0 {
                app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            }
        }
        XCTAssertTrue(sheet.exists, "Expected rename sheet")
        let input = sheet.textFields.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 3), "Expected rename text field")
        input.click()
        input.typeKey("a", modifierFlags: [.command])
        input.typeText(title)
        let renameButton = sheet.buttons["Rename"]
        XCTAssertTrue(renameButton.waitForExistence(timeout: 3), "Expected Rename button")
        renameButton.click()
    }

    private func workspaceRow(_ title: String, app: XCUIApplication) throws -> XCUIElement {
        let row = workspaceRowElement(title, app: app)
        XCTAssertTrue(row.waitForExistence(timeout: 6), "Expected workspace row \(title)")
        XCTAssertTrue(row.isHittable, "Expected workspace row \(title) to be hittable")
        return row
    }

    private func workspaceRowElement(_ title: String, app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "\(title), workspace "))
            .firstMatch
    }

    private func allWorkspaceRows(app: XCUIApplication) -> [XCUIElement] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", ", workspace "))
            .allElementsBoundByIndex
            .filter { $0.exists && !$0.frame.isEmpty }
            .sorted { $0.frame.midY < $1.frame.midY }
    }

    private func workspaceRows(app: XCUIApplication) -> [XCUIElement] {
        allWorkspaceRows(app: app).filter { $0.label.hasPrefix(workspaceTitlePrefix) }
    }

    private func allWorkspaceLabels(app: XCUIApplication) -> [String] {
        allWorkspaceRows(app: app).map(\.label)
    }

    private func workspaceOrder(app: XCUIApplication) -> [String] {
        workspaceRows(app: app).map { workspaceTitle(from: $0.label) }
    }

    private func waitForWorkspaceCount(_ count: Int, app: XCUIApplication) -> Bool {
        pollUntil(timeout: 8) { self.allWorkspaceRows(app: app).count == count }
    }

    private func waitForWorkspace(_ title: String, immediatelyBefore targetTitle: String, app: XCUIApplication) -> Bool {
        pollUntil(timeout: 6) {
            let order = self.workspaceOrder(app: app)
            guard let index = order.firstIndex(of: title), index + 1 < order.count else { return false }
            return order[index + 1] == targetTitle
        }
    }

    private func isWorkspaceGrouped(_ title: String, app: XCUIApplication) -> Bool {
        guard let row = try? workspaceRow(title, app: app) else { return false }
        row.rightClick()
        let removeFromGroup = row.menuItems["Remove from Group"].firstMatch
        let grouped = removeFromGroup.waitForExistence(timeout: 1) && removeFromGroup.isEnabled
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        return grouped
    }

    /// Captures an absolute destination before the drag starts. Coordinates
    /// rooted in a row follow that row while the live preview moves it, which
    /// shortens the gesture and never reaches the intended midpoint.
    private func fixedCoordinate(at point: CGPoint, app: XCUIApplication) -> XCUICoordinate {
        let window = app.windows.firstMatch
        let origin = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        return origin.withOffset(
            CGVector(dx: point.x - window.frame.minX, dy: point.y - window.frame.minY)
        )
    }

    private func workspaceTitle(from label: String) -> String {
        label.split(separator: ",", maxSplits: 1).first.map(String.init) ?? label
    }

    private func pollUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return condition()
    }

    private func addScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
