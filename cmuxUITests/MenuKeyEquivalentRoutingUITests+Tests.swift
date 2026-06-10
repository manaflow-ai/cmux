import XCTest
import Foundation
import CoreGraphics
import ImageIO
import Darwin


// MARK: - Routing tests & harness
extension MenuKeyEquivalentRoutingUITests {
    func testCmdNWorksWhenWebViewFocusedAfterTabSwitch() {
        let app = launchWithBrowserSetup()

        // Simulate the repro: switch away and back.
        app.typeKey("[", modifierFlags: [.command, .shift])
        app.typeKey("]", modifierFlags: [.command, .shift])

        // Force WebKit to become first responder again (Cmd+L then Escape).
        refocusWebView(app: app)

        let baseline = loadKeyequiv()["addTabInvocations"].flatMap(Int.init) ?? 0
        app.typeKey("n", modifierFlags: [.command])

        XCTAssertTrue(
            waitForKeyequivInt(key: "addTabInvocations", toBeAtLeast: baseline + 1, timeout: 5.0),
            "Expected Cmd+N to reach app menu and create a new tab even when WKWebView is first responder"
        )
    }

    func testCmdNWorksWhenBrowserAddressBarFocused() {
        let app = launchWithBrowserSetup()

        app.typeKey("l", modifierFlags: [.command])

        let omnibar = app.textFields["BrowserOmnibarTextField"].firstMatch
        XCTAssertTrue(omnibar.waitForExistence(timeout: 6.0), "Expected browser omnibar after Cmd+L")

        let marker = "cmdn-\(UUID().uuidString.prefix(8))"
        app.typeText(marker)
        XCTAssertTrue(
            waitForCondition(timeout: 5.0) {
                ((omnibar.value as? String) ?? "").contains(marker)
            },
            "Expected Cmd+L to focus browser omnibar before Cmd+N. value=\(String(describing: omnibar.value))"
        )

        let baseline = loadKeyequiv()["addTabInvocations"].flatMap(Int.init) ?? 0
        app.typeKey("n", modifierFlags: [.command])

        XCTAssertTrue(
            waitForKeyequivInt(key: "addTabInvocations", toBeAtLeast: baseline + 1, timeout: 5.0),
            "Expected Cmd+N to reach app menu and create a new tab even when browser omnibar is first responder"
        )
    }

    func testCmdWWorksWhenWebViewFocusedAfterTabSwitch() {
        let app = launchWithBrowserSetup()

        // Simulate the repro: switch away and back.
        app.typeKey("[", modifierFlags: [.command, .shift])
        app.typeKey("]", modifierFlags: [.command, .shift])

        // Force WebKit to become first responder again (Cmd+L then Escape).
        refocusWebView(app: app)

        let baseline = loadKeyequiv()["closePanelInvocations"].flatMap(Int.init) ?? 0
        app.typeKey("w", modifierFlags: [.command])

        XCTAssertTrue(
            waitForKeyequivInt(key: "closePanelInvocations", toBeAtLeast: baseline + 1, timeout: 5.0),
            "Expected Cmd+W to reach app menu and close the focused tab even when WKWebView is first responder"
        )
    }

    func testCmdShiftWWorksWhenWebViewFocusedAfterTabSwitch() {
        let app = launchWithBrowserSetup()

        // Simulate the repro: switch away and back.
        app.typeKey("[", modifierFlags: [.command, .shift])
        app.typeKey("]", modifierFlags: [.command, .shift])

        // Force WebKit to become first responder again (Cmd+L then Escape).
        refocusWebView(app: app)

        let baseline = loadKeyequiv()["closeTabInvocations"].flatMap(Int.init) ?? 0
        app.typeKey("w", modifierFlags: [.command, .shift])

        XCTAssertTrue(
            waitForKeyequivInt(key: "closeTabInvocations", toBeAtLeast: baseline + 1, timeout: 6.0),
            "Expected Cmd+Shift+W to reach app menu and close the current workspace even when WKWebView is first responder"
        )
    }

    func testCmdFOpensRightSidebarFindInsteadOfWebContentFindShortcut() {
        let app = launchWithBrowserSetup(browserURL: makeBrowserHandledCmdFPageURL())

        XCTAssertTrue(
            waitForGotoSplitMatch(timeout: 10.0) { data in
                data["browserPageTitle"] == "cmdf-pending"
            },
            "Expected the browser test page to finish loading before Cmd+F"
        )

        app.typeKey("f", modifierFlags: [.command])

        let findField = app.textFields["FileExplorerSearchField"].firstMatch
        XCTAssertTrue(findField.waitForExistence(timeout: 6.0), "Expected right sidebar file search after Cmd+F")

        app.typeText("needle")
        XCTAssertTrue(
            waitForCondition(timeout: 4.0) {
                ((findField.value as? String) ?? "") == "needle"
            },
            "Expected Cmd+F to focus right sidebar file search. value=\(String(describing: findField.value))"
        )
        XCTAssertNotEqual(
            loadGotoSplit()?["browserPageTitle"],
            "cmdf-handled",
            "Expected Cmd+F to stay out of browser page content. data=\(loadGotoSplit() ?? [:])"
        )
    }

