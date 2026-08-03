import XCTest
import Foundation

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/9199:
/// ⌘⇧R while a workspace group's anchor row is focused must rename the group
/// (the name that row renders), not the hidden anchor workspace title.
final class WorkspaceGroupRenameShortcutUITests: XCTestCase {
    private var launchTag = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        launchTag = "ui-tests-group-rename-\(UUID().uuidString.lowercased())"
    }

    func testRenameShortcutRenamesFocusedWorkspaceGroup() {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = launchTag
        launchAndActivate(app)

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10.0), "Expected a main window")

        // Ctrl+Cmd+G creates an empty workspace group and focuses its anchor
        // workspace, which is the row the sidebar draws as the group header.
        app.typeKey("g", modifierFlags: [.command, .control])

        let groupRow = app
            .descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'sidebarWorkspaceGroup.'"))
            .firstMatch
        XCTAssertTrue(
            groupRow.waitForExistence(timeout: 10.0),
            "Expected Ctrl+Cmd+G to create a workspace group header row"
        )

        app.typeKey("r", modifierFlags: [.command, .shift])

        let renameField = app.textFields["CommandPaletteRenameField"].firstMatch
        XCTAssertTrue(
            renameField.waitForExistence(timeout: 10.0),
            "Expected Cmd+Shift+R to open the palette rename editor"
        )

        let newName = "Renamed Group \(String(UUID().uuidString.prefix(6)))"
        app.typeKey("a", modifierFlags: [.command])
        app.typeText(newName)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        XCTAssertTrue(
            pollUntil(timeout: 10.0) { !renameField.exists },
            "Expected Enter to apply the rename and dismiss the palette"
        )

        // The sidebar group header labels itself with the group name, so the
        // rename is only visible if the shortcut targeted the group.
        XCTAssertTrue(
            pollUntil(timeout: 10.0) { groupRow.exists && groupRow.label == newName },
            "Expected Cmd+Shift+R to rename the focused workspace group. label=\(groupRow.label)"
        )
    }

    private func launchAndActivate(_ app: XCUIApplication, timeout: TimeInterval = 12.0) {
        app.launch()
        _ = pollUntil(timeout: timeout) {
            if app.state == .runningForeground { return true }
            app.activate()
            return app.state == .runningForeground
        }
        XCTAssertTrue(
            pollUntil(timeout: 5.0) { app.state == .runningForeground || app.state == .runningBackground },
            "App did not start. state=\(app.state.rawValue)"
        )
    }

    private func pollUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        while true {
            if condition() { return true }
            if (ProcessInfo.processInfo.systemUptime - start) >= timeout { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }
}
