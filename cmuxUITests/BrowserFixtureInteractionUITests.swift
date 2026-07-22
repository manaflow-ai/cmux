import XCTest
import Foundation
import Darwin

/// Shared harness for socket-driven browser fixture tests.
///
/// Launches the app with a unique tagged debug socket (same conventions as
/// `AutomationSocketUITests`), exposes V2 request helpers (newline-delimited
/// `{id, method, params}` JSON over the unix socket; responses carry
/// `ok`/`result`/`error`), and helpers to open a browser split and navigate
/// it to a local fixture page under `cmuxUITests/BrowserFixtures/`.
///
/// All page interactions in subclasses must go through the socket
/// `browser.*` interaction methods (click/fill/press/select/focus);
/// `browser.eval` is used only to read page state for assertions.
class BrowserFixtureSocketTestCase: XCTestCase {
    private(set) var socketPath = ""
    private var diagnosticsPath = ""
    private var launchTag = ""
    private(set) var app: XCUIApplication?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-debug-\(UUID().uuidString).sock"
        diagnosticsPath = "/tmp/cmux-ui-test-browser-fixtures-\(UUID().uuidString).json"
        launchTag = "ui-tests-browser-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
        try? FileManager.default.removeItem(atPath: taggedSocketPath())
    }

    override func tearDown() {
        app?.terminate()
        app = nil
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
        try? FileManager.default.removeItem(atPath: taggedSocketPath())
        super.tearDown()
    }

    // MARK: - Launch

    @discardableResult
    func launchApp() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-socketControlMode", "allowAll",
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
        // Debug launches require a tag outside reload.sh; provide one in UITests so CI
        // does not fail with "Application ... does not have a process ID".
        app.launchEnvironment["CMUX_TAG"] = launchTag
        if let path = ProcessInfo.processInfo.environment["PATH"], !path.isEmpty {
            app.launchEnvironment["PATH"] = path
        }
        self.app = app
        // On headless CI runners (no GUI session), XCUIApplication.launch()
        // blocks ~60s then fails with "Failed to activate application
        // (current state: Running Background)". Mark this as an expected
        // failure so the test can continue: these tests are socket-driven and
        // browser webviews mount in the app windows regardless of activation.
        let activationOptions = XCTExpectedFailure.Options()
        activationOptions.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: activationOptions) {
            app.launch()
        }
        if app.state != .runningForeground {
            XCTAssertTrue(
                app.state == .runningBackground,
                "Expected app to be running for browser fixture test. state=\(app.state.rawValue)"
            )
        }
        XCTAssertTrue(
            waitForSocketPong(timeout: 12.0),
            "Expected socket ping at \(socketPath). diagnostics=\(loadDiagnostics())"
        )
        return app
    }


    // MARK: - V2 socket helpers

    /// Sends one V2 request and returns the raw response envelope
    /// (`{"id":…,"ok":…,"result"/"error":…}`), or nil if the socket did not answer.
    func socketEnvelope(
        method: String,
        params: [String: Any],
        responseTimeout: TimeInterval = 8.0
    ) -> [String: Any]? {
        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params,
        ]
        return ControlSocketClient(path: socketPath, responseTimeout: responseTimeout).sendJSON(request)
    }

    /// Sends one V2 request, asserts `ok == true`, and returns `result`.
    @discardableResult
    func socketResult(
        method: String,
        params: [String: Any],
        responseTimeout: TimeInterval = 8.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let envelope = try XCTUnwrap(
            socketEnvelope(method: method, params: params, responseTimeout: responseTimeout),
            "No socket response for \(method)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            envelope["ok"] as? Bool,
            true,
            "\(method) failed: \(envelope)",
            file: file,
            line: line
        )
        return envelope["result"] as? [String: Any] ?? [:]
    }

    // MARK: - Browser fixture helpers

    /// Resolves a fixture page next to this source file (works in CI checkouts,
    /// no test-bundle resource wiring needed).
    static func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("BrowserFixtures/\(name).html")
    }

    /// Creates a fresh workspace and opens a URL-less browser split in it.
    /// Returns the browser surface id (UUID string).
    func openBrowserSurface(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let workspace = try socketResult(
            method: "workspace.create",
            params: ["title": "Browser fixture \(name)", "focus": true],
            file: file,
            line: line
        )
        let workspaceID = try XCTUnwrap(
            workspace["workspace_id"] as? String,
            "workspace.create returned no workspace_id: \(workspace)",
            file: file,
            line: line
        )
        let sourceSurfaceID = try XCTUnwrap(
            workspace["surface_id"] as? String,
            "workspace.create returned no surface_id: \(workspace)",
            file: file,
            line: line
        )
        let opened = try socketResult(
            method: "browser.open_split",
            params: ["workspace_id": workspaceID, "surface_id": sourceSurfaceID],
            responseTimeout: 15.0,
            file: file,
            line: line
        )
        return try XCTUnwrap(
            opened["surface_id"] as? String,
            "browser.open_split returned no surface_id: \(opened)",
            file: file,
            line: line
        )
    }

    /// Opens a browser split, navigates it to the named fixture, and waits
    /// for `document.readyState === "complete"`.
    func openFixture(
        _ fixtureName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let surfaceID = try openBrowserSurface(file: file, line: line)
        let url = Self.fixtureURL(fixtureName)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "Missing browser fixture: \(url.path)",
            file: file,
            line: line
        )
        try socketResult(
            method: "browser.navigate",
            params: ["surface_id": surfaceID, "url": url.absoluteString],
            responseTimeout: 15.0,
            file: file,
            line: line
        )
        try socketResult(
            method: "browser.wait",
            params: ["surface_id": surfaceID, "load_state": "complete", "timeout_ms": 10_000],
            responseTimeout: 16.0,
            file: file,
            line: line
        )
        return surfaceID
    }

    // MARK: - Read-only page state (browser.eval is for assertions only)

    func evalValue(
        _ script: String,
        surfaceID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Any? {
        let result = try socketResult(
            method: "browser.eval",
            params: ["surface_id": surfaceID, "script": script],
            responseTimeout: 15.0,
            file: file,
            line: line
        )
        return result["value"]
    }

    func evalString(
        _ script: String,
        surfaceID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        try XCTUnwrap(
            try evalValue(script, surfaceID: surfaceID, file: file, line: line) as? String,
            "Expected string from eval of: \(script)",
            file: file,
            line: line
        )
    }

    func evalBool(
        _ script: String,
        surfaceID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Bool {
        try XCTUnwrap(
            try evalValue(script, surfaceID: surfaceID, file: file, line: line) as? Bool,
            "Expected bool from eval of: \(script)",
            file: file,
            line: line
        )
    }

    func statusText(
        surfaceID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        try evalString(
            "document.getElementById('status').textContent",
            surfaceID: surfaceID,
            file: file,
            line: line
        )
    }

    // MARK: - Socket plumbing (mirrors AutomationSocketUITests)

    private func waitForSocketPong(timeout: TimeInterval) -> Bool {
        waitForControlSocketReady(
            pingTimeout: timeout,
            socketFileExists: {
                self.socketCandidates().contains { FileManager.default.fileExists(atPath: $0) }
            },
            pingReturnsPong: {
                for candidate in self.socketCandidates() {
                    guard FileManager.default.fileExists(atPath: candidate) else { continue }
                    if ControlSocketClient(path: candidate, responseTimeout: 1.0).sendLine("ping") == "PONG" {
                        self.socketPath = candidate
                        return true
                    }
                }
                return false
            }
        )
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
                }
            }
            return accumulator.isEmpty ? nil : accumulator.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// Drives the BrowserFixtures pages exclusively through socket `browser.*`
/// interaction methods and asserts the page-observed outcome.
///
/// Tests use `XCTExpectFailure` (strict) to produce an honest capability map:
/// each expected failure documents a real gap in the current interaction
/// implementation. When an implementation gap is fixed, the strict expected
/// failure turns into a test failure, prompting an assertion upgrade.
final class BrowserFixtureInteractionUITests: BrowserFixtureSocketTestCase {

    /// browser.click delivers a click and browser.fill delivers the final
    /// value, but fill is a single value assignment + one synthetic `input`
    /// event: there are no per-character keydown/keyup events, so the
    /// fixture's strict ordering check (3 inputs, each preceded by its
    /// keydown) can never flip #status to PASS. Assert the log instead.
    func testEventTrustAndOrder() throws {
        try launchApp()
        let sid = try openFixture("event-trust-and-order")

        try socketResult(method: "browser.click", params: ["surface_id": sid, "selector": "#btn"])
        try socketResult(method: "browser.fill", params: ["surface_id": sid, "selector": "#field", "text": "abc"])

        XCTAssertEqual(
            try evalString("document.getElementById('field').value", surfaceID: sid),
            "abc",
            "fill should land the final value in #field"
        )
        XCTAssertTrue(
            try evalBool(
                "window.__cmuxLog.some(e => e.type === 'click' && e.target === '#btn')",
                surfaceID: sid
            ),
            "click on #btn should be observed by the page listener"
        )
        XCTAssertTrue(
            try evalBool(
                "window.__cmuxLog.some(e => e.type === 'input' && e.target === '#field' && e.value === 'abc')",
                surfaceID: sid
            ),
            "fill should dispatch an input event carrying the final value"
        )
        // Synthetic events are not trusted (el.click() / dispatchEvent).
        XCTAssertFalse(
            try evalBool("window.__cmuxLog.some(e => e.isTrusted === true)", surfaceID: sid),
            "socket-driven events should be untrusted synthetic events"
        )
        // fill emits exactly one input and zero keydowns: per-key ordering is unachievable.
        XCTAssertFalse(
            try evalBool("window.__cmuxLog.some(e => e.type === 'keydown')", surfaceID: sid),
            "fill should not synthesize keydown events (documents the gap below)"
        )
        XCTExpectFailure(
            "browser.fill sets the value once and dispatches a single untrusted input event " +
            "with no per-character keydown/keyup, so the fixture's per-keystroke ordering check " +
            "(3 inputs, each preceded by a matching keydown) cannot reach PASS"
        ) {
            XCTAssertEqual(try? statusText(surfaceID: sid), "PASS")
        }
    }

    /// browser.click/fill resolve selectors with `document.querySelector`,
    /// which cannot pierce shadow roots (even open ones), and there is no
    /// piercing selector syntax. The failure mode is a `not_found` error
    /// envelope ("Element not found") for elements inside the shadow root.
    func testShadowOpen() throws {
        try launchApp()
        let sid = try openFixture("shadow-open")

        // Read-only sanity: the open shadow root and its controls exist.
        XCTAssertTrue(
            try evalBool(
                "!!(document.getElementById('host').shadowRoot && " +
                "document.getElementById('host').shadowRoot.getElementById('s-btn'))",
                surfaceID: sid
            ),
            "fixture should expose an open shadow root with #s-btn"
        )

        XCTExpectFailure("shadow DOM selectors not yet supported") {
            let clickEnvelope = socketEnvelope(
                method: "browser.click",
                params: ["surface_id": sid, "selector": "#s-btn"]
            )
            XCTAssertEqual(
                clickEnvelope?["ok"] as? Bool,
                true,
                "browser.click cannot reach #s-btn inside the open shadow root: \(String(describing: clickEnvelope))"
            )
            let fillEnvelope = socketEnvelope(
                method: "browser.fill",
                params: ["surface_id": sid, "selector": "#s-input", "text": "shadow-ok"]
            )
            XCTAssertEqual(
                fillEnvelope?["ok"] as? Bool,
                true,
                "browser.fill cannot reach #s-input inside the open shadow root: \(String(describing: fillEnvelope))"
            )
            XCTAssertEqual(try? statusText(surfaceID: sid), "PASS")
        }
    }

    /// One level of `browser.frame.select` works (the click script's
    /// `document` is rebound to the selected frame's contentDocument). The
    /// innermost iframe is unreachable: frame.select re-resolves the stored
    /// frame selector against the MAIN document on every subsequent action,
    /// so selecting "#inner" while "#outer" is active appears to succeed but
    /// silently falls back to the main frame afterwards.
    func testIframeNested() throws {
        try launchApp()
        let sid = try openFixture("iframe-nested")

        // srcdoc frames mount asynchronously; wait for the deep button to exist.
        try socketResult(
            method: "browser.wait",
            params: [
                "surface_id": sid,
                "function":
                    "(function(){ const o = document.querySelector('#outer'); " +
                    "if (!o || !o.contentDocument) return false; " +
                    "const i = o.contentDocument.querySelector('#inner'); " +
                    "if (!i || !i.contentDocument) return false; " +
                    "return !!i.contentDocument.querySelector('#deep-btn'); })()",
                "timeout_ms": 10_000,
            ],
            responseTimeout: 16.0
        )

        // One-level frame targeting works.
        try socketResult(method: "browser.frame.select", params: ["surface_id": sid, "selector": "#outer"])
        try socketResult(method: "browser.click", params: ["surface_id": sid, "selector": "#mid-btn"])
        try socketResult(method: "browser.frame.main", params: ["surface_id": sid])
        XCTAssertTrue(
            try evalBool(
                "window.__cmuxLog.some(e => e.type === 'click' && e.target === '#mid-btn')",
                surfaceID: sid
            ),
            "frame.select #outer + click should reach #mid-btn one level deep"
        )

        // Nested (two-level) frame targeting is genuinely unsupported.
        try socketResult(method: "browser.frame.select", params: ["surface_id": sid, "selector": "#outer"])
        try XCTExpectFailure(
            "nested iframe targeting not supported: browser.frame.select stores a selector that " +
            "is re-resolved against the main document on each action, so selecting #inner from " +
            "within #outer silently retargets the main frame and #deep-btn is never reachable"
        ) {
            // This frame.select returns ok (the selector resolves inside the
            // outer document at select time), which is itself misleading.
            _ = socketEnvelope(method: "browser.frame.select", params: ["surface_id": sid, "selector": "#inner"])
            let deepClick = socketEnvelope(
                method: "browser.click",
                params: ["surface_id": sid, "selector": "#deep-btn"]
            )
            XCTAssertEqual(
                deepClick?["ok"] as? Bool,
                true,
                "browser.click cannot reach #deep-btn in the nested iframe: \(String(describing: deepClick))"
            )
            try socketResult(method: "browser.frame.main", params: ["surface_id": sid])
            XCTAssertEqual(try? statusText(surfaceID: sid), "PASS", "PASS requires the innermost #deep-btn click")
        }
    }

    func testCustomDropdowns() throws {
        try launchApp()
        let sid = try openFixture("custom-dropdowns")

        // Native <select>: browser.select dispatches input then change.
        try socketResult(
            method: "browser.select",
            params: ["surface_id": sid, "selector": "#native", "value": "c"]
        )
        XCTAssertEqual(
            try evalString("document.getElementById('native').value", surfaceID: sid),
            "c"
        )
        XCTAssertTrue(
            try evalBool(
                "window.__cmuxLog.some(e => e.type === 'change' && e.target === '#native' && e.value === 'c')",
                surfaceID: sid
            ),
            "native select change should be observed with value c"
        )

        // ARIA combobox: click opens the listbox, click the option commits it.
        try socketResult(method: "browser.click", params: ["surface_id": sid, "selector": "#combo"])
        try socketResult(
            method: "browser.wait",
            params: ["surface_id": sid, "selector": "#combo-list", "timeout_ms": 5_000],
            responseTimeout: 10.0
        )
        try socketResult(
            method: "browser.click",
            params: ["surface_id": sid, "selector": "#combo-list [data-opt=\"beta\"]"]
        )
        XCTAssertEqual(
            try evalString("document.getElementById('combo').value", surfaceID: sid),
            "beta"
        )

        // Plain div menu: trigger then item.
        try socketResult(method: "browser.click", params: ["surface_id": sid, "selector": "#menu-trigger"])
        try socketResult(
            method: "browser.click",
            params: ["surface_id": sid, "selector": "#menu [data-value=\"gamma\"]"]
        )
        XCTAssertTrue(
            try evalBool("document.getElementById('menu').hidden", surfaceID: sid),
            "menu should close after picking gamma"
        )

        XCTAssertEqual(try statusText(surfaceID: sid), "PASS")
    }

    /// Synthetic el.click() bypasses hit-testing entirely, so overlays,
    /// sticky banners, and covering pseudo-layers do not block socket clicks.
    func testOcclusionOverlay() throws {
        try launchApp()
        let sid = try openFixture("occlusion-overlay")

        try socketResult(method: "browser.click", params: ["surface_id": sid, "selector": "#under-overlay"])
        try socketResult(method: "browser.click", params: ["surface_id": sid, "selector": "#under-banner"])
        try socketResult(method: "browser.click", params: ["surface_id": sid, "selector": "#covered-check"])

        XCTAssertTrue(
            try evalBool("document.getElementById('covered-check').checked", surfaceID: sid),
            "clicking the covered checkbox should toggle it"
        )
        XCTAssertEqual(try statusText(surfaceID: sid), "PASS")
    }

    /// browser.fill on a contenteditable assigns textContent (no `value`
    /// property); the fixture accepts the resulting mutation as edit evidence.
    func testContenteditable() throws {
        try launchApp()
        let sid = try openFixture("contenteditable")

        try socketResult(method: "browser.fill", params: ["surface_id": sid, "selector": "#editor", "text": "edited"])

        XCTAssertEqual(
            try evalString("document.getElementById('editor').textContent", surfaceID: sid),
            "edited",
            "fill should replace the contenteditable's prefill text"
        )
        XCTAssertEqual(try statusText(surfaceID: sid), "PASS")
    }

    func testKeyboardWidget() throws {
        try launchApp()
        let sid = try openFixture("keyboard-widget")

        try socketResult(method: "browser.focus", params: ["surface_id": sid, "selector": "#pad"])
        XCTAssertTrue(try evalBool("document.activeElement?.id === 'pad'", surfaceID: sid), "browser.focus should focus #pad")
        for _ in 0..<3 {
            try socketResult(method: "browser.press", params: ["surface_id": sid, "key": "ArrowRight"])
        }
        XCTAssertEqual(try evalString("document.getElementById('pad-status').textContent", surfaceID: sid), "PASS")

        // fill focuses #entry before setting the value; press targets the active element.
        try socketResult(method: "browser.fill", params: ["surface_id": sid, "selector": "#entry", "text": "go"])
        try socketResult(method: "browser.press", params: ["surface_id": sid, "key": "Enter"])
        XCTAssertEqual(try evalString("document.getElementById('entry-status').textContent", surfaceID: sid), "PASS")

        try socketResult(method: "browser.focus", params: ["surface_id": sid, "selector": "#space-button"])
        try socketResult(method: "browser.press", params: ["surface_id": sid, "key": "Space"])
        let canonicalSpaceKeyDown = try evalBool(
            "window.__cmuxLog.filter(e => e.type === 'keydown' && e.target === '#space-button' && e.key === ' ' && e.code === 'Space').length === 1",
            surfaceID: sid
        )
        XCTAssertTrue(canonicalSpaceKeyDown, "Space should emit exactly one canonical keydown")
        XCTAssertEqual(try evalString("document.getElementById('space-status').textContent", surfaceID: sid), "PASS")

        try socketResult(method: "browser.keydown", params: ["surface_id": sid, "key": " "])
        try socketResult(method: "browser.keyup", params: ["surface_id": sid, "key": " "])
        let canonicalRawSpacePair = try evalBool(
            """
            window.__cmuxLog
              .filter(e => e.target === '#space-button' && e.key === ' ' && e.code === 'Space')
              .slice(-2)
              .map(e => e.type)
              .join(',') === 'keydown,keyup'
            """,
            surfaceID: sid
        )
        XCTAssertTrue(canonicalRawSpacePair, "Raw Space should add one canonical keydown/keyup pair")
        XCTAssertEqual(try statusText(surfaceID: sid), "PASS")
    }

    /// Regression: on a page whose CSP has no 'unsafe-eval', the page-world
    /// callAsyncJavaScript/eval is blocked; automation must fall back to the
    /// isolated content world (which shares the DOM). Both eval and the
    /// interaction methods must keep working. A browser.eval served from the
    /// isolated world must also flag content_world so the agent knows page-world
    /// JS globals were not visible (the value came from a different JS context).
    func testCSPNoUnsafeEval() throws {
        try launchApp()
        let sid = try openFixture("csp-no-unsafe-eval")

        let evalResult = try socketResult(
            method: "browser.eval",
            params: ["surface_id": sid, "script": "document.title"],
            responseTimeout: 15.0
        )
        XCTAssertEqual(
            evalResult["value"] as? String,
            "csp-no-unsafe-eval",
            "browser.eval must succeed under CSP without 'unsafe-eval' (isolated-world fallback)"
        )
        XCTAssertEqual(
            evalResult["content_world"] as? String,
            "isolated",
            "a CSP-blocked browser.eval served from the isolated world must flag content_world"
        )

        try socketResult(method: "browser.click", params: ["surface_id": sid, "selector": "#csp-btn"])
        XCTAssertEqual(
            try evalString("document.getElementById('counter').textContent", surfaceID: sid),
            "1",
            "click should increment the counter under CSP"
        )
        XCTAssertEqual(try statusText(surfaceID: sid), "PASS")
    }

    /// The fixture's hostile listeners revert the first two input events and
    /// rewrite the value on the first change event, so a single fill is
    /// deliberately defeated. Each step below asserts the documented
    /// per-attempt behavior; three fills converge to the final value.
    func testStickyInput() throws {
        try launchApp()
        let sid = try openFixture("sticky-input")
        let valueScript = "document.getElementById('sticky').value"

        // Fill 1: input revert #1 eats the value, then the change handler
        // rewrites it once.
        try socketResult(method: "browser.fill", params: ["surface_id": sid, "selector": "#sticky", "text": "final-text"])
        XCTAssertEqual(
            try evalString(valueScript, surfaceID: sid),
            "rewritten-once",
            "a single fill is defeated by the hostile input/change listeners"
        )

        // Fill 2: input revert #2 eats the value again.
        try socketResult(method: "browser.fill", params: ["surface_id": sid, "selector": "#sticky", "text": "final-text"])
        XCTAssertEqual(try evalString(valueScript, surfaceID: sid), "rewritten-once")

        // Fill 3: reverts exhausted; the value finally sticks.
        try socketResult(method: "browser.fill", params: ["surface_id": sid, "selector": "#sticky", "text": "final-text"])
        XCTAssertEqual(
            try evalString(valueScript, surfaceID: sid),
            "final-text",
            "fill should stick once the hostile listeners are exhausted"
        )
        XCTAssertEqual(try statusText(surfaceID: sid), "PASS")
    }

    func testDatetimeRange() throws {
        try launchApp()
        let sid = try openFixture("datetime-range")

        try socketResult(method: "browser.fill", params: ["surface_id": sid, "selector": "#date", "text": "2026-01-15"])
        try socketResult(method: "browser.fill", params: ["surface_id": sid, "selector": "#range", "text": "90"])

        XCTAssertEqual(
            try evalString("document.getElementById('date').value", surfaceID: sid),
            "2026-01-15"
        )
        XCTAssertTrue(
            try evalBool("document.getElementById('range').valueAsNumber === 90", surfaceID: sid),
            "range input should accept the filled numeric value"
        )
        XCTAssertEqual(try statusText(surfaceID: sid), "PASS")
    }
}