    func testBrowserFirstFindShortcutDoesNotReplayUnclaimedCmdEIntoWebContentTwice() {
        let app = launchWithBrowserSetup(browserURL: makeBrowserObservedCmdEPageURL())

        XCTAssertTrue(
            waitForGotoSplitMatch(timeout: 10.0) { data in
                data["browserPageTitle"] == "cmde-0"
            },
            "Expected the Cmd+E test page to finish loading before the shortcut. data=\(loadGotoSplit() ?? [:])"
        )

        app.typeKey("e", modifierFlags: [.command])

        XCTAssertTrue(
            waitForGotoSplitMatch(timeout: 5.0) { data in
                data["browserPageTitle"] == "cmde-1"
            },
            "Expected Cmd+E to reach browser content exactly once. data=\(loadGotoSplit() ?? [:])"
        )

        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(
            loadGotoSplit()?["browserPageTitle"],
            "cmde-1",
            "Expected Cmd+E to avoid a second WebKit replay. data=\(loadGotoSplit() ?? [:])"
        )
    }

    func testBrowserLocalFindShortcutsStillReachWebContentWhenBrowserFindBarIsHidden() {
        let app = launchWithBrowserSetup(browserURL: makeVisibleBrowserFindOwnershipPageURL())

        XCTAssertTrue(
            waitForGotoSplitMatch(timeout: 10.0) { data in
                data["browserPageTitle"] == "find-owner-idle"
            },
            "Expected the browser find ownership page to finish loading before opening find. data=\(loadGotoSplit() ?? [:])"
        )

        guard let browserPanelId = loadGotoSplit()?["browserPanelId"], !browserPanelId.isEmpty else {
            XCTFail("Missing browserPanelId in goto_split setup data")
            return
        }

        clickBrowserPane(app: app, browserPanelId: browserPanelId)

        app.typeKey("g", modifierFlags: [.command])
        XCTAssertTrue(
            waitForGotoSplitMatch(timeout: 6.0) { data in
                data["browserPageTitle"] == "page-handled-cmdg" &&
                    data["browserFindVisible"] == "false"
            },
            "Expected Cmd+G to stay browser-local when browser find is hidden. data=\(loadGotoSplit() ?? [:])"
        )

        clickBrowserPane(app: app, browserPanelId: browserPanelId)

        app.typeKey("f", modifierFlags: [.command, .shift])
        XCTAssertTrue(
            waitForGotoSplitMatch(timeout: 6.0) { data in
                data["browserPageTitle"] == "page-handled-cmdshiftf" &&
                    data["browserFindVisible"] == "false"
            },
            "Expected Cmd+Shift+F to stay browser-local when browser find is hidden. data=\(loadGotoSplit() ?? [:])"
        )
    }

