import CMUXMobileCore
import Network
import UIKit
import XCTest

final class cmuxUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testStackAuthEntryUsesStableIdentifiers() throws {
        let app = launchApp(mockData: false, clearAuth: true)

        XCTAssertTrue(app.buttons["signin.apple"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["signin.google"].exists)

        let emailField = app.textFields["Email"]
        XCTAssertTrue(emailField.exists)

        let emailCodeButton = app.buttons["signin.emailCode"]
        XCTAssertTrue(emailCodeButton.exists)
        XCTAssertFalse(emailCodeButton.isEnabled)

        try typeText("dogfood@example.com", into: emailField, in: app)
        XCTAssertTrue(emailCodeButton.isEnabled)
    }

    @MainActor
    func testAddDeviceManualHostValidationUsesStableIdentifiers() throws {
        let invalidHostApp = launchAddDeviceApp(environment: [
            "CMUX_UITEST_ADD_DEVICE_HOST": "dev/path.local"
        ])

        XCTAssertTrue(invalidHostApp.otherElements["MobileAddDeviceForm"].waitForExistence(timeout: 8))
        XCTAssertTrue(invalidHostApp.textFields["MobileAddDeviceNameField"].exists)
        XCTAssertTrue(invalidHostApp.textFields["MobileAddDeviceHostField"].exists)
        XCTAssertTrue(invalidHostApp.textFields["MobileAddDevicePortField"].exists)
        XCTAssertTrue(invalidHostApp.staticTexts["MobileAddDeviceSignedInAccount"].exists)
        XCTAssertTrue(invalidHostApp.staticTexts["MobileAddDeviceSignedInAccount"].label.contains("uitest@cmux.local"))
        XCTAssertTrue(invalidHostApp.buttons["MobileScanQRCodeButton"].exists)

        let invalidHostPairButton = invalidHostApp.buttons["MobilePairButton"]
        XCTAssertTrue(invalidHostPairButton.exists)
        XCTAssertTrue(invalidHostPairButton.isEnabled)

        tap(invalidHostPairButton, in: invalidHostApp)
        assertPairingError(contains: "Enter a host or IP address", in: invalidHostApp)
        invalidHostApp.terminate()

        let invalidPortApp = launchAddDeviceApp(environment: [
            "CMUX_UITEST_ADD_DEVICE_HOST": "127.0.0.1",
            "CMUX_UITEST_ADD_DEVICE_PORT": "70000",
        ])
        defer { invalidPortApp.terminate() }
        let invalidPortPairButton = invalidPortApp.buttons["MobilePairButton"]
        XCTAssertTrue(invalidPortPairButton.exists)
        XCTAssertTrue(invalidPortPairButton.isEnabled)

        tap(invalidPortPairButton, in: invalidPortApp)
        assertPairingError(contains: "Enter a port from 1 to 65535", in: invalidPortApp)
    }

