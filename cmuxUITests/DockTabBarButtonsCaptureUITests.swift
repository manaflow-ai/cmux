import XCTest

/// Capture-only evidence for cmux#27843: the window Dock's tab bar with
/// `ui.surfaceTabBar.buttons = []` and with the default buttons. It asserts
/// nothing about the buttons; it keeps a window screenshot, a Dock-cropped
/// screenshot and the Dock's tab-bar control identifiers as attachments, which
/// test-e2e.yml uploads in the `test-results` xcresult and the `ui-frames`
/// artifact.
final class DockTabBarButtonsCaptureUITests: XCTestCase {
    private var scratch: URL!

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ui-test-dock-buttons-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    func testCaptureDockTabBarWithEmptyButtons() throws {
        try capture(cmuxJSON: #"{"ui":{"surfaceTabBar":{"buttons":[]}}}"#, label: "buttons-empty")
    }

    func testCaptureDockTabBarWithDefaultButtons() throws {
        try capture(cmuxJSON: nil, label: "buttons-default")
    }

    private func capture(cmuxJSON: String?, label: String) throws {
        let fileManager = FileManager.default
        let home = scratch.appendingPathComponent("home", isDirectory: true)
        let configDir = home.appendingPathComponent(".config/cmux", isDirectory: true)
        try fileManager.createDirectory(at: configDir, withIntermediateDirectories: true)
        if let cmuxJSON {
            try Data(cmuxJSON.utf8).write(to: configDir.appendingPathComponent("cmux.json"), options: .atomic)
        }
        let dockConfig = scratch.appendingPathComponent("dock.json")
        let dockJSON = #"{"controls":[{"id":"capture","title":"Capture","command":"printf 'dock capture\\n'; exec sleep 600"}]}"#
        try Data(dockJSON.utf8).write(to: dockConfig, options: .atomic)

        let app = XCUIApplication.cmuxTestApplication()
        app.launchArguments += ["-NSAppSleepDisabled", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["HOME"] = home.path
        app.launchEnvironment["CFFIXED_USER_HOME"] = home.path
        app.launchEnvironment["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config", isDirectory: true).path
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_DOCK_CONFIG_PATH"] = dockConfig.path
        app.launchEnvironment["CMUX_SOCKET_PATH"] = "/tmp/cmux-dock-buttons-\(UUID().uuidString.prefix(8)).sock"
        app.launchEnvironment["CMUX_TAG"] = "ui-tests-dock-buttons-\(UUID().uuidString.prefix(8))"
        if let path = ProcessInfo.processInfo.environment["PATH"], !path.isEmpty {
            app.launchEnvironment["PATH"] = path
        }
        app.launch()
        if app.state != .runningForeground { app.activate() }
        _ = app.wait(for: .runningForeground, timeout: 15)

        let dockPanel = app.descendants(matching: .any)["DockPanel"].firstMatch
        let dockButton = app.buttons["RightSidebarModeButton.dock"].firstMatch
        if !dockPanel.waitForExistence(timeout: 3) {
            if !dockButton.waitForExistence(timeout: 5) {
                app.typeKey("e", modifierFlags: [.command, .shift])
            }
            if dockButton.waitForExistence(timeout: 5) {
                dockButton.click()
            } else {
                app.typeKey("5", modifierFlags: [.control])
            }
        }
        let dockShown = dockPanel.waitForExistence(timeout: 10)
        // Let the Dock's terminal mount and the tab bar settle.
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))

        keep(app.windows.firstMatch.screenshot(), name: "\(label)-window")
        if dockShown {
            keep(dockPanel.screenshot(), name: "\(label)-dock")
            let controls = dockPanel.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "paneTabBarControl."))
                .allElementsBoundByIndex
                .map { "\($0.identifier) frame=\($0.frame)" }
            keepText("controls=\(controls.count)\n" + controls.joined(separator: "\n"), name: "\(label)-dock-controls")
        } else {
            keepText(app.debugDescription, name: "\(label)-tree")
            XCTFail("Dock did not open; kept the window screenshot and tree")
        }
        app.terminate()
    }

    private func keep(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func keepText(_ text: String, name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
