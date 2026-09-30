import XCTest

/// With `emptyPane.artFile` set, a pane left empty when its last terminal exits
/// shows the user's art above the Terminal and Browser buttons.
///
/// The settings come in through the launch-argument defaults domain, the same
/// defaults keys cmux.json writes: the art file, and keeping the workspace open
/// when its last surface closes (otherwise the workspace closes instead of
/// leaving an empty pane). The art mixes a lolcat-style
/// truecolor banner, 16-color text and chafa-style half blocks so the
/// screenshot shows each.
final class EmptyPaneArtUITests: SettingsUITestCase {
    func testEmptyPaneShowsConfiguredArt() throws {
        let artURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-empty-pane-art-\(UUID().uuidString).ans")
        try Self.sampleArt.write(to: artURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: artURL) }

        let app = XCUIApplication.cmuxTestApplication()
        app.launchArguments += settingsLaunchArguments + [
            "-emptyPaneArtFile", artURL.path,
            "-closeWorkspaceOnLastSurfaceShortcut", "NO",
        ]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = "ui-empty-pane-art-\(UUID().uuidString.prefix(8))"
        launchAndActivate(app)
        defer { app.terminate() }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "Expected the main window")
        let terminal = app.textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 15), "Expected the launch terminal")
        XCTAssertTrue(poll(timeout: 10) { terminal.frame.height > 100 }, "Expected a laid-out terminal")

        // Exit the launch shell. A surface that closes on its own (not an
        // explicit Close) leaves an empty pane when the workspace is kept
        // open on its last surface; the Close shortcut would close the
        // workspace instead.
        let shellReadyPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-empty-pane-art-shell-ready-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: shellReadyPath) }
        terminal.click()
        app.typeText("printf '__CMUX_EMPTY_PANE_ART_READY__\\n'; touch \(shellReadyPath)\n")
        XCTAssertTrue(
            poll(timeout: 15) { FileManager.default.fileExists(atPath: shellReadyPath) },
            "Expected the launch shell to accept input"
        )
        app.typeText("exit\n")

        let art = app.descendants(matching: .any)["EmptyPanelArt"]
        let appeared = art.waitForExistence(timeout: 15)
        let screenshot = XCTAttachment(screenshot: window.exists ? window.screenshot() : XCUIScreen.main.screenshot())
        screenshot.name = appeared ? "empty pane with art" : "after exiting the last shell"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertTrue(appeared, "Expected the configured art in the empty pane")
        XCTAssertTrue(app.buttons["Terminal"].exists || app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Terminal")
        ).firstMatch.exists, "Expected the Terminal button to stay")
    }

    private static var sampleArt: String {
        let esc = "\u{1B}"
        let banner = [
            "  _________ ___  __  ___  __",
            " / ___/ __ `__ \\/ / / / |/_/",
            "/ /__/ / / / / / /_/ />  <  ",
            "\\___/_/ /_/ /_/\\__,_/_/|_|  ",
        ]
        var out = ""
        for (row, line) in banner.enumerated() {
            for (column, character) in line.enumerated() {
                let phase = Double(row * 3 + column) * 0.12
                let r = Int(sin(phase) * 127 + 128)
                let g = Int(sin(phase + 2 * .pi / 3) * 127 + 128)
                let b = Int(sin(phase + 4 * .pi / 3) * 127 + 128)
                out += "\(esc)[38;2;\(r);\(g);\(b)m\(character)"
            }
            out += "\(esc)[0m\n"
        }
        out += "\n\(esc)[1;91mred \(esc)[93myellow \(esc)[92mgreen \(esc)[96mcyan\(esc)[0m \(esc)[2mdim\(esc)[0m\n\n"
        for row in 0..<6 {
            for column in 0..<28 {
                let top = (column * 9, 80 + row * 20, 255 - column * 9)
                let bottom = (column * 9, 90 + row * 20, 245 - column * 9)
                out += "\(esc)[38;2;\(top.0);\(top.1);\(top.2);48;2;\(bottom.0);\(bottom.1);\(bottom.2)m▀"
            }
            out += "\(esc)[0m\n"
        }
        return out
    }
}
