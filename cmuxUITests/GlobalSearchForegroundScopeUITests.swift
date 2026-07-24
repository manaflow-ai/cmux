import AppKit
import XCTest

final class GlobalSearchForegroundScopeUITests: XCTestCase {
    private static let shortcutProbeBundleIdentifier = "com.cmuxterm.tests.shortcut-probe"

    private var app: XCUIApplication!
    private var appProcess: Process?
    private var shortcutProbeProcess: Process?
    private var shortcutProbeRootURL: URL?

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
        if let shortcutProbeRootURL {
            try? FileManager.default.removeItem(at: shortcutProbeRootURL)
        }
        shortcutProbeRootURL = nil
        app = nil
    }

    func testBackgroundGlobalSearchShortcutIsDeliveredToForegroundApp() throws {
        defer { attachScreenshot(named: "background-shortcut-delivered-to-foreground-app") }

        let globalSearchField = app.textFields["GlobalSearchSearchField"].firstMatch
        XCTAssertFalse(globalSearchField.exists, "Global Search should start closed")

        let probeExecutableURL = try buildShortcutProbe()
        let probeProcess = Process()
        probeProcess.executableURL = probeExecutableURL
        try probeProcess.run()
        shortcutProbeProcess = probeProcess

        let probe = XCUIApplication(bundleIdentifier: Self.shortcutProbeBundleIdentifier)
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

    private func buildShortcutProbe() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-shortcut-probe-\(UUID().uuidString)", isDirectory: true)
        let appURL = rootURL.appendingPathComponent("ShortcutProbe.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let executableDirectoryURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let executableURL = executableDirectoryURL.appendingPathComponent("ShortcutProbe")
        let sourceURL = rootURL.appendingPathComponent("main.swift")

        try FileManager.default.createDirectory(at: executableDirectoryURL, withIntermediateDirectories: true)
        try Self.shortcutProbeSource.write(to: sourceURL, atomically: true, encoding: .utf8)
        shortcutProbeRootURL = rootURL

        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = [
            "swiftc",
            sourceURL.path,
            "-o", executableURL.path,
            "-framework", "AppKit",
        ]
        let diagnostics = Pipe()
        compiler.standardError = diagnostics
        try compiler.run()
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else {
            let output = String(
                data: diagnostics.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "<no compiler diagnostics>"
            throw NSError(
                domain: "GlobalSearchForegroundScopeUITests",
                code: Int(compiler.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Failed to build shortcut probe: \(output)"]
            )
        }

        let info: [String: Any] = [
            "CFBundleExecutable": "ShortcutProbe",
            "CFBundleIdentifier": Self.shortcutProbeBundleIdentifier,
            "CFBundleName": "ShortcutProbe",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "14.0",
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"), options: .atomic)
        return executableURL
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

    private static let shortcutProbeSource = """
    import AppKit

    final class ShortcutProbeDelegate: NSObject, NSApplicationDelegate {
        private let statusLabel = NSTextField(labelWithString: "Waiting for Cmd-Option-F")
        private let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        func applicationDidFinishLaunching(_ notification: Notification) {
            let contentView = NSView(frame: window.contentLayoutRect)
            statusLabel.setAccessibilityIdentifier("ShortcutProbeStatus")
            statusLabel.alignment = .center
            statusLabel.font = .systemFont(ofSize: 24, weight: .medium)
            statusLabel.frame = NSRect(x: 30, y: 80, width: 460, height: 40)
            contentView.addSubview(statusLabel)
            window.contentView = contentView
            window.title = "Foreground Shortcut Probe"

            let mainMenu = NSMenu()
            let applicationMenuItem = NSMenuItem()
            let applicationMenu = NSMenu()
            let shortcutItem = NSMenuItem(
                title: "Receive Cmd-Option-F",
                action: #selector(receiveShortcut),
                keyEquivalent: "f"
            )
            shortcutItem.keyEquivalentModifierMask = [.command, .option]
            shortcutItem.target = self
            applicationMenu.addItem(shortcutItem)
            applicationMenuItem.submenu = applicationMenu
            mainMenu.addItem(applicationMenuItem)
            NSApp.mainMenu = mainMenu

            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        @objc private func receiveShortcut() {
            statusLabel.stringValue = "Received Cmd-Option-F"
            statusLabel.setAccessibilityLabel("Received Cmd-Option-F")
        }

        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
            true
        }
    }

    let application = NSApplication.shared
    let delegate = ShortcutProbeDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
    """
}