    func testBrowserFocusModeRoutesPageShortcutsAndDoubleEscapeExits() {
        let app = launchWithBrowserSetup(browserURL: makeBrowserFocusModePageURL())

        XCTAssertTrue(
            waitForGotoSplitMatch(timeout: 10.0) { data in
                data["browserPageTitle"] == "focus-ready"
            },
            "Expected the focus-mode test page to finish loading. data=\(loadGotoSplit() ?? [:])"
        )

        let focusModeButton = app.buttons["BrowserFocusModeButton"].firstMatch
        XCTAssertTrue(
            focusModeButton.waitForExistence(timeout: 5.0),
            "Expected browser focus-mode toolbar button to exist"
        )
        focusModeButton.click()

        XCTAssertTrue(
            waitForGotoSplitMatch(timeout: 5.0) { data in
                data["browserFocusModeActive"] == "true"
            },
            "Expected toolbar button to enter browser focus mode. data=\(loadGotoSplit() ?? [:])"
        )

        app.typeKey("f", modifierFlags: [.command])
        XCTAssertTrue(
            waitForGotoSplitMatch(timeout: 5.0) { data in
                data["browserPageTitle"] == "focus-cmdf-1"
            },
            "Expected Cmd+F to reach the page while focus mode is active. data=\(loadGotoSplit() ?? [:])"
        )

        app.typeKey("p", modifierFlags: [.command])
        XCTAssertTrue(
            waitForGotoSplitMatch(timeout: 5.0) { data in
                data["browserPageTitle"] == "focus-cmdp-1"
            },
            "Expected Cmd+P to reach the page while focus mode is active. data=\(loadGotoSplit() ?? [:])"
        )

        app.typeKey("s", modifierFlags: [.command])
        XCTAssertTrue(
            waitForGotoSplitMatch(timeout: 5.0) { data in
                data["browserPageTitle"] == "focus-cmds-1"
            },
            "Expected Cmd+S to reach the page while focus mode is active. data=\(loadGotoSplit() ?? [:])"
        )

        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(
            waitForGotoSplitMatch(timeout: 5.0) { data in
                data["browserPageTitle"] == "focus-escape-1" &&
                    data["browserFocusModeActive"] == "true" &&
                    data["browserFocusModeExitArmed"] == "true"
            },
            "Expected first Escape to reach the page and arm focus-mode exit. data=\(loadGotoSplit() ?? [:])"
        )

        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(
            waitForGotoSplitMatch(timeout: 5.0) { data in
                data["browserPageTitle"] == "focus-escape-1" &&
                    data["browserFocusModeActive"] == "false" &&
                    data["browserFocusModeExitArmed"] == "false"
            },
            "Expected second Escape to exit focus mode without reaching the page. data=\(loadGotoSplit() ?? [:])"
        )

        let baselineAddTabInvocations = loadKeyequiv()["addTabInvocations"].flatMap(Int.init) ?? 0
        app.typeKey("n", modifierFlags: [.command])
        XCTAssertTrue(
            waitForKeyequivInt(key: "addTabInvocations", toBeAtLeast: baselineAddTabInvocations + 1, timeout: 5.0),
            "Expected Cmd+N to resume normal cmux routing after focus mode exit. data=\(loadKeyequiv())"
        )
    }

    private func launchWithBrowserSetup(browserURL: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = gotoSplitPath
        app.launchEnvironment["CMUX_UI_TEST_KEYEQUIV_PATH"] = keyequivPath
        if let browserURL {
            app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_BROWSER_URL"] = browserURL
        }
        launchAndEnsureForeground(app)

        XCTAssertTrue(
            waitForGotoSplit(keys: ["browserPanelId", "webViewFocused"], timeout: 25.0),
            "Expected goto_split setup data to be written. data=\(loadGotoSplit() ?? [:])"
        )

        if let setup = loadGotoSplit() {
            XCTAssertEqual(setup["webViewFocused"], "true", "Expected WKWebView to be first responder for this test setup")
        }

        return app
    }

