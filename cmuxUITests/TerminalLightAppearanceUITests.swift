import AppKit
import XCTest

/// Exercises the real Settings -> Ghostty reload -> existing terminal rendering path (#12797).
final class TerminalLightAppearanceUITests: SettingsUITestCase {
    func testLightModeRecolorsExistingWorkspaceWithFontOnlyConfig() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-light-appearance-\(UUID().uuidString)")
        let configDirectory = home.appendingPathComponent(".config/ghostty")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try "font-size = 17\n".write(
            to: configDirectory.appendingPathComponent("config.ghostty"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let app = XCUIApplication.cmuxTestApplication()
        app.launchArguments += settingsLaunchArguments
        app.launchEnvironment["CFFIXED_USER_HOME"] = home.path
        app.launchEnvironment["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config").path
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = "ui-tests-light-\(UUID().uuidString.prefix(8))"
        launchAndActivate(app)
        defer { app.terminate() }

        let terminal = app.textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 15), "The workspace must contain a live terminal")

        selectAppearance("Dark", app: app)
        XCTAssertTrue(waitForBackground(terminal, isLight: false), "Baseline terminal must render dark")
        attachDesktop("Existing workspace in Dark mode")

        selectAppearance("Light", app: app)
        let changed = waitForBackground(terminal, isLight: true)
        attachDesktop("Same workspace after selecting Light")
        XCTAssertTrue(changed, "Selecting Light must recolor the existing terminal despite its font setting")

    }

    private func selectAppearance(_ name: String, app: XCUIApplication) {
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["cmux.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        let appSection = settings.outlines.staticTexts["App"].firstMatch
        XCTAssertTrue(appSection.waitForExistence(timeout: 5))
        appSection.click()
        let choice = settings.buttons[name].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.click()
        settings.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(poll(timeout: 5) { !settings.exists })
    }

    private func waitForBackground(_ terminal: XCUIElement, isLight: Bool) -> Bool {
        poll(timeout: 10, interval: 0.2) {
            guard terminal.exists,
                  terminal.frame.width > 100, terminal.frame.height > 100,
                  let bitmap = NSBitmapImageRep(data: terminal.screenshot().pngRepresentation) else {
                return false
            }
            // Sample empty interior cells, away from the prompt, cursor, edges, and scrollbar.
            let xs = [0.4, 0.5, 0.6]
            let ys = [0.4, 0.5, 0.6]
            return xs.allSatisfy { x in
                ys.allSatisfy { y in
                    guard let color = bitmap.colorAt(
                        x: Int(Double(bitmap.pixelsWide) * x),
                        y: Int(Double(bitmap.pixelsHigh) * y)
                    )?.usingColorSpace(.sRGB) else { return false }
                    let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                    return isLight ? brightness > 0.85 : brightness < 0.25
                }
            }
        }
    }

    private func attachDesktop(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
