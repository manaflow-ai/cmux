import Foundation
import XCTest

final class BrowserDownloadsPopoverContrastUITests: XCTestCase {
    private var app: XCUIApplication?
    private var appProcess: Process?
    private var appLogPath = ""
    private var isolatedHome: URL?
    private var launchTag = ""
    private var probePath = ""
    private var setupPath = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        let token = UUID().uuidString
        let temporaryDirectory = FileManager.default.temporaryDirectory
        appLogPath = temporaryDirectory
            .appendingPathComponent("cmux-ui-test-downloads-popover-\(token).log")
            .path
        launchTag = "ui-tests-downloads-popover-\(token.prefix(8))"
        probePath = temporaryDirectory
            .appendingPathComponent("cmux-ui-test-downloads-popover-probe-\(token).json")
            .path
        setupPath = temporaryDirectory
            .appendingPathComponent("cmux-ui-test-downloads-popover-setup-\(token).json")
            .path
        removeTestArtifacts()
    }

    override func tearDown() {
        app?.terminate()
        terminateAppProcess()
        if let isolatedHome {
            try? FileManager.default.removeItem(at: isolatedHome)
        }
        removeTestArtifacts()
        super.tearDown()
    }

    func testDownloadsPopoverKeepsLightChromeReadableWhenAppKitAppearanceIsDark() throws {
        let isolatedHome = try makeIsolatedHomeWithLightTerminalTheme()
        self.isolatedHome = isolatedHome
        let fixtureURL = isolatedHome
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("error.txt", isDirectory: false)
        try Data(repeating: 0x41, count: 5_400).write(to: fixtureURL, options: .atomic)

        let app = XCUIApplication(bundleIdentifier: "com.cmuxterm.app.debug")
        self.app = app
        app.terminate()

        let launchArguments = [
            "-appearanceMode", "dark",
            "-browserThemeMode", "light",
            "-browserAskWhereToSaveDownloads", "false",
        ]
        let launchEnvironment = [
            "HOME": isolatedHome.path,
            "CFFIXED_USER_HOME": isolatedHome.path,
            "XDG_CONFIG_HOME": isolatedHome.appendingPathComponent(".config", isDirectory: true).path,
            "CMUX_TAG": launchTag,
            "CMUX_UI_TEST_PROCESS": "1",
            "CMUX_UI_TEST_MODE": "1",
            "CMUX_UI_TEST_GOTO_SPLIT_SETUP": "1",
            "CMUX_UI_TEST_GOTO_SPLIT_PATH": setupPath,
            "CMUX_UI_TEST_GOTO_SPLIT_BROWSER_URL": makePageDataURL(),
            "CMUX_UI_TEST_GOTO_SPLIT_USE_GHOSTTY_CONFIG": "1",
            "CMUX_UI_TEST_DOWNLOADS_POPOVER_APPEARANCE_PATH": probePath,
            "CMUX_UI_TEST_DOWNLOADS_POPOVER_FIXTURE_PATH": fixtureURL.path,
        ]
        try launchAppProcess(arguments: launchArguments, environment: launchEnvironment)

        XCTAssertTrue(
            waitForJSON(atPath: setupPath, timeout: 12) { $0["browserPageTitle"] == "downloads-popover-contrast" },
            "Expected the browser fixture to finish loading. " +
                "data=\(loadJSON(atPath: setupPath) ?? [:]) app=\(launchedAppDiagnostics()) " +
                "log=\(appLogTail())"
        )
        XCTAssertTrue(
            waitForJSON(atPath: probePath, timeout: 8) {
                $0["contentColorScheme"] == "light" &&
                    $0["windowAppearance"] == "light" &&
                    $0["windowClass"] == "_NSPopoverWindow"
            },
            "Expected the real downloads popover to report its presentation appearance. " +
                "probe=\(loadJSON(atPath: probePath) ?? [:]) app=\(launchedAppDiagnostics()) " +
                "log=\(appLogTail())"
        )

        let probe = try XCTUnwrap(loadJSON(atPath: probePath))
        XCTAssertEqual(
            probe["contentColorScheme"],
            "light",
            "Expected the popover content to inherit the light browser-chrome scheme. probe=\(probe)"
        )
        XCTAssertEqual(
            probe["windowAppearance"],
            "light",
            "Expected the AppKit popover presentation and its semantic foregrounds to resolve " +
                "under the same light appearance. probe=\(probe)"
        )
        XCTAssertEqual(
            probe["windowClass"],
            "_NSPopoverWindow",
            "Expected the probe to observe the genuine AppKit popover window. probe=\(probe)"
        )
    }

    private func makeIsolatedHomeWithLightTerminalTheme() throws -> URL {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-ui-test-downloads-popover-home-\(UUID().uuidString)",
            isDirectory: true
        )
        let ghosttyDirectory = home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
        try fileManager.createDirectory(at: ghosttyDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: home.appendingPathComponent("Downloads", isDirectory: true),
            withIntermediateDirectories: true
        )

        let config = """
        # Force browser chrome to resolve light while AppKit remains dark.
        working-directory = \(home.path)
        background = #f5f5f5
        foreground = #111111
        background-opacity = 1

        """
        try config.write(
            to: ghosttyDirectory.appendingPathComponent("config.ghostty", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        return home
    }

    private func makePageDataURL() -> String {
        let html = """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><title>downloads-popover-contrast</title></head>
        <body></body>
        </html>
        """
        return "data:text/html;base64,\(Data(html.utf8).base64EncodedString())"
    }

    private func launchAppProcess(arguments: [String], environment: [String: String]) throws {
        // XCUIApplication.launch() waits for foreground activation and aborts
        // after 60 seconds on headless runners. Launch the built binary directly;
        // the app-side probe exercises the real popover without AX interaction.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try resolveAppBinaryPath())
        process.arguments = arguments
        var launchEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            launchEnvironment[key] = value
        }
        process.environment = launchEnvironment

        _ = FileManager.default.createFile(atPath: appLogPath, contents: nil)
        let logHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: appLogPath))
        process.standardOutput = logHandle
        process.standardError = logHandle

        try process.run()
        appProcess = process
    }

    private func resolveAppBinaryPath() throws -> String {
        let testBundle = Bundle(for: Self.self)
        let productsDirectory = testBundle.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let binaryPath = productsDirectory
            .appendingPathComponent("cmux DEV.app")
            .appendingPathComponent("Contents/MacOS/cmux DEV")
            .path
        guard FileManager.default.fileExists(atPath: binaryPath) else {
            throw NSError(
                domain: "BrowserDownloadsPopoverContrastUITests",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "App binary not found at \(binaryPath). testBundle=\(testBundle.bundleURL.path)"
                ]
            )
        }
        return binaryPath
    }

    private func terminateAppProcess() {
        guard let process = appProcess else { return }
        defer { appProcess = nil }
        guard process.isRunning else { return }

        process.terminate()
        if waitForProcessExit(process, timeout: 5) {
            return
        }
        process.interrupt()
        XCTAssertTrue(
            waitForProcessExit(process, timeout: 2),
            "Expected UI-test app process \(process.processIdentifier) to exit after interrupt"
        )
    }

    private func waitForProcessExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !process.isRunning },
            object: nil
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func launchedAppDiagnostics() -> String {
        guard let process = appProcess else { return "not-launched" }
        return "pid=\(process.processIdentifier) running=\(process.isRunning)"
    }

    private func appLogTail() -> String {
        (try? String(contentsOfFile: appLogPath, encoding: .utf8))
            .map { String($0.suffix(2_000)) } ?? "<empty>"
    }

    private func removeTestArtifacts() {
        for path in [setupPath, probePath, appLogPath] where !path.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func waitForJSON(
        atPath path: String,
        timeout: TimeInterval,
        predicate: @escaping ([String: String]) -> Bool
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard let data = self.loadJSON(atPath: path) else { return false }
                return predicate(data)
            },
            object: nil
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func loadJSON(atPath path: String) -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }
}
