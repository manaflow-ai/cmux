import Foundation
import XCTest

/// Behavior-level coverage for the two workspace rename gestures on a sidebar
/// row: double-click (inline field on the row) and secondary-click →
/// "Rename Workspace…" (NSAlert). Both must end with the row's title showing
/// the typed name.
final class WorkspaceSidebarRenameUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testDoubleClickInlineRenameCommitsNewTitle() {
        let app = launchedApp(tag: "ui-rename-inline")
        let row = firstWorkspaceRow(app: app)
        XCTAssertTrue(
            pollUntil(timeout: 10.0) { row.exists && row.isHittable },
            "Expected the initial workspace row to be visible"
        )

        row.doubleClick()

        let field = app.descendants(matching: .textField)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "workspace name"))
            .firstMatch
        let anyField = field.exists ? field : app.descendants(matching: .textField).firstMatch
        XCTAssertTrue(
            pollUntil(timeout: 5.0) { anyField.exists && anyField.isHittable },
            "Double-click should open the inline rename field on the row"
        )

        anyField.typeText("InlineRenamed")
        anyField.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(
            waitForRowLabelContaining("InlineRenamed", app: app, timeout: 8.0),
            "Inline rename should commit the typed title to the sidebar row"
        )
    }

    func testSecondaryClickRenameWorkspaceMenuItemCommitsNewTitle() {
        let app = launchedApp(tag: "ui-rename-menu")
        let row = firstWorkspaceRow(app: app)
        XCTAssertTrue(
            pollUntil(timeout: 10.0) { row.exists && row.isHittable },
            "Expected the initial workspace row to be visible"
        )

        row.rightClick()

        let renameItem = app.descendants(matching: .menuItem)
            .matching(NSPredicate(format: "title BEGINSWITH %@", "Rename Workspace"))
            .firstMatch
        XCTAssertTrue(
            pollUntil(timeout: 5.0) { renameItem.exists },
            "Secondary-click on a workspace row should offer \"Rename Workspace…\""
        )
        XCTAssertTrue(renameItem.isEnabled, "\"Rename Workspace…\" should be enabled")
        renameItem.click()

        let sheetField = app.descendants(matching: .textField)
            .matching(NSPredicate(format: "placeholderValue CONTAINS[c] %@", "workspace name"))
            .firstMatch
        XCTAssertTrue(
            pollUntil(timeout: 5.0) { sheetField.exists && sheetField.isHittable },
            "\"Rename Workspace…\" should present the rename alert with a text field"
        )

        sheetField.click()
        sheetField.typeKey("a", modifierFlags: [.command])
        sheetField.typeText("MenuRenamed")

        let renameButton = app.descendants(matching: .button)
            .matching(NSPredicate(format: "title == %@", "Rename"))
            .firstMatch
        XCTAssertTrue(renameButton.waitForExistence(timeout: 3.0), "Expected the alert's Rename button")
        renameButton.click()

        XCTAssertTrue(
            waitForRowLabelContaining("MenuRenamed", app: app, timeout: 8.0),
            "The context-menu rename should commit the typed title to the sidebar row"
        )
    }

    /// Control-click is macOS's equivalent of a right-click and must open the
    /// same workspace row context menu, including "Rename Workspace…".
    func testControlClickOpensWorkspaceRowContextMenuWithRename() {
        let app = launchedApp(tag: "ui-rename-ctrl")
        let row = firstWorkspaceRow(app: app)
        XCTAssertTrue(
            pollUntil(timeout: 10.0) { row.exists && row.isHittable },
            "Expected the initial workspace row to be visible"
        )

        XCUIElement.perform(withKeyModifiers: .control) {
            row.click()
        }

        let renameItem = app.descendants(matching: .menuItem)
            .matching(NSPredicate(format: "title BEGINSWITH %@", "Rename Workspace"))
            .firstMatch
        XCTAssertTrue(
            pollUntil(timeout: 5.0) { renameItem.exists },
            "Control-click on a workspace row should open the row context menu with \"Rename Workspace…\""
        )
    }

    /// Diagnostic: dumps how a secondary-click context menu actually appears in
    /// the accessibility hierarchy, so the assertions above can be scoped to the
    /// popup menu instead of matching the View menu's "Rename Workspace…".
    func testDiagnosticDumpContextMenuHierarchy() {
        let app = launchedApp(tag: "ui-rename-diag")
        let row = firstWorkspaceRow(app: app)
        XCTAssertTrue(pollUntil(timeout: 10.0) { row.exists && row.isHittable }, "row visible")

        print("DIAG-BASELINE-MENUS count=\(app.menus.count) menuBars=\(app.menuBars.count)")
        let baselineRename = app.descendants(matching: .menuItem)
            .matching(NSPredicate(format: "title BEGINSWITH %@", "Rename Workspace"))
        print("DIAG-BASELINE-RENAME-MATCHES count=\(baselineRename.count)")
        for i in 0..<baselineRename.count {
            let e = baselineRename.element(boundBy: i)
            print("DIAG-BASELINE-RENAME[\(i)] hittable=\(e.isHittable) frame=\(e.frame)")
        }

        row.rightClick()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        print("DIAG-AFTER-RIGHTCLICK menus=\(app.menus.count)")
        let afterRename = app.descendants(matching: .menuItem)
            .matching(NSPredicate(format: "title BEGINSWITH %@", "Rename Workspace"))
        print("DIAG-AFTER-RENAME-MATCHES count=\(afterRename.count)")
        for i in 0..<afterRename.count {
            let e = afterRename.element(boundBy: i)
            print("DIAG-AFTER-RENAME[\(i)] hittable=\(e.isHittable) frame=\(e.frame)")
        }
        print("DIAG-WINDOW-MENUS count=\(app.windows.descendants(matching: .menu).count)")
        print("DIAG-HIERARCHY-BEGIN")
        print(app.debugDescription)
        print("DIAG-HIERARCHY-END")
    }

    // MARK: Helpers

    private func launchedApp(tag: String) -> XCUIApplication {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchArguments += ["-newWorkspacePlacement", "end"]
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = tag

        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("Headless CI may launch the app without foreground activation", options: options) {
            app.launch()
        }
        XCTAssertTrue(
            pollUntil(timeout: 15.0) {
                app.state == .runningForeground || app.state == .runningBackground
            },
            "App failed to launch. state=\(app.state.rawValue)"
        )
        XCTAssertTrue(pollUntil(timeout: 10.0) { app.windows.count >= 1 }, "Expected a main window")
        return app
    }

    private func firstWorkspaceRow(app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label ENDSWITH %@", "workspace 1 of 1"))
            .firstMatch
    }

    private func waitForRowLabelContaining(
        _ text: String,
        app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let renamed = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ AND label ENDSWITH %@", text, "workspace 1 of 1"))
            .firstMatch
        return pollUntil(timeout: timeout) { renamed.exists }
    }

    private func pollUntil(
        timeout: TimeInterval,
        interval: TimeInterval = 0.05,
        _ condition: () -> Bool
    ) -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        while true {
            if condition() { return true }
            if ProcessInfo.processInfo.systemUptime - start >= timeout { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(interval))
        }
    }
}
