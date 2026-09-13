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
        app.launchArguments += ["-mobileHost.deviceID", try preparedHostIdentity()]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = "ui-empty-group-\(UUID().uuidString.prefix(8))"
        app.launchEnvironment["CMUX_UI_TEST_KEYEQUIV_PATH"] = recorder.path
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 12))

        let workspace = app.cells.matching(
            NSPredicate(format: "label ENDSWITH %@", "workspace 1 of 1")
        ).firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        let group = app.staticTexts["Group 1"].firstMatch
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
        let after = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: recorder))
        XCTAssertEqual(after["selectedTabId"], selectedWorkspaceId)
        XCTAssertEqual(after["tabCount"], "2", "The empty group owns one generated anchor")
        attachScreenshot(named: "After grouping: empty header, original workspace focused")
    }

    /// Avoid an unrelated cold-start identity migration deadlock before UI input.
    /// Reuse the host's identity; never replace an existing shared identity.
    private func preparedHostIdentity() throws -> String {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("cmux", isDirectory: true)
        let url = directory.appendingPathComponent("mobile-host-device-id")
        if FileManager.default.fileExists(atPath: url.path) {
            let value = try String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return try XCTUnwrap(UUID(uuidString: value)).uuidString.lowercased()
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let value = UUID().uuidString.lowercased()
        try Data(value.utf8).write(to: url, options: .withoutOverwriting)
        return value
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
