import AppKit
import Darwin
import XCTest

final class CommandPaletteIdentifierClipboardUITests: XCTestCase {
    private let debugDefaultsDomain = "com.cmuxterm.app.debug"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        resetMenuBarOnlyDefault()
    }

    override func tearDown() {
        resetMenuBarOnlyDefault()
        super.tearDown()
    }

    func testCmdShiftPCopyIdentifierCommandsWriteExpectedClipboardPayloads() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-menuBarOnly", "false"]
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

    func testCmdShiftPOpenCmuxJSONOpensUserConfigFile() throws {
        let app = XCUIApplication()
        let capturePath = "/tmp/cmux-ui-test-open-cmux-json-\(UUID().uuidString).txt"
        try? FileManager.default.removeItem(atPath: capturePath)
        addTeardownBlock {
            app.terminate()
            try? FileManager.default.removeItem(atPath: capturePath)
        }

        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-menuBarOnly", "false"]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_CAPTURE_OPEN_PATH"] = capturePath
        launchAndActivate(app)

        XCTAssertTrue(
            pollUntil(timeout: 8.0) { app.windows.count >= 1 },
            "Expected the main window to be visible"
        )

        openCommandPaletteCommands(app: app)
        let searchField = app.textFields["CommandPaletteSearchField"]
        searchField.typeText("open cmux json")

        let predicate = NSPredicate(
            format: "identifier BEGINSWITH %@ AND value == %@",
            "CommandPaletteResultRow.",
            "palette.openCmuxSettingsFile"
        )
        let row = app.descendants(matching: .any)
            .matching(predicate)
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5.0), "Expected row for Open cmux.json")
        try? FileManager.default.removeItem(atPath: capturePath)
        row.click()

        let openedPath = try XCTUnwrap(
            capturedOpenPath(at: capturePath, timeout: 3.0),
            "Expected the palette action to attempt opening a file"
        )
        let expectedPath = (loginHomeDirectoryPath() as NSString)
            .appendingPathComponent(".config/cmux/cmux.json")
        XCTAssertEqual(openedPath, expectedPath)
    }

    private func loginHomeDirectoryPath() -> String {
        if let passwd = getpwuid(getuid()), let home = passwd.pointee.pw_dir {
            return String(cString: home)
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    private func launchAndActivate(_ app: XCUIApplication) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }

        if app.state == .runningForeground { return }

        var reachedForeground = false
        let activateOptions = XCTExpectedFailure.Options()
        activateOptions.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: activateOptions) {
            reachedForeground = pollUntil(timeout: 4.0) {
                if app.state != .runningForeground {
                    app.activate()
                }
                return app.state == .runningForeground
            }
            XCTAssertTrue(reachedForeground, "App did not reach runningForeground before UI interactions")
        }
        if reachedForeground || app.state == .runningBackground {
            return
        }
        XCTFail("App failed to start. state=\(app.state.rawValue)")
    }

    private func resetMenuBarOnlyDefault() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["write", debugDefaultsDomain, "menuBarOnly", "-bool", "false"]
        do {
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(
                process.terminationStatus,
                0,
                "Failed to reset menuBarOnly default: status \(process.terminationStatus)"
            )
        } catch {
            XCTFail("Failed to reset menuBarOnly default: \(error.localizedDescription)")
        }
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

    private func capturedOpenPath(at path: String, timeout: TimeInterval) -> String? {
        var captured: String?
        let matched = pollUntil(timeout: timeout) {
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                return false
            }
            captured = contents
                .split(separator: "\n")
                .map(String.init)
                .first
            return captured != nil
        }
        return matched ? captured : nil
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
