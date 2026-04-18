import XCTest
import Foundation

final class LatestMacOSLaunchSmokeUITests: XCTestCase {
    private let launchTag = "ui-tests-latest-macos-launch-smoke"
    private var launchHomeDirectory: URL?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        launchHomeDirectory = makeIsolatedHomeDirectory()
    }

    override func tearDown() {
        if let launchHomeDirectory {
            try? FileManager.default.removeItem(at: launchHomeDirectory)
        }
        launchHomeDirectory = nil
        super.tearDown()
    }

    func testAppLaunchDoesNotCrashOnStartupWithManagedAppIconSettings() throws {
        guard let launchHomeDirectory else {
            XCTFail("Missing isolated HOME directory")
            return
        }
        try writeManagedSettingsFixture(into: launchHomeDirectory)

        let app = XCUIApplication()
        app.launchEnvironment["CMUX_TAG"] = launchTag
        app.launchEnvironment["HOME"] = launchHomeDirectory.path

        launchAllowingHeadlessBackgroundState(app)

        XCTAssertTrue(
            waitForAppToStart(app, timeout: 20.0),
            "Expected cmux to start on latest macOS. state=\(app.state.rawValue)"
        )

        XCTAssertTrue(
            waitForNoImmediateCrash(app, duration: 10.0),
            "Expected cmux to remain running for startup stability window. state=\(app.state.rawValue)"
        )

        if isRunning(app) {
            app.terminate()
        }
    }

    private func launchAllowingHeadlessBackgroundState(_ app: XCUIApplication) {
        // Some CI runners launch in background-only mode, which can emit an
        // activation failure even when the process is healthy.
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }
    }

    private func waitForAppToStart(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isRunning(app) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return isRunning(app)
    }

    private func waitForNoImmediateCrash(_ app: XCUIApplication, duration: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            if !isRunning(app) {
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return true
    }

    private func isRunning(_ app: XCUIApplication) -> Bool {
        app.state == .runningForeground || app.state == .runningBackground
    }

    private func makeIsolatedHomeDirectory() -> URL {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ui-test-home-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: path,
            withIntermediateDirectories: true
        )
        return path
    }

    private func writeManagedSettingsFixture(into homeDirectory: URL) throws {
        let configDirectory = homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: true)
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        let settingsURL = configDirectory.appendingPathComponent("settings.json", isDirectory: false)
        let settings = """
        {
          "schemaVersion": 1,
          "app": {
            "appIcon": "automatic"
          }
        }
        """
        try settings.write(to: settingsURL, atomically: true, encoding: .utf8)
    }
}