    private func launchAndEnsureForeground(_ app: XCUIApplication) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }

        if app.state == .runningForeground { return }

        // launch() can leave the app backgrounded on some runners. Bring it to
        // the foreground so subsequent typeKey() input is routed to cmux and not
        // the wrong target; tolerate runners where activation genuinely can't win.
        if app.state == .runningBackground {
            app.activate()
            if app.state == .runningForeground { return }
            XCTExpectFailure("App could not be foregrounded on this runner", options: options) {
                XCTFail("cmux stayed backgrounded after activate(); key input may not reach it. state=\(app.state.rawValue)")
            }
            return
        }

        XCTFail("App failed to start. state=\(app.state.rawValue)")
    }

    private func makeBrowserHandledCmdFPageURL() -> String {
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <title>cmdf-pending</title>
        </head>
        <body tabindex="-1">
          <main>Browser find shortcut passthrough</main>
          <script>
            window.addEventListener('load', () => {
              document.body.focus();
            });
            window.addEventListener('keydown', (event) => {
              const key = String(event.key || '').toLowerCase();
              if (event.metaKey && !event.shiftKey && !event.altKey && !event.ctrlKey && key === 'f') {
                event.preventDefault();
                document.title = 'cmdf-handled';
                document.body.dataset.cmdf = 'handled';
              }
            }, true);
          </script>
        </body>
        </html>
        """
        return makeDataURL(html)
    }

    private func makeBrowserObservedCmdEPageURL() -> String {
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <title>cmde-0</title>
        </head>
        <body tabindex="-1">
          <main>Cmd+E should only reach the page once</main>
          <script>
            window.addEventListener('load', () => {
              document.body.focus();
            });
            let countState = { value: 0 };
            window.addEventListener('keydown', (event) => {
              const key = String(event.key || '').toLowerCase();
              if (event.metaKey && !event.shiftKey && !event.altKey && !event.ctrlKey && key === 'e') {
                countState.value += 1;
                document.title = `cmde-${countState.value}`;
                document.body.dataset.cmdeCount = String(countState.value);
              }
            }, true);
          </script>
        </body>
        </html>
        """
        return makeDataURL(html)
    }

    private func makeVisibleBrowserFindOwnershipPageURL() -> String {
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <title>find-owner-idle</title>
        </head>
        <body tabindex="-1">
          <main>needle alpha</main>
          <main>needle beta</main>
          <main>needle gamma</main>
          <script>
            window.addEventListener('load', () => {
              document.body.focus();
            });
            window.addEventListener('keydown', (event) => {
              const key = String(event.key || '').toLowerCase();
              if (event.metaKey && !event.altKey && !event.ctrlKey && !event.shiftKey && key === 'g') {
                event.preventDefault();
                event.stopImmediatePropagation();
                document.title = 'page-handled-cmdg';
                return;
              }
              if (event.metaKey && event.shiftKey && !event.altKey && !event.ctrlKey && key === 'f') {
                event.preventDefault();
                event.stopImmediatePropagation();
                document.title = 'page-handled-cmdshiftf';
              }
            }, true);
          </script>
        </body>
        </html>
        """
        return makeDataURL(html)
    }

    private func makeBrowserFocusModePageURL() -> String {
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <title>focus-loading</title>
        </head>
        <body tabindex="-1">
          <main>Browser focus mode shortcut passthrough</main>
          <script>
            const counts = { f: 0, p: 0, s: 0, escape: 0 };
            window.addEventListener('load', () => {
              document.body.focus();
              document.title = 'focus-ready';
            });
            window.addEventListener('keydown', (event) => {
              const key = String(event.key || '').toLowerCase();
              const plainCommand = event.metaKey && !event.shiftKey && !event.altKey && !event.ctrlKey;
              if (plainCommand && (key === 'f' || key === 'p' || key === 's')) {
                event.preventDefault();
                event.stopImmediatePropagation();
                counts[key] += 1;
                document.title = `focus-cmd${key}-${counts[key]}`;
                return;
              }
              if (!event.metaKey && !event.shiftKey && !event.altKey && !event.ctrlKey && key === 'escape') {
                event.preventDefault();
                event.stopImmediatePropagation();
                counts.escape += 1;
                document.title = `focus-escape-${counts.escape}`;
              }
            }, true);
          </script>
        </body>
        </html>
        """
        return makeDataURL(html)
    }

    private func makeDataURL(_ html: String) -> String {
        let encoded = Data(html.utf8).base64EncodedString()
        return "data:text/html;base64,\(encoded)"
    }

    private func clickBrowserPane(app: XCUIApplication, browserPanelId: String) {
        let browserPane = app.otherElements["BrowserPanelContent.\(browserPanelId)"].firstMatch
        XCTAssertTrue(browserPane.waitForExistence(timeout: 6.0), "Expected browser pane content for click target")
        browserPane.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    }

    private func refocusWebView(app: XCUIApplication) {
        // Cmd+L focuses the omnibar (so WebKit is no longer first responder).
        app.typeKey("l", modifierFlags: [.command])
        XCTAssertTrue(
            waitForGotoSplitMatch(timeout: 5.0) { data in
                data["webViewFocusedAfterAddressBarFocus"] == "false"
            },
            "Expected Cmd+L to focus omnibar (WebKit not first responder)"
        )

        // Escape should leave the omnibar and focus WebKit again.
        // Send Escape twice: the first may only clear suggestions/editing state
        // (Chrome-like two-stage escape), the second triggers blur to WebView.
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        if !waitForGotoSplitMatch(timeout: 2.0, predicate: { $0["webViewFocusedAfterAddressBarExit"] == "true" }) {
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        }
        XCTAssertTrue(
            waitForGotoSplitMatch(timeout: 5.0) { data in
                data["webViewFocusedAfterAddressBarExit"] == "true"
            },
            "Expected Escape to return focus to WebKit"
        )
    }

    private func waitForGotoSplit(keys: [String], timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            guard let data = self.loadGotoSplit() else { return false }
            return keys.allSatisfy { data[$0] != nil }
        }
    }

    private func waitForGotoSplitMatch(timeout: TimeInterval, predicate: @escaping ([String: String]) -> Bool) -> Bool {
        waitForCondition(timeout: timeout) {
            guard let data = self.loadGotoSplit() else { return false }
            return predicate(data)
        }
    }

    private func waitForKeyequivInt(key: String, toBeAtLeast expected: Int, timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            let value = self.loadKeyequiv()[key].flatMap(Int.init) ?? 0
            return value >= expected
        }
    }

    private func loadGotoSplit() -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: gotoSplitPath)) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }

    private func loadKeyequiv() -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: keyequivPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }
}
