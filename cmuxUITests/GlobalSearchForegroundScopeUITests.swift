import AppKit
import XCTest

final class GlobalSearchForegroundScopeUITests: XCTestCase {
    private var app: XCUIApplication!
    private var appProcess: Process?

    override func setUpWithError() throws {
        continueAfterFailure = false
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCmuxExecutablePath())
        process.arguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO",
            "-menuBarOnly", "false",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_UI_TEST_MODE"] = "1"
        process.environment = environment

        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-global-search-background-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        appProcess = process

        app = XCUIApplication(bundleIdentifier: "com.cmuxterm.app.debug")
        XCTAssertTrue(
            app.wait(for: .runningBackground, timeout: 10.0),
            "Expected cmux to launch in the background. state=\(app.state.rawValue)"
        )
    }

    override func tearDownWithError() throws {
        app?.terminate()
        terminateAppProcess()
        app = nil
    }

    func testBackgroundGlobalSearchShortcutIsDeliveredToFinder() throws {
        defer { attachScreenshot(named: "background-shortcut-delivered-to-finder") }

        let globalSearchField = app.textFields["GlobalSearchSearchField"].firstMatch
        XCTAssertFalse(globalSearchField.exists, "Global Search should start closed")

        let finderProbeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-global-search-finder-probe-\(UUID().uuidString)")
        try Data().write(to: finderProbeURL)
        defer { try? FileManager.default.removeItem(at: finderProbeURL) }

        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        NSWorkspace.shared.activateFileViewerSelecting([finderProbeURL])
        XCTAssertTrue(
            finder.wait(for: .runningForeground, timeout: 8.0),
            "Expected Finder to be foreground. state=\(finder.state.rawValue)"
        )
        XCTAssertTrue(
            finder.windows.firstMatch.waitForExistence(timeout: 8.0),
            "Expected Finder to open a window for keyboard input"
        )
        XCTAssertTrue(
            waitForAppToLeaveForeground(app, timeout: 8.0),
            "Expected cmux to be backgrounded. state=\(app.state.rawValue)"
        )

        finder.typeKey("f", modifierFlags: [.command, .option])

        let finderSearchField = finder.searchFields.firstMatch
        XCTAssertTrue(
            waitForKeyboardFocus(finderSearchField, timeout: 8.0),
            "Expected Finder to receive Cmd-Option-F and focus its search field"
        )
        XCTAssertEqual(finder.state, .runningForeground, "Finder should remain foreground after Cmd-Option-F")
        XCTAssertNotEqual(
            app.state,
            .runningForeground,
            "cmux must remain backgrounded after Finder receives Cmd-Option-F"
        )
        XCTAssertFalse(globalSearchField.exists, "Background Cmd-Option-F must not open cmux Global Search")
    }

    private func waitForAppToLeaveForeground(_ application: XCUIApplication, timeout: TimeInterval) -> Bool {
        waitForPredicate(
            NSPredicate(format: "state != %d", XCUIApplication.State.runningForeground.rawValue),
            object: application,
            timeout: timeout
        )
    }

    private func waitForKeyboardFocus(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        waitForPredicate(
            NSPredicate(format: "exists == true AND hasKeyboardFocus == true"),
            object: element,
            timeout: timeout
        )
    }

    private func waitForPredicate(_ predicate: NSPredicate, object: Any, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: object)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func builtCmuxExecutablePath() throws -> String {
        let testBundle = Bundle(for: Self.self)
        let productsDirectory = testBundle.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let executablePath = productsDirectory
            .appendingPathComponent("cmux DEV.app")
            .appendingPathComponent("Contents/MacOS/cmux DEV")
            .path
        guard FileManager.default.fileExists(atPath: executablePath) else {
            throw NSError(
                domain: "GlobalSearchForegroundScopeUITests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not locate the built cmux executable at \(executablePath)"]
            )
        }
        return executablePath
    }

    private func terminateAppProcess() {
        guard let appProcess else { return }
        defer { self.appProcess = nil }
        guard appProcess.isRunning else { return }

        appProcess.terminate()
        let deadline = Date.now.addingTimeInterval(5.0)
        while appProcess.isRunning, Date.now < deadline {
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.1))
        }
        if appProcess.isRunning {
            appProcess.interrupt()
        }
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
