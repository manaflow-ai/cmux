import XCTest

final class CmxLongHaulStressUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testOneHourTerminalWorkspaceReconnectAndResizeStress() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CMUX_IOS_RUN_LONG_HAUL_STRESS"] == "1",
            "Set CMUX_IOS_RUN_LONG_HAUL_STRESS=1 to run the opt-in one-hour stress test."
        )

        let duration = Self.durationSeconds()
        let deadline = Date().addingTimeInterval(duration)
        let app = launchApp()
        var terminal = try openTerminal(in: app)
        var iteration = 0
        var knownWorkspaceTitles = ["main", "ios-sync-ws", "bd34-sync"]
        var currentWorkspaceTitle = "main"

        while Date() < deadline {
            try autoreleasepool {
                iteration += 1
                let token = "LH_\(iteration)_\(Self.seed)"

                try type("echo \(token) first line\n", into: terminal, app: app)
                XCTAssertTrue(waitForTerminalValue(terminal, containing: token, timeout: 8))

                try type("echo \(token)_multi_a && echo \(token)_multi_b\n", into: terminal, app: app)
                XCTAssertTrue(waitForTerminalValue(terminal, containing: "\(token)_multi_b", timeout: 8))

                if iteration.isMultiple(of: 2) {
                    let target = knownWorkspaceTitles[iteration % knownWorkspaceTitles.count]
                    terminal = try selectMenuItem(target, app: app)
                    currentWorkspaceTitle = target
                    try type("echo \(token)_workspace_\(target)\n", into: terminal, app: app)
                    XCTAssertTrue(waitForTerminalValue(terminal, containing: "\(token)_workspace_\(target)", timeout: 8))
                }

                if iteration.isMultiple(of: 3) {
                    terminal.pinch(withScale: 0.72, velocity: -1)
                    terminal.pinch(withScale: 1.28, velocity: 1)
                    try type("echo \(token)_pinch_ok\n", into: terminal, app: app)
                    XCTAssertTrue(waitForTerminalValue(terminal, containing: "\(token)_pinch_ok", timeout: 8))
                }

                if iteration.isMultiple(of: 4) {
                    try type("vim\n", into: terminal, app: app)
                    XCTAssertTrue(waitForTerminalValue(terminal, containing: "LONG-HAUL BUFFER", timeout: 8))
                    try type(":q\n", into: terminal, app: app)
                    XCTAssertTrue(waitForTerminalValue(terminal, containing: "alt screen exited", timeout: 8))
                    try type("echo \(token)_alt_screen_ok\n", into: terminal, app: app)
                    XCTAssertTrue(waitForTerminalValue(terminal, containing: "\(token)_alt_screen_ok", timeout: 8))
                }

                if iteration.isMultiple(of: 5) {
                    try type("cmux-stress-burst 128 \(token)_burst\n", into: terminal, app: app)
                    XCTAssertTrue(waitForTerminalValue(terminal, containing: "\(token)_burst line 127", timeout: 8))
                }

                if iteration.isMultiple(of: 6) {
                    try type("clear\n", into: terminal, app: app)
                    XCTAssertTrue(waitForTerminalValue(terminal, containing: "ui-test$", timeout: 8))
                }

                if iteration.isMultiple(of: 7) {
                    let workspaceTitle = "stress-\(iteration)"
                    try type("cmx new-workspace \(workspaceTitle)\n", into: terminal, app: app)
                    knownWorkspaceTitles.append(workspaceTitle)
                    currentWorkspaceTitle = workspaceTitle
                    terminal = try waitForTerminal(app: app)
                    XCTAssertTrue(waitForTerminalValue(terminal, containing: workspaceTitle, timeout: 8))
                }

                if iteration.isMultiple(of: 8) {
                    let sourceTitle = "rename-source-\(iteration)"
                    let workspaceTitle = "renamed-\(iteration)"
                    try type("cmx new-workspace \(sourceTitle)\n", into: terminal, app: app)
                    knownWorkspaceTitles.append(sourceTitle)
                    currentWorkspaceTitle = sourceTitle
                    terminal = try waitForTerminal(app: app)
                    try type("cmx rename workspace \(workspaceTitle)\n", into: terminal, app: app)
                    knownWorkspaceTitles.removeAll { $0 == currentWorkspaceTitle }
                    knownWorkspaceTitles.append(workspaceTitle)
                    currentWorkspaceTitle = workspaceTitle
                    XCTAssertTrue(waitForTerminalValue(terminal, containing: "renamed workspace \(workspaceTitle)", timeout: 8))
                }

                if iteration.isMultiple(of: 9) {
                    try type("cmx new-space space-\(iteration)\n", into: terminal, app: app)
                    terminal = try waitForTerminal(app: app)
                    try type("cmx new-tab tab-\(iteration)\n", into: terminal, app: app)
                    terminal = try waitForTerminal(app: app)
                    try type("echo \(token)_new_space_tab_ok\n", into: terminal, app: app)
                    XCTAssertTrue(waitForTerminalValue(terminal, containing: "\(token)_new_space_tab_ok", timeout: 8))
                }

                if iteration.isMultiple(of: 10) {
                    if knownWorkspaceTitles.contains("main") {
                        terminal = try selectMenuItem("main", app: app)
                        currentWorkspaceTitle = "main"
                    }
                    terminal = try selectMenuItem("logs", app: app)
                    try type("echo \(token)_logs_terminal_ok\n", into: terminal, app: app)
                    XCTAssertTrue(waitForTerminalValue(terminal, containing: "\(token)_logs_terminal_ok", timeout: 8))
                }

                if iteration.isMultiple(of: 11) {
                    XCUIDevice.shared.orientation = .landscapeLeft
                    XCTAssertTrue(waitForTerminalFrameToBecomeStable(terminal, timeout: 8))
                    try type("echo \(token)_landscape_ok\n", into: terminal, app: app)
                    XCTAssertTrue(waitForTerminalValue(terminal, containing: "\(token)_landscape_ok", timeout: 8))
                    XCUIDevice.shared.orientation = .portrait
                    XCTAssertTrue(waitForTerminalFrameToBecomeStable(terminal, timeout: 8))
                }

                if iteration.isMultiple(of: 12) {
                    toggleWorkspaceAction("workspace.action.unread.1", app: app)
                    toggleWorkspaceAction("workspace.action.pin.2", app: app)
                    terminal = try waitForTerminal(app: app)
                }

                if iteration.isMultiple(of: 13) {
                    XCUIDevice.shared.press(.home)
                    app.activate()
                    terminal = try waitForTerminal(app: app)
                    try type("echo \(token)_foreground_ok\n", into: terminal, app: app)
                    XCTAssertTrue(waitForTerminalValue(terminal, containing: "\(token)_foreground_ok", timeout: 8))
                }

                if iteration.isMultiple(of: 17) {
                    app.terminate()
                    app.launch()
                    terminal = try openTerminal(in: app)
                    XCTAssertTrue(waitForTerminalValue(terminal, containing: "ui-test$", timeout: 10))
                    knownWorkspaceTitles = ["main", "ios-sync-ws", "bd34-sync"]
                    currentWorkspaceTitle = "main"
                }
            }
        }
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "CMUX_IOS_BRIDGE_TICKET": Self.directTicket,
            "CMUX_IOS_AUTOCONNECT": "1",
            "CMUX_IOS_UI_TESTING_ECHO_SESSION": "1",
            "CMUX_IOS_SHOW_TERMINAL_BOUNDS": "1",
        ]
        app.launch()
        return app
    }

    @MainActor
    private func openTerminal(in app: XCUIApplication) throws -> XCUIElement {
        let workspace = app.descendants(matching: .any)["workspace.row.1"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        workspace.tap()
        let terminal = try waitForTerminal(app: app)
        XCTAssertTrue(waitForTerminalValue(terminal, containing: "ui-test$", timeout: 10))
        return terminal
    }

    @MainActor
    private func waitForTerminal(app: XCUIApplication) throws -> XCUIElement {
        let terminal = app.descendants(matching: .any)["terminal.surface"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["terminal.empty"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["terminal.loading"].exists)
        return terminal
    }

    @MainActor
    private func type(_ text: String, into terminal: XCUIElement, app: XCUIApplication) throws {
        terminal.tap()
        let input = app.descendants(matching: .any)["terminal.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.typeText(text)
    }

    @MainActor
    private func selectMenuItem(_ label: String, app: XCUIApplication) throws -> XCUIElement {
        let selector = app.descendants(matching: .any)["terminal.selector"]
        XCTAssertTrue(selector.waitForExistence(timeout: 10))
        selector.tap()

        let candidates = [
            app.buttons[label],
            app.menuItems[label],
            app.staticTexts[label],
        ]
        for candidate in candidates where candidate.waitForExistence(timeout: 3) {
            candidate.tap()
            return try waitForTerminal(app: app)
        }
        XCTFail("Menu item '\(label)' did not appear")
        return try waitForTerminal(app: app)
    }

    @MainActor
    private func toggleWorkspaceAction(_ identifier: String, app: XCUIApplication) {
        let action = app.descendants(matching: .any)[identifier]
        if action.waitForExistence(timeout: 2) {
            action.tap()
        }
    }

    private func waitForTerminalValue(
        _ terminal: XCUIElement,
        containing expected: String,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate { element, _ in
            guard let terminal = element as? XCUIElement else { return false }
            return MainActor.assumeIsolated {
                (terminal.value as? String)?.contains(expected) == true
            }
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: terminal)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForTerminalFrameToBecomeStable(_ terminal: XCUIElement, timeout: TimeInterval) -> Bool {
        var previous = CGRect.null
        let predicate = NSPredicate { element, _ in
            guard let terminal = element as? XCUIElement else { return false }
            return MainActor.assumeIsolated {
                let frame = terminal.frame
                defer { previous = frame }
                return !frame.isEmpty && !previous.isNull && abs(frame.width - previous.width) < 0.5
                    && abs(frame.height - previous.height) < 0.5
            }
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: terminal)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private static func durationSeconds() -> TimeInterval {
        guard let rawValue = ProcessInfo.processInfo.environment["CMUX_IOS_STRESS_DURATION_SECONDS"],
              let value = TimeInterval(rawValue),
              value > 0 else {
            return 3_600
        }
        return value
    }

    private static var seed: String {
        ProcessInfo.processInfo.environment["CMUX_IOS_STRESS_SEED"] ?? "default"
    }

    private static let directTicket = #"{"version":1,"alpn":"/cmux/cmx/3","endpoint":{"id":"ui-test-endpoint","addrs":[]},"auth":{"mode":"direct"},"node":{"id":"ui-test-node","name":"UI Test Mac","subtitle":"Ghostty echo session","kind":"macbook"}}"#
}
