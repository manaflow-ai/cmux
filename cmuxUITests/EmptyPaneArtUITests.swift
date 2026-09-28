import XCTest

/// With `emptyPane.artFile` set, a pane left empty by closing its last tab
/// shows the user's art above the Terminal and Browser buttons.
///
/// The settings come in through the launch-argument defaults domain, the same
/// defaults keys cmux.json writes: the art file, and keeping the workspace open
/// when the tab-strip close button closes its last tab (otherwise the window
/// closes instead of leaving an empty pane). The art mixes a lolcat-style
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
            "-warnBeforeClosingTabXButton", "NO",
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
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        // The selected tab sits in the pane's tab strip right above the
        // terminal; its close button is the trailing 16 pt accessory inside
        // 6 pt of padding (Bonsplit TabBarMetrics).
        let terminalFrame = terminal.frame
        let tab = try XCTUnwrap(
            app.buttons.allElementsBoundByIndex.first { element in
                let frame = element.frame
                return frame.height >= 20 && frame.height <= 40
                    && abs(frame.maxY - terminalFrame.minY) <= 20
                    && frame.minX >= terminalFrame.minX - 4
                    && frame.minX < terminalFrame.midX
            },
            "Expected the terminal's tab above \(terminalFrame)"
        )
        tab.hover()
        tab.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: tab.frame.width - 14, dy: 0))
            .click()

        let art = app.descendants(matching: .any)["EmptyPanelArt"]
        let appeared = art.waitForExistence(timeout: 15)
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = appeared ? "empty pane with art" : "after closing the last tab"
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
