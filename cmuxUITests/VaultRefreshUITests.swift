import Foundation
import XCTest

/// Reads real transcript fixtures through the Sessions sidebar's reload button.
final class VaultRefreshUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testReloadFindsExternalSessionsInMinimalSidebar() throws {
        try exerciseReload(presentation: "minimal")
    }

    func testReloadFindsExternalSessionsInStandardSidebar() throws {
        try exerciseReload(presentation: "standard")
    }

    func testKiroSessionsAppearAndPreview() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-kiro-vault-ui-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions/cli", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID().uuidString
        let prompt = "Kiro4566 saved conversation"
        let response = "Kiro4566 preview response"
        try JSONSerialization.data(withJSONObject: ["session_id": sessionID, "cwd": root.path])
            .write(to: sessions.appendingPathComponent("\(sessionID).json"))
        var transcript = Data()
        for (kind, text) in [("UserMessage", prompt), ("AssistantMessage", response)] {
            transcript.append(try JSONSerialization.data(withJSONObject: [
                "version": "v1", "kind": kind, "data": ["content": [["kind": "text", "data": text]]]
            ]))
            transcript.append(0x0A)
        }
        try transcript.write(to: sessions.appendingPathComponent("\(sessionID).jsonl"))

        let app = XCUIApplication.cmuxTestApplication()
        let setupURL = root.appendingPathComponent("setup.json")
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH"] = setupURL.path
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_SHOW_RIGHT_SIDEBAR"] = "1"
        app.launchEnvironment["KIRO_HOME"] = root.path
        app.launchArguments += [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-workspacePresentationMode", "standard", "-sessionIndex.grouping", "recency"
        ]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(waitUntil(timeout: 30) {
            guard let data = try? Data(contentsOf: setupURL),
                  let setup = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return false }
            return setup["ready"] == "1"
        })
        let mode = app.buttons["RightSidebarModeButton.sessions"]
        XCTAssertTrue(mode.waitForExistence(timeout: 30))
        mode.click()
        let row = app.staticTexts[prompt]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "Kiro sessions must appear without a cmux hook record")
        row.doubleClick()
        XCTAssertTrue(app.staticTexts[response].waitForExistence(timeout: 15), "Preview must decode Kiro's persisted messages")
        attach(app, name: "kiro-saved-session-preview")
    }

    private func exerciseReload(presentation: String) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vault-refresh-\(UUID().uuidString)", isDirectory: true)
        let config = root.appendingPathComponent("claude", isDirectory: true)
        let project = config.appendingPathComponent("projects/-tmp-vault-refresh", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let baselineURL = try writeSession("baseline", in: project)

        let app = XCUIApplication.cmuxTestApplication()
        let setupURL = root.appendingPathComponent("setup.json")
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH"] = setupURL.path
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_SHOW_RIGHT_SIDEBAR"] = "1"
        app.launchEnvironment["CLAUDE_CONFIG_DIR"] = config.path
        app.launchArguments += [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-workspacePresentationMode", presentation,
            "-sessionIndex.grouping", "recency",
            "-sessionIndex.compactView", "NO"
        ]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(waitUntil(timeout: 30) {
            guard let data = try? Data(contentsOf: setupURL),
                  let setup = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return false }
            return setup["ready"] == "1"
        }, "Expected the isolated sidebar fixture to finish setup")

        let modes = app.buttons["RightSidebarModeButton.sessions"]
        XCTAssertTrue(modes.waitForExistence(timeout: 30))
        modes.click()
        // The sidebar container's identifier propagates through SwiftUI on macOS.
        // Query the visible accessible name in this explicitly English fixture.
        let reload = app.buttons["Reload Vault"]
        XCTAssertTrue(reload.waitForExistence(timeout: 10))
        XCTAssertEqual(reload.label, "Reload Vault")
        XCTAssertTrue(app.staticTexts[title("baseline")].waitForExistence(timeout: 30))
        XCTAssertTrue(waitUntil { reload.isEnabled && reload.isHittable })
        attach(app, name: "\(presentation)-before-external-change")

        for (grouping, label) in [("recency", "Recent"), ("directory", "Folder"), ("agent", "Agent")] {
            app.buttons[label].click()
            _ = try writeSession(grouping, in: project)
            XCTAssertFalse(app.staticTexts[title(grouping)].exists, "External writes should still need the explicit reload")
            XCTAssertTrue(waitUntil { reload.isEnabled && reload.isHittable })
            reload.click()
            XCTAssertTrue(app.staticTexts[title(grouping)].waitForExistence(timeout: 30))
            XCTAssertTrue(app.staticTexts[title("baseline")].exists, "Existing sessions must survive refresh")
        }

        let search = app.searchFields.matching(
            NSPredicate(format: "placeholderValue == %@", "Search sessions…")
        ).firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("Vault13919")
        XCTAssertTrue(app.staticTexts[title("baseline")].waitForExistence(timeout: 15))
        _ = try writeSession("searched", in: project)
        XCTAssertFalse(app.staticTexts[title("searched")].exists)
        reload.click()
        XCTAssertTrue(app.staticTexts[title("searched")].waitForExistence(timeout: 30))
        XCTAssertEqual(search.value as? String, "Vault13919")
        // Typing without clicking the field again verifies that refresh kept
        // the search editor as first responder.
        app.typeText("missing")
        XCTAssertEqual(search.value as? String, "Vault13919missing")
        XCTAssertTrue(app.staticTexts["No matching sessions"].waitForExistence(timeout: 15))
        XCTAssertTrue(reload.isEnabled && reload.isHittable)
        search.typeKey("a", modifierFlags: [.command])
        search.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        XCTAssertTrue(app.staticTexts[title("baseline")].waitForExistence(timeout: 15))

        try FileManager.default.removeItem(at: baselineURL)
        reload.click()
        XCTAssertTrue(waitUntil {
            reload.isEnabled && !app.staticTexts[self.title("baseline")].exists
                && app.staticTexts[self.title("searched")].exists
        })

        // Existing keyboard mode selection and the density menu remain usable.
        app.buttons["RightSidebarModeButton.files"].click()
        app.typeKey("3", modifierFlags: [.control])
        XCTAssertTrue(reload.waitForExistence(timeout: 10))
        app.buttons["Session view"].click()
        let compact = app.menuItems["Compact view"]
        XCTAssertTrue(compact.waitForExistence(timeout: 5))
        compact.click()
        XCTAssertTrue(reload.isEnabled && reload.isHittable)
        XCTAssertTrue(app.staticTexts[title("searched")].exists)
        attach(app, name: "\(presentation)-after-reload-and-compact-view")
    }

    private func title(_ id: String) -> String { "Vault13919 \(id)" }

    @discardableResult
    private func writeSession(_ id: String, in directory: URL) throws -> URL {
        let object: [String: Any] = [
            "type": "user", "sessionId": id, "cwd": "/tmp/vault-refresh",
            "message": ["role": "user", "content": title(id)]
        ]
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        let url = directory.appendingPathComponent("\(id).jsonl")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func waitUntil(timeout: TimeInterval = 15, _ predicate: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in predicate() }, object: nil
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
