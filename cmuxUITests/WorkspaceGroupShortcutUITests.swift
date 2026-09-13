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
        app.launchArguments += ["-mobileHost.deviceID", hostIdentityForLaunch()]
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

    /// Reuse the host identity through a launch argument so an unrelated
    /// cold-start migration deadlock cannot block the keyboard regression.
    private func hostIdentityForLaunch() -> String {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("cmux/mobile-host-device-id")
        let shared = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let stable = UserDefaults(suiteName: "com.cmuxterm.app")?.string(forKey: "mobileHost.deviceID")
        for candidate in [shared, stable] {
            if let candidate,
               let id = UUID(uuidString: candidate.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return id.uuidString.lowercased()
            }
        }
        return UUID().uuidString.lowercased()
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
