import AppKit
import XCTest

final class CommandPaletteIdentifierClipboardUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testCmdShiftPCopyIdentifierCommandsWriteExpectedClipboardPayloads() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        launchAndActivate(app)

        XCTAssertTrue(
            pollUntil(timeout: 8.0) { app.windows.count >= 1 },
            "Expected the main window to be visible"
        )

        runCommandPaletteCopyCommand(
            app: app,
            query: "copy workspace id",
            commandId: "palette.copyWorkspaceID",
            expectedClipboardKeys: ["workspace_id"]
        )
        runCommandPaletteCopyCommand(
            app: app,
            query: "copy workspace ref",
            commandId: "palette.copyWorkspaceIDAndRef",
            expectedClipboardKeys: ["workspace_ref", "workspace_id"]
        )
        runCommandPaletteCopyCommand(
            app: app,
            query: "copy pane id",
            commandId: "palette.copyPaneID",
            expectedClipboardKeys: ["pane_id"]
        )
        runCommandPaletteCopyCommand(
            app: app,
            query: "copy surface id",
            commandId: "palette.copySurfaceID",
            expectedClipboardKeys: ["surface_id"]
        )
        runCommandPaletteCopyCommand(
            app: app,
            query: "workspace pane surface",
            commandId: "palette.copyIdentifiers",
            expectedClipboardKeys: [
                "workspace_ref",
                "workspace_id",
                "pane_ref",
                "pane_id",
                "surface_ref",
                "surface_id",
            ]
        )
    }

    private func launchAndActivate(_ app: XCUIApplication) {
        app.launch()
        XCTAssertTrue(
            pollUntil(timeout: 4.0) {
                guard app.state != .runningForeground else { return true }
                app.activate()
                return app.state == .runningForeground
            },
            "App did not reach runningForeground before UI interactions"
        )
    }

    private func runCommandPaletteCopyCommand(
        app: XCUIApplication,
        query: String,
        commandId: String,
        expectedClipboardKeys: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        NSPasteboard.general.clearContents()
        openCommandPaletteCommands(app: app)
        let searchField = app.textFields["CommandPaletteSearchField"]
        searchField.typeText(query)

        let predicate = NSPredicate(
            format: "identifier BEGINSWITH %@ AND value == %@",
            "CommandPaletteResultRow.",
            commandId
        )
        let row = app.descendants(matching: .any)
            .matching(predicate)
            .firstMatch
        XCTAssertTrue(
            row.waitForExistence(timeout: 5.0),
            "Expected row for command \(commandId)",
            file: file,
            line: line
        )
        row.click()
        XCTAssertTrue(
            pollUntil(timeout: 2.0) { !searchField.exists },
            "Expected command palette to dismiss after \(commandId)",
            file: file,
            line: line
        )

        let observed = waitForIdentifierClipboard(keys: expectedClipboardKeys, timeout: 2.0)
        XCTAssertTrue(
            identifierClipboardPayloadMatches(observed, keys: expectedClipboardKeys),
            "Expected clipboard keys \(expectedClipboardKeys), got \(observed ?? "<nil>")",
            file: file,
            line: line
        )
    }

    private func openCommandPaletteCommands(app: XCUIApplication) {
        let searchField = app.textFields["CommandPaletteSearchField"]
        app.typeKey("p", modifierFlags: [.command, .shift])
        XCTAssertTrue(searchField.waitForExistence(timeout: 5.0), "Expected command palette search field")
        searchField.click()
    }

    private func waitForIdentifierClipboard(keys: [String], timeout: TimeInterval) -> String? {
        var latest: String?
        _ = pollUntil(timeout: timeout) {
            latest = NSPasteboard.general.string(forType: .string)
            return identifierClipboardPayloadMatches(latest, keys: keys)
        }
        return latest
    }

    private func identifierClipboardPayloadMatches(_ payload: String?, keys: [String]) -> Bool {
        guard let payload else { return false }
        let lines = payload.components(separatedBy: "\n")
        guard lines.count == keys.count else { return false }
        return zip(lines, keys).allSatisfy { line, key in
            guard line.hasPrefix("\(key)=") else { return false }
            let value = String(line.dropFirst(key.count + 1))
            if key.hasSuffix("_id") {
                return UUID(uuidString: value) != nil
            }
            if key.hasSuffix("_ref") {
                let expectedPrefix: String
                switch key {
                case "workspace_ref":
                    expectedPrefix = "workspace:"
                case "pane_ref":
                    expectedPrefix = "pane:"
                case "surface_ref":
                    expectedPrefix = "surface:"
                default:
                    return false
                }
                guard value.hasPrefix(expectedPrefix) else { return false }
                return Int(value.dropFirst(expectedPrefix.count)) != nil
            }
            return false
        }
    }

    private func pollUntil(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.05,
        condition: () -> Bool
    ) -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        while true {
            if condition() {
                return true
            }
            if (ProcessInfo.processInfo.systemUptime - start) >= timeout {
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
    }
}