    @MainActor
    func testManualHostConnectsAndNavigatesToWorkspace() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)

        try openSelectedWorkspaceIfNeeded(app)
        XCTAssertTrue(app.otherElements["MobileTerminalSurface"].waitForExistence(timeout: 6))
        assertTerminalRow(0, label: "$ cmux ios status", in: app)
        assertTerminalRow(1, label: "Mobile Core: connected", in: app)
        assertTerminalRow(2, label: "host: UI Test Mac", in: app)
    }

    @MainActor
    func testDeleteComputersVerifierPasses() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_DELETE_COMPUTERS_VERIFIER": "1",
        ])
        defer { app.terminate() }

        let status = app.staticTexts["DeleteComputersVerifierStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let pass = NSPredicate(format: "label == %@", "PASS")
        expectation(for: pass, evaluatedWith: status)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(status.label, "PASS")
        XCTAssertTrue(app.staticTexts["halfRemovedAbsent=true"].exists)
        XCTAssertTrue(app.staticTexts["halfRemainingPresent=true"].exists)
        XCTAssertTrue(app.staticTexts["halfNoDisconnectedBanner=true"].exists)
        XCTAssertTrue(app.staticTexts["refreshPreservedHalfList=true"].exists)
        XCTAssertTrue(app.staticTexts["allRemoved=true"].exists)
        XCTAssertTrue(app.staticTexts["refreshPreservedEmptyList=true"].exists)
    }

    @MainActor
    func testWorkspaceMacPickerUsesComputerCopy() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
        ])
        defer { app.terminate() }

        let picker = app.buttons["MobileWorkspaceMacPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["All Computers"].exists)

        picker.tap()

        XCTAssertTrue(app.staticTexts["Choose Computer"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["All Computers"].exists)
        XCTAssertFalse(app.staticTexts["Choose Mac"].exists)
        XCTAssertFalse(app.staticTexts["All Macs"].exists)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "workspace-mac-picker-computer-copy"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

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

    /// Freeze fuzzing for the keyboard + layout interactions, modeled on
    /// `testFastPinchZoomDoesNotHangOrCorrupt`. The user report: "Sometimes the
    /// terminal on iOS freezes; we should do some fuzzing around here." The
    /// suspects are the geometry-sync coalescing gate, the display-link
    /// start/stop, the render suspend/resume, and `syncSurfaceGeometry`
    /// dispatching to the serial output queue while main waits on it. Rapidly
    /// toggling the keyboard (focus/dismiss) interleaved with terminal taps,
    /// composer open/close, and pinch-zoom hammers exactly those paths.
    ///
    /// At the end the test asserts the surface is still LIVE: the app is
    /// foreground (no watchdog hang), the terminal still renders its known
    /// content (not a blank/frozen grid), the dock is coherent, and once the
    /// keyboard is down the grid has returned to (near) full height, which also
    /// guards the "terminal not full height when keyboard closed" fix
    /// (`scheduleKeyboardHideHeightResync` + the host-tested
    /// `TerminalLetterboxGeometry.terminalContainerSize`).
    @MainActor
    func testKeyboardLayoutFuzzDoesNotFreeze() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        let surface = app.otherElements["MobileTerminalSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 8))

        // Dismiss any system banner that could intercept the gestures (matches the
        // pinch-zoom test's monitor pattern).
        addUIInterruptionMonitor(withDescription: "system banner") { banner in
            banner.swipeUp()
            return true
        }
        app.swipeDown(velocity: .fast)
        app.swipeUp(velocity: .fast)

        let composeButton = app.buttons[Composer.composeButton]
        let hideKeyboardButton = app.buttons["terminal.inputAccessory.hideKeyboard"]

        // Fuzz loop: each iteration interleaves the focus/dismiss, tap, composer,
        // and pinch paths in a slightly different order so the geometry sync and
        // render gates are hit in many orderings. Raw gestures (no waits between
        // them) so the coalescing/display-link timing is genuinely stressed.
        for cycle in 0..<40 {
            // 1. Focus the composer -> keyboard up -> grid reserves keyboard.
            if composeButton.exists, composeButton.isHittable {
                composeButton.tap()
            }
            // 2. Pinch while the keyboard is (coming) up: zoom + keyboard geometry
            //    contend for the same syncSurfaceGeometry path.
            surface.pinch(withScale: 4.0, velocity: 8.0)
            // 3. Dismiss the keyboard -> keyboard down -> grid must reclaim height.
            if hideKeyboardButton.exists, hideKeyboardButton.isHittable {
                hideKeyboardButton.tap()
            }
            // 4. Tap the terminal (re-shows chrome if hidden, toggles focus).
            surface.tap()
            // 5. Pinch the other way with the keyboard down.
            surface.pinch(withScale: 0.3, velocity: -8.0)
            // 6. Every few cycles, toggle the composer via the compose control
            //    (close/refocus), then the compose tap at the top of the next
            //    cycle drives it the other way. This drives the composer-band-
            //    height reservation in and out under load.
            if cycle % 3 == 0, composeButton.exists, composeButton.isHittable {
                composeButton.tap()
            }
            // The app must survive every cycle, not just the end (a mid-loop
            // watchdog hang would otherwise be reported only at teardown).
            XCTAssertEqual(
                app.state, .runningForeground,
                "App must stay foreground through keyboard/layout fuzz (cycle \(cycle))"
            )
        }

        // Settle: dismiss the keyboard so the final assertions run in the
        // keyboard-down state, where the grid must be at full height.
        if hideKeyboardButton.exists, hideKeyboardButton.isHittable {
            hideKeyboardButton.tap()
        }
        _ = waitForKeyboardDismissal(in: app)

        // LIVENESS 1: still foreground (no watchdog hang / freeze).
        XCTAssertEqual(
            app.state, .runningForeground,
            "App must survive the keyboard/layout fuzz without a watchdog hang/freeze"
        )

        // LIVENESS 2: the surface still renders (the probe is read live on every
        // accessibility query, so a frozen main thread would time this out).
        let dock = waitForDock(in: app, timeout: 8, describe: "post-fuzz: keyboard down, toolbar visible") {
            $0["keyboardUp"] == "0" && $0["toolbarVisible"] == "1"
        }
        assertDockCoherent(in: app, cycle: 99)

        // LIVENESS 3: the grid returned to (near) full height once the keyboard is
        // down. The grid floors to whole cells and reserves the toolbar + safe
        // area + any open composer band, so it sits some points under bounds; the
        // FREEZE / stale-height bug instead leaves it stuck at the much shorter
        // keyboard-up height. A generous budget (it must be within ~45% of bounds,
        // i.e. clearly NOT pinned at the keyboard-up size) catches the regression
        // without flaking on the legitimate chrome reservation.
        if let renderH = dock["renderHeight"].flatMap(Int.init),
           let boundsH = dock["boundsHeight"].flatMap(Int.init),
           boundsH > 0 {
            XCTAssertGreaterThan(
                Double(renderH), Double(boundsH) * 0.55,
                "Terminal grid stuck short after keyboard down (freeze/stale-height). renderHeight=\(renderH) boundsHeight=\(boundsH) dock=\(dock)"
            )
        }

        // LIVENESS 4: known content still on screen, not a blank/jumbled grid.
        assertTerminalRow(0, label: "$ cmux ios status", in: app)
        assertTerminalRow(1, label: "Mobile Core: connected", in: app)
    }

    @MainActor
    func testTerminalPreviewRenderBottomTracksSyntheticKeyboardViewport() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_TERMINAL_PREVIEW": "1",
            "CMUX_UITEST_FAKE_KEYBOARD_HEIGHT": "320",
        ])
        XCTAssertTrue(app.otherElements["MobileTerminalSurface"].waitForExistence(timeout: 8))

        let dock = waitForDock(in: app, timeout: 8, describe: "terminal preview with synthetic keyboard") {
            guard let renderHeight = Int($0["renderHeight"] ?? ""),
                  let renderMaxY = Int($0["renderMaxY"] ?? ""),
                  let viewportHeight = Int($0["viewportHeight"] ?? "") else {
                return false
            }
            return renderHeight > 120
                && viewportHeight > 120
                && abs(renderMaxY - viewportHeight) <= 2
                && $0["keyboardUp"] == "1"
                && $0["toolbarVisible"] == "1"
        }
        assertTerminalRenderBottomAttachedToViewport(dock, context: "synthetic keyboard preview")
    }

    @MainActor
    func testBottomScrollStaysPinnedAcrossComposerViewportShrink() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_BOTTOM_SCROLL_STRESS": "1",
        ])
        XCTAssertTrue(app.otherElements["MobileTerminalSurface"].waitForExistence(timeout: 8))

        let dock = waitForDock(in: app, timeout: 8, describe: "bottom scroll stress completed") {
            $0["bottomStressPhase"] == "done"
        }
        XCTAssertEqual(
            dock["scrollAtBottom"],
            "1",
            "Harness must start from Ghostty-confirmed scrollback bottom before checking viewport anchoring. dock=\(dock)"
        )
        XCTAssertEqual(
            dock["staleViewportObserved"],
            "0",
            "Bottom-scrolled terminal render used a stale taller viewport during composer/keyboard shrink. dock=\(dock)"
        )
    }

    @MainActor
    func testWorkspaceToolbarCreatesWorkspaceAndTerminal() async throws {
        let server = try MobileSyncMockHostServer(createdWorkspaceTerminalDelay: 1.5)
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        try openSelectedWorkspaceIfNeeded(app)
        XCTAssertTrue(app.buttons["MobileWorkspaceBackButton"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["MobileWorkspaceTitleMenu"].waitForExistence(timeout: 4))

        tapCompactToolbarTitleMenu(app.buttons["MobileWorkspaceTitleMenu"], in: app)
        XCTAssertTrue(app.buttons["MobileWorkspaceTitleRenameMenuItem"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["MobileWorkspaceTitleReadStateMenuItem"].exists)
        XCTAssertTrue(app.buttons["MobileWorkspaceTitleCloseMenuItem"].exists)
        XCTAssertFalse(app.buttons["MobileNewTerminalMenuItem"].exists)
        dismissOpenMenu(in: app)

        tap(app.buttons["MobileTerminalNewWorkspaceButton"], in: app)
        let freshBackButton = app.buttons["MobileWorkspaceBackButton"]
        let freshTitleMenu = app.buttons["MobileWorkspaceTitleMenu"]
        let freshTerminalDropdown = app.buttons["MobileTerminalDropdown"]
        assertWorkspaceToolbarVisible(
            backButton: freshBackButton,
            titleMenu: freshTitleMenu,
            terminalDropdown: freshTerminalDropdown,
            in: app,
            context: "fresh no-agent workspace immediately after create"
        )
        assertMenuButtonDoesNotExist("MobileWorkspaceSettingsMenu", in: app)
        assertToolbarOverflowButtonDoesNotExist(in: app)
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        await assertHostSelection(
            workspaceID: "workspace-3",
            terminalID: "workspace-3-terminal-1",
            server: server
        )
        assertWorkspaceToolbarVisible(
            backButton: freshBackButton,
            titleMenu: freshTitleMenu,
            terminalDropdown: freshTerminalDropdown,
            in: app,
            context: "fresh no-agent workspace after 5s"
        )
        assertMenuButtonDoesNotExist("MobileWorkspaceSettingsMenu", in: app)
        assertToolbarOverflowButtonDoesNotExist(in: app)
        assertBackButtonFrameStaysCompactAroundPress(freshBackButton, in: app)

        tap(app.buttons["MobileTerminalDropdown"], in: app)
        assertTerminalMenuItemExists("workspace-3-terminal-1", in: app)
        assertMenuButtonDoesNotExist("MobileWorkspaceTitleRenameMenuItem", in: app)
        assertMenuButtonDoesNotExist("MobileWorkspaceTitleReadStateMenuItem", in: app)
        assertMenuButtonDoesNotExist("MobileWorkspaceTitleCloseMenuItem", in: app)
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
    func testWorkspaceDetailToolbarSurvivesDelayedTerminalLifecycle() throws {
        let app = launchWorkspaceDetailDelayedTerminalPreviewApp()
        let backButton = app.buttons["MobileWorkspaceBackButton"]
        let titleMenu = app.buttons["MobileWorkspaceTitleMenu"]
        let terminalDropdown = app.buttons["MobileTerminalDropdown"]

        assertWorkspaceToolbarVisible(
            backButton: backButton,
            titleMenu: titleMenu,
            terminalDropdown: terminalDropdown,
            in: app,
            context: "fresh no-agent workspace before delayed terminal"
        )
        assertMenuButtonDoesNotExist("MobileWorkspaceSettingsMenu", in: app)
        assertToolbarOverflowButtonDoesNotExist(in: app)

        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        assertWorkspaceToolbarVisible(
            backButton: backButton,
            titleMenu: titleMenu,
            terminalDropdown: terminalDropdown,
            in: app,
            context: "fresh no-agent workspace after delayed terminal appears"
        )
        assertMenuButtonDoesNotExist("MobileWorkspaceSettingsMenu", in: app)
        assertToolbarOverflowButtonDoesNotExist(in: app)
        assertBackButtonFrameStaysCompactAroundPress(backButton, in: app)

        tap(terminalDropdown, in: app)
        assertTerminalMenuItemExists("terminal-delayed", in: app)
    }

    @MainActor
    func testWorkspaceDetailToolbarKeepsTerminalPickerVisibleWithLongTitle() throws {
        let app = launchWorkspaceDetailDelayedTerminalPreviewApp(environment: [
            "CMUX_UITEST_WORKSPACE_DETAIL_LONG_TITLE": "1",
        ])
        let backButton = app.buttons["MobileWorkspaceBackButton"]
        let titleMenu = app.buttons["MobileWorkspaceTitleMenu"]
        let terminalDropdown = app.buttons["MobileTerminalDropdown"]

        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        assertWorkspaceToolbarVisible(
            backButton: backButton,
            titleMenu: titleMenu,
            terminalDropdown: terminalDropdown,
            in: app,
            context: "long workspace title without chat toggle"
        )
        XCTAssertFalse(app.buttons["MobileWorkspaceAgentChatButton"].exists)
        assertToolbarOverflowButtonDoesNotExist(in: app)
        tap(terminalDropdown, in: app)
        assertTerminalMenuItemExists("terminal-delayed", in: app)
    }

    @MainActor
    func testWorkspaceDetailToolbarKeepsTerminalPickerVisibleWithLongTitleAndChatToggle() throws {
        let app = launchWorkspaceDetailDelayedTerminalPreviewApp(environment: [
            "CMUX_UITEST_WORKSPACE_DETAIL_LONG_TITLE": "1",
            "CMUX_UITEST_WORKSPACE_DETAIL_CHAT_TOGGLE": "1",
        ])
        let backButton = app.buttons["MobileWorkspaceBackButton"]
        let titleMenu = app.buttons["MobileWorkspaceTitleMenu"]
        let chatButton = app.buttons["MobileWorkspaceAgentChatButton"]
        let terminalDropdown = app.buttons["MobileTerminalDropdown"]

        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        assertWorkspaceToolbarVisible(
            backButton: backButton,
            titleMenu: titleMenu,
            terminalDropdown: terminalDropdown,
            in: app,
            context: "long workspace title with chat toggle"
        )
        XCTAssertTrue(chatButton.waitForExistence(timeout: 4))
        XCTAssertTrue(chatButton.isHittable)
        assertToolbarOverflowButtonDoesNotExist(in: app)
        tap(terminalDropdown, in: app)
        assertTerminalMenuItemExists("terminal-delayed", in: app)
    }

    @MainActor
    func testWorkspaceDetailToolbarSurvivesCreateWorkspaceDelayedTerminalLifecycle() throws {
        let app = launchWorkspaceDetailCreateDelayedTerminalPreviewApp()
        let initialTerminalDropdown = app.buttons["MobileTerminalDropdown"]
        tap(initialTerminalDropdown, in: app)
        tapMenuItem(app.buttons["MobileNewWorkspaceMenuItem"], in: app)

        let backButton = app.buttons["MobileWorkspaceBackButton"]
        let titleMenu = app.buttons["MobileWorkspaceTitleMenu"]
        let terminalDropdown = app.buttons["MobileTerminalDropdown"]

        assertWorkspaceToolbarVisible(
            backButton: backButton,
            titleMenu: titleMenu,
            terminalDropdown: terminalDropdown,
            in: app,
            context: "created no-agent workspace before delayed terminal"
        )
        assertMenuButtonDoesNotExist("MobileWorkspaceSettingsMenu", in: app)
        assertToolbarOverflowButtonDoesNotExist(in: app)

        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        assertWorkspaceToolbarVisible(
            backButton: backButton,
            titleMenu: titleMenu,
            terminalDropdown: terminalDropdown,
            in: app,
            context: "created no-agent workspace after delayed terminal appears"
        )
        assertMenuButtonDoesNotExist("MobileWorkspaceSettingsMenu", in: app)
        assertToolbarOverflowButtonDoesNotExist(in: app)
        assertBackButtonFrameStaysCompactAroundPress(backButton, in: app)

        tap(terminalDropdown, in: app)
        assertTerminalMenuItemExists("workspace-3-terminal-1", in: app)
    }

    @MainActor
    func testTerminalDropdownScrollsLongTerminalList() async throws {
        let server = try MobileSyncMockHostServer(additionalMainTerminalCount: 24)
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        try openSelectedWorkspaceIfNeeded(app)

        tap(app.buttons["MobileTerminalDropdown"], in: app)
        assertTerminalMenuItemExists("terminal-build", in: app)
        let target = scrollTerminalMenuToItem("terminal-extra-24", in: app)
        tapMenuItem(target, in: app)
        await assertHostSelection(workspaceID: "workspace-main", terminalID: "terminal-extra-24", server: server)
        await assertTerminalReplay(terminalID: "terminal-extra-24", server: server)
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

    /// Pixel-level regression for the blank / garbled terminal class. Buffer
    /// checks (``assertTerminalRow``) false-passed while the screen was blank,
    /// so this gates on the actual on-screen composited pixels via
    /// `XCUIScreenshot`. The mock host streams repeating red/green/blue
    /// full-row color bands; at every discrete zoom level the rendered surface
    /// must show those bands (>=3 distinct strong colors) and each band row
    /// must be horizontally uniform (no torn / mis-scaled / garbled frame).
    @MainActor
    func testTerminalRendersColorBandsAcrossZoomLevels() async throws {
        // The selected terminal streams the repeating R/G/B color bands on
        // attach, so the bands render without a flaky dropdown switch.
        let server = try MobileSyncMockHostServer(defaultTerminalLines: MockColorBands.lines())
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port, assertStatusRows: false)

        let surface = app.otherElements["MobileTerminalSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 8))

        // Verify clean bands at the attached size first (no zoom interaction).
        assertCleanColorBands(of: surface, level: 0)

        // Then sweep zoom sizes via the keyboard-accessory buttons, checking
        // the render stays clean (not blank / garbled) at each settled level.
        surface.tap()
        let zoomOut = app.buttons["terminal.inputAccessory.zoomOut"]
        let zoomIn = app.buttons["terminal.inputAccessory.zoomIn"]
        XCTAssertTrue(zoomOut.waitForExistence(timeout: 6), "zoom controls should appear")

        for _ in 0..<10 where zoomOut.isEnabled { zoomOut.tap() }
        var level = 1
        while level < 8 {
            assertCleanColorBands(of: surface, level: level)
            level += 1
            guard zoomIn.isEnabled else { break }
            zoomIn.tap()
            zoomIn.tap()
        }
    }

    @MainActor
    private func assertCleanColorBands(
        of surface: XCUIElement,
        level: Int,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        // The off-main renderer presents a frame behind, so right after a
        // keyboard transition or rapid zoom the surface can be momentarily
        // blank/stale. Poll until the bands settle into a clean state rather
        // than judging a single frame (sleeps are acceptable in tests).
        var lastDetail = "no frames sampled"
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 0.4)
            guard let cg = surface.screenshot().image.cgImage else {
                lastDetail = "no screenshot image"
                continue
            }
            let pixels = BitmapPixels(cg)

            // Vertical strip down the horizontal center, in the upper 55%
            // (clear of the keyboard). Clean bands produce many distinct,
            // strongly-colored samples; a blank screen produces near-zero.
            let strip = (0..<24).map { i -> RGB in
                let y = 0.03 + 0.52 * Double(i) / 23.0
                return pixels.color(xUnit: 0.5, yUnit: y)
            }
            let strong = strip.filter { $0.isStrong }
            let distinct = RGB.distinctCount(strong, tolerance: 60)

            // A torn / mis-scaled frame breaks horizontal uniformity within a
            // band row. Sample left/center/right of a few rows; where all three
            // are strongly colored they must match.
            var uniform = true
            for yUnit in [0.12, 0.30, 0.48] {
                let l = pixels.color(xUnit: 0.22, yUnit: yUnit)
                let c = pixels.color(xUnit: 0.50, yUnit: yUnit)
                let r = pixels.color(xUnit: 0.78, yUnit: yUnit)
                guard l.isStrong, c.isStrong, r.isStrong else { continue }
                if !(l.isClose(to: c, tolerance: 70) && c.isClose(to: r, tolerance: 70)) {
                    uniform = false
                }
            }

            lastDetail = "strong=\(strong.count)/24 distinct=\(distinct) uniform=\(uniform) strip=\(strip)"
            // Clean banded rendering: horizontally uniform (not garbled/torn)
            // AND either several distinct bands (lower zoom) or one band that
            // solidly fills the keyboard-clear strip (higher zoom, where a
            // single thick band can span the whole window). Blank => no strong
            // pixels; garbled => not uniform. The single-band threshold leaves
            // room for the always-visible bottom dock (toolbar + default-open
            // composer band) that shortens the terminal grid: on the iPhone
            // height a clean max-zoom band fills ~14 of the 24 strip samples
            // with row gaps in between, which is a clean render, not a blank
            // or torn one.
            let enoughBands = (distinct >= 2 && strong.count >= 6)
                || (distinct == 1 && strong.count >= 12)
            if uniform, enoughBands {
                return
            }
        }
        XCTFail(
            "zoom level \(level): never rendered clean color bands. last: \(lastDetail)",
            file: file, line: line
        )
    }

    /// A sampled pixel.
    private struct RGB: CustomStringConvertible {
        let r: Int, g: Int, b: Int
        /// A clearly-colored pixel: a bright, saturated channel mix, ignoring
        /// the near-black terminal background.
        var isStrong: Bool {
            let mx = max(r, g, b), mn = min(r, g, b)
            return mx >= 110 && (mx - mn) >= 50
        }
        func isClose(to o: RGB, tolerance: Int) -> Bool {
            abs(r - o.r) <= tolerance && abs(g - o.g) <= tolerance && abs(b - o.b) <= tolerance
        }
        var description: String { "(\(r),\(g),\(b))" }
        static func distinctCount(_ xs: [RGB], tolerance: Int) -> Int {
            var reps: [RGB] = []
            for x in xs where !reps.contains(where: { $0.isClose(to: x, tolerance: tolerance) }) {
                reps.append(x)
            }
            return reps.count
        }
    }

    /// Reads RGB pixels out of a `CGImage` (an `XCUIScreenshot`'s image) by
    /// unit coordinates.
    private struct BitmapPixels {
        let width: Int
        let height: Int
        private let data: [UInt8]
        private let bytesPerRow: Int

        init(_ cg: CGImage) {
            let w = cg.width
            let h = cg.height
            let bpr = w * 4
            var buf = [UInt8](repeating: 0, count: max(1, h * bpr))
            let cs = CGColorSpaceCreateDeviceRGB()
            buf.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(
                    data: raw.baseAddress,
                    width: w,
                    height: h,
                    bitsPerComponent: 8,
                    bytesPerRow: bpr,
                    space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return }
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            width = w
            height = h
            bytesPerRow = bpr
            data = buf
        }

        func color(xUnit: Double, yUnit: Double) -> RGB {
            guard width > 0, height > 0 else { return RGB(r: 0, g: 0, b: 0) }
            let x = min(width - 1, max(0, Int(xUnit * Double(width))))
            let y = min(height - 1, max(0, Int(yUnit * Double(height))))
            let o = y * bytesPerRow + x * 4
            return RGB(r: Int(data[o]), g: Int(data[o + 1]), b: Int(data[o + 2]))
        }
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
    func testInlineWorkspaceTitleMenuShowsWorkspaceActions() throws {
        let app = launchAgentChatInlinePreviewApp()
        let titleMenu = app.buttons["MobileWorkspaceTitleMenu"]
        let backButton = app.buttons["MobileWorkspaceBackButton"]
        let chatToggle = app.buttons["AgentChatInlinePreviewChatToggle"]
        let surfacePicker = app.buttons["AgentChatInlinePreviewTerminalPicker"]
        XCTAssertTrue(titleMenu.waitForExistence(timeout: 8))
        XCTAssertTrue(backButton.waitForExistence(timeout: 4))
        XCTAssertTrue(chatToggle.waitForExistence(timeout: 4))
        XCTAssertTrue(surfacePicker.waitForExistence(timeout: 4))
        XCTAssertTrue(
            waitForCompactToolbarHeightsToMatch(
                titleMenu: titleMenu,
                backButton: backButton,
                surfacePicker: surfacePicker,
                tolerance: 2,
                timeout: 4
            )
        )
        XCTAssertTrue(
            waitForWorkspaceTitleCenteredAndSeparated(
                titleMenu: titleMenu,
                backButton: backButton,
                trailingControl: chatToggle,
                in: app,
                timeout: 4
            )
        )

        tapCompactToolbarTitleMenu(titleMenu, in: app)

        XCTAssertTrue(app.buttons["MobileWorkspaceTitleRenameMenuItem"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["MobileWorkspaceTitleReadStateMenuItem"].exists)
        XCTAssertFalse(app.buttons["MobileNewTerminalMenuItem"].exists)
    }

    @MainActor
    func testInlineWorkspaceTitleKeepsCompactHeightWithTallGlyphs() throws {
        let app = launchAgentChatInlinePreviewApp(environment: [
            "CMUX_UITEST_INLINE_WORKSPACE_TITLE": "✳️ Claude Code",
            "CMUX_UITEST_INLINE_WORKSPACE_SUBTITLE": "🧑🏽‍💻 Claude Code",
        ])
        let titleMenu = app.buttons["MobileWorkspaceTitleMenu"]
        let backButton = app.buttons["MobileWorkspaceBackButton"]
        let surfacePicker = app.buttons["AgentChatInlinePreviewTerminalPicker"]

        XCTAssertTrue(titleMenu.waitForExistence(timeout: 8))
        XCTAssertTrue(backButton.waitForExistence(timeout: 4))
        XCTAssertTrue(surfacePicker.waitForExistence(timeout: 4))

        XCTAssertTrue(
            waitForCompactToolbarHeightsToMatch(
                titleMenu: titleMenu,
                backButton: backButton,
                surfacePicker: surfacePicker,
                tolerance: 2,
                timeout: 4
            )
        )

        let screenshotAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshotAttachment.name = "inline-title-tall-glyph-compact-height"
        screenshotAttachment.lifetime = .keepAlways
        add(screenshotAttachment)

        tapCompactToolbarTitleMenu(titleMenu, in: app)
        XCTAssertTrue(app.buttons["MobileWorkspaceTitleRenameMenuItem"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["MobileNewTerminalMenuItem"].exists)
    }

    /// Regression for WhatsApp-style chat keyboard tracking: focusing the chat
    /// composer must translate the actual transcript table frame upward with the
    /// composer while preserving the table's own bottom-visible content. The table
    /// stays full height behind a keyboard-owned clip view, so the bottom content
    /// remains visible and keyboard motion clips only from the top.
    @MainActor
    func testAgentChatTranscriptKeepsTopEdgeVisibleWithKeyboardAcrossScrollPositions() throws {
        do {
            let app = launchAgentChatInlinePreviewApp()
            let table = app.tables["ChatTranscriptTableView"]
            XCTAssertTrue(table.waitForExistence(timeout: 8))
            let composerBar = app.otherElements["ChatComposerBar"]
            XCTAssertTrue(composerBar.waitForExistence(timeout: 8))
            let composerField = chatComposerField(in: app)
            XCTAssertTrue(composerField.waitForExistence(timeout: 8))
            assertChatComposerControlsVisible(in: app)
            let loadedMetrics = try waitForTranscriptMetrics(table, timeout: 8) {
                $0.frameHeight > 240 && $0.frameMaxY > 300 && $0.contentHeight > $0.boundsHeight * 1.6
            }
            try scrollTranscript(table, direction: .up, timeout: 8) {
                $0.distanceFromBottom < 60
            }
            try assertChatKeyboardTracking(
                table: table,
                composerBar: composerBar,
                composerField: composerField,
                app: app,
                baselineMaxY: loadedMetrics.frameMaxY,
                scrollPosition: "bottom"
            )
        }

        do {
            let app = launchAgentChatInlinePreviewApp()
            let table = app.tables["ChatTranscriptTableView"]
            XCTAssertTrue(table.waitForExistence(timeout: 8))
            let composerBar = app.otherElements["ChatComposerBar"]
            XCTAssertTrue(composerBar.waitForExistence(timeout: 8))
            let composerField = chatComposerField(in: app)
            XCTAssertTrue(composerField.waitForExistence(timeout: 8))
            let loadedMetrics = try waitForTranscriptMetrics(table, timeout: 8) {
                $0.frameHeight > 240 && $0.frameMaxY > 300 && $0.contentHeight > $0.boundsHeight * 1.6
            }
            // Move away from the live tail before focusing the field. This is the
            // reported case: a long transcript with the current bottom content not
            // visible, then the keyboard appears.
            try scrollTranscript(table, direction: .down, timeout: 6) {
                $0.distanceFromBottom > 120 && $0.offsetY > 80
            }
            try assertChatKeyboardTracking(
                table: table,
                composerBar: composerBar,
                composerField: composerField,
                app: app,
                baselineMaxY: loadedMetrics.frameMaxY,
                scrollPosition: "middle"
            )
        }

        do {
            let app = launchAgentChatInlinePreviewApp()
            let table = app.tables["ChatTranscriptTableView"]
            XCTAssertTrue(table.waitForExistence(timeout: 8))
            let composerBar = app.otherElements["ChatComposerBar"]
            XCTAssertTrue(composerBar.waitForExistence(timeout: 8))
            let composerField = chatComposerField(in: app)
            XCTAssertTrue(composerField.waitForExistence(timeout: 8))
            let loadedMetrics = try waitForTranscriptMetrics(table, timeout: 8) {
                $0.frameHeight > 240 && $0.frameMaxY > 300 && $0.contentHeight > $0.boundsHeight * 1.6
            }
            try scrollTranscript(table, direction: .down, timeout: 8) {
                $0.offsetY < 80 && $0.contentHeight > $0.boundsHeight * 1.6
            }
            try assertChatKeyboardTracking(
                table: table,
                composerBar: composerBar,
                composerField: composerField,
                app: app,
                baselineMaxY: loadedMetrics.frameMaxY,
                scrollPosition: "top"
            )
        }
    }

    @MainActor
    func testAgentChatMiddleKeyboardVideoEvidence() throws {
        let app = launchAgentChatInlinePreviewApp(environment: [
            "CMUX_UITEST_CHAT_AUTOFOCUS_DELAY": "14.0",
            "CMUX_UITEST_CHAT_AUTO_DISMISS_DELAY": "1.25",
        ])
        let table = app.tables["ChatTranscriptTableView"]
        XCTAssertTrue(table.waitForExistence(timeout: 8))
        let composerBar = app.otherElements["ChatComposerBar"]
        XCTAssertTrue(composerBar.waitForExistence(timeout: 8))

        let loadedMetrics = try waitForTranscriptMetrics(table, timeout: 8) {
            $0.frameHeight > 240 && $0.frameMaxY > 300 && $0.contentHeight > $0.boundsHeight * 1.6
        }
        try scrollTranscript(table, direction: .down, timeout: 5) {
            $0.distanceFromBottom > 180 && $0.offsetY > 100
        }
        let beforeKeyboard = try waitForTranscriptMetrics(table, timeout: 2) {
            abs($0.frameMaxY - loadedMetrics.frameMaxY) < 4 && $0.keyboardOverlap == 0
        }

        let animationSamples = sampleKeyboardEvidenceFrames(
            table: table,
            composerBar: composerBar,
            duration: 8.0,
            frameCapturePrefix: "middle"
        )
        guard let maxOverlapIndex = animationSamples.indices.max(by: {
            animationSamples[$0].metrics.keyboardOverlap < animationSamples[$1].metrics.keyboardOverlap
        }) else {
            XCTFail("Video evidence setup did not collect keyboard animation samples")
            return
        }
        let keyboardUp = animationSamples[maxOverlapIndex].metrics
        let keyboardDown = animationSamples.suffix(from: maxOverlapIndex).reversed().first {
            $0.metrics.keyboardOverlap == 0
                && abs($0.metrics.frameMaxY - beforeKeyboard.frameMaxY) < 6
        }?.metrics

        assertChatKeyboardAnimationStayedAttached(
            animationSamples,
            scrollPosition: "middle video evidence"
        )
        assertChatKeyboardVisibleBottomStayedPinned(
            animationSamples,
            baselineVisibleBottomY: beforeKeyboard.visibleBottomY,
            scrollPosition: "middle video evidence"
        )
        assertChatKeyboardEvidenceCapturedIntermediateMotion(
            animationSamples,
            scrollPosition: "middle video evidence"
        )
        XCTAssertGreaterThan(
            keyboardUp.keyboardOverlap,
            120,
            "Video evidence setup must capture the keyboard-up state. samples=\(animationSamples)"
        )
        XCTAssertEqual(
            keyboardUp.presentationFrameMaxY,
            keyboardUp.composerPresentationMinY,
            accuracy: 4,
            "Video evidence setup must have the visible transcript bottom flush to the visible composer top with the keyboard up. \(keyboardUp)"
        )
        XCTAssertEqual(
            keyboardUp.visibleBottomY,
            beforeKeyboard.visibleBottomY,
            accuracy: 36,
            "Video evidence setup must preserve the same visible bottom content while the keyboard opens. before=\(beforeKeyboard) after=\(keyboardUp)"
        )
        guard let keyboardDown else {
            XCTFail("Video evidence setup must capture the keyboard returning down. samples=\(animationSamples)")
            return
        }
        XCTAssertEqual(
            keyboardDown.visibleBottomY,
            beforeKeyboard.visibleBottomY,
            accuracy: 36,
            "Video evidence setup must preserve visible bottom content while the keyboard hides. before=\(beforeKeyboard) after=\(keyboardDown)"
        )
    }

    @MainActor
    func testAgentChatMiddleKeyboardInterruptedShowDismissVideoEvidence() throws {
        let app = launchAgentChatInlinePreviewApp(environment: [
            "CMUX_UITEST_CHAT_AUTOFOCUS_DELAY": "14.0",
            "CMUX_UITEST_CHAT_AUTO_DISMISS_DELAY": "0.18",
        ])
        let table = app.tables["ChatTranscriptTableView"]
        XCTAssertTrue(table.waitForExistence(timeout: 8))
        let composerBar = app.otherElements["ChatComposerBar"]
        XCTAssertTrue(composerBar.waitForExistence(timeout: 8))

        let loadedMetrics = try waitForTranscriptMetrics(table, timeout: 8) {
            $0.frameHeight > 240 && $0.frameMaxY > 300 && $0.contentHeight > $0.boundsHeight * 1.6
        }
        try scrollTranscript(table, direction: .down, timeout: 5) {
            $0.distanceFromBottom > 180 && $0.offsetY > 100
        }
        let beforeKeyboard = try waitForTranscriptMetrics(table, timeout: 2) {
            abs($0.frameMaxY - loadedMetrics.frameMaxY) < 4 && $0.keyboardOverlap == 0
        }

        let animationSamples = sampleKeyboardEvidenceFrames(
            table: table,
            composerBar: composerBar,
            duration: 8.0,
            frameCapturePrefix: "middle-show-dismiss"
        )
        let maxKeyboardEvents = animationSamples.map(\.metrics.keyboardEvents).max() ?? 0
        XCTAssertGreaterThanOrEqual(
            maxKeyboardEvents,
            2,
            "Interrupted show-dismiss evidence must capture both show and dismiss transitions. samples=\(animationSamples)"
        )
        assertChatKeyboardAnimationStayedAttached(
            animationSamples,
            scrollPosition: "middle interrupted show-dismiss video evidence"
        )
        assertChatKeyboardVisibleBottomStayedPinned(
            animationSamples,
            baselineVisibleBottomY: beforeKeyboard.visibleBottomY,
            scrollPosition: "middle interrupted show-dismiss video evidence"
        )
        assertChatKeyboardMotionCapturedIntermediateSteps(
            animationSamples,
            scrollPosition: "middle interrupted show-dismiss video evidence",
            minimumDistinctFrameBuckets: 2
        )
        let maxVisibleMotion = animationSamples
            .map { activeKeyboardPresentationMotion($0.metrics) }
            .max() ?? 0
        XCTAssertGreaterThan(
            maxVisibleMotion,
            80,
            "Interrupted show-dismiss must capture partially visible keyboard motion, not only down state. samples=\(animationSamples)"
        )
        guard let keyboardDown = animationSamples.last?.metrics,
              isKeyboardDownClipSettled(keyboardDown),
              abs(keyboardDown.frameMaxY - beforeKeyboard.frameMaxY) < 8 else {
            XCTFail("Interrupted show-dismiss evidence must end with the keyboard down. samples=\(animationSamples)")
            return
        }
        XCTAssertEqual(
            keyboardDown.visibleBottomY,
            beforeKeyboard.visibleBottomY,
            accuracy: 36,
            "Interrupted show-dismiss must preserve visible bottom content. before=\(beforeKeyboard) down=\(keyboardDown)"
        )
    }

    @MainActor
    func testAgentChatMiddleKeyboardInterruptedRefocusVideoEvidence() throws {
        let app = launchAgentChatInlinePreviewApp(environment: [
            "CMUX_UITEST_CHAT_AUTOFOCUS_DELAY": "14.0",
            "CMUX_UITEST_CHAT_AUTO_DISMISS_DELAY": "1.05",
            "CMUX_UITEST_CHAT_AUTO_REFOCUS_AFTER_DISMISS_DELAY": "0.18",
        ])
        let table = app.tables["ChatTranscriptTableView"]
        XCTAssertTrue(table.waitForExistence(timeout: 8))
        let composerBar = app.otherElements["ChatComposerBar"]
        XCTAssertTrue(composerBar.waitForExistence(timeout: 8))

        let loadedMetrics = try waitForTranscriptMetrics(table, timeout: 8) {
            $0.frameHeight > 240 && $0.frameMaxY > 300 && $0.contentHeight > $0.boundsHeight * 1.6
        }
        try scrollTranscript(table, direction: .down, timeout: 5) {
            $0.distanceFromBottom > 180 && $0.offsetY > 100
        }
        let beforeKeyboard = try waitForTranscriptMetrics(table, timeout: 2) {
            abs($0.frameMaxY - loadedMetrics.frameMaxY) < 4 && $0.keyboardOverlap == 0
        }

        let animationSamples = sampleKeyboardEvidenceFrames(
            table: table,
            composerBar: composerBar,
            duration: 8.0,
            frameCapturePrefix: "middle-interrupt"
        )
        let maxKeyboardEvents = animationSamples.map(\.metrics.keyboardEvents).max() ?? 0
        XCTAssertGreaterThanOrEqual(
            maxKeyboardEvents,
            3,
            "Interrupted refocus evidence must capture show, hide, and refocus keyboard transitions. samples=\(animationSamples)"
        )
        assertChatKeyboardAnimationStayedAttached(
            animationSamples,
            scrollPosition: "middle interrupted refocus video evidence"
        )
        assertChatKeyboardVisibleBottomStayedPinned(
            animationSamples,
            baselineVisibleBottomY: beforeKeyboard.visibleBottomY,
            scrollPosition: "middle interrupted refocus video evidence"
        )
        assertChatKeyboardEvidenceCapturedIntermediateMotion(
            animationSamples,
            scrollPosition: "middle interrupted refocus video evidence"
        )
        assertChatKeyboardMotionHasNoLargeSnap(
            animationSamples,
            scrollPosition: "middle interrupted refocus video evidence"
        )
        assertChatKeyboardMotionCapturedIntermediateSteps(
            animationSamples,
            scrollPosition: "middle interrupted refocus video evidence",
            minimumVisibleMotion: 48,
            minimumDistinctFrameBuckets: 2
        )
        guard let keyboardUp = animationSamples.reversed().first(where: { $0.metrics.keyboardOverlap > 120 })?.metrics else {
            XCTFail("Interrupted refocus evidence must end with the keyboard visible. samples=\(animationSamples)")
            return
        }
        XCTAssertEqual(
            keyboardUp.visibleBottomY,
            beforeKeyboard.visibleBottomY,
            accuracy: 36,
            "Interrupted refocus must preserve the same visible bottom content. before=\(beforeKeyboard) after=\(keyboardUp)"
        )
    }

    @MainActor
    func testAgentChatMiddleKeyboardToggleVideoEvidence() throws {
        for refocusCase in [
            (delay: 0.08, prefix: "toggle-interrupt-edge", label: "middle edge interrupted hide-refocus"),
            (delay: 0.16, prefix: "toggle-interrupt-early", label: "middle early interrupted hide-refocus"),
            (delay: 0.24, prefix: "toggle-interrupt-mid", label: "middle interrupted hide-refocus"),
            (delay: 0.32, prefix: "toggle-interrupt-late", label: "middle late interrupted hide-refocus"),
            (delay: 0.44, prefix: "toggle-after-settle", label: "middle settled hide-refocus"),
        ] {
            let app = launchAgentChatInlinePreviewApp(environment: [
                "CMUX_UITEST_CHAT_AUTOFOCUS_DELAY": "14.0",
                "CMUX_UITEST_CHAT_AUTO_DISMISS_DELAY": "1.05",
                "CMUX_UITEST_CHAT_AUTO_REFOCUS_AFTER_DISMISS_DELAY": String(refocusCase.delay),
            ])
            let table = app.tables["ChatTranscriptTableView"]
            XCTAssertTrue(table.waitForExistence(timeout: 8))
            let composerBar = app.otherElements["ChatComposerBar"]
            XCTAssertTrue(composerBar.waitForExistence(timeout: 8))

            let loadedMetrics = try waitForTranscriptMetrics(table, timeout: 8) {
                $0.frameHeight > 240 && $0.frameMaxY > 300 && $0.contentHeight > $0.boundsHeight * 1.6
            }
            try scrollTranscript(table, direction: .down, timeout: 5) {
                $0.distanceFromBottom > 180 && $0.offsetY > 100
            }
            let beforeKeyboard = try waitForTranscriptMetrics(table, timeout: 2) {
                abs($0.frameMaxY - loadedMetrics.frameMaxY) < 4 && $0.keyboardOverlap == 0
            }

            let interruptedSamples = sampleKeyboardEvidenceFrames(
                table: table,
                composerBar: composerBar,
                duration: 8.0,
                frameCapturePrefix: refocusCase.prefix
            )
            let maxKeyboardEvents = interruptedSamples.map(\.metrics.keyboardEvents).max() ?? 0
            XCTAssertGreaterThanOrEqual(
                maxKeyboardEvents,
                3,
                "\(refocusCase.label) evidence must capture show, hide, and refocus keyboard transitions. samples=\(interruptedSamples)"
            )
            assertChatKeyboardAnimationStayedAttached(
                interruptedSamples,
                scrollPosition: refocusCase.label
            )
            assertChatKeyboardVisibleBottomStayedPinned(
                interruptedSamples,
                baselineVisibleBottomY: beforeKeyboard.visibleBottomY,
                scrollPosition: refocusCase.label
            )
            assertChatKeyboardMotionHasNoLargeSnap(
                interruptedSamples,
                scrollPosition: refocusCase.label
            )
            assertChatKeyboardMotionCapturedIntermediateSteps(
                interruptedSamples,
                scrollPosition: refocusCase.label,
                minimumDistinctFrameBuckets: 2
            )
            guard let refocused = interruptedSamples.last?.metrics,
                  isKeyboardUpClipSettled(refocused) else {
                XCTFail("\(refocusCase.label) evidence must end with the keyboard visible. samples=\(interruptedSamples)")
                return
            }
            XCTAssertEqual(
                refocused.visibleBottomY,
                beforeKeyboard.visibleBottomY,
                accuracy: 36,
                "\(refocusCase.label) must preserve visible bottom content. before=\(beforeKeyboard) refocused=\(refocused)"
            )
        }
    }

    @MainActor
    func testAgentChatMiddleKeyboardUserTapToggleVideoEvidence() throws {
        for refocusCase in [
            (delay: 0.10, prefix: "tap-toggle-early", label: "middle user-tap early hide-refocus"),
            (delay: 0.22, prefix: "tap-toggle-mid", label: "middle user-tap mid hide-refocus"),
            (delay: 0.34, prefix: "tap-toggle-late", label: "middle user-tap late hide-refocus"),
        ] {
            let app = launchAgentChatInlinePreviewApp()
            let table = app.tables["ChatTranscriptTableView"]
            XCTAssertTrue(table.waitForExistence(timeout: 8))
            let composerBar = app.otherElements["ChatComposerBar"]
            XCTAssertTrue(composerBar.waitForExistence(timeout: 8))
            let composerField = chatComposerField(in: app)
            XCTAssertTrue(composerField.waitForExistence(timeout: 8))

            let loadedMetrics = try waitForTranscriptMetrics(table, timeout: 8) {
                $0.frameHeight > 240 && $0.frameMaxY > 300 && $0.contentHeight > $0.boundsHeight * 1.6
            }
            try scrollTranscript(table, direction: .down, timeout: 5) {
                $0.distanceFromBottom > 180 && $0.offsetY > 100
            }
            let beforeKeyboard = try waitForTranscriptMetrics(table, timeout: 2) {
                abs($0.frameMaxY - loadedMetrics.frameMaxY) < 4 && $0.keyboardOverlap == 0
            }

            let samples = sampleKeyboardEvidenceFrames(
                table: table,
                composerBar: composerBar,
                duration: 5.0,
                frameCapturePrefix: refocusCase.prefix,
                scheduledActions: [
                    TimedKeyboardAction(delay: 0.08) {
                        _ = self.tapChatComposerField(composerField, composerBar: composerBar, in: app)
                    },
                    TimedKeyboardAction(delay: 1.10) {
                        self.tapChatTranscriptOnceForDismiss(in: app, table: table)
                    },
                    TimedKeyboardAction(delay: 1.10 + refocusCase.delay) {
                        _ = self.tapChatComposerField(composerField, composerBar: composerBar, in: app)
                    },
                ]
            )
            let maxKeyboardEvents = samples.map(\.metrics.keyboardEvents).max() ?? 0
            XCTAssertGreaterThanOrEqual(
                maxKeyboardEvents,
                3,
                "\(refocusCase.label) evidence must capture show, user tap-dismiss, and user refocus transitions. samples=\(samples)"
            )
            assertChatKeyboardAnimationStayedAttached(
                samples,
                scrollPosition: refocusCase.label
            )
            assertChatKeyboardVisibleBottomStayedPinned(
                samples,
                baselineVisibleBottomY: beforeKeyboard.visibleBottomY,
                scrollPosition: refocusCase.label
            )
            assertChatKeyboardMotionHasNoLargeSnap(
                samples,
                scrollPosition: refocusCase.label
            )
            // XCUI taps synchronize on app idleness, so this user-driven path
            // intentionally asserts the observed transition events and final
            // attachment/pinning. Dense in-flight frames come from the external
            // simulator recording used for dogfood evidence.
            guard let refocused = samples.last?.metrics,
                  isKeyboardUpClipSettled(refocused) else {
                XCTFail("\(refocusCase.label) evidence must end with the keyboard visible. samples=\(samples)")
                return
            }
            XCTAssertEqual(
                refocused.visibleBottomY,
                beforeKeyboard.visibleBottomY,
                accuracy: 36,
                "\(refocusCase.label) must preserve visible bottom content. before=\(beforeKeyboard) refocused=\(refocused)"
            )
        }
    }

    @MainActor
    func testAgentChatTopScrollEdgeUnderlapsNavigationBarEvidence() throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("Top scroll-edge underlap uses iOS 26 content scroll view registration.")
        }

        let app = launchAgentChatInlinePreviewApp()
        let table = app.tables["ChatTranscriptTableView"]
        XCTAssertTrue(table.waitForExistence(timeout: 8))
        let navigationBar = app.navigationBars.firstMatch
        XCTAssertTrue(navigationBar.waitForExistence(timeout: 8))

        let loadedMetrics = try waitForTranscriptMetrics(table, timeout: 8) {
            $0.frameHeight > 240 && $0.contentHeight > $0.boundsHeight * 1.6
        }
        let navigationFrame = navigationBar.frame
        XCTAssertLessThan(
            loadedMetrics.frameMinY,
            navigationFrame.maxY - 8,
            "The chat transcript table must extend under the navigation bar so the native top scroll-edge effect can blend content into the toolbar. metrics=\(loadedMetrics) navigationBar=\(navigationFrame)"
        )

        captureKeyboardEvidenceFrame(
            prefix: "top-edge-loaded",
            index: 0,
            startedAt: Date(),
            metrics: loadedMetrics
        )
        // Drive the transcript to the very top with XCUI scrolling (the chat
        // transcript loads anchored at the bottom; there is no app-side
        // initial-scroll seam in production source). Then re-read once the
        // momentum settles so the precise top-edge assertions run on a stable
        // frame.
        try scrollTranscript(table, direction: .down, timeout: 10) {
            abs($0.visibleTopY) <= 3
                && $0.adjustedTopInset > 20
                && $0.contentHeight > $0.boundsHeight * 1.6
        }
        let topMetrics = try waitForTranscriptMetrics(table, timeout: 4) {
            abs($0.visibleTopY) <= 3
                && $0.adjustedTopInset > 20
                && $0.contentHeight > $0.boundsHeight * 1.6
        }
        XCTAssertTrue(
            topMetrics.topContentScrollViewRegistered,
            "When the keyboard is not active, the chat transcript should remain registered as the navigation bar's top content scroll view so the normal top underlap effect works. metrics=\(topMetrics)"
        )
        XCTAssertEqual(
            topMetrics.offsetY,
            -topMetrics.adjustedTopInset,
            accuracy: 3,
            "At the beginning of the chat, UIKit's adjusted top inset must reserve the navigation chrome while the table frame still underlaps it. metrics=\(topMetrics)"
        )
        let todayHeader = app.staticTexts["ChatDateHeader"].firstMatch
        XCTAssertTrue(todayHeader.waitForExistence(timeout: 2))
        XCTAssertGreaterThanOrEqual(
            todayHeader.frame.minY,
            navigationFrame.maxY - 4,
            "The Today header must be visible below the navigation controls at top scroll. today=\(todayHeader.frame) navigationBar=\(navigationFrame)"
        )
        XCTAssertLessThanOrEqual(
            todayHeader.frame.minY,
            navigationFrame.maxY + 72,
            "The Today header should sit near the navigation chrome; a larger gap means top chrome spacing was applied as real content padding. today=\(todayHeader.frame) navigationBar=\(navigationFrame) metrics=\(topMetrics)"
        )
        captureTopScrollEdgeEvidenceFrames(table: table, prefix: "top-edge")
    }

    @MainActor
    func testAgentChatScrollToBottomButtonClearsFloatingComposer() throws {
        let app = launchAgentChatInlinePreviewApp()
        let table = app.tables["ChatTranscriptTableView"]
        XCTAssertTrue(table.waitForExistence(timeout: 8))
        let composerBar = app.otherElements["ChatComposerBar"]
        XCTAssertTrue(composerBar.waitForExistence(timeout: 8))

        try scrollTranscript(table, direction: .down, timeout: 6) {
            $0.distanceFromBottom > 180 && $0.contentHeight > $0.boundsHeight * 1.6
        }

        let button = app.buttons["ChatScrollToBottomButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 4))
        XCTAssertLessThanOrEqual(
            button.frame.maxY,
            composerBar.frame.minY - 6,
            "The scroll-to-bottom button must float above the glass composer, not underneath it. button=\(button.frame) composer=\(composerBar.frame)"
        )
        XCTAssertTrue(button.isHittable)
        button.tap()
        _ = try waitForTranscriptMetrics(table, timeout: 4) {
            $0.distanceFromBottom < 60
        }
    }

    @MainActor
    func testAgentChatTranscriptFastSwipeEvidence() throws {
        let app = launchAgentChatInlinePreviewApp(environment: [
            "CMUX_UITEST_CHAT_INITIAL_SCROLL": "middle",
        ])
        let table = app.tables["ChatTranscriptTableView"]
        XCTAssertTrue(table.waitForExistence(timeout: 8))

        let before = try waitForTranscriptMetrics(table, timeout: 8) {
            $0.frameHeight > 240
                && $0.contentHeight > $0.boundsHeight * 1.6
                && $0.offsetY > 80
                && $0.distanceFromBottom > 220
        }
        captureKeyboardEvidenceFrame(
            prefix: "scroll-deceleration-before",
            index: 0,
            startedAt: Date(),
            metrics: before
        )

        table.swipeUp(velocity: .fast)
        let afterSwipe = try waitForTranscriptMetrics(table, timeout: 1.5) {
            $0.offsetY > before.offsetY + 40
        }
        captureKeyboardEvidenceFrame(
            prefix: "scroll-deceleration-after",
            index: 0,
            startedAt: Date(),
            metrics: afterSwipe
        )
        XCTAssertGreaterThan(
            afterSwipe.offsetY,
            before.offsetY + 40,
            "A fast transcript swipe should move through the chat history instead of being swallowed by parent gesture handling. before=\(before) after=\(afterSwipe)"
        )
        XCTAssertGreaterThan(
            afterSwipe.distanceFromBottom,
            80,
            "A single fast swipe from the middle fixture must not snap to the live bottom. before=\(before) after=\(afterSwipe)"
        )
    }

    @MainActor
    func testAgentChatExpansionControlsPreserveTranscriptScrollPosition() throws {
        let app = launchAgentChatInlinePreviewApp()
        let table = app.tables["ChatTranscriptTableView"]
        XCTAssertTrue(table.waitForExistence(timeout: 8))
        _ = try waitForTranscriptMetrics(table, timeout: 8) {
            $0.frameHeight > 240 && $0.contentHeight > $0.boundsHeight * 1.6
        }

        try assertExpansionTogglePreservesTranscriptPosition(
            buttonID: "ChatToolUseToggle-msg-fixture-4",
            table: table,
            app: app
        )
        try assertExpansionTogglePreservesTranscriptPosition(
            buttonID: "ChatTerminalToggle-msg-fixture-6",
            table: table,
            app: app
        )
    }

    @MainActor
    func testAgentChatBottomScrollEdgeUnderlapsDeviceBottom() throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("Bottom scroll-edge underlap uses iOS 26 edge effects.")
        }

        let app = launchAgentChatInlinePreviewApp()
        let table = app.tables["ChatTranscriptTableView"]
        XCTAssertTrue(table.waitForExistence(timeout: 8))
        let composerBar = app.otherElements["ChatComposerBar"]
        XCTAssertTrue(composerBar.waitForExistence(timeout: 8))

        let metrics = try waitForTranscriptMetrics(table, timeout: 8) {
            $0.frameHeight > 240
                && $0.contentHeight > $0.boundsHeight * 1.6
                && $0.composerOverlayBottomInset > 40
        }
        let windowFrame = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(
            metrics.frameMaxY,
            windowFrame.maxY - 2,
            "The transcript table must physically extend to the device bottom so the bottom scroll-edge effect can continue through the safe area. metrics=\(metrics) window=\(windowFrame)"
        )
        XCTAssertGreaterThanOrEqual(
            metrics.presentationFrameMaxY,
            windowFrame.maxY - 2,
            "The rendered transcript clip must also reach the device bottom when the keyboard is down. Clipping at the composer top hides the iOS 26 bottom underlap even when the table frame is full height. metrics=\(metrics) window=\(windowFrame)"
        )
        XCTAssertLessThanOrEqual(
            composerBar.frame.maxY,
            metrics.frameMaxY - 20,
            "The transcript table should underlap the device bottom independently; the floating composer must keep its original safe-area position instead of following the table underlap. composer=\(composerBar.frame) metrics=\(metrics) window=\(windowFrame)"
        )
        XCTAssertEqual(
            metrics.frameMaxY - metrics.composerOverlayBottomInset,
            composerBar.frame.minY,
            accuracy: 8,
            "The transcript bottom inset must cover the whole obscured region from the underlapped table bottom to the floating composer's top. metrics=\(metrics) composer=\(composerBar.frame)"
        )
        XCTAssertEqual(
            metrics.adjustedBottomInset,
            metrics.composerOverlayBottomInset,
            accuracy: 4,
            "The adjusted transcript inset must equal the physical composer clearance. A larger value double-counts the device bottom safe area. metrics=\(metrics) composer=\(composerBar.frame)"
        )
    }

    @MainActor
    private func assertChatComposerControlsVisible(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let attach = app.descendants(matching: .any)["ChatComposerAttach"]
        XCTAssertTrue(
            attach.waitForExistence(timeout: 4),
            "GUI chat composer should expose the shared attachment control.",
            file: file,
            line: line
        )
        let mic = app.descendants(matching: .any)["ChatComposerMic"]
        XCTAssertTrue(
            mic.waitForExistence(timeout: 4),
            "GUI chat composer should expose the shared audio/dictation control beside attachment.",
            file: file,
            line: line
        )
    }

    @MainActor
    private func assertChatKeyboardTracking(
        table: XCUIElement,
        composerBar: XCUIElement,
        composerField: XCUIElement,
        app: XCUIApplication,
        baselineMaxY: CGFloat,
        scrollPosition: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        dismissChatKeyboard(in: app, table: table)
        let beforeKeyboard = try waitForTranscriptMetrics(table, timeout: 4) {
            abs($0.frameMaxY - baselineMaxY) < 4 && $0.frameHeight > 240
        }
        let animationSamples = focusTextInputAndSampleTranscriptAnimation(
            composerField,
            table: table,
            composerBar: composerBar,
            in: app
        )
        assertChatKeyboardAnimationStayedAttached(
            animationSamples,
            scrollPosition: scrollPosition,
            file: file,
            line: line
        )
        if beforeKeyboard.distanceFromBottom <= 40 {
            assertChatKeyboardVisibleBottomStayedPinned(
                animationSamples,
                baselineVisibleBottomY: beforeKeyboard.visibleBottomY,
                scrollPosition: scrollPosition,
                file: file,
                line: line
            )
        }
        let afterKeyboard = try waitForTranscriptMetrics(table, timeout: 6) {
            $0.keyboardOverlap > 120
                && $0.presentationFrameMaxY < beforeKeyboard.presentationFrameMaxY - 120
        }
        let metricsAttachment = XCTAttachment(
            string: "scrollPosition=\(scrollPosition)\nbefore=\(beforeKeyboard)\nafter=\(afterKeyboard)"
        )
        metricsAttachment.name = "keyboard-top-edge-metrics-\(scrollPosition)"
        metricsAttachment.lifetime = .keepAlways
        add(metricsAttachment)
        let screenshotAttachment = XCTAttachment(screenshot: app.screenshot())
        screenshotAttachment.name = "keyboard-top-edge-screenshot-\(scrollPosition)"
        screenshotAttachment.lifetime = .keepAlways
        add(screenshotAttachment)
        XCTAssertTrue(
            afterKeyboard.topEdgeEffectSoft,
            "Chat transcript must keep the iOS 26 top scroll-edge effect while the keyboard clips the transcript from \(scrollPosition). The keyboard may move the viewport, but it must not remove the top fade under the navigation chrome. before=\(beforeKeyboard) after=\(afterKeyboard)",
            file: file,
            line: line
        )
        XCTAssertTrue(
            afterKeyboard.topContentScrollViewRegistered,
            "Chat transcript must keep driving the navigation bar's top content scroll view while the keyboard clips the transcript from \(scrollPosition). Deregistering it removes the top scroll-edge treatment shown in the keyboard repro. before=\(beforeKeyboard) after=\(afterKeyboard)",
            file: file,
            line: line
        )
        XCTAssertTrue(
            afterKeyboard.bottomEdgeEffectSoft,
            "Chat transcript must keep the soft bottom scroll-edge effect while the keyboard is up from \(scrollPosition), so bottom chrome blends instead of drawing a hard separator. before=\(beforeKeyboard) after=\(afterKeyboard)",
            file: file,
            line: line
        )
        XCTAssertTrue(
            afterKeyboard.bottomEdgeElementContainerRegistered,
            "The keyboard-up shortcut row and input bar must remain registered as the bottom scroll-edge element container. Missing registration leaves a hard line between the transcript and bottom chrome. before=\(beforeKeyboard) after=\(afterKeyboard)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            afterKeyboard.frameMinY,
            beforeKeyboard.frameMinY,
            accuracy: 4,
            "Chat transcript UITableView top must stay at the visible nav underlap while the keyboard is up from \(scrollPosition). Moving the table to a negative Y keeps the flags enabled but renders the native top edge blur offscreen. before=\(beforeKeyboard) after=\(afterKeyboard)",
            file: file,
            line: line
        )
        let keyboardFrame = keyboardFrameAfterFocus(
            in: app,
            overlap: afterKeyboard.keyboardOverlap,
            file: file,
            line: line
        )
        guard let composerBarFrame = waitForUsableFrame(of: composerBar, timeout: 2) else {
            XCTFail("Chat composer bar frame unavailable after keyboard opens from \(scrollPosition)", file: file, line: line)
            return
        }
        guard let composerFieldFrame = waitForUsableFrame(of: composerField, timeout: 2) else {
            XCTFail("Chat composer field frame unavailable after keyboard opens from \(scrollPosition)", file: file, line: line)
            return
        }

        XCTAssertLessThan(
            afterKeyboard.presentationFrameMaxY,
            beforeKeyboard.presentationFrameMaxY - 120,
            "Chat transcript visible clipped bottom must move up with the keyboard from \(scrollPosition). The table frame itself stays at the top so the native top scroll-edge blur remains visible. before=\(beforeKeyboard) after=\(afterKeyboard) keyboard=\(keyboardFrame)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            afterKeyboard.frameHeight,
            beforeKeyboard.frameHeight,
            accuracy: 8,
            "Chat transcript UITableView keeps its full viewport height while the keyboard-owned clip view hides content from the top. before=\(beforeKeyboard) after=\(afterKeyboard)",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            afterKeyboard.presentationFrameMaxY,
            keyboardFrame.minY - 44,
            "Transcript table effective visible bottom should sit above the composer and keyboard from \(scrollPosition), not behind the keyboard. after=\(afterKeyboard) keyboard=\(keyboardFrame)",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            composerBarFrame.maxY,
            keyboardFrame.minY + 2,
            "Chat composer bar must stay above the keyboard from \(scrollPosition). composer=\(composerBarFrame) keyboard=\(keyboardFrame)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            afterKeyboard.presentationFrameMaxY,
            afterKeyboard.composerPresentationMinY,
            accuracy: 4,
            "Transcript table effective visible bottom must stay flush with the visible composer host top from \(scrollPosition), with no blank band between the table content and input host. after=\(afterKeyboard) composer=\(composerBarFrame) keyboard=\(keyboardFrame)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            afterKeyboard.adjustedBottomInset,
            afterKeyboard.composerOverlayBottomInset + afterKeyboard.keyboardOverlap,
            accuracy: 6,
            "Keyboard-up transcript inset must include the keyboard-clipped viewport below the composer. Otherwise bottom-pinned state can report success while the newest content is hidden. after=\(afterKeyboard)",
            file: file,
            line: line
        )
        XCTAssertGreaterThan(
            composerBarFrame.height,
            52,
            "Chat composer bar must retain usable height after keyboard opens from \(scrollPosition). composer=\(composerBarFrame)",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            composerFieldFrame.maxY,
            keyboardFrame.minY - 4,
            "Chat composer field must stay visibly above the keyboard from \(scrollPosition). field=\(composerFieldFrame) keyboard=\(keyboardFrame)",
            file: file,
            line: line
        )
        XCTAssertGreaterThan(
            composerFieldFrame.height,
            18,
            "Chat composer field must retain a usable text-entry frame after keyboard opens from \(scrollPosition). field=\(composerFieldFrame)",
            file: file,
            line: line
        )
        if beforeKeyboard.distanceFromBottom <= 40 {
            XCTAssertLessThanOrEqual(
                afterKeyboard.distanceFromBottom,
                44,
                "Bottom-pinned transcript should remain bottom-pinned while the keyboard opens. before=\(beforeKeyboard) after=\(afterKeyboard)",
                file: file,
                line: line
            )
        }
    }

    @MainActor
    private func keyboardFrameAfterFocus(
        in app: XCUIApplication,
        overlap: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> CGRect {
        let keyboard = app.keyboards.firstMatch
        if keyboard.waitForExistence(timeout: 1) {
            return keyboard.frame
        }
        let windowFrame = app.windows.firstMatch.frame
        guard overlap > 0, !windowFrame.isNull, !windowFrame.isEmpty else {
            XCTFail("Expected a keyboard element or positive keyboard overlap. overlap=\(overlap) window=\(windowFrame)", file: file, line: line)
            return .zero
        }
        return CGRect(
            x: windowFrame.minX,
            y: windowFrame.maxY - overlap,
            width: windowFrame.width,
            height: overlap
        )
    }

    /// Tapping a text field opens the system keyboard; the floating Pair
    /// button (via `.safeAreaInset(edge: .bottom)` with a gradient backdrop)
    /// must remain in the hierarchy and not jump below the keyboard. We can't
    /// reliably XCUI-test the swipe-to-dismiss path against SwiftUI's Form
    /// (the keyboard return key labels differ between iOS versions and
    /// XCUI's keyboard button lookup is fragile), so we cover the visible
    /// invariant instead and rely on manual dogfood for the dismiss gesture.
    @MainActor
    func testAddDevicePairButtonStaysVisibleWhenKeyboardOpens() throws {
        let app = launchAddDeviceApp()

        let hostField = app.textFields["MobileAddDeviceHostField"]
        XCTAssertTrue(hostField.waitForExistence(timeout: 4))
        let pairButton = app.buttons["MobilePairButton"]
        XCTAssertTrue(pairButton.waitForExistence(timeout: 4))

        hostField.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4),
                      "Tapping the host field should bring up the keyboard")

        // The pair button stays in the hierarchy when the keyboard is up,
        // proving the .safeAreaInset placement survives keyboard avoidance.
        XCTAssertTrue(pairButton.exists, "Pair button must remain in the hierarchy with keyboard up")
        XCTAssertGreaterThan(pairButton.frame.height, 30,
                             "Pair button should retain a tappable height when the keyboard is up")
    }

    @MainActor
    private func launchConnectedApp(port: UInt16, assertStatusRows: Bool = true) throws -> XCUIApplication {
        let attachURL = try attachURL(port: port)
        let app = launchApp(mockData: true, environment: [
            "CMUX_UITEST_ATTACH_URL": attachURL.absoluteString,
        ])
        waitForWorkspaceShell(in: app)
        try openSelectedWorkspaceIfNeeded(app)
        if assertStatusRows {
            assertTerminalRow(0, label: "$ cmux ios status", in: app)
            assertTerminalRow(1, label: "Mobile Core: connected", in: app)
        }
        return app
    }

    private func attachURL(port: UInt16) throws -> URL {
        let route = try CmxAttachRoute(
            id: "debug_loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: Int(port))
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "ui-test-mac",
            macDisplayName: "UI Test Mac",
            routes: [route],
            expiresAt: Date(timeIntervalSinceNow: 60 * 60),
            authToken: "ui-test-ticket"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = base64URLEncode(try encoder.encode(ticket))
        guard let url = URL(string: "cmux-ios://attach?v=\(ticket.version)&payload=\(payload)") else {
            throw URLError(.badURL)
        }
        return url
    }

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    @MainActor
    private func launchAddDeviceApp(environment: [String: String] = [:]) -> XCUIApplication {
        let app = launchApp(mockData: true, environment: environment)
        XCTAssertTrue(app.otherElements["MobileAddDeviceForm"].waitForExistence(timeout: 8))
        return app
    }

    @MainActor
    private func launchAgentChatPreviewApp() -> XCUIApplication {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_AGENT_CHAT_PREVIEW": "1",
        ])
        XCTAssertTrue(app.tables["ChatTranscriptTableView"].waitForExistence(timeout: 8))
        return app
    }

    @MainActor
    private func launchAgentChatInlinePreviewApp(environment: [String: String] = [:]) -> XCUIApplication {
        var launchEnvironment = [
            "CMUX_UITEST_AGENT_CHAT_INLINE_PREVIEW": "1",
        ]
        for (key, value) in environment {
            launchEnvironment[key] = value
        }
        let app = launchApp(mockData: false, environment: launchEnvironment)
        let table = app.tables["ChatTranscriptTableView"]
        XCTAssertTrue(table.waitForExistence(timeout: 8))
        XCTAssertTrue(
            settleChatPreviewKeyboardDown(in: app, table: table),
            "Chat preview must start keyboard-down before keyboard evidence is collected. metrics=\(String(describing: transcriptMetrics(from: table)))"
        )
        return app
    }

    @MainActor
    private func launchWorkspaceDetailDelayedTerminalPreviewApp(environment: [String: String] = [:]) -> XCUIApplication {
        var launchEnvironment = [
            "CMUX_UITEST_WORKSPACE_DETAIL_DELAYED_TERMINAL": "1",
            "CMUX_MOBILE_SOAK_OPEN_SELECTED_WORKSPACE": "1",
        ]
        for (key, value) in environment {
            launchEnvironment[key] = value
        }
        let app = launchApp(mockData: false, environment: launchEnvironment)
        XCTAssertTrue(app.buttons["MobileWorkspaceTitleMenu"].waitForExistence(timeout: 8))
        return app
    }

    @MainActor
    private func launchWorkspaceDetailCreateDelayedTerminalPreviewApp() -> XCUIApplication {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_WORKSPACE_DETAIL_CREATE_DELAYED_TERMINAL": "1",
            "CMUX_MOBILE_SOAK_OPEN_SELECTED_WORKSPACE": "1",
        ])
        if !app.buttons["MobileWorkspaceTitleMenu"].waitForExistence(timeout: 4) {
            let row = app.descendants(matching: .any)["MobileWorkspaceRow-workspace-main"]
            XCTAssertTrue(row.waitForExistence(timeout: 8))
            row.tap()
        }
        XCTAssertTrue(app.buttons["MobileWorkspaceTitleMenu"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["MobileTerminalDropdown"].waitForExistence(timeout: 8))
        return app
    }

    @MainActor
    private func launchApp(
        mockData: Bool,
        clearAuth: Bool = false,
        environment: [String: String] = [:]
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = mockData ? "1" : "0"
        for (key, value) in environment {
            app.launchEnvironment[key] = value
        }
        if clearAuth {
            app.launchEnvironment["CMUX_UITEST_CLEAR_AUTH"] = "1"
        }
        app.launch()
        return app
    }

    @MainActor
    private func openSelectedWorkspaceIfNeeded(_ app: XCUIApplication) throws {
        if app.otherElements["MobileTerminalSurface"].waitForExistence(timeout: 8) {
            return
        }

        let row = app.descendants(matching: .any)["MobileWorkspaceRow-workspace-main"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        XCTAssertTrue(app.otherElements["MobileTerminalSurface"].waitForExistence(timeout: 8))
    }

    @MainActor
    private func assertTerminalRow(
        _ index: Int,
        label expectedLabel: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let surface = app.otherElements["MobileTerminalSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 6), file: file, line: line)
        let labelExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                self.terminalRows(in: app).dropFirst(index).first == expectedLabel
            },
            object: app
        )
        let result = XCTWaiter.wait(for: [labelExpectation], timeout: 6)
        XCTAssertEqual(
            result,
            .completed,
            "Expected terminal row \(index) to equal \(expectedLabel). Rows: \(terminalRowLabels(in: app))",
            file: file,
            line: line
        )
        XCTAssertEqual(terminalRows(in: app).dropFirst(index).first, expectedLabel, file: file, line: line)
    }

    @MainActor
    private func assertTerminalRows(
        _ expectedLabels: [Int: String],
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let surface = app.otherElements["MobileTerminalSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 6), file: file, line: line)
        let labelExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                expectedLabels.allSatisfy { index, expectedLabel in
                    self.terminalRows(in: app).dropFirst(index).first == expectedLabel
                }
            },
            object: app
        )
        let result = XCTWaiter.wait(for: [labelExpectation], timeout: 6)
        if result != .completed {
            XCTFail(
                "Expected terminal rows \(expectedLabels). Rows: \(terminalRowLabels(in: app))",
                file: file,
                line: line
            )
            return
        }
        for (index, expectedLabel) in expectedLabels.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(terminalRows(in: app).dropFirst(index).first, expectedLabel, file: file, line: line)
        }
    }

    @MainActor
    private func waitForWorkspaceShell(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let workspaceRow = app.descendants(matching: .any)["MobileWorkspaceRow-workspace-main"]
        let terminalSurface = app.otherElements["MobileTerminalSurface"]
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                workspaceRow.exists || terminalSurface.exists
            },
            object: app
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: 90)
        XCTAssertEqual(result, .completed, file: file, line: line)
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
        // 20s: a saturated CI runner can take well past the old 8s default for
        // the create round-trip + the new surface (and its composer band) to
        // mount and report the selection. This is a wait-until, so a fast run
        // still returns immediately.
        let didSelect = await server.waitForSelection(
            workspaceID: workspaceID,
            terminalID: terminalID,
            timeout: 20
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
    private func assertMenuButtonDoesNotExist(
        _ identifier: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            app.buttons[identifier].exists,
            "Expected menu to exclude \(identifier).",
            file: file,
            line: line
        )
    }

    @MainActor
    private func assertToolbarOverflowButtonDoesNotExist(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let overflowButton = app.buttons["More"]
        XCTAssertFalse(
            overflowButton.exists && overflowButton.frame.minY < 140,
            "Workspace detail toolbar must not collapse into SwiftUI's overflow button.",
            file: file,
            line: line
        )
    }

    @MainActor
    private func scrollTerminalMenuToItem(
        _ terminalID: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let item = app.buttons["MobileTerminalMenuItem-\(terminalID)"]
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if item.exists, item.isHittable {
                return item
            }
            app.swipeUp(velocity: .slow)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        XCTFail("Expected terminal menu to scroll to \(terminalID).", file: file, line: line)
        return item
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
    private func assertPairingError(
        contains expectedText: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let error = app.staticTexts["MobilePairingError"]
        if !error.waitForExistence(timeout: 4) {
            app.swipeUp()
        }
        XCTAssertTrue(error.waitForExistence(timeout: 4), file: file, line: line)
        XCTAssertTrue(error.label.contains(expectedText), file: file, line: line)
    }

    @MainActor
    private func terminalRow(_ index: Int, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["MobileTerminalRow-\(index)"]
    }

    @MainActor
    private func terminalRowLabels(in app: XCUIApplication) -> [String] {
        terminalRows(in: app).enumerated().map { index, row in
            "\(index):\(row)"
        }
    }

    @MainActor
    private func terminalRows(in app: XCUIApplication) -> [String] {
        let surface = app.otherElements["MobileTerminalSurface"]
        guard surface.exists else { return [] }
        return surface.label
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    @MainActor
    private func typeText(_ text: String, into element: XCUIElement, in app: XCUIApplication) throws {
        XCTAssertTrue(element.waitForExistence(timeout: 4))
        XCTAssertTrue(focusTextInput(element, in: app), "Expected text input to accept keyboard focus: \(element.debugDescription)")
        element.typeText(text)
        dismissKeyboard(in: app, preferAddDeviceAccessoryDoneButton: isAddDeviceField(element))
    }

    @MainActor
    private func replaceText(_ text: String, in element: XCUIElement, app: XCUIApplication) throws {
        XCTAssertTrue(element.waitForExistence(timeout: 4))
        XCTAssertTrue(focusTextInput(element, in: app), "Expected text input to accept keyboard focus: \(element.debugDescription)")
        element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 80))
        element.typeText(text)
        dismissKeyboard(in: app, preferAddDeviceAccessoryDoneButton: isAddDeviceField(element))
    }

    @MainActor
    private func isAddDeviceField(_ element: XCUIElement) -> Bool {
        element.identifier.hasPrefix("MobileAddDevice")
    }

    @MainActor
    private func tap(
        _ element: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 4), file: file, line: line)
        dismissKeyboard(in: app)
        if element.isHittable {
            element.tap()
            return
        }
        guard let frame = waitForUsableFrame(of: element, timeout: 4) else {
            XCTFail("Element has no usable frame: \(element.debugDescription)", file: file, line: line)
            return
        }
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX, dy: frame.midY))
            .tap()
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

    @MainActor
    private func chatComposerField(in app: XCUIApplication) -> XCUIElement {
        let textField = app.textFields["ChatComposerField"]
        if textField.exists {
            return textField
        }
        let textView = app.textViews["ChatComposerField"]
        if textView.exists {
            return textView
        }
        return app.descendants(matching: .any)["ChatComposerField"]
    }

    @MainActor
    private func waitForUsableFrame(of element: XCUIElement, timeout: TimeInterval) -> CGRect? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let frame = element.frame
            if !frame.isNull,
               !frame.isEmpty,
               !frame.origin.x.isNaN,
               !frame.origin.y.isNaN,
               !frame.width.isNaN,
               !frame.height.isNaN {
                return frame
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let frame = element.frame
        if !frame.isNull,
           !frame.isEmpty,
           !frame.origin.x.isNaN,
           !frame.origin.y.isNaN,
           !frame.width.isNaN,
           !frame.height.isNaN {
            return frame
        }
        return nil
    }

    @MainActor
    private func waitForCompactToolbarHeightsToMatch(
        titleMenu: XCUIElement,
        backButton: XCUIElement,
        surfacePicker: XCUIElement,
        tolerance: CGFloat,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var lastTitleFrame = titleMenu.frame
        var lastBackFrame = backButton.frame
        var lastPickerFrame = surfacePicker.frame

        while Date() < deadline {
            lastTitleFrame = titleMenu.frame
            lastBackFrame = backButton.frame
            lastPickerFrame = surfacePicker.frame
            let nearbyToolbarHeight = max(lastBackFrame.height, lastPickerFrame.height)
            if lastTitleFrame.midY > 60,
               lastBackFrame.midY > 60,
               lastPickerFrame.midY > 60,
               abs(lastTitleFrame.height - nearbyToolbarHeight) <= tolerance {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        let nearbyToolbarHeight = max(lastBackFrame.height, lastPickerFrame.height)
        XCTFail(
            "Tall glyphs must not make the compact title glass taller than nearby toolbar controls. title=\(lastTitleFrame), back=\(lastBackFrame), picker=\(lastPickerFrame), delta=\(abs(lastTitleFrame.height - nearbyToolbarHeight))",
            file: file,
            line: line
        )
        return false
    }

    @MainActor
    private func assertWorkspaceToolbarVisible(
        backButton: XCUIElement,
        titleMenu: XCUIElement,
        terminalDropdown: XCUIElement,
        in app: XCUIApplication,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(backButton.waitForExistence(timeout: 4), "\(context): missing back button", file: file, line: line)
        XCTAssertTrue(titleMenu.waitForExistence(timeout: 4), "\(context): missing title menu", file: file, line: line)
        XCTAssertTrue(terminalDropdown.waitForExistence(timeout: 4), "\(context): missing terminal dropdown", file: file, line: line)
        XCTAssertTrue(
            waitForCompactToolbarHeightsToMatch(
                titleMenu: titleMenu,
                backButton: backButton,
                surfacePicker: terminalDropdown,
                tolerance: 2,
                timeout: 4,
                file: file,
                line: line
            ),
            "\(context): toolbar items must keep compact native heights",
            file: file,
            line: line
        )
    }

    @MainActor
    private func assertBackButtonFrameStaysCompactAroundPress(
        _ backButton: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let before = waitForToolbarFrame(of: backButton, timeout: 4) else {
            XCTFail("Back button has no usable frame before press", file: file, line: line)
            return
        }
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: before.midX, dy: before.midY))
        let end = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: before.midX, dy: before.midY + 90))
        start.press(forDuration: 0.25, thenDragTo: end)
        guard let after = waitForToolbarFrame(of: backButton, timeout: 4) else {
            XCTFail("Back button disappeared after press", file: file, line: line)
            return
        }
        XCTAssertLessThanOrEqual(
            after.height,
            before.height + 4,
            "Back button press must not leave an enlarged chevron/control frame. before=\(before), after=\(after)",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            after.width,
            before.width + 8,
            "Back button press must not leave a stretched rectangular control frame. before=\(before), after=\(after)",
            file: file,
            line: line
        )
    }

    @MainActor
    private func tapCompactToolbarTitleMenu(
        _ titleMenu: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(titleMenu.waitForExistence(timeout: 4), file: file, line: line)
        dismissKeyboard(in: app)
        guard let frame = waitForToolbarFrame(of: titleMenu, timeout: 4) else {
            XCTFail("Title menu has no usable frame: \(titleMenu.debugDescription)", file: file, line: line)
            return
        }
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.minX + min(24, frame.width / 2), dy: frame.midY))
            .tap()
    }

    @MainActor
    private func dismissOpenMenu(in app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    @MainActor
    private func waitForToolbarFrame(of element: XCUIElement, timeout: TimeInterval) -> CGRect? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let frame = waitForUsableFrame(of: element, timeout: 0.1),
               frame.midY > 60 {
                return frame
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return waitForUsableFrame(of: element, timeout: 0.1)
    }

    @MainActor
    private func waitForWorkspaceTitleCenteredAndSeparated(
        titleMenu: XCUIElement,
        backButton: XCUIElement,
        trailingControl: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let window = app.windows.firstMatch
        let windowFrame = window.exists ? window.frame : app.frame
        let centerTolerance = max(windowFrame.width * 0.10, 28)
        var lastTitleFrame = titleMenu.frame
        var lastBackFrame = backButton.frame
        var lastTrailingFrame = trailingControl.frame

        while Date() < deadline {
            lastTitleFrame = titleMenu.frame
            lastBackFrame = backButton.frame
            lastTrailingFrame = trailingControl.frame
            if lastTitleFrame.midY > 60,
               abs(lastTitleFrame.midX - windowFrame.midX) <= centerTolerance,
               lastTitleFrame.minX > lastBackFrame.maxX + 16,
               lastTitleFrame.maxX < lastTrailingFrame.minX - 2 {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        XCTFail(
            "Workspace title must be centered as its own toolbar island, separated from leading and trailing controls. title=\(lastTitleFrame), back=\(lastBackFrame), trailing=\(lastTrailingFrame), window=\(windowFrame)",
            file: file,
            line: line
        )
        return false
    }

    private struct ChatTranscriptMetrics: CustomStringConvertible {
        let frameMinY: CGFloat
        let frameMaxY: CGFloat
        let frameHeight: CGFloat
        let presentationFrameMaxY: CGFloat
        let boundsHeight: CGFloat
        let offsetY: CGFloat
        let adjustedTopInset: CGFloat
        let adjustedBottomInset: CGFloat
        let visibleTopY: CGFloat
        let visibleBottomY: CGFloat
        let contentHeight: CGFloat
        let distanceFromBottom: CGFloat
        let keyboardEvents: Int
        let keyboardOverlap: CGFloat
        let keyboardTargetOverlap: CGFloat
        let composerMinY: CGFloat
        let composerPresentationMinY: CGFloat
        let presentationGap: CGFloat
        let topChromeOverlayInset: CGFloat
        let composerOverlayBottomInset: CGFloat
        let keyboardAnimationActive: Bool
        let keyboardAnimationProgress: CGFloat
        let keyboardTransitionDuration: TimeInterval
        let maxAnimationPresentationGap: CGFloat
        let keyboardAnimationSamples: Int
        let topEdgeEffectSoft: Bool
        let bottomEdgeEffectSoft: Bool
        let topContentScrollViewRegistered: Bool
        let bottomEdgeElementContainerRegistered: Bool
        let scrollTracking: Bool
        let scrollDragging: Bool
        let scrollDecelerating: Bool

        var description: String {
            "frameMinY=\(frameMinY), frameMaxY=\(frameMaxY), frameHeight=\(frameHeight), presentationFrameMaxY=\(presentationFrameMaxY), boundsHeight=\(boundsHeight), offsetY=\(offsetY), adjustedTopInset=\(adjustedTopInset), adjustedBottomInset=\(adjustedBottomInset), visibleTopY=\(visibleTopY), visibleBottomY=\(visibleBottomY), contentHeight=\(contentHeight), distanceFromBottom=\(distanceFromBottom), keyboardEvents=\(keyboardEvents), keyboardOverlap=\(keyboardOverlap), keyboardTargetOverlap=\(keyboardTargetOverlap), composerMinY=\(composerMinY), composerPresentationMinY=\(composerPresentationMinY), presentationGap=\(presentationGap), topChromeOverlayInset=\(topChromeOverlayInset), composerOverlayBottomInset=\(composerOverlayBottomInset), keyboardAnimationActive=\(keyboardAnimationActive), keyboardAnimationProgress=\(keyboardAnimationProgress), keyboardTransitionDuration=\(keyboardTransitionDuration), maxAnimationPresentationGap=\(maxAnimationPresentationGap), keyboardAnimationSamples=\(keyboardAnimationSamples), topEdgeEffectSoft=\(topEdgeEffectSoft), bottomEdgeEffectSoft=\(bottomEdgeEffectSoft), topContentScrollViewRegistered=\(topContentScrollViewRegistered), bottomEdgeElementContainerRegistered=\(bottomEdgeElementContainerRegistered), scrollTracking=\(scrollTracking), scrollDragging=\(scrollDragging), scrollDecelerating=\(scrollDecelerating)"
        }

        var effectiveFrameMaxY: CGFloat {
            composerPresentationMinY
        }

        init?(_ rawValue: String) {
            var values: [String: CGFloat] = [:]
            for pair in rawValue.split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2,
                      let value = Double(parts[1]) else {
                    continue
                }
                values[String(parts[0])] = CGFloat(value)
            }
            guard let frameMinY = values["frameMinY"],
                  let frameMaxY = values["frameMaxY"],
                  let frameHeight = values["frameHeight"],
                  let boundsHeight = values["boundsHeight"],
                  let offsetY = values["offsetY"],
                  let visibleBottomY = values["visibleBottomY"],
                  let contentHeight = values["contentHeight"],
                  let distanceFromBottom = values["distanceFromBottom"] else {
                return nil
            }
            self.frameMinY = frameMinY
            self.frameMaxY = frameMaxY
            self.frameHeight = frameHeight
            self.presentationFrameMaxY = values["presentationFrameMaxY"] ?? frameMaxY
            self.boundsHeight = boundsHeight
            self.offsetY = offsetY
            self.adjustedTopInset = values["adjustedTopInset"] ?? 0
            self.adjustedBottomInset = values["adjustedBottomInset"] ?? 0
            self.visibleTopY = values["visibleTopY"] ?? offsetY
            self.visibleBottomY = visibleBottomY
            self.contentHeight = contentHeight
            self.distanceFromBottom = distanceFromBottom
            self.keyboardEvents = Int(values["keyboardEvents"] ?? 0)
            self.keyboardOverlap = values["keyboardOverlap"] ?? 0
            self.keyboardTargetOverlap = values["keyboardTargetOverlap"] ?? self.keyboardOverlap
            self.composerMinY = values["composerMinY"] ?? frameMaxY
            self.composerPresentationMinY = values["composerPresentationMinY"] ?? self.composerMinY
            self.presentationGap = values["presentationGap"] ?? 0
            self.topChromeOverlayInset = values["topChromeOverlayInset"] ?? 0
            self.composerOverlayBottomInset = values["composerOverlayBottomInset"] ?? 0
            self.keyboardAnimationActive = (values["keyboardAnimationActive"] ?? 0) >= 0.5
            self.keyboardAnimationProgress = values["keyboardAnimationProgress"] ?? 1
            self.keyboardTransitionDuration = TimeInterval(values["keyboardTransitionDuration"] ?? 0)
            self.maxAnimationPresentationGap = values["maxAnimationPresentationGap"] ?? 0
            self.keyboardAnimationSamples = Int(values["keyboardAnimationSamples"] ?? 0)
            self.topEdgeEffectSoft = (values["topEdgeEffectSoft"] ?? 0) >= 0.5
            self.bottomEdgeEffectSoft = (values["bottomEdgeEffectSoft"] ?? 0) >= 0.5
            self.topContentScrollViewRegistered = (values["topContentScrollViewRegistered"] ?? 0) >= 0.5
            self.bottomEdgeElementContainerRegistered = (values["bottomEdgeElementContainerRegistered"] ?? 0) >= 0.5
            self.scrollTracking = (values["scrollTracking"] ?? 0) >= 0.5
            self.scrollDragging = (values["scrollDragging"] ?? 0) >= 0.5
            self.scrollDecelerating = (values["scrollDecelerating"] ?? 0) >= 0.5
        }
    }

    private struct ChatKeyboardAnimationSample: CustomStringConvertible {
        let elapsed: TimeInterval
        let metrics: ChatTranscriptMetrics
        let composerFrame: CGRect?

        var visiblePresentationGap: CGFloat? {
            max(0, metrics.presentationGap)
        }

        var description: String {
            "elapsed=\(elapsed), metrics={\(metrics)}, composerFrame=\(String(describing: composerFrame)), visiblePresentationGap=\(String(describing: visiblePresentationGap))"
        }
    }

    private struct TimedKeyboardAction {
        let delay: TimeInterval
        let action: @MainActor () -> Void
    }

    @MainActor
    private func focusTextInputAndSampleTranscriptAnimation(
        _ element: XCUIElement,
        table: XCUIElement,
        composerBar: XCUIElement,
        in app: XCUIApplication,
        frameCapturePrefix: String? = nil
    ) -> [ChatKeyboardAnimationSample] {
        var samples: [ChatKeyboardAnimationSample] = []
        for _ in 0..<4 {
            if !focusTextInput(element, in: app) {
                _ = tapChatComposerField(element, composerBar: composerBar, in: app)
            }
            let deadline = Date().addingTimeInterval(1.1)
            let captureStart = Date()
            var nextCaptureTime = captureStart
            var frameIndex = 0
            var sawKeyboardTransition = false
            while Date() < deadline {
                if let metrics = transcriptMetrics(from: table) {
                    if let frameCapturePrefix, Date() >= nextCaptureTime {
                        captureKeyboardEvidenceFrame(
                            prefix: frameCapturePrefix,
                            index: frameIndex,
                            startedAt: captureStart,
                            metrics: metrics
                        )
                        frameIndex += 1
                        nextCaptureTime = Date().addingTimeInterval(0.06)
                    }
                    let elapsed = Date().timeIntervalSince(captureStart)
                    samples.append(ChatKeyboardAnimationSample(
                        elapsed: elapsed,
                        metrics: metrics,
                        composerFrame: usableFrameNow(of: composerBar)
                    ))
                    sawKeyboardTransition = sawKeyboardTransition
                        || metrics.keyboardAnimationActive
                        || metrics.keyboardOverlap > 0
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            if sawKeyboardTransition {
                return samples
            }
        }
        return samples
    }

    @MainActor
    private func sampleKeyboardEvidenceFrames(
        table: XCUIElement,
        composerBar: XCUIElement,
        duration: TimeInterval,
        frameCapturePrefix: String,
        scheduledActions: [TimedKeyboardAction] = []
    ) -> [ChatKeyboardAnimationSample] {
        var samples: [ChatKeyboardAnimationSample] = []
        let captureStart = Date()
        let deadline = captureStart.addingTimeInterval(duration)
        var nextCaptureTime = captureStart
        var frameIndex = 0
        var nextActionIndex = 0
        while Date() < deadline {
            let elapsed = Date().timeIntervalSince(captureStart)
            while nextActionIndex < scheduledActions.count,
                  elapsed >= scheduledActions[nextActionIndex].delay {
                scheduledActions[nextActionIndex].action()
                nextActionIndex += 1
            }
            if let metrics = transcriptMetrics(from: table) {
                if Date() >= nextCaptureTime {
                    captureKeyboardEvidenceFrame(
                        prefix: frameCapturePrefix,
                        index: frameIndex,
                        startedAt: captureStart,
                        metrics: metrics
                    )
                    frameIndex += 1
                    nextCaptureTime = Date().addingTimeInterval(0.08)
                }
                samples.append(ChatKeyboardAnimationSample(
                    elapsed: elapsed,
                    metrics: metrics,
                    composerFrame: usableFrameNow(of: composerBar)
                ))
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return samples
    }

    @MainActor
    private func captureKeyboardEvidenceFrame(
        prefix: String,
        index: Int,
        startedAt: Date,
        metrics: ChatTranscriptMetrics
    ) {
        let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
        let basename = String(
            format: "%@-%03d-%04dms-overlap%03.0f-gap%03.0f",
            prefix,
            index,
            elapsedMS,
            max(0, metrics.keyboardOverlap),
            max(0, metrics.presentationGap)
        )
        let screenshot = XCUIScreen.main.screenshot()
        let screenshotAttachment = XCTAttachment(screenshot: screenshot)
        screenshotAttachment.name = basename
        screenshotAttachment.lifetime = .keepAlways
        add(screenshotAttachment)

        let metricsAttachment = XCTAttachment(string: metrics.description)
        metricsAttachment.name = "\(basename).metrics"
        metricsAttachment.lifetime = .keepAlways
        add(metricsAttachment)
    }

    @MainActor
    private func captureTopScrollEdgeEvidenceFrames(table: XCUIElement, prefix: String) {
        let captureStart = Date()
        for index in 0..<8 {
            if let metrics = transcriptMetrics(from: table) {
                captureKeyboardEvidenceFrame(
                    prefix: prefix,
                    index: index,
                    startedAt: captureStart,
                    metrics: metrics
                )
            }
            if index.isMultiple(of: 2) {
                table.swipeUp(velocity: .slow)
            } else {
                table.swipeDown(velocity: .slow)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        }
    }

    @MainActor
    private func assertChatKeyboardAnimationStayedAttached(
        _ samples: [ChatKeyboardAnimationSample],
        scrollPosition: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let measured = samples.reversed().first(where: {
            isChatKeyboardVisiblyMoving($0.metrics)
        }) else {
            XCTFail(
                "Expected keyboard tracking metrics after focusing from \(scrollPosition). Samples: \(samples)",
                file: file,
                line: line
            )
            return
        }
        let activeVisibleGaps = samples
            .filter { isChatKeyboardVisiblyMoving($0.metrics) }
            .compactMap(\.visiblePresentationGap)
            .map { max(0, $0) }
        if let maxVisibleGap = activeVisibleGaps.max() {
            XCTAssertLessThanOrEqual(
                maxVisibleGap,
                8,
                "Visible transcript table bottom must stay attached to the visible composer during keyboard animation from \(scrollPosition). maxVisibleGap=\(maxVisibleGap) samples=\(samples)",
                file: file,
                line: line
            )
        }
        if measured.metrics.keyboardAnimationSamples > 0 {
            XCTAssertLessThanOrEqual(
                measured.metrics.maxAnimationPresentationGap,
                8,
                "Transcript table presentation bottom must stay attached to the composer during keyboard animation from \(scrollPosition). Metrics: \(measured)",
                file: file,
                line: line
            )
        } else {
            XCTAssertLessThanOrEqual(
                measured.metrics.presentationGap,
                8,
                "Transcript table bottom must stay attached to the composer after keyboard transition from \(scrollPosition). Metrics: \(measured)",
                file: file,
                line: line
            )
        }
    }

    @MainActor
    private func assertChatKeyboardVisibleBottomStayedPinned(
        _ samples: [ChatKeyboardAnimationSample],
        baselineVisibleBottomY: CGFloat,
        scrollPosition: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let movingSamples = samples.filter {
            isChatKeyboardVisiblyMoving($0.metrics)
        }
        guard !movingSamples.isEmpty else {
            XCTFail(
                "Keyboard evidence for \(scrollPosition) must include moving samples before visible-bottom pinning can be evaluated. samples=\(samples)",
                file: file,
                line: line
            )
            return
        }
        let largestDeviation = movingSamples
            .map { abs($0.metrics.visibleBottomY - baselineVisibleBottomY) }
            .max() ?? 0
        XCTAssertLessThanOrEqual(
            largestDeviation,
            36,
            "Visible bottom content must stay pinned while keyboard animates from \(scrollPosition). largestDeviation=\(largestDeviation) baselineVisibleBottomY=\(baselineVisibleBottomY) samples=\(samples)",
            file: file,
            line: line
        )
    }

    @MainActor
    private func assertChatKeyboardMotionHasNoLargeSnap(
        _ samples: [ChatKeyboardAnimationSample],
        scrollPosition: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let movingSamples = samples.filter {
            isChatKeyboardVisiblyMoving($0.metrics)
        }
        guard movingSamples.count >= 2 else { return }
        let frameYs = movingSamples.map(\.metrics.presentationFrameMaxY)
        guard let minFrameY = frameYs.min(), let maxFrameY = frameYs.max() else { return }
        let totalMotion = maxFrameY - minFrameY
        guard totalMotion > 80 else { return }
        let transitionLegs = Dictionary(grouping: movingSamples, by: { $0.metrics.keyboardEvents })
            .values
        for leg in transitionLegs {
            let orderedLeg = leg.sorted { $0.elapsed < $1.elapsed }
            let legFrameYs = orderedLeg.map(\.metrics.presentationFrameMaxY)
            let distinctFrameBuckets = Set(legFrameYs.map { Int(($0 / 8).rounded()) })
            guard distinctFrameBuckets.count >= 3,
                  let legMinFrameY = legFrameYs.min(),
                  let legMaxFrameY = legFrameYs.max()
            else {
                continue
            }
            let legTotalMotion = legMaxFrameY - legMinFrameY
            guard legTotalMotion > 80 else { continue }
            for (previous, next) in zip(orderedLeg, orderedLeg.dropFirst()) {
                let elapsedGap = max(next.elapsed - previous.elapsed, 1.0 / 120.0)
                guard elapsedGap <= 0.12 else { continue }
                let duration = max(
                    max(previous.metrics.keyboardTransitionDuration, next.metrics.keyboardTransitionDuration),
                    1.0 / 60.0
                )
                let expectedStep = (legTotalMotion / CGFloat(duration)) * CGFloat(elapsedGap)
                let allowedStep = min(legTotalMotion * 0.95, max(72, expectedStep * 2.5 + 32))
                let step = abs(next.metrics.presentationFrameMaxY - previous.metrics.presentationFrameMaxY)
                XCTAssertLessThanOrEqual(
                    step,
                    allowedStep,
                    "Keyboard tracking should not snap between sampled presentation frames during \(scrollPosition). event=\(previous.metrics.keyboardEvents) step=\(step) allowedStep=\(allowedStep) elapsedGap=\(elapsedGap) totalMotion=\(legTotalMotion) samples=\(samples)",
                    file: file,
                    line: line
                )
            }
        }
    }

    @MainActor
    private func assertChatKeyboardMotionCapturedIntermediateSteps(
        _ samples: [ChatKeyboardAnimationSample],
        scrollPosition: String,
        minimumVisibleMotion: CGFloat = 80,
        minimumDistinctFrameBuckets: Int = 3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let movingSamples = samples.filter {
            isChatKeyboardVisiblyMoving($0.metrics)
        }
        let frameYs = movingSamples.map(\.metrics.presentationFrameMaxY)
        guard let minY = frameYs.min(), let maxY = frameYs.max() else {
            XCTFail(
                "Keyboard tracking evidence must include moving transcript frames during \(scrollPosition). samples=\(samples)",
                file: file,
                line: line
            )
            return
        }
        let motion = maxY - minY
        XCTAssertGreaterThan(
            motion,
            minimumVisibleMotion,
            "Keyboard tracking evidence should capture visible transcript movement during \(scrollPosition), not only settled endpoints. frames=\(frameYs) samples=\(samples)",
            file: file,
            line: line
        )
        guard motion > minimumVisibleMotion else {
            return
        }
        let distinctFrameBuckets = Set(frameYs.map { Int(($0 / 8).rounded()) })
        XCTAssertGreaterThanOrEqual(
            distinctFrameBuckets.count,
            minimumDistinctFrameBuckets,
            "Keyboard tracking evidence should include multiple partial transcript positions during \(scrollPosition), not only endpoints. frames=\(frameYs) samples=\(samples)",
            file: file,
            line: line
        )
    }

    @MainActor
    private func assertChatKeyboardEvidenceCapturedIntermediateMotion(
        _ samples: [ChatKeyboardAnimationSample],
        scrollPosition: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let capturedPresentationMotion = samples.contains {
            isChatKeyboardVisiblyMoving($0.metrics)
                && activeKeyboardPresentationMotion($0.metrics) > 8
        }
        XCTAssertTrue(
            capturedPresentationMotion,
            "Keyboard evidence for \(scrollPosition) must include at least one in-flight presentation frame, not only settled states. samples=\(samples)",
            file: file,
            line: line
        )
    }

    private func isChatKeyboardVisiblyMoving(_ metrics: ChatTranscriptMetrics) -> Bool {
        metrics.keyboardAnimationActive
            || metrics.keyboardOverlap > 0
    }

    private func activeKeyboardPresentationMotion(_ metrics: ChatTranscriptMetrics) -> CGFloat {
        guard isChatKeyboardVisiblyMoving(metrics) else { return 0 }
        return abs(metrics.presentationFrameMaxY - metrics.effectiveFrameMaxY)
    }

    private func isKeyboardUpClipSettled(_ metrics: ChatTranscriptMetrics) -> Bool {
        metrics.keyboardOverlap > 120
            && abs(metrics.presentationFrameMaxY - metrics.effectiveFrameMaxY) < 4
    }

    private func isKeyboardDownClipSettled(_ metrics: ChatTranscriptMetrics) -> Bool {
        abs(metrics.keyboardOverlap) <= 0.5
            && metrics.presentationFrameMaxY >= metrics.frameMaxY - 6
    }

    private struct TranscriptMetricsWaitError: Error, CustomStringConvertible {
        let description: String
    }

    @MainActor
    private func waitForTranscriptMetrics(
        _ table: XCUIElement,
        timeout: TimeInterval,
        matching predicate: @escaping (ChatTranscriptMetrics) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ChatTranscriptMetrics {
        var lastRawValue = ""
        var lastMetrics: ChatTranscriptMetrics?
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else {
                    return false
                }
                guard let metrics = self.transcriptMetrics(from: element) else {
                    lastRawValue = String(describing: element.value)
                    return false
                }
                lastRawValue = String(describing: element.value)
                lastMetrics = metrics
                return predicate(metrics)
            },
            object: table
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        guard result == .completed, let metrics = lastMetrics else {
            let message = "Timed out waiting for transcript metrics. Last metrics: \(String(describing: lastMetrics)); raw: \(lastRawValue)"
            XCTFail(message, file: file, line: line)
            throw TranscriptMetricsWaitError(description: message)
        }
        return metrics
    }

    @MainActor
    private func transcriptMetrics(from table: XCUIElement) -> ChatTranscriptMetrics? {
        guard let rawValue = table.value as? String else { return nil }
        return ChatTranscriptMetrics(rawValue)
    }

    @MainActor
    private func usableFrameNow(of element: XCUIElement) -> CGRect? {
        let frame = element.frame
        guard !frame.isNull,
              !frame.isEmpty,
              !frame.origin.x.isNaN,
              !frame.origin.y.isNaN,
              !frame.width.isNaN,
              !frame.height.isNaN else {
            return nil
        }
        return frame
    }

    private enum TranscriptScrollDirection {
        case up
        case down
    }

    @MainActor
    @discardableResult
    private func scrollTranscript(
        _ table: XCUIElement,
        direction: TranscriptScrollDirection,
        timeout: TimeInterval,
        until predicate: @escaping (ChatTranscriptMetrics) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ChatTranscriptMetrics? {
        let deadline = Date().addingTimeInterval(timeout)
        var lastMetrics: ChatTranscriptMetrics?
        while Date() < deadline {
            if let metrics = transcriptMetrics(from: table) {
                lastMetrics = metrics
                if predicate(metrics) {
                    return metrics
                }
            }
            switch direction {
            case .up:
                table.swipeUp(velocity: .fast)
            case .down:
                table.swipeDown(velocity: .fast)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            if let metrics = transcriptMetrics(from: table) {
                lastMetrics = metrics
                if predicate(metrics) {
                    return metrics
                }
            }
        }
        if let metrics = transcriptMetrics(from: table), predicate(metrics) {
            return metrics
        }
        XCTFail(
            "Timed out scrolling transcript \(direction). Last metrics: \(String(describing: transcriptMetrics(from: table) ?? lastMetrics))",
            file: file,
            line: line
        )
        return lastMetrics
    }

    @MainActor
    private func assertExpansionTogglePreservesTranscriptPosition(
        buttonID: String,
        table: XCUIElement,
        app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let button = app.buttons[buttonID]
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, !button.isHittable {
            table.swipeDown(velocity: .fast)
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        }
        XCTAssertTrue(button.isHittable, "Expected expansion control \(buttonID) to become hittable", file: file, line: line)

        let before = try waitForTranscriptMetrics(
            table,
            timeout: 4,
            matching: { $0.distanceFromBottom > 180 && $0.contentHeight > $0.boundsHeight * 1.4 },
            file: file,
            line: line
        )
        button.tap()
        let predicate = NSPredicate(format: "value == %@", "Expanded")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: button)
        let result = XCTWaiter.wait(for: [expectation], timeout: 4)
        XCTAssertEqual(result, .completed, "Expected \(buttonID) to expand", file: file, line: line)
        let after = try waitForTranscriptMetrics(
            table,
            timeout: 4,
            matching: { $0.distanceFromBottom > 120 },
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            abs(after.visibleTopY - before.visibleTopY),
            120,
            "Tapping \(buttonID) must preserve the visible transcript region instead of jumping. before=\(before) after=\(after)",
            file: file,
            line: line
        )
        XCTAssertGreaterThan(
            after.distanceFromBottom,
            120,
            "Tapping \(buttonID) must leave the transcript away from the live tail. before=\(before) after=\(after)",
            file: file,
            line: line
        )
    }

    @MainActor
    private func focusTextInput(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<4 {
            if let frame = waitForUsableFrame(of: element, timeout: 1) {
                app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: frame.midX, dy: frame.midY))
                    .tap()
            } else {
                element.tap()
            }

            if waitForKeyboardFocus(of: element, timeout: 1) || app.keyboards.firstMatch.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return waitForKeyboardFocus(of: element, timeout: 0.5) || app.keyboards.firstMatch.exists
    }

    @MainActor
    private func settleChatPreviewKeyboardDown(in app: XCUIApplication, table: XCUIElement) -> Bool {
        let deadline = Date().addingTimeInterval(4)
        var didRequestDismiss = false
        while Date() < deadline {
            if let metrics = transcriptMetrics(from: table),
               isKeyboardDownClipSettled(metrics) {
                return true
            }
            if !didRequestDismiss {
                didRequestDismiss = true
                if app.keyboards.firstMatch.exists {
                    tapChatTranscriptOnceForDismiss(in: app, table: table)
                    dismissKeyboard(in: app)
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }

    @MainActor
    private func tapChatTranscriptOnceForDismiss(in app: XCUIApplication, table: XCUIElement) {
        if let frame = usableFrameNow(of: table) {
            let visibleTranscriptY = min(
                frame.maxY - 36,
                max(frame.minY + 24, frame.maxY - min(140, frame.height * 0.35))
            )
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.midX, dy: visibleTranscriptY))
                .tap()
        } else {
            table.tap()
        }
    }

    @MainActor
    private func tapChatComposerField(
        _ element: XCUIElement,
        composerBar: XCUIElement,
        in app: XCUIApplication
    ) -> Bool {
        if tapTextInputOnce(element, in: app) {
            return true
        }
        if let barFrame = usableFrameNow(of: composerBar) {
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(
                    dx: barFrame.midX,
                    dy: barFrame.maxY - min(50, barFrame.height * 0.45)
                ))
                .tap()
            return true
        }
        return tapTextInputOnce(element, in: app)
    }

    @MainActor
    private func tapTextInputOnce(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        if element.isHittable {
            element.tap()
            return true
        }
        if let frame = waitForUsableFrame(of: element, timeout: 1) {
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.midX, dy: frame.midY))
                .tap()
            return true
        }
        guard element.exists else { return false }
        element.tap()
        return true
    }

    @MainActor
    private func dismissChatKeyboard(in app: XCUIApplication, table: XCUIElement) {
        guard app.keyboards.firstMatch.exists else { return }
        if let frame = waitForUsableFrame(of: table, timeout: 1) {
            let visibleTranscriptY = min(
                frame.maxY - 36,
                max(frame.minY + 24, frame.maxY - min(140, frame.height * 0.35))
            )
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.midX, dy: visibleTranscriptY))
                .tap()
            if waitForKeyboardDismissal(in: app) {
                return
            }
        }
        dismissKeyboard(in: app)
    }

    @MainActor
    private func waitForKeyboardFocus(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func dismissKeyboard(
        in app: XCUIApplication,
        preferAddDeviceAccessoryDoneButton: Bool = false
    ) {
        guard app.keyboards.firstMatch.exists else {
            return
        }
        let terminalHideKeyboardButton = app.buttons["terminal.inputAccessory.hideKeyboard"]
        if terminalHideKeyboardButton.exists, terminalHideKeyboardButton.isHittable {
            terminalHideKeyboardButton.tap()
            if waitForKeyboardDismissal(in: app) {
                return
            }
        }
        if preferAddDeviceAccessoryDoneButton,
           app.buttons["MobileAddDeviceKeyboardDoneButton"].exists {
            let addDeviceDoneButton = app.buttons["MobileAddDeviceKeyboardDoneButton"]
            addDeviceDoneButton.tap()
            if waitForKeyboardDismissal(in: app) {
                return
            }
        }
        let fallbackLabels = preferAddDeviceAccessoryDoneButton
            ? ["Done", "Return", "Next"]
            : ["Done", "Next"]
        for label in fallbackLabels {
            let button = app.keyboards.buttons[label]
            if button.exists {
                button.tap()
                if waitForKeyboardDismissal(in: app) {
                    return
                }
            }
        }
    }

    // MARK: - Composer open/close repro

    /// Identifiers for the composer dock controls and the DEBUG state probes.
    private enum Composer {
        /// Toolbar compose button (`square.and.pencil`) — opens / closes / reveals.
        static let composeButton = "terminal.inputAccessory.composer"
        /// Toolbar HIDE button (`chevron.down.square`) — suppresses all bottom chrome.
        static let hideButton = "terminal.inputAccessory.hideChrome"
        /// The growing message field inside the composer band.
        static let field = "MobileComposerField"
        /// Surface-side live dock-state probe (`key=value;…`).
        static let surfaceProbe = "MobileComposerDockProbe"
        /// Store-side source-of-truth probe (`key=value;…`).
        static let storeProbe = "MobileComposerStoreProbe"
    }

    /// Parse a `key=value;key=value;…` probe value into a dictionary.
    private func parseProbe(_ value: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in value.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            out[String(kv[0])] = String(kv[1])
        }
        return out
    }

    /// Read the surface-side dock probe (live on every query) as a parsed dictionary.
    @MainActor
    private func surfaceDock(in app: XCUIApplication) -> [String: String] {
        let probe = app.descendants(matching: .any)[Composer.surfaceProbe]
        guard probe.waitForExistence(timeout: 4) else { return [:] }
        return parseProbe(probe.value as? String ?? "")
    }

    /// Read the store-side composer probe as a parsed dictionary.
    @MainActor
    private func storeComposer(in app: XCUIApplication) -> [String: String] {
        let probe = app.descendants(matching: .any)[Composer.storeProbe]
        guard probe.waitForExistence(timeout: 4) else { return [:] }
        return parseProbe(probe.value as? String ?? "")
    }

    /// Wait until the surface dock probe satisfies `predicate`, then return the parsed
    /// dock. The probe is computed live on every accessibility read, so this converges
    /// on the SETTLED post-transition state even though field focus flips a runloop
    /// after the synchronous toggle.
    @MainActor
    @discardableResult
    private func waitForDock(
        in app: XCUIApplication,
        timeout: TimeInterval = 5,
        describe: String,
        _ predicate: @escaping ([String: String]) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [String: String] {
        let probe = app.descendants(matching: .any)[Composer.surfaceProbe]
        XCTAssertTrue(probe.waitForExistence(timeout: timeout), "dock probe missing", file: file, line: line)
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak self] object, _ in
                guard let self, let element = object as? XCUIElement else { return false }
                return predicate(self.parseProbe(element.value as? String ?? ""))
            },
            object: probe
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        let dock = parseProbe(probe.value as? String ?? "")
        XCTAssertEqual(
            result,
            .completed,
            "Timed out waiting for dock: \(describe). Last surface=\(dock) store=\(storeComposer(in: app))",
            file: file,
            line: line
        )
        return dock
    }

    /// Assert the structural invariants that hold on the SIMULATOR (which has no
    /// software keyboard, so `keyboardUp`/`proxyFirstResponder` are not reliable
    /// pass/fail signals — see the keyboard-state segregation note). These are the
    /// sim-faithful "is the dock coherent?" checks:
    ///   1. surface `composerActive` mirrors store `isComposerPresented`,
    ///   2. the always-visible toolbar is visible (never stuck hidden), and
    ///   3. there is never a "band/composer up while the whole chrome is hidden" state.
    @MainActor
    private func assertDockCoherent(
        in app: XCUIApplication,
        cycle: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let surface = surfaceDock(in: app)
        let store = storeComposer(in: app)
        let composerActive = surface["composerActive"] == "1"
        let presented = store["isComposerPresented"] == "1"
        XCTAssertEqual(
            composerActive, presented,
            "cycle \(cycle): surface composerActive(\(composerActive)) must mirror store isComposerPresented(\(presented)). surface=\(surface) store=\(store)",
            file: file, line: line
        )
        XCTAssertEqual(
            surface["toolbarVisible"], "1",
            "cycle \(cycle): the always-visible toolbar must stay visible. surface=\(surface)",
            file: file, line: line
        )
        if Int(surface["renderHeight"] ?? "") ?? 0 > 0 {
            assertTerminalRenderBottomAttachedToViewport(
                surface,
                context: "cycle \(cycle)",
                file: file,
                line: line
            )
        }
        // Capture the geometry that decides hittability BEFORE asserting it (the assert
        // aborts the test under `continueAfterFailure=false`). This disambiguates the
        // two failure modes the advisor flagged:
        //   - compose-button hit-point UNDER the software keyboard frame → a SIM
        //     ARTIFACT: the surface positions the toolbar at keyboardHeight=0 (it never
        //     sees the keyboard height on the sim) while a real keyboard is drawn over
        //     it. On device the toolbar rides above the keyboard and is hittable.
        //   - compose-button clear of the keyboard but under the composer field/band →
        //     a REAL reveal-path z-order/geometry bug.
        let composeFrame = app.buttons[Composer.composeButton].frame
        let kb = app.keyboards.firstMatch
        let kbInfo = kb.exists ? "\(kb.frame)" : "absent"
        let fieldEl = app.descendants(matching: .any)[Composer.field]
        let fieldInfo = fieldEl.exists ? "\(fieldEl.frame)" : "absent"
        let windowFrame = app.windows.firstMatch.frame
        // ROOT-CAUSE ASSERTION: the compose button must be horizontally ON-SCREEN.
        // The hide→reveal reflow corrupts the accessory toolbar's leading inset
        // (`accessoryLayoutInsetsProvider` reads the surface's window-relative `minX`
        // at a moment it is wrong), shifting the whole button row ~840pt OFF-SCREEN
        // LEFT (observed composeFrame.minX ≈ -840) even though the surface still reports
        // `chromeHidden=0`/`toolbarVisible=1`. This is the real jank — NOT the keyboard
        // covering the bar (compose y is well above the keyboard) and NOT the reducer.
        XCTAssertGreaterThanOrEqual(
            composeFrame.minX, windowFrame.minX - 1,
            "cycle \(cycle): compose button shifted OFF-SCREEN LEFT (reveal-path toolbar inset corruption). composeFrame=\(composeFrame) window=\(windowFrame) keyboard=\(kbInfo) field=\(fieldInfo) surface=\(surface)",
            file: file, line: line
        )
        XCTAssertLessThanOrEqual(
            composeFrame.maxX, windowFrame.maxX + 1,
            "cycle \(cycle): compose button shifted OFF-SCREEN RIGHT. composeFrame=\(composeFrame) window=\(windowFrame) surface=\(surface)",
            file: file, line: line
        )
        XCTAssertTrue(
            app.buttons[Composer.composeButton].isHittable,
            "cycle \(cycle): compose button must stay tappable. composeFrame=\(composeFrame) keyboard=\(kbInfo) field=\(fieldInfo) surface=\(surface)",
            file: file, line: line
        )
        // Item-4 edge case: a presented composer must not be left with the chrome
        // suppressed (band up but textbox hidden), which strands the draft visually.
        XCTAssertFalse(
            composerActive && surface["chromeHidden"] == "1" && surface["toolbarVisible"] == "0",
            "cycle \(cycle): composer presented while ALL chrome is hidden (band-up/textbox-hidden stuck state). surface=\(surface)",
            file: file, line: line
        )
    }

    private func assertTerminalRenderBottomAttachedToViewport(
        _ dock: [String: String],
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let renderMaxY = Int(dock["renderMaxY"] ?? ""),
              let viewportHeight = Int(dock["viewportHeight"] ?? "") else {
            XCTFail("Missing terminal render/viewport geometry for \(context). dock=\(dock)", file: file, line: line)
            return
        }
        XCTAssertLessThanOrEqual(
            abs(renderMaxY - viewportHeight),
            2,
            "Terminal render bottom must stay attached to the live keyboard viewport for \(context). dock=\(dock)",
            file: file,
            line: line
        )
    }

    /// Repeatedly open and close the composer via the toolbar compose button and assert
    /// the dock stays coherent each cycle. This is the primary "composer jank" repro:
    /// the round-9 reducer reads `fieldFocused` synchronously, but the field's focus is
    /// set a runloop later (deferred `@FocusState`), so a fast re-tap can resolve
    /// `revealAndFocus` instead of `close` and the composer fails to close — a stuck
    /// state this asserts against.
    @MainActor
    func testComposerSurvivesRepeatedOpenCloseCycles() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        XCTAssertTrue(app.otherElements["MobileTerminalSurface"].waitForExistence(timeout: 8))

        // Baseline: the composer is OPEN BY DEFAULT for the selected terminal
        // (iMessage-style input bar), but UNFOCUSED — the keyboard stays down.
        let baseline = waitForDock(in: app, describe: "baseline: default-open composer band") {
            $0["composerActive"] == "1" && $0["bandMounted"] == "1"
        }
        XCTAssertEqual(baseline["fieldFocused"], "0", "default-open must not focus the field. \(baseline)")
        assertDockCoherent(in: app, cycle: 0)

        let composeButton = app.buttons[Composer.composeButton]
        XCTAssertTrue(composeButton.waitForExistence(timeout: 6))

        // Dismiss the default-open composer via the accessory toolbar's compose
        // toggle so the loop below exercises the explicit open→close cycle from a
        // closed dock. (The band's chevron was replaced by the attach button, so
        // close now runs through the toolbar toggle.) The default-open composer
        // is UNFOCUSED, so the first tap reveals + focuses it; the second resolves
        // `close` once it holds first responder.
        composeButton.tap()
        waitForDock(in: app, describe: "baseline: reveal focuses the default-open composer") {
            $0["composerActive"] == "1" && $0["fieldFocused"] == "1"
        }
        composeButton.tap()
        waitForDock(in: app, describe: "baseline: compose toggle dismissed the default-open composer") {
            $0["composerActive"] == "0"
        }
        assertDockCoherent(in: app, cycle: 0)

        for cycle in 1...10 {
            // OPEN: tap compose → reducer should resolve `open`, store presents,
            // surface mirrors, band mounts, and the field SETTLES to first responder.
            // Waiting for `fieldFocused=1` here isolates the steady-state close path
            // from the deferred-focus race (which the rapid-double-toggle test probes):
            // once the field is genuinely focused, a close tap MUST resolve `close`.
            //
            // NOTE: use the RAW `.tap()`, not the `tap(_:in:)` helper — that helper
            // force-dismisses the keyboard via the keyboard 'Return' key, which the
            // multi-line composer field treats as a newline (and the AX scroll-to
            // -visible on 'Return' fails fatally with `continueAfterFailure=false`).
            composeButton.tap()
            waitForDock(in: app, describe: "cycle \(cycle) OPEN: composerActive=1 && bandMounted=1 && fieldFocused=1") {
                $0["composerActive"] == "1" && $0["bandMounted"] == "1" && $0["fieldFocused"] == "1"
            }
            assertDockCoherent(in: app, cycle: cycle)
            XCTAssertTrue(
                app.descendants(matching: .any)[Composer.field].waitForExistence(timeout: 4),
                "cycle \(cycle): composer field must be present after open"
            )

            // CLOSE: tap compose again. On a genuinely visible+focused composer the
            // reducer must resolve `close` and the composer must dismiss. If the field
            // has not yet taken first responder (deferred focus), the reducer reads
            // `fieldFocused=0` and resolves `reveal` instead, leaving it stuck open —
            // that is the jank this assertion pins.
            composeButton.tap()
            let closed = waitForDock(in: app, describe: "cycle \(cycle) CLOSE: composerActive=0") {
                $0["composerActive"] == "0"
            }
            XCTAssertEqual(
                closed["lastIntent"], "close",
                "cycle \(cycle): a second compose tap on a visible composer must resolve `close`, not `\(closed["lastIntent"] ?? "?")` (deferred-focus jank). surface=\(closed) store=\(storeComposer(in: app))"
            )
            assertDockCoherent(in: app, cycle: cycle)
        }
    }

    /// The specific bug Lawrence reported: compose → hide → tap terminal (reveal) →
    /// compose must NOT lose the draft. Asserts the draft text survives the full cycle
    /// and the composer stays presented (never toggled off). Draft survival is the
    /// sim-faithful signal here (the text lives in `store.terminalInputText`).
    @MainActor
    func testComposerDraftSurvivesHideRevealCompose() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        let surface = app.otherElements["MobileTerminalSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 8))

        // OPEN + type a draft. Use the RAW `.tap()` (the `tap(_:in:)` helper would
        // force-dismiss the keyboard via 'Return', which a multi-line composer field
        // treats as a newline and which fails fatally under `continueAfterFailure`).
        let composeButton = app.buttons[Composer.composeButton]
        composeButton.tap()
        let field = app.descendants(matching: .any)[Composer.field]
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        // The field auto-focuses on appear (deferred a runloop); wait for the dock to
        // report it as first responder before typing so the keystrokes land in it.
        waitForDock(in: app, describe: "OPEN: fieldFocused=1 before typing") {
            $0["composerActive"] == "1" && $0["fieldFocused"] == "1"
        }
        let draft = "hello agent draft"
        field.typeText(draft)
        let typed = waitForDock(in: app, describe: "draft typed: store draftLength>0") { _ in
            (self.storeComposer(in: app)["draftLength"].flatMap(Int.init) ?? 0) >= draft.count
        }
        XCTAssertEqual(typed["composerActive"], "1")

        // HIDE: suppress the chrome via the HIDE button (raw tap). The composer stays
        // presented; only the chrome is suppressed; the draft must be untouched.
        app.buttons[Composer.hideButton].tap()
        let hidden = waitForDock(in: app, describe: "HIDE: chromeHidden=1, still presented") {
            $0["chromeHidden"] == "1" && $0["composerActive"] == "1"
        }
        XCTAssertEqual(hidden["composerActive"], "1", "HIDE must not dismiss the composer: \(hidden)")
        let draftAfterHide = storeComposer(in: app)["draftLength"].flatMap(Int.init) ?? -1
        XCTAssertGreaterThanOrEqual(draftAfterHide, draft.count, "draft must survive HIDE. store=\(storeComposer(in: app))")

        // REVEAL: tap the terminal surface. handleTap should reveal the chrome and
        // re-focus the composer field (presented stays true).
        surface.tap()
        waitForDock(in: app, describe: "REVEAL: chromeHidden=0, still presented") {
            $0["chromeHidden"] == "0" && $0["composerActive"] == "1"
        }
        // Assert draft survival FIRST (the survival data must be captured even if the
        // dock-coherence hittability check below aborts the test).
        XCTAssertGreaterThanOrEqual(
            storeComposer(in: app)["draftLength"].flatMap(Int.init) ?? -1, draft.count,
            "draft must survive REVEAL. store=\(storeComposer(in: app))"
        )
        assertDockCoherent(in: app, cycle: 99)

        // COMPOSE again: the historically-destructive tap. With round-9 it must resolve
        // `reveal` (presented+visible-but-unfocused) or `close`, NEVER silently dropping
        // the draft. Assert the draft text still exists no matter the intent.
        composeButton.tap()
        let afterRecompose = waitForDock(in: app, describe: "RECOMPOSE settled") { _ in true }
        let finalDraft = storeComposer(in: app)["draftLength"].flatMap(Int.init) ?? -1
        XCTAssertGreaterThanOrEqual(
            finalDraft, draft.count,
            "DRAFT LOST after compose→hide→reveal→compose. surface=\(afterRecompose) store=\(storeComposer(in: app))"
        )
    }

    /// CONTROL test for the draft test's hittability failure: open the composer, type
    /// (which draws a real software keyboard on the sim), but do NOT hide/reveal. Then
    /// assert the compose button is still hittable.
    ///
    /// This isolates the variable. If the compose button is NOT hittable here either,
    /// the cause is the drawn software keyboard covering the toolbar (the surface
    /// positions it at keyboardHeight=0 because it never sees the keyboard height on the
    /// sim) — a SIM ARTIFACT, not the reveal path. If it IS hittable here but not after
    /// hide→reveal, the reveal path is the real culprit.
    @MainActor
    func testComposerButtonHittabilityAfterTypingNoHideReveal() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        XCTAssertTrue(app.otherElements["MobileTerminalSurface"].waitForExistence(timeout: 8))

        let composeButton = app.buttons[Composer.composeButton]
        composeButton.tap()
        let field = app.descendants(matching: .any)[Composer.field]
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        waitForDock(in: app, describe: "OPEN: fieldFocused=1 before typing") {
            $0["composerActive"] == "1" && $0["fieldFocused"] == "1"
        }
        field.typeText("control")
        _ = waitForDock(in: app, describe: "typed, settled") { _ in true }

        // Same coherence check as the draft test, but with NO hide/reveal in between.
        // A failure here means the keyboard/typing — not the reveal path — drives the
        // hittability loss (sim artifact). A pass here while the draft test fails means
        // the reveal path is the real bug.
        assertDockCoherent(in: app, cycle: 1)
    }

    /// Rapid double-toggle: two compose taps with no settle in between. This is the
    /// most direct provocation of the deferred-focus race — the second tap can land
    /// before the field has taken first responder, so the reducer mis-resolves and the
    /// composer ends in an inconsistent state. Asserts surface and store agree once it
    /// settles (the dock must not be left desynced).
    @MainActor
    func testComposerRapidDoubleToggleSettlesConsistently() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        XCTAssertTrue(app.otherElements["MobileTerminalSurface"].waitForExistence(timeout: 8))
        let composeButton = app.buttons[Composer.composeButton]
        XCTAssertTrue(composeButton.waitForExistence(timeout: 6))

        for cycle in 1...5 {
            // Two taps back-to-back with no wait between them.
            composeButton.tap()
            composeButton.tap()
            // Let everything settle, then surface and store MUST agree.
            _ = waitForDock(in: app, describe: "cycle \(cycle): dock settled") { _ in true }
            let surface = surfaceDock(in: app)
            let store = storeComposer(in: app)
            XCTAssertEqual(
                surface["composerActive"], store["isComposerPresented"],
                "cycle \(cycle): rapid double-toggle left surface(\(surface["composerActive"] ?? "?")) and store(\(store["isComposerPresented"] ?? "?")) desynced. surface=\(surface) store=\(store)"
            )
            assertDockCoherent(in: app, cycle: cycle)
        }
    }

    @MainActor
    private func waitForKeyboardDismissal(in app: XCUIApplication) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let app = object as? XCUIApplication else {
                    return false
                }
                return !app.keyboards.firstMatch.exists
            },
            object: app
        )
        return XCTWaiter.wait(for: [expectation], timeout: 3) == .completed
    }
}

