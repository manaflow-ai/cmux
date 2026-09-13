import Foundation
import XCTest

final class WorkspaceGroupShortcutUITests: XCTestCase {
    func testEmptySidebarSelectionCreatesGroupWithoutMovingWorkspaceFocus() throws {
        continueAfterFailure = false
        let app = XCUIApplication.cmuxTestApplication()
        let recorder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-empty-group-\(UUID().uuidString).json")
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: recorder)
        }
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += ["-cmux.flags.override.sidebar-appkit-list-experiment", "YES"]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = "ui-empty-group-\(UUID().uuidString.prefix(8))"
        app.launchEnvironment["CMUX_UI_TEST_KEYEQUIV_PATH"] = recorder.path
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 12))

        let sidebar = app.tables.firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
        let workspace = sidebar.tableRows.firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        XCTAssertEqual(sidebar.tableRows.count, 1)
        let group = sidebar.staticTexts["Group 1"].firstMatch
        XCTAssertFalse(group.exists)
        let before = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: recorder))
        let selectedWorkspaceId = try XCTUnwrap(before["selectedTabId"])
        XCTAssertFalse(selectedWorkspaceId.isEmpty)

        // 1. Leave the sidebar with no workspace selected.
        workspace.click()
        XCUIElement.perform(withKeyModifiers: .command) { workspace.click() }
        attachScreenshot(named: "Before grouping: empty sidebar selection")

        // 2. Press `⌘⇧G`.
        app.typeKey("g", modifierFlags: [.command, .shift])

        // 3. Observe that no empty workspace group is created (the regression).
        // The fixed behavior must show a new header without adopting the row.
        XCTAssertTrue(group.waitForExistence(timeout: 8))
        XCTAssertEqual(sidebar.tableRows.count, 2)
        let after = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: recorder))
        XCTAssertEqual(after["selectedTabId"], selectedWorkspaceId)
        XCTAssertEqual(after["tabCount"], "2", "The empty group owns one generated anchor")
        attachScreenshot(named: "After grouping: empty header, original workspace focused")
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
