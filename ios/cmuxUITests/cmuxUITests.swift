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
        let workspaceStart = Date()
        assertTerminalRows([
            1: "workspace: Workspace 3",
            2: "terminal: Terminal 1",
        ], in: app)
        XCTAssertLessThan(Date().timeIntervalSince(workspaceStart), 6.0)

        tap(app.buttons["MobileTerminalDropdown"], in: app)
        tap(app.buttons["MobileNewTerminalMenuItem"], in: app)
        let terminalStart = Date()
        assertTerminalRows([
            1: "workspace: Workspace 3",
            2: "terminal: Terminal 2",
        ], in: app)
        XCTAssertLessThan(Date().timeIntervalSince(terminalStart), 6.0)
    }

    @MainActor
    func testTerminalDropdownSwitchesToAlternateScreenSnapshot() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        try openSelectedWorkspaceIfNeeded(app)

        tap(app.buttons["MobileTerminalDropdown"], in: app)
        tap(app.buttons["MobileTerminalMenuItem-terminal-tui"], in: app)

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
        try switchToTUITerminal(in: app)

        XCUIDevice.shared.orientation = .portrait
        let portraitFrame = try waitForTerminalSurfaceFrame(in: app) { frame in
            frame.height > frame.width
        }
        assertTerminalSurfaceUsesAvailableViewport(portraitFrame, in: app)
        assertTerminalRow(0, label: "LAZYGIT", in: app)

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
        assertTerminalRow(0, label: "LAZYGIT", in: app)
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
            // pixels; garbled => not uniform.
            let enoughBands = (distinct >= 2 && strong.count >= 6)
                || (distinct == 1 && strong.count >= 16)
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
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        tap(app.buttons["MobileTerminalDropdown"], in: app, file: file, line: line)
        tap(app.buttons["MobileTerminalMenuItem-terminal-tui"], in: app, file: file, line: line)
        assertTerminalRow(0, label: "LAZYGIT", in: app, file: file, line: line)
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
        dismissKeyboard(in: app, preferAddDeviceAccessoryDoneButton: true)
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
        if preferAddDeviceAccessoryDoneButton,
           app.buttons["MobileAddDeviceKeyboardDoneButton"].exists {
            let addDeviceDoneButton = app.buttons["MobileAddDeviceKeyboardDoneButton"]
            addDeviceDoneButton.tap()
            if waitForKeyboardDismissal(in: app) {
                return
            }
        }
        for label in ["Done", "Return", "Next"] {
            let button = app.keyboards.buttons[label]
            if button.exists {
                button.tap()
                if waitForKeyboardDismissal(in: app) {
                    return
                }
            }
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
    private var readyContinuation: CheckedContinuation<UInt16, Error>?
    private var connections: [NWConnection] = []
    private var selectedWorkspaceID = "workspace-main"
    private var selectedTerminalID = "terminal-build"
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

    init(defaultTerminalLines: [String]? = nil) throws {
        listener = try NWListener(using: .tcp, on: .any)
        // Optionally replace the selected terminal's content (used by the
        // color-band render test so the bands stream on attach without a flaky
        // dropdown switch).
        if let lines = defaultTerminalLines {
            workspaces[0].terminals[0].lines = lines
            workspaces[0].terminals[0].activeScreen = "primary"
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
        case "workspace.list":
            result = workspaceListResult()
        case "workspace.create":
            result = createWorkspaceResult()
        case "terminal.create":
            result = createTerminalResult(params: params)
        case "mobile.events.subscribe":
            result = ["stream_id": params["stream_id"] as? String ?? "events"]
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

    private func createWorkspaceResult() -> [String: Any] {
        let nextIndex = workspaces.count + 1
        let workspaceID = "workspace-\(nextIndex)"
        let terminalID = "\(workspaceID)-terminal-1"
        let workspace = Workspace(
            id: workspaceID,
            title: "Workspace \(nextIndex)",
            currentDirectory: "~/workspace-\(nextIndex)",
            terminals: [
                Terminal(
                    id: terminalID,
                    title: "Terminal 1",
                    currentDirectory: "~/workspace-\(nextIndex)",
                    lines: [
                        "$ cmux ios",
                        "workspace: Workspace \(nextIndex)",
                        "terminal: Terminal 1",
                    ]
                ),
            ]
        )
        workspaces.append(workspace)
        selectedWorkspaceID = workspaceID
        selectedTerminalID = terminalID

        var result = workspaceListResult()
        result["created_workspace_id"] = workspaceID
        return result
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
