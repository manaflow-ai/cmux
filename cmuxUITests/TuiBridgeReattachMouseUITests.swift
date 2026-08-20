import XCTest
import Foundation
import Darwin

/// Closes the round-6 human dogfood loop for the cmux-tui terminal-backend
/// spike in CI: a daemon-backed terminal whose inner app enables mouse
/// tracking in btop's order (1002h, 1015h, 1006h — SGR set last) must keep
/// receiving clicks as SGR after "Keep Sessions and Quit" plus relaunch.
///
/// The regression this pins: the daemon serialized the extended-coordinate
/// mouse modes as a numeric flag dump, so the reattached client's mirror
/// ended with urxvt (1015) active and re-encoded forwarded clicks as urxvt,
/// which SGR-only apps (btop) ignore — fresh-attach clicks worked, every
/// reattach went mouse-dead. Fixed in cmux-tui by replay carrying the active
/// selector last plus an SGR-preference fallback in the attach client; this
/// test drives the whole loop through the real app: real window-server
/// clicks, the real quit dialog, real session restore.
///
/// Requires a cmux-tui binary: CMUX_UI_TEST_TUI_BINARY, or
/// $GITHUB_WORKSPACE/cmux-tui/target/debug/cmux-tui (built by the
/// test-e2e workflow when the filter targets this class). Skips when absent.
final class TuiBridgeReattachMouseUITests: XCTestCase {
    private var socketPath = ""
    private var diagnosticsPath = ""
    private var launchTag = ""
    private var lastSocketFailure: String?

