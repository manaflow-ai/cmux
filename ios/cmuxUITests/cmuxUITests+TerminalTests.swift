import CMUXMobileCore
import Network
import UIKit
import XCTest


// MARK: - Terminal Workspace Tests
extension cmuxUITests {
    /// Regression: fast pinch-zoom must not hang the main thread (the
    /// scene-update watchdog `0x8BADF00D` was killing the app because
    /// libghostty surface calls block on the main thread) and must not
    /// corrupt the rendered grid. Runs the real zoom path through real
    /// pinch gestures on the live terminal surface.
    @MainActor
    func testFastPinchZoomDoesNotHangOrCorrupt() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        let surface = app.otherElements["MobileTerminalSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 8))

        // Dismiss any notification banner that could intercept the gestures.
        addUIInterruptionMonitor(withDescription: "system banner") { banner in
            banner.swipeUp()
            return true
        }
        app.swipeDown(velocity: .fast) // trigger the monitor if a banner is up
        app.swipeUp(velocity: .fast)

        // Drastic + fast zoom sweep, far beyond a human pinch: full zoom-in
        // then full zoom-out, at high velocity, many times. Pre-fix this hung
        // the main thread on a libghostty futex and tripped the 10s watchdog.
        for _ in 0..<120 {
            surface.pinch(withScale: 8.0, velocity: 12.0)   // hard zoom in
            surface.pinch(withScale: 0.1, velocity: -12.0)  // hard zoom out
        }

        // If the app watchdog-hung/crashed it is no longer foreground.
        XCTAssertEqual(
            app.state,
            .runningForeground,
            "App must survive fast/drastic pinch-zoom without a watchdog hang"
        )
        // And the terminal must still render its known content, not a blank
        // or jumbled grid.
        assertTerminalRow(0, label: "$ cmux ios status", in: app)
        assertTerminalRow(1, label: "Mobile Core: connected", in: app)
    }

    @MainActor
    func testWorkspaceToolbarCreatesWorkspaceAndTerminal() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        try openSelectedWorkspaceIfNeeded(app)

        tap(app.buttons["MobileTerminalNewWorkspaceButton"], in: app)
        await assertHostSelection(
            workspaceID: "workspace-3",
            terminalID: "workspace-3-terminal-1",
            server: server
        )

        tap(app.buttons["MobileTerminalDropdown"], in: app)
        assertTerminalMenuItemExists("workspace-3-terminal-1", in: app)
        tapMenuItem(app.buttons["MobileNewTerminalMenuItem"], in: app)
        await assertHostSelection(
            workspaceID: "workspace-3",
            terminalID: "workspace-3-terminal-2",
            server: server
        )

