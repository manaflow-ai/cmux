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
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = "ui-empty-group-\(UUID().uuidString.prefix(8))"
        app.launchEnvironment["CMUX_UI_TEST_KEYEQUIV_PATH"] = recorder.path
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 12))

        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "sidebarWorkspace.")
        )
        let workspace = rows.firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        let workspaceIdentity = workspace.identifier
        let groups = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "sidebarWorkspaceGroup.")
        )
        XCTAssertEqual(groups.count, 0)
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
        XCTAssertTrue(groups.firstMatch.waitForExistence(timeout: 8))
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.firstMatch.identifier, workspaceIdentity)
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