    /// SGR-encoded press/release prefix as echoed by `cat -v` (ESC -> "^[").
    private let sgrMarker = "^[[<0;"
    /// urxvt-encoded press (32 = button 0) and release (35) prefixes.
    private let urxvtPressMarker = "^[[32;"
    private let urxvtReleaseMarker = "^[[35;"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-debug-\(UUID().uuidString).sock"
        diagnosticsPath = "/tmp/cmux-ui-test-tui-bridge-\(UUID().uuidString).json"
        launchTag = "ui-tui-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
        try? FileManager.default.removeItem(atPath: taggedSocketPath())
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
        try? FileManager.default.removeItem(atPath: taggedSocketPath())
        super.tearDown()
    }

    func testClickReachesInnerAppAsSgrAfterKeepQuitAndRelaunch() throws {
        let tuiBinary = try resolveTuiBinary()

        let app = launchApp(tuiBinary: tuiBinary)
        defer { forceTerminate(app) }

        // A NEW terminal tab is the daemon-backed surface (the first
        // workspace terminal intentionally stays on the local spawn path).
        app.typeKey("t", modifierFlags: .command)
        waitForScreen(timeout: 30, description: "new tab shell prompt") { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        // btop's exact mouse-mode order (SGR last), then raw byte echo. The
        // kernel tty echoes the forwarded click bytes immediately with
        // control characters rendered visibly (^[), so the screen itself is
        // the byte evidence.
        app.typeText("printf '\\033[?1002h\\033[?1015h\\033[?1006h'; exec cat -v")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        app.typeText("CMUX_FIXTURE_READY")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        waitForScreen(timeout: 20, description: "cat -v fixture echoing input") {
            $0.components(separatedBy: "CMUX_FIXTURE_READY").count >= 3
        }

        // Fresh-attach click: must arrive at the inner PTY as SGR.
        clickTerminal(app)
        waitForScreen(timeout: 15, description: "fresh-attach click forwarded as SGR") {
            self.occurrences(of: self.sgrMarker, in: $0) >= 2
        }
        let freshMarkers = occurrences(of: sgrMarker, in: currentScreen())

        // Quit keeping the daemon sessions. The app is frontmost in XCUITest,
        // so the keep-vs-stop dialog holds instead of auto-resolving.
        app.typeKey("q", modifierFlags: .command)
        let keepButton = app.buttons["Keep Sessions and Quit"]
        XCTAssertTrue(
            keepButton.waitForExistence(timeout: 15),
            "Keep-vs-stop quit dialog never appeared; is the daemon-backed tab live? screen=\(currentScreen())"
        )
        keepButton.click()
        XCTAssertTrue(
            app.wait(for: .notRunning, timeout: 30),
            "App did not terminate after Keep Sessions and Quit"
        )

        // Relaunch the SAME tagged app: session restore reattaches the
        // daemon terminal by terminal_id.
        launchAgain(app)
        waitForScreen(timeout: 45, description: "reattached fixture screen after relaunch") {
            $0.contains("CMUX_FIXTURE_READY")
        }

        // Reattach click: THE regression assertion. Today's binaries forward
        // this click as urxvt (^[[32;...M) and no new SGR marker appears.
        clickTerminal(app)
        waitForScreen(timeout: 15, description: "reattach click forwarded as SGR, not urxvt") {
            self.occurrences(of: self.sgrMarker, in: $0) >= freshMarkers + 2
        }
        let finalScreen = currentScreen()
        XCTAssertFalse(
            finalScreen.contains(urxvtPressMarker) || finalScreen.contains(urxvtReleaseMarker),
            "Reattached client re-encoded the click as urxvt; btop parses only SGR. screen=\(finalScreen)"
        )

        // Cleanup: stop the daemon session through the same dialog.
        app.typeKey("q", modifierFlags: .command)
        let stopButton = app.buttons["Stop Sessions and Quit"]
        XCTAssertTrue(
            stopButton.waitForExistence(timeout: 15),
            "Keep-vs-stop dialog missing on the cleanup quit"
        )
        stopButton.click()
        XCTAssertTrue(
            app.wait(for: .notRunning, timeout: 60),
            "App did not terminate after Stop Sessions and Quit"
        )
    }

    // MARK: - Launch

    private func resolveTuiBinary() throws -> String {
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let explicit = env["CMUX_UI_TEST_TUI_BINARY"], !explicit.isEmpty {
            candidates.append(explicit)
        }
        if let workspace = env["GITHUB_WORKSPACE"], !workspace.isEmpty {
            candidates.append("\(workspace)/cmux-tui/target/debug/cmux-tui")
        }
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        throw XCTSkip(
            "No cmux-tui binary; set CMUX_UI_TEST_TUI_BINARY or build cmux-tui/target/debug/cmux-tui (candidates: \(candidates))"
        )
    }

    private func launchApp(tuiBinary: String) -> XCUIApplication {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchArguments += [
            "-socketControlMode", "allowAll",
            // Plist-typed bool: the settings decoder accepts only real
            // booleans, so a bare "YES" string never enables the flag.
            "-terminal.beta.tuiBackend.enabled", "<true/>",
            "-terminal.beta.tuiBackend.binaryPath", tuiBinary,
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-ApplePersistenceIgnoreState", "YES",
            "-NSAppSleepDisabled", "YES",
        ]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = launchTag
        if let path = ProcessInfo.processInfo.environment["PATH"], !path.isEmpty {
            app.launchEnvironment["PATH"] = path
        }
        launchAgain(app)
        return app
    }

    private func launchAgain(_ app: XCUIApplication) {
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 30),
            "App never reached foreground. state=\(app.state.rawValue)"
        )
        app.activate()
        XCTAssertTrue(
            waitForSocket(timeout: 30),
            "control socket never answered. candidates=\(socketCandidates()) lastFailure=\(lastSocketFailure ?? "nil") diagnostics=\(loadDiagnostics())"
        )
    }

    private func forceTerminate(_ app: XCUIApplication) {
        guard app.state != .notRunning else { return }
        app.terminate()
    }

    // MARK: - Terminal interaction

    private func clickTerminal(_ app: XCUIApplication) {
        app.activate()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "No app window to click")
        // Middle-right of the window: inside the terminal grid, clear of the
        // sidebar and the tab strip. The reported cell does not matter; the
        // fixture echoes whatever coordinates arrive.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6)).click()
    }

    private func currentScreen() -> String {
        guard let response = socketJSON(
            method: "surface.read_text",
            params: ["scrollback": true, "lines": 200]
        ) else { return "" }
        return (response["text"] as? String) ?? ""
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    @discardableResult
    private func waitForScreen(
        timeout: TimeInterval,
        description: String,
        until predicate: @escaping (String) -> Bool
    ) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < deadline {
            last = currentScreen()
            if predicate(last) { return last }
            Thread.sleep(forTimeInterval: 0.4)
        }
        XCTFail("Timed out waiting for \(description). last screen=\(last)")
        return last
    }

    // MARK: - Socket plumbing (same shape as RemoteTmuxSizingUITests+Socket)

    private func waitForSocket(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for candidate in socketCandidates() {
                guard FileManager.default.fileExists(atPath: candidate) else { continue }
                socketPath = candidate
                if socketJSON(method: "system.ping", params: [:])?["ok"] as? Bool == true {
                    return true
                }
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return false
    }

    private func socketCandidates() -> [String] {
        var candidates = [socketPath, taggedSocketPath()]
        if let expected = loadDiagnostics()["socketExpectedPath"], !expected.isEmpty {
            candidates.append(expected)
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private func loadDiagnostics() -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: diagnosticsPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object.reduce(into: [:]) { $0[$1.key] = String(describing: $1.value) }
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

    private func socketJSON(method: String, params: [String: Any]) -> [String: Any]? {
        let request: [String: Any] = ["id": UUID().uuidString, "method": method, "params": params]
        guard JSONSerialization.isValidJSONObject(request),
              let data = try? JSONSerialization.data(withJSONObject: request),
              let line = String(data: data, encoding: .utf8),
              let response = sendLine(line),
              let responseData = response.data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any]
        else { return nil }
        if let result = object["result"] as? [String: Any] {
            for (key, value) in result where object[key] == nil { object[key] = value }
        }
        return object
    }

    private func sendLine(_ line: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            lastSocketFailure = "socket() errno=\(errno)"
            return nil
        }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        withUnsafePointer(to: &timeout) { ptr in
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }
        var addr = sockaddr_un()
        memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            for index in 0..<pathBytes.count { raw[index] = pathBytes[index] }
        }
        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        let addrLen = socklen_t(pathOffset + pathBytes.count)
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, addrLen) }
        }
        guard connected == 0 else {
            lastSocketFailure = "connect(\(socketPath)) errno=\(errno)"
            return nil
        }
        let payload = Array((line + "\n").utf8)
        let wrote = payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            return Darwin.write(fd, base, raw.count) == raw.count
        }
        guard wrote else { return nil }
        var buffer = [UInt8](repeating: 0, count: 8192)
        var accumulator = Data()
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            accumulator.append(contentsOf: buffer[0..<count])
            if let newline = accumulator.firstIndex(of: UInt8(ascii: "\n")) {
                return String(decoding: accumulator[..<newline], as: UTF8.self)
            }
        }
        return accumulator.isEmpty
            ? nil
            : String(decoding: accumulator, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