/// Shared definition of the deterministic color-band test pattern, used by
/// both the mock host (to emit it) and the render test (to verify it).
private enum MockColorBands {
    /// Strong, easily separated colors: red, green, blue.
    static let colors: [(r: Int, g: Int, b: Int)] = [(210, 40, 40), (40, 180, 70), (50, 90, 220)]

    /// Rows of solid color in THICK bands (``bandHeight`` rows per color)
    /// cycling through ``colors``. Each row is a run of full-block glyphs
    /// (`█`, U+2588) in a 24-bit FOREGROUND color, so every cell is filled by a
    /// real character. Foreground glyphs (unlike a background `ESC[K` fill)
    /// survive a terminal resize/reflow, so the bands stay visible as the font
    /// is zoomed (which resizes the grid). Thick bands (not 1-row stripes)
    /// stay clearly distinguishable at any cell size, and the repeating cycle
    /// means any viewport height / scroll position shows several clean bands.
    static let bandHeight = 6
    static func lines(count: Int = 96) -> [String] {
        // Wider than any phone terminal grid so the block run fills each row.
        let block = String(repeating: "\u{2588}", count: 220)
        var out: [String] = []
        out.reserveCapacity(count + 1)
        for i in 0..<count {
            let c = colors[(i / bandHeight) % colors.count]
            out.append("\u{1B}[38;2;\(c.r);\(c.g);\(c.b)m\(block)")
        }
        out.append("\u{1B}[0m")
        return out
    }
}

