import XCTest
import Foundation
import CoreGraphics
import ImageIO
import Darwin

final class AutomationSocketUITests: XCTestCase {
    private var socketPath = ""
    private var diagnosticsPath = ""
    private let defaultsDomain = "com.cmuxterm.app.debug"
    private let modeKey = "socketControlMode"
    private let legacyKey = "socketControlEnabled"
    private var launchTag = ""
    private var temporaryRoots: [URL] = []

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-debug-\(UUID().uuidString).sock"
        diagnosticsPath = "/tmp/cmux-ui-test-automation-socket-\(UUID().uuidString).json"
        launchTag = "ui-tests-automation-\(UUID().uuidString.prefix(8))"
        temporaryRoots = []
        resetSocketDefaults()
        removeSocketFile()
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
        try? FileManager.default.removeItem(atPath: taggedSocketPath())
    }

    override func tearDown() {
        removeSocketFile()
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
        try? FileManager.default.removeItem(atPath: taggedSocketPath())
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots = []
        super.tearDown()
    }

    func testSocketToggleDisablesAndEnables() {
        let app = configuredApp(mode: "cmuxOnly")
        app.launch()
        XCTAssertTrue(
            ensureRunningAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for socket toggle test. state=\(app.state.rawValue)"
        )

        guard let resolvedPath = resolveSocketPath(timeout: 5.0, allowTmpFallback: false) else {
            XCTFail("Expected control socket to exist")
            return
        }
        socketPath = resolvedPath
        XCTAssertTrue(waitForSocket(exists: true, timeout: 2.0))
        app.terminate()
    }

    func testSocketPathDeletionRecreatesListener() throws {
        let app = configuredApp(mode: "automation")
        app.launch()
        XCTAssertTrue(
            ensureRunningAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for socket path recreation test. state=\(app.state.rawValue)"
        )

        guard let resolvedPath = resolveSocketPath(timeout: 5.0, allowTmpFallback: false) else {
            XCTFail("Expected control socket to exist")
            return
        }
        socketPath = resolvedPath
        XCTAssertTrue(waitForSocketPong(timeout: 5.0), "Expected initial socket ping at \(socketPath)")

        try FileManager.default.removeItem(atPath: socketPath)

        XCTAssertTrue(
            waitForSocketPong(timeout: 8.0, allowDiagnosticsFallback: false),
            "Expected listener to recreate removed socket path and answer ping at \(socketPath)"
        )
        app.terminate()
    }

    func testSimulateShortcutPlainCharacterKeepsAppAlive() throws {
        let app = configuredApp(mode: "cmuxOnly")
        // Backgrounded apps on CI runners get App Nap throttled and can stall
        // main-thread hops indefinitely; simulate_shortcut replies after a main hop.
        app.launchArguments += ["-NSAppSleepDisabled", "YES"]
        app.launch()
        XCTAssertTrue(
            ensureRunningAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for plain-char simulation test. state=\(app.state.rawValue)"
        )

        guard let resolvedPath = resolveSocketPath(timeout: 5.0, allowTmpFallback: false) else {
            XCTFail("Expected control socket to exist")
            return
        }
        socketPath = resolvedPath
        XCTAssertTrue(waitForSocketPong(timeout: 5.0), "Expected socket ping at \(socketPath)")

        // Backgrounded apps service main-thread hops slowly (multi-second), and
        // simulate_shortcut dispatches on the main thread, so activate first and
        // give the reply a generous timeout; ping is not a main-hop and stays fast.
        app.activate()

        // First launch on a clean runner can wedge the main thread for a long
        // time (session restore, network timeouts). Prove a main-hop round trip
        // completes before measuring the interesting command.
        var mainHopReady = false
        for _ in 0..<12 {
            if ControlSocketClient(path: socketPath, responseTimeout: 10.0)
                .sendLine("activate_app") == "OK" {
                mainHopReady = true
                break
            }
        }
        try XCTSkipUnless(
            mainHopReady,
            "Main thread never serviced a socket hop on this host; main-hop verbs cannot be exercised here"
        )

        // A modifier-less key is not consumed as a shortcut, so it runs the full
        // keyDown -> interpretKeyEvents pipeline. Synthetic events built without
        // CGEvent backing make NSTextInputContext raise there, which terminated
        // the app mid-reply (socket closed, no crash report).
        let reply = ControlSocketClient(path: socketPath, responseTimeout: 30.0)
            .sendLine("simulate_shortcut x")

        // Liveness first so a regression reads as "app died", not as a nil-reply
        // timeout; only then require the OK reply.
        XCTAssertNotEqual(
            app.state, .notRunning,
            "App died processing plain-char simulation (CGEvent-less crash regressed). reply=\(reply ?? "nil")"
        )
        XCTAssertTrue(
            waitForSocketPong(timeout: 10.0),
            "Socket must still answer after plain-char simulation. reply=\(reply ?? "nil") state=\(app.state.rawValue)"
        )
        XCTAssertEqual(reply, "OK", "simulate_shortcut x should reply OK. state=\(app.state.rawValue)")
        app.terminate()
    }

    func testSocketDisabledWhenSettingOff() {
        let app = configuredApp(mode: "off")
        app.launch()
        XCTAssertTrue(
            ensureRunningAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for socket off test. state=\(app.state.rawValue)"
        )

        XCTAssertTrue(waitForSocket(exists: false, timeout: 3.0))
        app.terminate()
    }

    func testCaffeineMenuAndSocketShareState() throws {
        let app = configuredApp(mode: "allowAll")
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-NSAppSleepDisabled", "YES"
        ]
        launchAllowingHeadlessBackground(app)
        defer {
            _ = socketResult(
                method: "caffeine.set",
                params: ["enabled": false]
            )
            app.terminate()
        }

        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected the app to launch for caffeine menu verification"
        )
        XCTAssertTrue(
            waitForSocketPong(timeout: 12.0),
            "Expected a control socket for caffeine verification"
        )
        XCTAssertEqual(
            socketResult(method: "caffeine.status", params: [:])?["enabled"] as? Bool,
            false
        )

        clickKeepMacAwakeMenu(in: app)

        let enabled = waitForJSON(timeout: 5.0) {
            guard self.socketResult(
                method: "caffeine.status",
                params: [:]
            )?["enabled"] as? Bool == true else { return nil }
            return ["enabled": true]
        }
        XCTAssertNotNil(enabled, "Expected the menu to enable the shared caffeine controller")

        XCTAssertEqual(
            socketResult(
                method: "caffeine.set",
                params: ["enabled": false]
            )?["enabled"] as? Bool,
            false
        )
        XCTAssertEqual(
            socketResult(method: "caffeine.status", params: [:])?["enabled"] as? Bool,
            false
        )
    }

    func testTextBoxSkillMentionFiltersWhenTypingAfterBareDollarTrigger() throws {
        let skillRoot = try makeSkillFixtureRoot(
            skillNames: [
                "agent-browser",
                "agent-cli-integration",
                "iterate-pr",
            ]
        )
        let app = XCUIApplication.cmuxTestApplication()
        configureTextBoxMentionLaunchEnvironment(app)
        defer { app.terminate() }
        app.launch()

        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for textbox mention test. state=\(app.state.rawValue)"
        )
        XCTAssertTrue(
            waitForSocketPong(timeout: 12.0),
            "Expected socket ping at \(socketPath). diagnostics=\(loadDiagnostics())"
        )

        let workspace = try XCTUnwrap(
            socketResult(
                method: "workspace.create",
                params: [
                    "title": "Textbox mention XCUITest",
                    "working_directory": skillRoot.path,
                    "focus": true,
                ]
            ),
            "Expected workspace.create to succeed"
        )
        let surfaceID = try XCTUnwrap(workspace["surface_id"] as? String, "Expected created surface id")

        _ = try XCTUnwrap(
            waitForTextBoxFixture(surfaceID: surfaceID, beforeText: "$", timeout: 8.0),
            "Expected text box fixture to mount with a bare $ trigger"
        )
        _ = try XCTUnwrap(
            socketResult(
                method: "debug.textbox.interact",
                params: ["surface_id": surfaceID, "action": "focus"]
            ),
            "Expected text box focus to succeed"
        )

        let bareState = try XCTUnwrap(
            waitForMentionState(surfaceID: surfaceID, timeout: 8.0) { state in
                let titles = state["mention_titles"] as? [String] ?? []
                return state["mention_trigger"] as? String == "$" &&
                    state["mention_query"] as? String == "" &&
                    titles.contains("$agent-browser")
            },
            "Expected bare $ suggestions to include $agent-browser"
        )
        XCTAssertEqual(bareState["plain_text"] as? String, "$")

        app.typeText("iterate")

        let typedState = try XCTUnwrap(
            waitForMentionState(surfaceID: surfaceID, timeout: 8.0) { state in
                let titles = state["mention_titles"] as? [String] ?? []
                return state["plain_text"] as? String == "$iterate" &&
                    state["mention_trigger"] as? String == "$" &&
                    state["mention_query"] as? String == "iterate" &&
                    state["mention_current"] as? Bool == true &&
                    titles.contains("$iterate-pr") &&
                    !titles.contains("$agent-browser")
            },
            "Expected typing iterate after bare $ to filter stale $agent-browser and show $iterate-pr"
        )

        let typedTitles = typedState["mention_titles"] as? [String] ?? []
        XCTAssertEqual(typedTitles.first, "$iterate-pr")
    }

    func testWindowScreenshotCommandWritesNonBlankPNGWithTerminalAndBrowserContent() throws {
        let app = configuredApp(mode: "allowAll")
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-NSAppSleepDisabled", "YES",
        ]
        defer { app.terminate() }

        launchAllowingHeadlessBackground(app)
        XCTAssertTrue(
            ensureRunningAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for the window screenshot test. state=\(app.state.rawValue)"
        )
        XCTAssertTrue(
            waitForSocketPong(timeout: 12.0),
            "Expected socket ping at \(socketPath). diagnostics=\(loadDiagnostics())"
        )

        let marker = "CMUX_SCREENSHOT_MARKER_9065"
        let markerCommand = """
        i=0; while [ $i -lt 8 ]; do printf '\\033[48;2;245;40;210m%-80s\\033[0m\\n' '\(marker)'; i=$((i+1)); done; tail -f /dev/null
        """
        let workspace = try XCTUnwrap(
            socketResult(
                method: "workspace.create",
                params: [
                    "title": "Window screenshot regression",
                    "initial_command": markerCommand,
                    "focus": true,
                ]
            ),
            "Expected workspace.create to return the marker terminal"
        )
        let surfaceID = try XCTUnwrap(
            workspace["surface_id"] as? String,
            "Expected workspace.create to return a surface id"
        )
        let workspaceID = try XCTUnwrap(
            workspace["workspace_id"] as? String,
            "Expected workspace.create to return a workspace id"
        )
        XCTAssertTrue(
            waitForTerminalText(marker, surfaceID: surfaceID, timeout: 12.0),
            "Expected marker text to render before taking the screenshot"
        )
        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 5.0),
            "Expected the main window to exist before taking the screenshot"
        )

        let terminalOnlyCapture = try XCTUnwrap(
            waitForWindowScreenshotContainingMarker(
                label: "issue-9065-terminal-only",
                minimumMarkerPixels: 100,
                minimumBrowserPixels: 0,
                timeout: 30.0
            ),
            "Expected the screenshot command to capture terminal-only window content"
        )
        XCTAssertGreaterThan(
            terminalOnlyCapture.stats.markerPixels,
            100,
            "Expected the terminal-only screenshot to include the magenta marker"
        )

        let browserHTML = """
        <!doctype html>
        <html>
          <body style="margin:0;min-height:100vh;background:rgb(20,220,240)">
            <h1>CMUX_BROWSER_SCREENSHOT_MARKER_9065</h1>
          </body>
        </html>
        """
        let browserURL = "data:text/html;base64,\(Data(browserHTML.utf8).base64EncodedString())"
        let browser = try XCTUnwrap(
            socketResult(
                method: "browser.open_split",
                params: [
                    "workspace_id": workspaceID,
                    "surface_id": surfaceID,
                ],
                responseTimeout: 10.0
            ),
            "Expected browser.open_split to create a browser panel"
        )
        let browserSurfaceID = try XCTUnwrap(
            browser["surface_id"] as? String,
            "Expected browser.open_split to return a surface id"
        )
        XCTAssertNotNil(
            socketResult(
                method: "browser.navigate",
                params: [
                    "surface_id": browserSurfaceID,
                    "url": browserURL,
                ],
                responseTimeout: 12.0
            ),
            "Expected the browser marker page to navigate"
        )
        XCTAssertNotNil(
            socketResult(
                method: "browser.wait",
                params: [
                    "surface_id": browserSurfaceID,
                    "load_state": "complete",
                    "timeout_ms": 10_000,
                ],
                responseTimeout: 12.0
            ),
            "Expected the browser marker page to finish loading"
        )

        let captured = try XCTUnwrap(
            waitForWindowScreenshotContainingMarker(
                label: "issue-9065-window",
                minimumMarkerPixels: 100,
                minimumBrowserPixels: 1_000,
                timeout: 30.0
            ),
            "Expected debug.window.screenshot to capture terminal and browser content"
        )
        let pngData = captured.pngData
        XCTAssertGreaterThan(pngData.count, 1_024, "Expected a non-empty PNG file")
        XCTAssertTrue(
            pngData.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
            "Expected the screenshot command to write PNG data"
        )

        let stats = captured.stats
        XCTAssertGreaterThan(stats.width, 500, "Expected a main-window-sized screenshot")
        XCTAssertGreaterThan(stats.height, 300, "Expected a main-window-sized screenshot")
        XCTAssertGreaterThan(
            stats.uniqueQuantizedColors,
            8,
            "Expected a non-blank, non-solid main window screenshot"
        )
        XCTAssertGreaterThan(
            stats.markerPixels,
            100,
            "Expected the screenshot to include the terminal's magenta marker content"
        )
        XCTAssertGreaterThan(
            stats.browserPixels,
            1_000,
            "Expected the screenshot to include the browser's cyan marker content"
        )
    }

    private struct WindowScreenshotPixelStats {
        let width: Int
        let height: Int
        let uniqueQuantizedColors: Int
        let markerPixels: Int
        let browserPixels: Int
    }

    private struct CapturedWindowScreenshot {
        let pngData: Data
        let stats: WindowScreenshotPixelStats
    }

    private func waitForTerminalText(
        _ expectedText: String,
        surfaceID: String,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                if let result = self.socketResult(
                    method: "surface.read_text",
                    params: ["surface_id": surfaceID]
                ),
                   let text = result["text"] as? String,
                   text.contains(expectedText) {
                    return true
                }
                return false
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForWindowScreenshotContainingMarker(
        label: String,
        minimumMarkerPixels: Int,
        minimumBrowserPixels: Int,
        timeout: TimeInterval
    ) -> CapturedWindowScreenshot? {
        var captured: CapturedWindowScreenshot?
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard let screenshot = self.socketResult(
                    method: "debug.window.screenshot",
                    params: ["label": label],
                    // Two independently bounded backend waits can total ten
                    // seconds; the outer wait leaves room for another poll.
                    responseTimeout: 11.0,
                    allowsReplayFallback: false
                ),
                    let path = screenshot["path"] as? String else {
                    return false
                }

                let screenshotURL = URL(fileURLWithPath: path)
                defer { try? FileManager.default.removeItem(at: screenshotURL) }
                guard let pngData = try? Data(contentsOf: screenshotURL),
                      let stats = self.windowScreenshotPixelStats(pngData),
                      stats.markerPixels > minimumMarkerPixels,
                      stats.browserPixels >= minimumBrowserPixels else {
                    return false
                }

                captured = CapturedWindowScreenshot(pngData: pngData, stats: stats)
                return true
            },
            object: NSObject()
        )
        guard XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed else {
            return nil
        }
        return captured
    }

    private func windowScreenshotPixelStats(_ pngData: Data) -> WindowScreenshotPixelStats? {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let decoded = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                          | CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard decoded else { return nil }

        var uniqueQuantizedColors = Set<UInt16>()
        var markerPixels = 0
        var browserPixels = 0
        let sampleStep = 2
        for y in stride(from: 0, to: height, by: sampleStep) {
            let row = y * bytesPerRow
            for x in stride(from: 0, to: width, by: sampleStep) {
                let index = row + x * bytesPerPixel
                let red = pixels[index]
                let green = pixels[index + 1]
                let blue = pixels[index + 2]
                let alpha = pixels[index + 3]

                if alpha > 16 {
                    let key = (UInt16(red >> 4) << 8)
                        | (UInt16(green >> 4) << 4)
                        | UInt16(blue >> 4)
                    uniqueQuantizedColors.insert(key)
                }
                if red > 200, green < 110, blue > 150, alpha > 200 {
                    markerPixels += 1
                }
                if red < 80, green > 180, blue > 180, alpha > 200 {
                    browserPixels += 1
                }
            }
        }

        return WindowScreenshotPixelStats(
            width: width,
            height: height,
            uniqueQuantizedColors: uniqueQuantizedColors.count,
            markerPixels: markerPixels,
            browserPixels: browserPixels
        )
    }

    private func configuredApp(mode: String) -> XCUIApplication {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchArguments += ["-\(modeKey)", mode]
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        // Debug launches require a tag outside reload.sh; provide one in UITests so CI
        // does not fail with "Application ... does not have a process ID".
        app.launchEnvironment["CMUX_TAG"] = launchTag
        return app
    }

    private func configureTextBoxMentionLaunchEnvironment(_ app: XCUIApplication) {
        app.launchArguments += [
            "-\(modeKey)", "allowAll",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        app.launchEnvironment["CMUX_TAG"] = launchTag
        if let path = ProcessInfo.processInfo.environment["PATH"], !path.isEmpty {
            app.launchEnvironment["PATH"] = path
        }
    }

    private func ensureForegroundAfterLaunch(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if app.wait(for: .runningForeground, timeout: timeout) {
            return true
        }
        // On busy UI runners the app can launch backgrounded; activate once before failing.
        if app.state == .runningBackground {
            app.activate()
            return app.wait(for: .runningForeground, timeout: 6.0)
        }
        return false
    }

    private func launchAllowingHeadlessBackground(_ app: XCUIApplication) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        options.issueMatcher = { issue in
            let diagnostics = [
                issue.compactDescription,
                issue.detailedDescription,
                issue.associatedError?.localizedDescription
            ]
                .compactMap { $0 }
                .joined(separator: "\n")
            return (issue.type == .system || issue.type == .assertionFailure) &&
                diagnostics.contains("Failed to activate application") &&
                diagnostics.contains("Running Background")
        }
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }
    }

    private func clickKeepMacAwakeMenu(in app: XCUIApplication) {
        let applicationMenu = app.menuBars.menuBarItems.element(boundBy: 0)
        XCTAssertTrue(
            applicationMenu.waitForExistence(timeout: 5.0),
            "Expected the application menu"
        )
        applicationMenu.click()
        let keepAwakeItem = app.menuItems["Keep Mac Awake"]
        XCTAssertTrue(
            keepAwakeItem.waitForExistence(timeout: 3.0),
            "Expected the localized Keep Mac Awake menu item"
        )
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "mac-keep-awake-menu"
        attachment.lifetime = .keepAlways
        add(attachment)
        keepAwakeItem.click()
    }

    private func ensureRunningAfterLaunch(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                app.state == .runningForeground || app.state == .runningBackground
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForSocketPong(timeout: TimeInterval, allowDiagnosticsFallback: Bool = true) -> Bool {
        var resolvedPath: String?
        let ready = waitForControlSocketReady(
            pingTimeout: timeout,
            socketFileExists: { self.socketCandidates().contains { FileManager.default.fileExists(atPath: $0) } },
            pingReturnsPong: {
                let originalPath = self.socketPath
                for candidate in self.socketCandidates() {
                    guard FileManager.default.fileExists(atPath: candidate) else { continue }
                    self.socketPath = candidate
                    if self.socketCommand("ping") == "PONG" {
                        resolvedPath = candidate
                        return true
                    }
                    self.socketPath = originalPath
                }
                return false
            }
        )
        if ready, let resolvedPath {
            socketPath = resolvedPath
            return true
        }
        guard allowDiagnosticsFallback else { return false }
        let diagnostics = loadDiagnostics()
        guard controlSocketDiagnosticsReportReady(diagnostics),
              let expectedPath = diagnostics["socketExpectedPath"],
              socketCandidates().contains(expectedPath) else {
            return false
        }
        socketPath = expectedPath
        return true
    }

    private func socketCandidates() -> [String] {
        var candidates = [socketPath, taggedSocketPath()]
        if let expectedPath = loadDiagnostics()["socketExpectedPath"], !expectedPath.isEmpty {
            candidates.append(expectedPath)
        }
        var seen = Set<String>()
        candidates.removeAll { !seen.insert($0).inserted }
        return candidates
    }

    private func taggedSocketPath() -> String {
        let slug = launchTag
            .lowercased()
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return "/tmp/cmux-debug-\(slug).sock"
    }

    private func loadDiagnostics() -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: diagnosticsPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var diagnostics: [String: String] = [:]
        for (key, value) in object {
            diagnostics[key] = String(describing: value)
        }
        return diagnostics
    }

    private func waitForSocket(exists: Bool, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                if exists {
                    return self.socketCandidates().contains { FileManager.default.fileExists(atPath: $0) }
                }
                return !self.socketCandidates().contains { FileManager.default.fileExists(atPath: $0) }
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func socketCommand(_ command: String) -> String? {
        ControlSocketClient(path: socketPath, responseTimeout: 1.0).sendLine(command) ??
            controlSocketCommandViaNetcat(command, socketPath: socketPath)
    }

    private func socketJSON(
        method: String,
        params: [String: Any],
        responseTimeout: TimeInterval = 2.0,
        allowsReplayFallback: Bool = true
    ) -> [String: Any]? {
        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params,
        ]
        if let response = ControlSocketClient(
            path: socketPath,
            responseTimeout: responseTimeout
        ).sendJSON(request) {
            return response
        }
        guard allowsReplayFallback else { return nil }
        return controlSocketJSONViaNetcat(
            request,
            socketPath: socketPath,
            responseTimeout: responseTimeout
        )
    }

    private func socketResult(
        method: String,
        params: [String: Any],
        responseTimeout: TimeInterval = 2.0,
        allowsReplayFallback: Bool = true
    ) -> [String: Any]? {
        guard let envelope = socketJSON(
            method: method,
            params: params,
            responseTimeout: responseTimeout,
            allowsReplayFallback: allowsReplayFallback
        ),
              envelope["ok"] as? Bool == true else {
            return nil
        }
        return envelope["result"] as? [String: Any]
    }

    private func waitForTextBoxFixture(
        surfaceID: String,
        beforeText: String,
        timeout: TimeInterval
    ) -> [String: Any]? {
        waitForJSON(timeout: timeout) {
            guard let result = self.socketResult(
                method: "debug.textbox.inline_fixture",
                params: [
                    "surface_id": surfaceID,
                    "before_text": beforeText,
                    "after_text": "",
                ]
            ) else {
                return nil
            }
            guard result["text_view_has_window"] as? Bool == true,
                  result["text_view_text"] as? String == beforeText else {
                return nil
            }
            return result
        }
    }

    private func waitForMentionState(
        surfaceID: String,
        timeout: TimeInterval,
        predicate: @escaping ([String: Any]) -> Bool
    ) -> [String: Any]? {
        waitForJSON(timeout: timeout) {
            guard let result = self.socketResult(
                method: "debug.textbox.interact",
                params: ["surface_id": surfaceID, "action": "focus"]
            ),
                  let state = result["state"] as? [String: Any] else {
                return nil
            }
            return predicate(state) ? state : nil
        }
    }

    private func waitForJSON(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.05,
        producer: () -> [String: Any]?
    ) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = producer() {
                return value
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        return producer()
    }

    private func makeSkillFixtureRoot(skillNames: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ui-textbox-skills-\(UUID().uuidString)", isDirectory: true)
        let skills = root.appendingPathComponent("skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        for skillName in skillNames {
            let skillDirectory = skills.appendingPathComponent(skillName, isDirectory: true)
            try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
            let contents = """
            ---
            name: \(skillName)
            ---

            Test skill fixture for \(skillName).
            """
            try contents.write(
                to: skillDirectory.appendingPathComponent("SKILL.md", isDirectory: false),
                atomically: true,
                encoding: .utf8
            )
        }
        temporaryRoots.append(root)
        return root
    }

    private func resolveSocketPath(timeout: TimeInterval, allowTmpFallback: Bool = true) -> String? {
        var resolvedPath: String?
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                if FileManager.default.fileExists(atPath: self.socketPath) {
                    resolvedPath = self.socketPath
                    return true
                }
                guard allowTmpFallback else { return false }
                if let found = self.findSocketInTmp() {
                    resolvedPath = found
                    return true
                }
                return false
            },
            object: NSObject()
        )
        if XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed {
            return resolvedPath
        }
        return resolvedPath
    }

    private func findSocketInTmp() -> String? {
        let tmpPath = "/tmp"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: tmpPath) else {
            return nil
        }
        let matches = entries.filter { $0.hasPrefix("cmux") && $0.hasSuffix(".sock") }
        if let debug = matches.first(where: { $0.contains("debug") }) {
            return (tmpPath as NSString).appendingPathComponent(debug)
        }
        if let first = matches.first {
            return (tmpPath as NSString).appendingPathComponent(first)
        }
        return nil
    }

    private func resetSocketDefaults() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["delete", defaultsDomain, modeKey]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
        let legacy = Process()
        legacy.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        legacy.arguments = ["delete", defaultsDomain, legacyKey]
        do {
            try legacy.run()
            legacy.waitUntilExit()
        } catch {
            return
        }
    }

    private func removeSocketFile() {
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private final class ControlSocketClient {
        private let path: String
        private let responseTimeout: TimeInterval

        init(path: String, responseTimeout: TimeInterval) {
            self.path = path
            self.responseTimeout = responseTimeout
        }

        func sendJSON(_ object: [String: Any]) -> [String: Any]? {
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  let line = String(data: data, encoding: .utf8),
                  let response = sendLine(line),
                  let responseData = response.data(using: .utf8) else {
                return nil
            }
            return (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any]
        }

        func sendLine(_ line: String) -> String? {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }

            var timeout = timeval(
                tv_sec: Int(responseTimeout),
                tv_usec: Int32((responseTimeout - floor(responseTimeout)) * 1_000_000)
            )
            withUnsafePointer(to: &timeout) { ptr in
                _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
                _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
            }

            var addr = sockaddr_un()
            memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
            addr.sun_family = sa_family_t(AF_UNIX)

            let pathBytes = Array(path.utf8CString)
            let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
            guard pathBytes.count <= maxLen else { return nil }
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                for index in 0..<pathBytes.count {
                    raw[index] = pathBytes[index]
                }
            }

            let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
            let addrLen = socklen_t(pathOffset + pathBytes.count)
            let connected = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.connect(fd, sockaddrPtr, addrLen)
                }
            }
            guard connected == 0 else { return nil }

            let payload = Array((line + "\n").utf8)
            let wrote = payload.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return true }
                return Darwin.write(fd, baseAddress, rawBuffer.count) == rawBuffer.count
            }
            guard wrote else { return nil }

            var buffer = [UInt8](repeating: 0, count: 4096)
            var accumulator = ""
            let deadline = Date().addingTimeInterval(responseTimeout)
            while Date() < deadline {
                let count = Darwin.read(fd, &buffer, buffer.count)
                guard count > 0 else { break }
                if let chunk = String(bytes: buffer[0..<count], encoding: .utf8) {
                    accumulator.append(chunk)
                    if let newline = accumulator.firstIndex(of: "\n") {
                        return String(accumulator[..<newline])
                    }
                    if count < buffer.count {
                        break
                    }
                }
            }
            return accumulator.isEmpty ? nil : accumulator.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
