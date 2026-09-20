import Foundation
import XCTest

/// Exercises Ghostty link activation and the shell wrapper in a running app.
final class TerminalLinkBrowserPlacementUITests: XCTestCase {
    private var application: XCUIApplication?
    private var fixture: URL!
    private var socketPath = ""
    private var launchTag = ""
    private var socketProbeResults: [String: String] = [:]

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-link-placement-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        // The sandboxed XCTest runner can connect to Unix sockets in its own
        // temporary directory. An app-owned /tmp socket is denied with EPERM.
        // Keep the basename short enough for sockaddr_un.sun_path.
        socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("tl-\(UUID().uuidString.prefix(8)).sock").path
        launchTag = "issue-12798-ui-\(UUID().uuidString.prefix(8))"
    }

    override func tearDown() {
        application?.terminate()
        try? FileManager.default.removeItem(at: fixture)
        try? FileManager.default.removeItem(atPath: socketPath)
        super.tearDown()
    }

    func testSplitPlacementCreatesSplit() throws {
        try verifyLinkPlacement("split", expectedPanes: 2)
    }

    func testSamePaneClickAndOpenCommandKeepOnePane() throws {
        try verifyLinkPlacement("samePane", expectedPanes: 1)
    }

    private func verifyLinkPlacement(_ placement: String, expectedPanes: Int) throws {
        let app = XCUIApplication.cmuxTestApplication()
        application = app
        let stateURL = fixture.appendingPathComponent("state.json")
        app.launchArguments += [
            "-socketControlMode", "allowAll",
            "-browserDisabledOverride", "NO",
            "-browserOpenTerminalLinksInCmuxBrowser", "YES",
            "-browserInterceptTerminalOpenCommandInCmuxBrowser", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launchEnvironment["CMUX_TAG"] = launchTag
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = fixture.appendingPathComponent("socket.json").path
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_PATH"] = stateURL.path
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_FIXTURE_DIR"] = fixture.path
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_LINE_FORMAT"] = "url"
        // Do not install the URL-capture sink: the click must create a real browser.
        app.launch()
        XCTAssertTrue(poll { self.readState(stateURL)["ready"] as? String == "1" })
        XCTAssertTrue(waitForControlSocketReady(
            listenerBindTimeout: 30,
            pingTimeout: 10,
            socketFileExists: {
                self.socketCandidates().contains { FileManager.default.fileExists(atPath: $0) }
            },
            pingReturnsPong: {
                for candidate in self.socketCandidates() {
                    guard FileManager.default.fileExists(atPath: candidate) else { continue }
                    let client = ControlSocketUITestClient(path: candidate, responseTimeout: 1)
                    let response = client.sendJSON(["id": "ready", "method": "system.ping", "params": [:]])
                    self.socketProbeResults[candidate] = response.map { String(describing: $0) } ?? client.lastFailure ?? "No reply"
                    if response?["ok"] as? Bool == true {
                        self.socketPath = candidate
                        return true
                    }
                }
                return false
            }
        ), "Probes: \(socketProbeResults). Socket diagnostics: \(readState(fixture.appendingPathComponent("socket.json")))")
        try selectPlacementInSettings(placement, app: app)
        let source = try XCTUnwrap(readState(stateURL)["surfaceId"] as? String)
        let workspace = try XCTUnwrap(rpc("workspace.current")["workspace_id"] as? String)
        let initial = try surfaces(workspace)
        let sourcePane = try XCTUnwrap(initial.first { $0["id"] as? String == source }?["pane_id"] as? String)
        attach(app, name: "\(placement)-before-terminal-link")

        // Without a command channel, the existing fixture stops after seeding
        // the terminal. Drive the real pointer with Command held; no fixture
        // poller can raise the terminal over Settings or steal subsequent focus.
        try clickTerminalLink(app: app, state: readState(stateURL))
        XCTAssertTrue(poll { (try? self.browsers(workspace).count) == 1 }, "Browser tabs: \(String(describing: try? browsers(workspace)))")
        XCTAssertEqual(try panes(workspace).count, expectedPanes)
        let clickedBrowser = try XCTUnwrap(try browsers(workspace).first)
        if placement == "samePane" {
            XCTAssertEqual(clickedBrowser["pane_id"] as? String, sourcePane)
        } else {
            XCTAssertNotEqual(clickedBrowser["pane_id"] as? String, sourcePane)
        }
        attach(app, name: "\(placement)-after-click")

        // Send the intercepted command to the source surface while a different
        // pane owns focus. In same-pane mode the click leaves only one pane, so
        // create a second terminal pane specifically for this origin-routing
        // assertion. A current-focus implementation would incorrectly open in
        // this pane instead of the source terminal's pane.
        let backgroundSurface: String
        if placement == "samePane" {
            let split = try rpc("surface.split", [
                "workspace_id": workspace,
                "surface_id": source,
                "direction": "right",
                "focus": true,
            ])
            backgroundSurface = try XCTUnwrap(split["surface_id"] as? String)
            XCTAssertEqual(try panes(workspace).count, expectedPanes + 1)
        } else {
            backgroundSurface = try XCTUnwrap(clickedBrowser["id"] as? String)
        }
        _ = try rpc("surface.focus", ["workspace_id": workspace, "surface_id": backgroundSurface])
        let expectedCommandPanes = placement == "samePane" ? expectedPanes + 1 : expectedPanes

        let outputPath = fixture.appendingPathComponent("open-output.txt").path
        let shellCommand = "open https://example.com/terminal-placement > '\(outputPath)' 2>&1"
        _ = try rpc("surface.send_text", ["workspace_id": workspace, "surface_id": source, "text": shellCommand])
        _ = try rpc("surface.send_key", ["workspace_id": workspace, "surface_id": source, "key": "enter"])
        XCTAssertTrue(poll { (try? self.browsers(workspace).count) == 2 }, "Browser tabs: \(String(describing: try? browsers(workspace)))")
        XCTAssertEqual(try panes(workspace).count, expectedCommandPanes)
        if placement == "samePane" {
            XCTAssertTrue(try browsers(workspace).allSatisfy { $0["pane_id"] as? String == sourcePane })
        }
        var wrapperOutput = ""
        let wrapperFinished = poll {
            wrapperOutput = (try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? ""
            return wrapperOutput.contains("OK surface=")
        }
        let output = XCTAttachment(string: wrapperOutput)
        output.name = "\(placement)-open-wrapper-output"
        output.lifetime = .keepAlways
        add(output)
        XCTAssertTrue(wrapperFinished, wrapperOutput)
        let openedBrowser = try XCTUnwrap(try browsers(workspace).first {
            $0["id"] as? String != clickedBrowser["id"] as? String
        }?["id"] as? String)
        _ = try rpc("surface.focus", ["workspace_id": workspace, "surface_id": openedBrowser])
        attach(app, name: "\(placement)-after-open-command")

        if placement == "samePane" {
            let explicit = try rpc("surface.split", [
                "workspace_id": workspace, "surface_id": source,
                "type": "browser", "direction": "down", "url": "about:blank", "focus": true,
            ])
            XCTAssertNotEqual(explicit["pane_id"] as? String, sourcePane)
            XCTAssertEqual(try panes(workspace).count, expectedCommandPanes + 1)
            attach(app, name: "samePane-manual-browser-split")
        }
    }

    private func selectPlacementInSettings(_ placement: String, app: XCUIApplication) throws {
        app.activate()
        _ = try rpc("settings.open", ["target": "browser", "activate": true])
        let settings = app.windows["cmux.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        settings.click()
        let search = settings.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeText("browser.terminalLinkBrowserPlacement")
        let result = settings.outlines.firstMatch.staticTexts["Terminal Link Placement"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.click()

        let picker = settings.popUpButtons["SettingsTerminalLinkBrowserPlacementPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.click()
        let title = placement == "samePane" ? "Tab in Same Pane" : "Split Right"
        let option = picker.menuItems[title]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.click()
        XCTAssertTrue(poll { picker.value as? String == title })
        attach(app, name: "\(placement)-settings-picker")
        settings.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(poll { !settings.exists })
    }

    private func clickTerminalLink(app: XCUIApplication, state: [String: Any]) throws {
        let terminal = try XCTUnwrap(state["terminalFrameInWindow"] as? [String: Double])
        let token = try XCTUnwrap(state["tokenHitPointInTerminal"] as? [String: Double])
        let main = app.windows.matching(NSPredicate(format: "identifier BEGINSWITH %@", "cmux.main.")).firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 5))
        let x = try XCTUnwrap(terminal["x"]) + XCTUnwrap(token["x"])
        let y = main.frame.height - (try XCTUnwrap(terminal["y"]) + XCTUnwrap(terminal["height"]))
            + (try XCTUnwrap(token["y"]))
        let target = main.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
        XCUIElement.perform(withKeyModifiers: .command) { target.click() }
    }

    private func rpc(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        let response = try XCTUnwrap(ControlSocketUITestClient(path: socketPath, responseTimeout: 8).sendJSON(
            ["id": UUID().uuidString, "method": method, "params": params]
        ), "No response for \(method). Diagnostics: \(readState(fixture.appendingPathComponent("socket.json")))")
        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        return try XCTUnwrap(response["result"] as? [String: Any])
    }

    private func surfaces(_ workspace: String) throws -> [[String: Any]] {
        try XCTUnwrap(rpc("surface.list", ["workspace_id": workspace])["surfaces"] as? [[String: Any]])
    }

    private func browsers(_ workspace: String) throws -> [[String: Any]] {
        // Browser placement needs the live browser inventory after a UI action;
        // surface.list may return a previously published control-plane snapshot.
        try XCTUnwrap(rpc("browser.tab.list", ["workspace_id": workspace])["tabs"] as? [[String: Any]])
    }

    private func panes(_ workspace: String) throws -> [[String: Any]] {
        try XCTUnwrap(rpc("pane.list", ["workspace_id": workspace])["panes"] as? [[String: Any]])
    }

    private func socketCandidates() -> [String] {
        let slug = launchTag
            .lowercased()
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        var candidates = [socketPath, "/tmp/cmux-debug-\(slug).sock"]
        let diagnosticsURL = fixture.appendingPathComponent("socket.json")
        if let expected = readState(diagnosticsURL)["socketExpectedPath"] as? String,
           !expected.isEmpty {
            candidates.append(expected)
        }
        return Array(Set(candidates))
    }

    private func readState(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }

    private func poll(timeout: TimeInterval = 30, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