private final class MobileSyncMockHostServer: @unchecked Sendable {
    private struct Workspace {
        var id: String
        var title: String
        var currentDirectory: String
        var terminals: [Terminal]
    }

    private struct Terminal {
        var id: String
        var title: String
        var currentDirectory: String
        var lines: [String]
        var activeScreen: String = "primary"
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.cmux.ios-ui-tests.mobile-sync-server")
    private let createdWorkspaceTerminalDelay: TimeInterval?
    private var readyContinuation: CheckedContinuation<UInt16, Error>?
    private var connections: [NWConnection] = []
    private var selectedWorkspaceID = "workspace-main"
    private var selectedTerminalID = "terminal-build"
    private var replayCounts: [String: Int] = [:]
    private var streamOffset: UInt64 = 1
    private var workspaces: [Workspace] = [
        Workspace(
            id: "workspace-main",
            title: "cmux",
            currentDirectory: "~/cmux",
            terminals: [
                Terminal(
                    id: "terminal-build",
                    title: "Build",
                    currentDirectory: "~/cmux",
                    lines: [
                        "$ cmux ios status",
                        "Mobile Core: connected",
                        "host: UI Test Mac",
                        "route: debugLoopback",
                    ]
                ),
                Terminal(
                    id: "terminal-tui",
                    title: "TUI",
                    currentDirectory: "~/cmux",
                    lines: [
                        "LAZYGIT",
                        "files branches log",
                        "main feat-ios clean",
                        "q quit",
                    ],
                    activeScreen: "alternate"
                ),
            ]
        ),
        Workspace(
            id: "workspace-docs",
            title: "Docs",
            currentDirectory: "~/cmux/docs",
            terminals: [
                Terminal(
                    id: "terminal-notes",
                    title: "Notes",
                    currentDirectory: "~/cmux/docs",
                    lines: [
                        "$ rg CMUXMobileCore docs",
                        "docs/ios-swift-mobile-plan.md:iOS shell depends on CMUXMobileCore.",
                    ]
                ),
            ]
        ),
    ]

