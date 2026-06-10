import XCTest
import Foundation


// MARK: - Find field focus persistence across pane switches and workspace round trips
extension BrowserPaneNavigationKeybindUITests {
    func testCmdOptionPaneSwitchPreservesFindFieldFocus() {
        runFindFocusPersistenceScenario(route: .cmdOptionArrows, useAutofocusRacePage: false)
    }

    func testCmdCtrlPaneSwitchPreservesFindFieldFocus() {
        runFindFocusPersistenceScenario(route: .cmdCtrlLetters, useAutofocusRacePage: false)
    }

    func testCmdOptionPaneSwitchPreservesFindFieldFocusDuringPageAutofocusRace() {
        runFindFocusPersistenceScenario(route: .cmdOptionArrows, useAutofocusRacePage: true)
    }

    func testCmdFOpensBrowserFindAfterCmdDCmdLNavigation() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_RECORD_ONLY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        launchAndEnsureForeground(app)
        XCTAssertTrue(waitForSocketPong(timeout: 12.0), "Expected control socket at \(socketPath)")

        app.typeKey("d", modifierFlags: [.command])
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                guard data["lastSplitDirection"] == "right" else { return false }
                guard let paneCountAfterSplit = Int(data["paneCountAfterSplit"] ?? "") else { return false }
                return paneCountAfterSplit >= 2
            },
            "Expected Cmd+D to create a split before opening the browser. data=\(String(describing: loadData()))"
        )

        app.typeKey("l", modifierFlags: [.command])

        let omnibar = app.textFields["BrowserOmnibarTextField"].firstMatch
        XCTAssertTrue(omnibar.waitForExistence(timeout: 8.0), "Expected browser omnibar after Cmd+L")

        app.typeKey("a", modifierFlags: [.command])
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        app.typeText("example.com")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        XCTAssertTrue(
            waitForOmnibarToContainExampleDomain(omnibar, timeout: 8.0),
            "Expected browser navigation to example domain before opening find. value=\(String(describing: omnibar.value))"
        )

        app.typeKey("f", modifierFlags: [.command])

        let browserFindField = app.textFields["BrowserFindSearchTextField"].firstMatch
        XCTAssertTrue(browserFindField.waitForExistence(timeout: 6.0), "Expected browser find field after Cmd+F")

        let omnibarValueBeforeFindTyping = (omnibar.value as? String) ?? ""
        app.typeText("needle")

        XCTAssertTrue(
            waitForCondition(timeout: 4.0) {
                ((browserFindField.value as? String) ?? "") == "needle"
            },
            "Expected Cmd+F to focus browser find after Cmd+D, Cmd+L, and navigation. " +
                "findValue=\(String(describing: browserFindField.value)) omnibarValue=\(String(describing: omnibar.value))"
        )
        let omnibarValueAfterFindTyping = (omnibar.value as? String) ?? ""
        XCTAssertFalse(
            omnibarValueAfterFindTyping.contains("needle"),
            "Expected typing after Cmd+F to stay out of the omnibar. " +
                "omnibarValueBefore=\(omnibarValueBeforeFindTyping) " +
                "omnibarValueAfter=\(String(describing: omnibar.value)) " +
                "findValue=\(String(describing: browserFindField.value))"
        )

        XCTAssertFalse(
            app.textFields["FileExplorerSearchField"].firstMatch.exists,
            "Expected browser Cmd+F to use browser find rather than right-sidebar Find"
        )
    }

    func testRightSidebarFindFieldKeepsFocusAfterNewWorkspaceRoundTrip() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_RECORD_ONLY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        launchAndEnsureForeground(app)
        XCTAssertTrue(waitForSocketPong(timeout: 12.0), "Expected control socket at \(socketPath)")

        guard let originalWorkspace = currentWorkspaceContext() else {
            XCTFail("Expected current workspace context before leaving the original workspace")
            return
        }

        app.typeKey("d", modifierFlags: [.command])
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                guard data["lastSplitDirection"] == "right" else { return false }
                guard let paneCountAfterSplit = Int(data["paneCountAfterSplit"] ?? "") else { return false }
                return paneCountAfterSplit >= 2
            },
            "Expected Cmd+D to create a split before opening the browser. data=\(String(describing: loadData()))"
        )

        app.typeKey("l", modifierFlags: [.command])

        let omnibar = app.textFields["BrowserOmnibarTextField"].firstMatch
        XCTAssertTrue(omnibar.waitForExistence(timeout: 8.0), "Expected browser omnibar after Cmd+L")

        app.typeKey("a", modifierFlags: [.command])
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        app.typeText("example.com")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        XCTAssertTrue(
            waitForOmnibarToContainExampleDomain(omnibar, timeout: 8.0),
            "Expected browser navigation to example domain before opening find. value=\(String(describing: omnibar.value))"
        )

        app.typeKey("f", modifierFlags: [.command])

        let findField = app.textFields["FileExplorerSearchField"].firstMatch
        XCTAssertTrue(findField.waitForExistence(timeout: 6.0), "Expected right sidebar file search after Cmd+F")

        app.typeText("seed")
        XCTAssertTrue(
            waitForCondition(timeout: 4.0) {
                ((findField.value as? String) ?? "") == "seed"
            },
            "Expected right sidebar file search to capture initial typing. value=\(String(describing: findField.value))"
        )

        openCommandPaletteForNewWorkspace(app, windowId: originalWorkspace.windowId)
        XCTAssertTrue(
            selectWorkspace(originalWorkspace.workspaceId),
            "Expected to return to the original workspace by identity"
        )

        let restoredFindField = app.textFields["FileExplorerSearchField"].firstMatch
        XCTAssertTrue(restoredFindField.waitForExistence(timeout: 6.0), "Expected right sidebar file search after returning to workspace 1")
        XCTAssertTrue(
            waitForCondition(timeout: 4.0) {
                ((restoredFindField.value as? String) ?? "") == "seed"
            },
            "Expected existing file search query to persist after returning. value=\(String(describing: restoredFindField.value))"
        )

        app.typeText("x")
        XCTAssertTrue(
            waitForCondition(timeout: 4.0) {
                ((restoredFindField.value as? String) ?? "") == "seedx"
            },
            "Expected typing after returning from a new workspace to stay in right sidebar file search. " +
                "findValue=\(String(describing: restoredFindField.value)) omnibarValue=\(String(describing: omnibar.value))"
        )
    }

    func testWorkspaceRoundTripPreservesFocusedTerminalFindWhenBrowserFindIsAlsoOpen() {
        runSplitFindWorkspaceRoundTripScenario(restoredOwner: .terminal)
    }

    func testWorkspaceRoundTripPreservesFocusedBrowserFindWhenTerminalFindIsAlsoOpen() {
        runSplitFindWorkspaceRoundTripScenario(restoredOwner: .browser)
    }

    private enum FindFocusRoute {
        case cmdOptionArrows
        case cmdCtrlLetters
    }

    private enum SplitFindOwner {
        case terminal
        case browser

        var focusedPanelKind: String {
            switch self {
            case .terminal:
                return "terminal"
            case .browser:
                return "browser"
            }
        }
    }

    private func runFindFocusPersistenceScenario(route: FindFocusRoute, useAutofocusRacePage: Bool) {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_RECORD_ONLY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        if route == .cmdCtrlLetters {
            app.launchEnvironment["CMUX_UI_TEST_FOCUS_SHORTCUTS"] = "1"
        }
        launchAndEnsureForeground(app)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10.0), "Expected main window to exist")

        // Repro setup: split, open browser split, navigate to example.com.
        app.typeKey("d", modifierFlags: [.command])
        focusRightPaneForFindScenario(app, route: route)

        app.typeKey("l", modifierFlags: [.command, .shift])
        let omnibar = app.textFields["BrowserOmnibarTextField"].firstMatch
        XCTAssertTrue(omnibar.waitForExistence(timeout: 8.0), "Expected browser omnibar after Cmd+Shift+L")

        app.typeKey("a", modifierFlags: [.command])
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        if useAutofocusRacePage {
            app.typeText(autofocusRacePageURL)
        } else {
            app.typeText("example.com")
        }
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        if useAutofocusRacePage {
            XCTAssertTrue(
                waitForOmnibarToContain(omnibar, value: "data:text/html", timeout: 8.0),
                "Expected browser navigation to data URL before running find flow. value=\(String(describing: omnibar.value))"
            )
        } else {
            XCTAssertTrue(
                waitForOmnibarToContainExampleDomain(omnibar, timeout: 8.0),
                "Expected browser navigation to example domain before running find flow. value=\(String(describing: omnibar.value))"
            )
        }

        // Left terminal: Cmd+F then type "la".
        focusLeftPaneForFindScenario(app, route: route)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["focusedPanelKind"] == "terminal"
            },
            "Expected left terminal pane to be focused before terminal find. data=\(String(describing: loadData()))"
        )
        app.typeKey("f", modifierFlags: [.command])
        app.typeText("la")

        // Right browser: Cmd+F then type "am".
        focusRightPaneForFindScenario(app, route: route)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["lastMoveDirection"] == "right"
                    && data["focusedPanelKind"] == "browser"
                    && data["terminalFindNeedle"] == "la"
            },
            "Expected terminal find query to persist as 'la' after focusing browser pane. data=\(String(describing: loadData()))"
        )
        app.typeKey("f", modifierFlags: [.command])
        app.typeText("am")

        if useAutofocusRacePage {
            XCTAssertTrue(
                waitForOmnibarToContain(omnibar, value: "#focused", timeout: 5.0),
                "Expected autofocus race page to signal focus handoff via URL hash. value=\(String(describing: omnibar.value))"
            )
        }

        // Left terminal: typing should keep going into terminal find field.
        focusLeftPaneForFindScenario(app, route: route)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["lastMoveDirection"] == "left"
                    && data["focusedPanelKind"] == "terminal"
                    && data["browserFindNeedle"] == "am"
            },
            "Expected browser find query to persist as 'am' after returning left. data=\(String(describing: loadData()))"
        )
        app.typeText("foo")

        // Right browser: typing should keep going into browser find field.
        focusRightPaneForFindScenario(app, route: route)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["lastMoveDirection"] == "right"
                    && data["focusedPanelKind"] == "browser"
                    && data["terminalFindNeedle"] == "lafoo"
            },
            "Expected terminal find query to stay focused and become 'lafoo'. data=\(String(describing: loadData()))"
        )
        app.typeText("do")

        // Move left once more so the recorder captures browser find state after typing.
        focusLeftPaneForFindScenario(app, route: route)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["lastMoveDirection"] == "left"
                    && data["focusedPanelKind"] == "terminal"
                    && data["browserFindNeedle"] == "amdo"
            },
            "Expected browser find query to stay focused and become 'amdo'. data=\(String(describing: loadData()))"
        )
    }

    private func runSplitFindWorkspaceRoundTripScenario(restoredOwner: SplitFindOwner) {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_RECORD_ONLY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_GOTO_SPLIT_PATH"] = dataPath
        launchAndEnsureForeground(app)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10.0), "Expected main window to exist")
        XCTAssertTrue(waitForSocketPong(timeout: 12.0), "Expected control socket at \(socketPath)")

        guard let originalWorkspace = currentWorkspaceContext() else {
            XCTFail("Expected current workspace context before leaving workspace 1")
            return
        }

        app.typeKey("d", modifierFlags: [.command])
        focusRightPaneForFindScenario(app, route: .cmdOptionArrows)

        app.typeKey("l", modifierFlags: [.command, .shift])
        let omnibar = app.textFields["BrowserOmnibarTextField"].firstMatch
        XCTAssertTrue(omnibar.waitForExistence(timeout: 8.0), "Expected browser omnibar after Cmd+Shift+L")

        app.typeKey("a", modifierFlags: [.command])
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        app.typeText("example.com")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        XCTAssertTrue(
            waitForOmnibarToContainExampleDomain(omnibar, timeout: 8.0),
            "Expected browser navigation to example domain before running workspace round trip. value=\(String(describing: omnibar.value))"
        )

        focusLeftPaneForFindScenario(app, route: .cmdOptionArrows)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["focusedPanelKind"] == "terminal"
            },
            "Expected left terminal pane to be focused before opening terminal find. data=\(String(describing: loadData()))"
        )
        app.typeKey("f", modifierFlags: [.command])
        app.typeText("la")

        focusRightPaneForFindScenario(app, route: .cmdOptionArrows)
        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["focusedPanelKind"] == "browser"
                    && data["terminalFindNeedle"] == "la"
            },
            "Expected terminal find query to persist before opening browser find. data=\(String(describing: loadData()))"
        )
        app.typeKey("f", modifierFlags: [.command])
        app.typeText("am")

        switch restoredOwner {
        case .terminal:
            focusLeftPaneForFindScenario(app, route: .cmdOptionArrows)
        case .browser:
            break
        }

        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["focusedPanelKind"] == restoredOwner.focusedPanelKind
                    && data["terminalFindNeedle"] == "la"
                    && data["browserFindNeedle"] == "am"
            },
            "Expected the intended find owner before leaving workspace 1. data=\(String(describing: loadData()))"
        )

        openCommandPaletteForNewWorkspace(app, windowId: originalWorkspace.windowId)
        XCTAssertTrue(
            selectWorkspace(originalWorkspace.workspaceId),
            "Expected to return to the original workspace by identity"
        )

        XCTAssertTrue(
            waitForDataMatch(timeout: 6.0) { data in
                data["focusedPanelKind"] == restoredOwner.focusedPanelKind
                    && data["terminalFindNeedle"] == "la"
                    && data["browserFindNeedle"] == "am"
            },
            "Expected the previously focused find owner to be restored after the workspace round trip. data=\(String(describing: loadData()))"
        )

        switch restoredOwner {
        case .terminal:
            app.typeText("foo")
            XCTAssertTrue(
                waitForDataMatch(timeout: 6.0) { data in
                    data["focusedPanelKind"] == "terminal"
                        && data["terminalFindNeedle"] == "lafoo"
                        && data["browserFindNeedle"] == "am"
                },
                "Expected typing after returning to stay in terminal find. data=\(String(describing: loadData()))"
            )
        case .browser:
            app.typeText("do")
            XCTAssertTrue(
                waitForDataMatch(timeout: 6.0) { data in
                    data["focusedPanelKind"] == "browser"
                        && data["terminalFindNeedle"] == "la"
                        && data["browserFindNeedle"] == "amdo"
                },
                "Expected typing after returning to stay in browser find. data=\(String(describing: loadData()))"
            )
        }
    }

    private func openCommandPaletteForNewWorkspace(_ app: XCUIApplication, windowId: String) {
        app.typeKey("p", modifierFlags: [.command, .shift])

        let paletteSearchField = app.textFields["CommandPaletteSearchField"].firstMatch
        XCTAssertTrue(paletteSearchField.waitForExistence(timeout: 5.0), "Expected command palette search field")
        paletteSearchField.click()
        paletteSearchField.typeText("New Workspace")

        guard let snapshot = waitForCommandPaletteSnapshot(
            windowId: windowId,
            mode: "commands",
            query: "New Workspace",
            timeout: 5.0,
            predicate: { snapshot in
                guard let firstRow = self.commandPaletteResultRows(from: snapshot).first else { return false }
                return (firstRow["command_id"] as? String) == "palette.newWorkspace"
            }
        ) else {
            XCTFail("Expected palette.newWorkspace to be the selected command palette result")
            return
        }
        XCTAssertEqual(
            commandPaletteResultRows(from: snapshot).first?["command_id"] as? String,
            "palette.newWorkspace",
            "Expected palette.newWorkspace to be selected before pressing Return"
        )

        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        XCTAssertTrue(
            waitForNonExistence(paletteSearchField, timeout: 5.0),
            "Expected command palette to dismiss after creating a workspace"
        )
    }

    private func focusLeftPaneForFindScenario(_ app: XCUIApplication, route: FindFocusRoute) {
        switch route {
        case .cmdOptionArrows:
            app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [.command, .option])
        case .cmdCtrlLetters:
            app.typeKey("h", modifierFlags: [.command, .control])
        }
    }

    private func focusRightPaneForFindScenario(_ app: XCUIApplication, route: FindFocusRoute) {
        switch route {
        case .cmdOptionArrows:
            app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [.command, .option])
        case .cmdCtrlLetters:
            app.typeKey("l", modifierFlags: [.command, .control])
        }
    }

    private func waitForOmnibarToContainExampleDomain(_ omnibar: XCUIElement, timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            let value = (omnibar.value as? String) ?? ""
            return value.contains("example.com") || value.contains("example.org")
        }
    }

    private func selectWorkspace(_ workspaceId: String) -> Bool {
        guard let envelope = socketJSON(
            method: "workspace.select",
            params: ["workspace_id": workspaceId]
        ),
        let ok = envelope["ok"] as? Bool,
        ok else {
            return false
        }

        return waitForCondition(timeout: 5.0) {
            self.currentWorkspaceContext()?.workspaceId == workspaceId
        }
    }

    private func commandPaletteResultRows(from snapshot: [String: Any]) -> [[String: Any]] {
        snapshot["results"] as? [[String: Any]] ?? []
    }

    private var autofocusRacePageURL: String {
        "data:text/html,%3Cinput%20id%3D%22q%22%3E%3Cscript%3EsetTimeout%28function%28%29%7Bdocument.getElementById%28%22q%22%29.focus%28%29%3Blocation.hash%3D%22focused%22%3B%7D%2C700%29%3B%3C%2Fscript%3E"
    }

}