        tap(app.buttons["MobileTerminalDropdown"], in: app)
        assertTerminalMenuItemExists("workspace-3-terminal-2", in: app)
    }

    @MainActor
    func testTerminalDropdownSwitchesToAlternateScreenSnapshot() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        try openSelectedWorkspaceIfNeeded(app)

        tap(app.buttons["MobileTerminalDropdown"], in: app)
        tapMenuItem(app.buttons["MobileTerminalMenuItem-terminal-tui"], in: app)
        await assertHostSelection(workspaceID: "workspace-main", terminalID: "terminal-tui", server: server)
        await assertTerminalReplay(terminalID: "terminal-tui", server: server)

        assertTerminalRow(0, label: "LAZYGIT", in: app)
        assertTerminalRow(1, label: "files branches log", in: app)
        assertTerminalRow(3, label: "q quit", in: app)
    }

    @MainActor
    func testTUITerminalUsesAvailableViewportAndResizes() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        try openSelectedWorkspaceIfNeeded(app)
        try await switchToTUITerminal(in: app, server: server)

        XCUIDevice.shared.orientation = .portrait
        let portraitFrame = try waitForTerminalSurfaceFrame(in: app) { frame in
            frame.height > frame.width
        }
        assertTerminalSurfaceUsesAvailableViewport(portraitFrame, in: app)
        await assertHostSelection(workspaceID: "workspace-main", terminalID: "terminal-tui", server: server)

        XCUIDevice.shared.orientation = .landscapeLeft
        let landscapeFrame = try waitForTerminalSurfaceFrame(in: app) { frame in
            app.isLandscape && frame.width > portraitFrame.width + 80
        }
        assertTerminalSurfaceUsesAvailableViewport(landscapeFrame, in: app)
        XCTAssertLessThan(
            landscapeFrame.height,
            portraitFrame.height - 40,
            "Terminal surface should shrink vertically after rotating to landscape."
        )

        XCUIDevice.shared.orientation = .portrait
        let restoredPortraitFrame = try waitForTerminalSurfaceFrame(in: app) { frame in
            app.isPortrait && frame.height > landscapeFrame.height + 40
        }
        assertTerminalSurfaceUsesAvailableViewport(restoredPortraitFrame, in: app)
        await assertHostSelection(workspaceID: "workspace-main", terminalID: "terminal-tui", server: server)
    }

    @MainActor
    func testTerminalReplayRendersGhosttyText() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        try openSelectedWorkspaceIfNeeded(app)

        let surface = app.otherElements["MobileTerminalSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 6))
        assertTerminalRow(0, label: "$ cmux ios status", in: app)
        assertTerminalRow(1, label: "Mobile Core: connected", in: app)
        assertTerminalRow(2, label: "host: UI Test Mac", in: app)
    }

    @MainActor
    private func switchToTUITerminal(
        in app: XCUIApplication,
        server: MobileSyncMockHostServer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        tap(app.buttons["MobileTerminalDropdown"], in: app, file: file, line: line)
        tapMenuItem(app.buttons["MobileTerminalMenuItem-terminal-tui"], in: app, file: file, line: line)
        await assertHostSelection(
            workspaceID: "workspace-main",
            terminalID: "terminal-tui",
            server: server,
            file: file,
            line: line
        )
        await assertTerminalReplay(
            terminalID: "terminal-tui",
            server: server,
            file: file,
            line: line
        )
    }

    @MainActor
    private func assertHostSelection(
        workspaceID: String,
        terminalID: String,
        server: MobileSyncMockHostServer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let didSelect = await server.waitForSelection(
            workspaceID: workspaceID,
            terminalID: terminalID
        )
        if !didSelect {
            let selection = await server.selectionDescription()
            XCTFail(
                "Expected mock host selection \(workspaceID)/\(terminalID). Last selection: \(selection)",
                file: file,
                line: line
            )
        }
    }

    @MainActor
    private func assertTerminalMenuItemExists(
        _ terminalID: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let item = app.buttons["MobileTerminalMenuItem-\(terminalID)"]
        XCTAssertTrue(
            item.waitForExistence(timeout: 4),
            "Expected terminal menu to contain \(terminalID).",
            file: file,
            line: line
        )
    }

    @MainActor
    private func assertTerminalReplay(
        terminalID: String,
        server: MobileSyncMockHostServer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let didReplay = await server.waitForReplay(terminalID: terminalID)
        if !didReplay {
            let replayDescription = await server.replayDescription()
            XCTFail(
                "Expected mock host replay for \(terminalID). Replay counts: \(replayDescription)",
                file: file,
                line: line
            )
        }
    }

    @MainActor
    private func waitForTerminalSurfaceFrame(
        in app: XCUIApplication,
        timeout: TimeInterval = 8,
        matching predicate: @escaping (CGRect) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> CGRect {
        let surface = app.otherElements["MobileTerminalSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 6), file: file, line: line)

        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else {
                    return false
                }
                return predicate(element.frame)
            },
            object: surface
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(
            result,
            .completed,
            "Timed out waiting for terminal surface resize. Last frame: \(surface.frame)",
            file: file,
            line: line
        )
        return surface.frame
    }

    @MainActor
    private func assertTerminalSurfaceUsesAvailableViewport(
        _ frame: CGRect,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let viewport = availableTerminalViewport(in: app)
        let horizontalTolerance: CGFloat = 12
        let bottomTolerance: CGFloat = 4
        let topChromeBudget = max(CGFloat(150), viewport.height * 0.22)

        XCTAssertLessThanOrEqual(
            abs(frame.minX - viewport.minX),
            horizontalTolerance,
            "Terminal surface should start at the available detail viewport edge. Frame: \(frame), viewport: \(viewport)",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            frame.maxX,
            viewport.maxX - horizontalTolerance,
            "Terminal surface should reach the available viewport trailing edge. Frame: \(frame), viewport: \(viewport)",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            frame.maxX,
            viewport.maxX + horizontalTolerance,
            "Terminal surface should not overflow the available viewport trailing edge. Frame: \(frame), viewport: \(viewport)",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            frame.maxY,
            viewport.maxY - bottomTolerance,
            "Terminal surface should reach the bottom of the viewport without a send/input bar. Frame: \(frame), viewport: \(viewport)",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            frame.minY - viewport.minY,
            topChromeBudget,
            "Terminal surface should only leave room for navigation chrome above it. Frame: \(frame), viewport: \(viewport)",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            frame.height,
            viewport.height - topChromeBudget - bottomTolerance,
            "Terminal surface should use the vertical space below the navigation bar. Frame: \(frame), viewport: \(viewport)",
            file: file,
            line: line
        )
    }

    @MainActor
    private func availableTerminalViewport(in app: XCUIApplication) -> CGRect {
        let window = app.windows.firstMatch
        let windowFrame = window.exists ? window.frame : app.frame
        let workspaceList = app.otherElements["MobileWorkspaceList"]
        guard workspaceList.exists,
              workspaceList.frame.width > 180,
              workspaceList.frame.maxX < windowFrame.maxX - 180 else {
            return windowFrame
        }

        return CGRect(
            x: workspaceList.frame.maxX,
            y: windowFrame.minY,
            width: windowFrame.maxX - workspaceList.frame.maxX,
            height: windowFrame.height
        )
    }

    @MainActor
    private func tapMenuItem(
        _ element: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 4), file: file, line: line)
        let hittableExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: element
        )
        let hittableResult = XCTWaiter.wait(for: [hittableExpectation], timeout: 4)
        XCTAssertEqual(
            hittableResult,
            .completed,
            "Menu item never became hittable: \(element.debugDescription)",
            file: file,
            line: line
        )
        element.tap()

        let dismissedExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        let dismissedResult = XCTWaiter.wait(for: [dismissedExpectation], timeout: 4)
        XCTAssertEqual(
            dismissedResult,
            .completed,
            "Menu item stayed visible after tap: \(element.debugDescription)",
            file: file,
            line: line
        )
    }

}