    init(
        defaultTerminalLines: [String]? = nil,
        additionalMainTerminalCount: Int = 0,
        createdWorkspaceTerminalDelay: TimeInterval? = nil
    ) throws {
        listener = try NWListener(using: .tcp, on: .any)
        self.createdWorkspaceTerminalDelay = createdWorkspaceTerminalDelay
        appendMainTerminals(count: additionalMainTerminalCount)
        // Optionally replace the selected terminal's content (used by the
        // color-band render test so the bands stream on attach without a flaky
        // dropdown switch).
        if let lines = defaultTerminalLines {
            workspaces[0].terminals[0].lines = lines
            workspaces[0].terminals[0].activeScreen = "primary"
        }
    }

    private func appendMainTerminals(count: Int) {
        guard count > 0 else { return }
        for index in 1...count {
            workspaces[0].terminals.append(
                Terminal(
                    id: "terminal-extra-\(index)",
                    title: "Extra Terminal \(index)",
                    currentDirectory: workspaces[0].currentDirectory,
                    lines: [
                        "$ cmux ios",
                        "workspace: \(workspaces[0].title)",
                        "terminal: Extra Terminal \(index)",
                    ]
                )
            )
        }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.readyContinuation = continuation
                self.listener.stateUpdateHandler = { [weak self] state in
                    self?.handleListenerState(state)
                }
                self.listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                self.listener.start(queue: self.queue)
            }
        }
    }

    func stop() {
        queue.async {
            self.listener.cancel()
            for connection in self.connections {
                connection.cancel()
            }
            self.connections.removeAll()
        }
    }

    func waitForSelection(
        workspaceID: String,
        terminalID: String,
        timeout: TimeInterval = 8
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let selection = await currentSelection()
            if selection.workspaceID == workspaceID,
               selection.terminalID == terminalID {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        let selection = await currentSelection()
        return selection.workspaceID == workspaceID && selection.terminalID == terminalID
    }

    func selectionDescription() async -> String {
        let selection = await currentSelection()
        return "\(selection.workspaceID)/\(selection.terminalID)"
    }

    private func currentSelection() async -> (workspaceID: String, terminalID: String) {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: (self.selectedWorkspaceID, self.selectedTerminalID))
            }
        }
    }

    func waitForReplay(
        terminalID: String,
        minimumCount: Int = 1,
        timeout: TimeInterval = 8
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = await replayCount(for: terminalID)
            if count >= minimumCount {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        return await replayCount(for: terminalID) >= minimumCount
    }

    func replayDescription() async -> String {
        await withCheckedContinuation { continuation in
            queue.async {
                let description = self.replayCounts
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key):\($0.value)" }
                    .joined(separator: ", ")
                continuation.resume(returning: description.isEmpty ? "none" : description)
            }
        }
    }

    private func replayCount(for terminalID: String) async -> Int {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.replayCounts[terminalID, default: 0])
            }
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener.port?.rawValue {
                readyContinuation?.resume(returning: port)
            } else {
                readyContinuation?.resume(throwing: serverError("Listener did not publish a port."))
            }
            readyContinuation = nil
        case let .failed(error):
            readyContinuation?.resume(throwing: error)
            readyContinuation = nil
        case .cancelled:
            readyContinuation?.resume(throwing: CancellationError())
            readyContinuation = nil
        case .setup, .waiting:
            break
        @unknown default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        receiveRequest(on: connection)
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data = Data()) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else {
                return
            }

            var nextBuffer = buffer
            if let data, !data.isEmpty {
                nextBuffer.append(data)
            }

            if let payload = Self.nextFrame(from: &nextBuffer) {
                self.respond(to: payload, on: connection, remainingBuffer: nextBuffer)
                return
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }

            self.receiveRequest(on: connection, buffer: nextBuffer)
        }
    }

    private func respond(to payload: Data, on connection: NWConnection, remainingBuffer: Data) {
        do {
            let responseFrame = try makeResponseFrame(for: payload)
            connection.send(
                content: responseFrame,
                contentContext: .defaultMessage,
                isComplete: false,
                completion: .contentProcessed { [weak self, weak connection] error in
                    guard error == nil,
                          let self,
                          let connection else {
                        connection?.cancel()
                        return
                    }
                    self.receiveRequest(on: connection, buffer: remainingBuffer)
                }
            )
        } catch {
            connection.cancel()
        }
    }

    private func makeResponseFrame(for payload: Data) throws -> Data {
        guard let request = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let method = request["method"] as? String else {
            throw serverError("Invalid request.")
        }

        let id = request["id"] as? String ?? ""
        let params = request["params"] as? [String: Any] ?? [:]
        let result: [String: Any]

        switch method {
        case "mobile.workspace.list", "workspace.list":
            result = workspaceListResult()
        case "workspace.create":
            result = createWorkspaceResult()
        case "terminal.create":
            result = createTerminalResult(params: params)
        case "mobile.events.subscribe":
            result = ["stream_id": params["stream_id"] as? String ?? "events"]
        case "mobile.host.status":
            result = mobileHostStatusResult()
        case "mobile.terminal.viewport", "terminal.viewport":
            result = [
                "columns": params["viewport_columns"] as? Int ?? 80,
                "rows": params["viewport_rows"] as? Int ?? 24,
            ]
        case "mobile.terminal.replay", "terminal.replay":
            result = terminalReplayResult(params: params)
        default:
            result = [:]
        }

        let envelope: [String: Any] = [
            "id": id,
            "ok": true,
            "result": result,
        ]
        let responsePayload = try JSONSerialization.data(withJSONObject: envelope)
        return Self.frame(responsePayload)
    }

    private func mobileHostStatusResult() -> [String: Any] {
        [
            "routes": [],
            "terminal_fidelity": "render_grid",
            "capabilities": [
                "events.v1",
                "notification.badge.v1",
                "notification.dismiss.v1",
                "notification.reconcile.v1",
                "terminal.bytes.v1",
                "terminal.render_grid.v1",
                "terminal.replay.v1",
                "terminal.viewport.v1",
                "workspace.actions.v1",
                "workspace.read_state.v1",
                "workspace.close.v1",
                "dogfood.v1",
                "workspace.groups.v1",
            ],
        ]
    }

    private func createWorkspaceResult() -> [String: Any] {
        let nextIndex = workspaces.count + 1
        let workspaceID = "workspace-\(nextIndex)"
        let terminalID = "\(workspaceID)-terminal-1"
        let terminal = Terminal(
            id: terminalID,
            title: "Terminal 1",
            currentDirectory: "~/workspace-\(nextIndex)",
            lines: [
                "$ cmux ios",
                "workspace: Workspace \(nextIndex)",
                "terminal: Terminal 1",
            ]
        )
        let workspace = Workspace(
            id: workspaceID,
            title: "Workspace \(nextIndex)",
            currentDirectory: "~/workspace-\(nextIndex)",
            terminals: createdWorkspaceTerminalDelay == nil ? [terminal] : []
        )
        workspaces.append(workspace)
        selectedWorkspaceID = workspaceID
        if createdWorkspaceTerminalDelay == nil {
            selectedTerminalID = terminalID
        } else {
            scheduleCreatedWorkspaceTerminal(terminal, workspaceID: workspaceID)
        }

        var result = workspaceListResult()
        result["created_workspace_id"] = workspaceID
        return result
    }

    private func scheduleCreatedWorkspaceTerminal(_ terminal: Terminal, workspaceID: String) {
        let delay = createdWorkspaceTerminalDelay ?? 0
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  let workspaceIndex = self.workspaces.firstIndex(where: { $0.id == workspaceID }),
                  self.workspaces[workspaceIndex].terminals.isEmpty else {
                return
            }
            self.workspaces[workspaceIndex].terminals.append(terminal)
            self.selectedWorkspaceID = workspaceID
            self.selectedTerminalID = terminal.id
            self.sendWorkspaceUpdatedEvent()
        }
    }

    private func createTerminalResult(params: [String: Any]) -> [String: Any] {
        let workspaceID = params["workspace_id"] as? String ?? selectedWorkspaceID
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            return workspaceListResult()
        }

        let terminalIndex = workspaces[workspaceIndex].terminals.count + 1
        let terminalID = "\(workspaceID)-terminal-\(terminalIndex)"
        let terminal = Terminal(
            id: terminalID,
            title: "Terminal \(terminalIndex)",
            currentDirectory: workspaces[workspaceIndex].currentDirectory,
            lines: [
                "$ cmux ios",
                "workspace: \(workspaces[workspaceIndex].title)",
                "terminal: Terminal \(terminalIndex)",
            ]
        )
        workspaces[workspaceIndex].terminals.append(terminal)
        selectedWorkspaceID = workspaceID
        selectedTerminalID = terminalID

        var result = workspaceListResult()
        result["created_terminal_id"] = terminalID
        return result
    }

    private func terminalReplayResult(params: [String: Any]) -> [String: Any] {
        let terminalID = params["surface_id"] as? String ?? selectedTerminalID
        selectedTerminalID = terminalID
        replayCounts[terminalID, default: 0] += 1
        if let workspace = workspaces.first(where: { workspace in
            workspace.terminals.contains(where: { $0.id == terminalID })
        }) {
            selectedWorkspaceID = workspace.id
        }
        let (terminal, workspaceID) = workspaces
            .lazy
            .flatMap { ws in ws.terminals.map { ($0, ws.id) } }
            .first { $0.0.id == terminalID }
            ?? (workspaces[0].terminals[0], workspaces[0].id)
        streamOffset += 1
        let bytes = terminalReplayBytes(for: terminal)
        return [
            "workspace_id": workspaceID,
            "surface_id": terminal.id,
            "seq": streamOffset,
            "data_b64": bytes.base64EncodedString(),
            "columns": 80,
            "rows": 24,
        ]
    }

    private func terminalReplayBytes(for terminal: Terminal) -> Data {
        var text = ""
        if terminal.activeScreen == "alternate" {
            text += "\u{1B}[?1049h\u{1B}[2J\u{1B}[H"
        }
        text += terminal.lines.joined(separator: "\r\n")
        text += "\r\n"
        return Data(text.utf8)
    }

    private func sendWorkspaceUpdatedEvent() {
        let envelope: [String: Any] = [
            "kind": "event",
            "topic": "workspace.updated",
            "payload": [:],
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: envelope) else {
            return
        }
        let frame = Self.frame(payload)
        for connection in connections {
            connection.send(
                content: frame,
                contentContext: .defaultMessage,
                isComplete: false,
                completion: .idempotent
            )
        }
    }

    private func workspaceListResult() -> [String: Any] {
        [
            "workspaces": workspaces.map { workspace in
                [
                    "id": workspace.id,
                    "title": workspace.title,
                    "current_directory": workspace.currentDirectory,
                    "is_selected": workspace.id == selectedWorkspaceID,
                    "terminals": workspace.terminals.map { terminal in
                        [
                            "id": terminal.id,
                            "title": terminal.title,
                            "current_directory": terminal.currentDirectory,
                            "is_focused": terminal.id == selectedTerminalID,
                        ] as [String: Any]
                    },
                ] as [String: Any]
            },
        ]
    }

    func overrideCursor(workspaceID: String, terminalID: String, row: Int, column: Int, isVisible: Bool) {
        queue.async { [weak self] in
            self?.cursorOverrides["\(workspaceID)/\(terminalID)"] = CursorOverride(row: row, column: column, isVisible: isVisible)
        }
    }

    private struct CursorOverride {
        var row: Int
        var column: Int
        var isVisible: Bool
    }
    private var cursorOverrides: [String: CursorOverride] = [:]

    private func snapshot(for terminal: Terminal, workspaceID: String) -> [String: Any] {
        let visibleRows = Array((terminal.lines + Array(repeating: "", count: 6)).prefix(6))
            .map { Self.row($0) }
        let override = cursorOverrides["\(workspaceID)/\(terminal.id)"]
        return [
            "schemaVersion": 1,
            "terminalID": terminal.id,
            "gridSize": [
                "columns": 48,
                "rows": 6,
            ],
            "activeScreen": terminal.activeScreen,
            "scrollbackRows": [],
            "visibleRows": visibleRows,
            "cursor": [
                "column": override?.column ?? 0,
                "row": override?.row ?? 5,
                "isVisible": override?.isVisible ?? false,
                "style": "block",
            ],
            "modes": [
                "bracketedPaste": false,
                "applicationCursorKeys": false,
                "applicationKeypad": false,
                "mouseTracking": terminal.activeScreen == "alternate",
                "cursorVisible": false,
            ],
            "streamOffset": streamOffset,
            "generatedAt": "1970-01-01T00:00:00Z",
        ]
    }

    private static func row(_ text: String, columns: Int = 48) -> [String: Any] {
        let visibleCells = text.prefix(columns).map { character in
            [
                "text": String(character),
                "width": "narrow",
                "style": [
                    "bold": false,
                    "italic": false,
                    "dim": false,
                    "inverse": false,
                    "underline": "none",
                ],
            ] as [String: Any]
        }
        let blankCell = [
            "text": "",
            "width": "narrow",
            "style": [
                "bold": false,
                "italic": false,
                "dim": false,
                "inverse": false,
                "underline": "none",
            ],
        ] as [String: Any]
        let cells = visibleCells + Array(repeating: blankCell, count: max(0, columns - visibleCells.count))
        return [
            "cells": cells,
            "isWrapped": false,
        ]
    }

    private static func nextFrame(from buffer: inout Data) -> Data? {
        let headerByteCount = 4
        guard buffer.count >= headerByteCount else {
            return nil
        }
        let payloadLength = Int(buffer.prefix(headerByteCount).reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        })
        guard buffer.count >= headerByteCount + payloadLength else {
            return nil
        }
        let payloadStart = headerByteCount
        let payloadEnd = payloadStart + payloadLength
        let payload = buffer.subdata(in: payloadStart..<payloadEnd)
        buffer.removeSubrange(0..<payloadEnd)
        return payload
    }

    private static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        return frame
    }

    private func serverError(_ message: String) -> NSError {
        NSError(domain: "MobileSyncMockHostServer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private extension XCUIApplication {
    var isLandscape: Bool {
        let frame = windows.firstMatch.exists ? windows.firstMatch.frame : self.frame
        return frame.width > frame.height
    }

    var isPortrait: Bool {
        let frame = windows.firstMatch.exists ? windows.firstMatch.frame : self.frame
        return frame.height > frame.width
    }
}
