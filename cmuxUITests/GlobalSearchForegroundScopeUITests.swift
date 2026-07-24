import AppKit
import XCTest

final class GlobalSearchForegroundScopeUITests: XCTestCase {
    private static let shortcutProbeBundleIdentifier = "com.cmuxterm.tests.shortcut-probe"

    private var app: XCUIApplication!
    private var appProcess: Process?
    private var shortcutProbeProcess: Process?

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
        terminateProcess(&shortcutProbeProcess)
        app?.terminate()
        terminateProcess(&appProcess)
        app = nil
    }

    func testBackgroundGlobalSearchShortcutIsDeliveredToForegroundApp() throws {
        defer { attachScreenshot(named: "background-shortcut-delivered-to-foreground-app") }

        let globalSearchField = app.textFields["GlobalSearchSearchField"].firstMatch
        XCTAssertFalse(globalSearchField.exists, "Global Search should start closed")

        let probeExecutableURL = try builtShortcutProbeExecutableURL()
        let probeProcess = Process()
        probeProcess.executableURL = probeExecutableURL
        try probeProcess.run()
        shortcutProbeProcess = probeProcess

        let probe = XCUIApplication(bundleIdentifier: Self.shortcutProbeBundleIdentifier)
        XCTAssertTrue(
            waitForAppToRun(probe, timeout: 10.0),
            "Expected shortcut probe to launch. state=\(probe.state.rawValue)"
        )
        if probe.state != .runningForeground {
            probe.activate()
        }
        XCTAssertTrue(
            probe.wait(for: .runningForeground, timeout: 10.0),
            "Expected shortcut probe to be foreground. state=\(probe.state.rawValue)"
        )
        XCTAssertTrue(
            probe.windows.firstMatch.waitForExistence(timeout: 8.0),
            "Expected shortcut probe to open a keyboard target window"
        )
        XCTAssertTrue(
            waitForAppToLeaveForeground(app, timeout: 8.0),
            "Expected cmux to be backgrounded. state=\(app.state.rawValue)"
        )

        let probeStatus = probe.staticTexts["ShortcutProbeStatus"]
        XCTAssertTrue(
            probeStatus.waitForExistence(timeout: 8.0),
            "Expected shortcut probe status label"
        )
        XCTAssertEqual(probeStatus.label, "Waiting for Cmd-Option-F")

        probe.typeKey("f", modifierFlags: [.command, .option])

        XCTAssertTrue(
            waitForLabel(probeStatus, equalTo: "Received Cmd-Option-F", timeout: 8.0),
            "Expected the foreground app to receive Cmd-Option-F"
        )
        XCTAssertEqual(probe.state, .runningForeground, "Shortcut probe should remain foreground")
        XCTAssertNotEqual(
            app.state,
            .runningForeground,
            "cmux must remain backgrounded after the foreground app receives Cmd-Option-F"
        )
        XCTAssertFalse(globalSearchField.exists, "Background Cmd-Option-F must not open cmux Global Search")

        app.activate()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 10.0),
            "Expected cmux to become foreground. state=\(app.state.rawValue)"
        )

        app.typeKey("f", modifierFlags: [.command, .option])
        XCTAssertTrue(
            globalSearchField.waitForExistence(timeout: 8.0),
            "Foreground Cmd-Option-F must open cmux Global Search"
        )

        app.typeKey("f", modifierFlags: [.command, .option])
        XCTAssertTrue(
            waitForPredicate(
                NSPredicate(format: "exists == false"),
                object: globalSearchField,
                timeout: 8.0
            ),
            "A second foreground Cmd-Option-F must close cmux Global Search"
        )
    }

    private func waitForAppToRun(_ application: XCUIApplication, timeout: TimeInterval) -> Bool {
        waitForPredicate(
            NSPredicate(
                format: "state == %d OR state == %d",
                XCUIApplication.State.runningBackground.rawValue,
                XCUIApplication.State.runningForeground.rawValue
            ),
            object: application,
            timeout: timeout
        )
    }

    private func waitForAppToLeaveForeground(_ application: XCUIApplication, timeout: TimeInterval) -> Bool {
        waitForPredicate(
            NSPredicate(format: "state != %d", XCUIApplication.State.runningForeground.rawValue),
            object: application,
            timeout: timeout
        )
    }

    private func waitForLabel(_ element: XCUIElement, equalTo label: String, timeout: TimeInterval) -> Bool {
        waitForPredicate(
            NSPredicate(format: "exists == true AND label == %@", label),
            object: element,
            timeout: timeout
        )
    }

    private func waitForPredicate(_ predicate: NSPredicate, object: Any, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: object)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func builtCmuxExecutablePath() throws -> String {
        let executablePath = builtProductsDirectory()
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

    private func builtShortcutProbeExecutableURL() throws -> URL {
        let executableURL = builtProductsDirectory()
            .appendingPathComponent("ShortcutProbe.app")
            .appendingPathComponent("Contents/MacOS/ShortcutProbe")
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw NSError(
                domain: "GlobalSearchForegroundScopeUITests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not locate shortcut probe at \(executableURL.path)"]
            )
        }
        return executableURL
    }

    private func builtProductsDirectory() -> URL {
        Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func terminateProcess(_ process: inout Process?) {
        guard let runningProcess = process else { return }
        defer { process = nil }
        guard runningProcess.isRunning else { return }

        runningProcess.terminate()
        let deadline = Date.now.addingTimeInterval(5.0)
        while runningProcess.isRunning, Date.now < deadline {
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.1))
        }
        if runningProcess.isRunning {
            runningProcess.interrupt()
        }
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
