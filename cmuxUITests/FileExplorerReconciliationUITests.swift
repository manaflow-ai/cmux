import XCTest
import Foundation

final class FileExplorerReconciliationUITests: XCTestCase {
    func testLoadedTreeRemainsResponsiveAcrossAccessibilityAndFindUpdates() throws {
        continueAfterFailure = false
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-outline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        // Match the captured incident's 291 realized outline rows after expansion.
        for folder in 0..<3 {
            let directory = fixture.appendingPathComponent(String(format: "folder-%02d", folder))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for file in 0..<(folder == 0 ? 288 : 0) {
                try "outline-search-token\n".write(
                    to: directory.appendingPathComponent(String(format: "entry-%02d.txt", file)),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }

        let tag = "ui-outline-\(UUID().uuidString.prefix(8).lowercased())"
        let app = XCUIApplication.cmuxTestApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = tag
        app.launchArguments += ["-NSAppSleepDisabled", "YES"]
        app.launch()
        defer { app.terminate() }
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))

        // Focus the real terminal and send one complete shell line. The marker
        // makes setup completion observable before Files reads the directory.
        let terminal = app.textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 15), "Expected the real terminal surface")
        terminal.click()
        let quotedPath = "'" + fixture.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let commandMarker = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-shell-command-(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: commandMarker) }
        let quotedMarker = "'" + commandMarker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        app.typeText("cd \(quotedPath); touch \(quotedMarker); printf '\\033]7;file://localhost%s\\007' \"$PWD\"\n")
        XCTAssertTrue(waitForFile(commandMarker.path, timeout: 15), "Expected the fixture shell command to run")
        app.typeKey("b", modifierFlags: [.command, .option])
        let filesButton = app.buttons["RightSidebarModeButton.files"].firstMatch
        XCTAssertTrue(filesButton.waitForExistence(timeout: 15))
        filesButton.click()

        let outline = app.outlines.firstMatch
        XCTAssertTrue(outline.waitForExistence(timeout: 15))
        let firstFolder = outline.outlineRows.firstMatch
        XCTAssertTrue(
            waitForRowCount(outline, 3),
            "Expected the real local directory listing. \(app.debugDescription)"
        )
        firstFolder.click()
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        let loadedRowCount = 291
        XCTAssertTrue(waitForRowCount(outline, loadedRowCount), "Expected all 288 fixture files. \(app.debugDescription)")

        for _ in 0..<10 {
            // A full Accessibility snapshot exercises AppKit's row realization path.
            _ = app.debugDescription
            filesButton.click()
            XCTAssertEqual(outline.outlineRows.count, loadedRowCount)
        }

        // Exercise the shared Find action through a real shortcut, then the Files button.
        app.typeKey("f", modifierFlags: [.command, .shift])
        let search = app.descendants(matching: .any)["FileExplorerSearchField"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        app.typeText("outline-search-token")
        // AppKit exposes the result cell's composed path and match text as
        // its accessibility value. The label is not stable across native
        // table-cell wrappers, so assert on the actual searchable token.
        let result = app.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@",
            "outline-search-token"
        )).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 15), "Find must return an actual fixture match. \(app.debugDescription)")
        XCTAssertTrue(filesButton.exists)
        filesButton.click()
        XCTAssertTrue(firstFolder.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForRowCount(outline, loadedRowCount), "Returning from Find must restore the expanded tree")

        // Positive control: suppressing redundant work must not suppress real disk changes.
        // The existing watcher observes the root directory, not nested paths.
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("added-live-directory"), withIntermediateDirectories: false)
        XCTAssertTrue(waitForRowCount(outline, loadedRowCount + 1), "The filesystem refresh must add a row and preserve all expanded children")
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Files after Accessibility, Find, and filesystem refresh"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitForRowCount(_ outline: XCUIElement, _ rowCount: Int) -> Bool {
        // The exact loaded row count and the real Find result below prove the
        // fixture rendered without depending on AppKit's row-label packaging.
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            outline.outlineRows.count == rowCount
        }, object: nil)
        return XCTWaiter().wait(for: [loaded], timeout: 15) == .completed
    }

    private func waitForFile(_ path: String, timeout: TimeInterval) -> Bool {
        let created = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: path)
        }, object: nil)
        return XCTWaiter().wait(for: [created], timeout: timeout) == .completed
    }
}
