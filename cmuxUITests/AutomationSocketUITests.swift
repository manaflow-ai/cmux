import XCTest
import Foundation

final class AutomationSocketUITests: XCTestCase {
    private var socketPath = ""
    private let defaultsDomain = "com.cmuxterm.app.debug"
    private let modeKey = "socketControlMode"
    private let legacyKey = "socketControlEnabled"
    private let launchTag = "ui-tests-automation-socket"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-debug-\(UUID().uuidString).sock"
        resetSocketDefaults()
        resetMobileSyncDefaults()
        removeSocketFile()
    }

    func testSocketToggleDisablesAndEnables() {
        let app = configuredApp(mode: "cmuxOnly")
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for socket toggle test. state=\(app.state.rawValue)"
        )

        guard let resolvedPath = resolveSocketPath(timeout: 5.0) else {
            XCTFail("Expected control socket to exist")
            return
        }
        socketPath = resolvedPath
        XCTAssertTrue(waitForSocket(exists: true, timeout: 2.0))
        app.terminate()
    }

    func testSocketDisabledWhenSettingOff() {
        let app = configuredApp(mode: "off")
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for socket off test. state=\(app.state.rawValue)"
        )

        XCTAssertTrue(waitForSocket(exists: false, timeout: 3.0))
        app.terminate()
    }

    func testMobileSyncSettingsTogglePersists() throws {
        let app = configuredApp(mode: "cmuxOnly")
        app.launchEnvironment["CMUX_UI_TEST_SHOW_SETTINGS"] = "1"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for mobile sync Settings test. state=\(app.state.rawValue)"
        )

        let toggle = try requireMobileSyncToggle(app: app)
        XCTAssertFalse(toggleIsOn(toggle), "Mobile sync should default off")
        toggle.click()
        XCTAssertTrue(waitForMobileSyncToggle(app: app, isOn: true, timeout: 4.0))
        app.terminate()

        let relaunchedApp = configuredApp(mode: "cmuxOnly")
        relaunchedApp.launchEnvironment["CMUX_UI_TEST_SHOW_SETTINGS"] = "1"
        relaunchedApp.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        relaunchedApp.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(relaunchedApp, timeout: 12.0),
            "Expected app to relaunch for mobile sync Settings test. state=\(relaunchedApp.state.rawValue)"
        )
        addTeardownBlock { relaunchedApp.terminate() }

        let persistedToggle = try requireMobileSyncToggle(app: relaunchedApp)
        XCTAssertTrue(toggleIsOn(persistedToggle), "Mobile sync setting should persist across launch")
        persistedToggle.click()
        XCTAssertTrue(waitForMobileSyncToggle(app: relaunchedApp, isOn: false, timeout: 4.0))
    }

    private func configuredApp(mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-\(modeKey)", mode]
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        // Debug launches require a tag outside reload.sh; provide one in UITests so CI
        // does not fail with "Application ... does not have a process ID".
        app.launchEnvironment["CMUX_TAG"] = launchTag
        return app
    }

    private func ensureForegroundAfterLaunch(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if app.wait(for: .runningForeground, timeout: timeout) {
            return true
        }
        // On busy UI runners the app can launch backgrounded; activate once before failing.
        if app.state == .runningBackground {
            app.activate()
            return app.wait(for: .runningForeground, timeout: 6.0)
        }
        return false
    }

    private func requireMobileSyncToggle(app: XCUIApplication) throws -> XCUIElement {
        let scrollView = app.scrollViews.firstMatch
        let candidates = mobileSyncToggleCandidates(app: app)

        for _ in 0..<10 {
            if let element = firstExistingElement(candidates: candidates, timeout: 0.5), element.isHittable {
                return element
            }
            if scrollView.exists {
                scrollView.swipeUp()
            } else {
                app.typeKey(",", modifierFlags: [.command])
            }
        }

        throw XCTSkip("Could not find the iOS and iPadOS Sync toggle")
    }

    private func waitForMobileSyncToggle(app: XCUIApplication, isOn: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let toggle = firstExistingElement(candidates: mobileSyncToggleCandidates(app: app), timeout: 0.2),
               toggleIsOn(toggle) == isOn {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return false
    }

    private func mobileSyncToggleCandidates(app: XCUIApplication) -> [XCUIElement] {
        [
            app.switches["SettingsMobileSyncToggle"],
            app.checkBoxes["SettingsMobileSyncToggle"],
            app.buttons["SettingsMobileSyncToggle"],
            app.otherElements["SettingsMobileSyncToggle"],
            app.switches["iOS and iPadOS Sync"],
            app.checkBoxes["iOS and iPadOS Sync"],
            app.buttons["iOS and iPadOS Sync"],
            app.otherElements["iOS and iPadOS Sync"],
        ]
    }

    private func toggleIsOn(_ element: XCUIElement) -> Bool {
        let value = String(describing: element.value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return value == "1" || value == "true" || value == "on"
    }

    private func firstExistingElement(candidates: [XCUIElement], timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let match = candidates.first(where: { $0.exists }) {
                return match
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return candidates.first(where: { $0.exists })
    }

    private func waitForSocket(exists: Bool, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: self.socketPath) == exists
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func resolveSocketPath(timeout: TimeInterval) -> String? {
        var resolvedPath: String?
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                if FileManager.default.fileExists(atPath: self.socketPath) {
                    resolvedPath = self.socketPath
                    return true
                }
                if let found = self.findSocketInTmp() {
                    resolvedPath = found
                    return true
                }
                return false
            },
            object: NSObject()
        )
        if XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed {
            return resolvedPath
        }
        return resolvedPath
    }

    private func findSocketInTmp() -> String? {
        let tmpPath = "/tmp"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: tmpPath) else {
            return nil
        }
        let matches = entries.filter { $0.hasPrefix("cmux") && $0.hasSuffix(".sock") }
        if let debug = matches.first(where: { $0.contains("debug") }) {
            return (tmpPath as NSString).appendingPathComponent(debug)
        }
        if let first = matches.first {
            return (tmpPath as NSString).appendingPathComponent(first)
        }
        return nil
    }

    private func resetSocketDefaults() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["delete", defaultsDomain, modeKey]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
        let legacy = Process()
        legacy.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        legacy.arguments = ["delete", defaultsDomain, legacyKey]
        do {
            try legacy.run()
            legacy.waitUntilExit()
        } catch {
            return
        }
    }

    private func resetMobileSyncDefaults() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["delete", defaultsDomain, MobileSyncDefaultsKey.enabled]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
    }

    private func removeSocketFile() {
        try? FileManager.default.removeItem(atPath: socketPath)
    }
}

private enum MobileSyncDefaultsKey {
    static let enabled = "mobileSyncEnabled"
}
