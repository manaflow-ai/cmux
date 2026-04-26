import XCTest
import Foundation

final class CloseWorkspacesConfirmDialogUITests: XCTestCase {
    private var socketPath = ""
    private var diagnosticsPath = ""
    private var launchTag = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-ui-test-close-workspaces-\(UUID().uuidString).sock"
        diagnosticsPath = "/tmp/cmux-ui-test-close-workspaces-\(UUID().uuidString).json"
        launchTag = "ui-tests-close-workspaces-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
        try? FileManager.default.removeItem(atPath: taggedSocketPath())
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
        try? FileManager.default.removeItem(atPath: taggedSocketPath())
        super.tearDown()
    }

    func testCommandPaletteCloseOtherWorkspacesShowsSingleSummaryDialog() {
        let app = XCUIApplication()
        configureSocketLaunchEnvironment(app)
        app.launchEnvironment["CMUX_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE"] = "1"
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for close-workspaces confirmation test. state=\(app.state.rawValue)"
        )
        XCTAssertTrue(
            waitForSocketPong(timeout: 12.0),
            "Expected control socket to respond at \(socketPath). diagnostics=\(loadJSON(atPath: diagnosticsPath) ?? [:])"
        )

        XCTAssertEqual(socketCommand("new_workspace")?.prefix(2), "OK")
        XCTAssertEqual(socketCommand("new_workspace")?.prefix(2), "OK")
        XCTAssertTrue(
            waitForWorkspaceCount(3, timeout: 5.0),
            "Expected 3 workspaces before running the close-other-workspaces command. list=\(socketCommand("list_workspaces") ?? "<nil>")"
        )
        XCTAssertEqual(socketCommand("select_workspace 1"), "OK")

        app.typeKey("p", modifierFlags: [.command, .shift])

        let searchField = app.textFields["CommandPaletteSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5.0), "Expected command palette search field")
        searchField.click()
        searchField.typeText("Close Other Workspaces")

        let resultButton = app.buttons["Close Other Workspaces"].firstMatch
        if resultButton.waitForExistence(timeout: 5.0) {
            resultButton.click()
        } else {
            app.typeKey(.return, modifierFlags: [])
        }

        XCTAssertTrue(
            waitForCloseWorkspacesAlert(app: app, timeout: 5.0),
            "Expected a single aggregated close-workspaces alert"
        )

        clickCancelOnCloseWorkspacesAlert(app: app)

        XCTAssertFalse(
            isCloseWorkspacesAlertPresent(app: app),
            "Expected aggregated close-workspaces alert to dismiss after clicking Cancel"
        )
        XCTAssertTrue(
            waitForWorkspaceCount(3, timeout: 5.0),
            "Expected all workspaces to remain after cancelling multi-close. list=\(socketCommand("list_workspaces") ?? "<nil>")"
        )
    }

    func testCmdShiftWUsesSidebarMultiSelectionSummaryDialog() {
        let app = XCUIApplication()
        configureSocketLaunchEnvironment(app)
        app.launchEnvironment["CMUX_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SIDEBAR_SELECTED_WORKSPACE_INDICES"] = "0,1"
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for close-workspaces shortcut test. state=\(app.state.rawValue)"
        )
        XCTAssertTrue(
            waitForSocketPong(timeout: 12.0),
            "Expected control socket to respond at \(socketPath). diagnostics=\(loadJSON(atPath: diagnosticsPath) ?? [:])"
        )

        XCTAssertEqual(socketCommand("new_workspace")?.prefix(2), "OK")
        XCTAssertTrue(
            waitForWorkspaceCount(2, timeout: 5.0),
            "Expected 2 workspaces before running Cmd+Shift+W. list=\(socketCommand("list_workspaces") ?? "<nil>")"
        )

        app.typeKey("w", modifierFlags: [.command, .shift])

        XCTAssertTrue(
            waitForCloseWorkspacesAlert(app: app, timeout: 5.0),
            "Expected Cmd+Shift+W to use the aggregated close-workspaces alert for sidebar multi-selection"
        )

        clickCancelOnCloseWorkspacesAlert(app: app)

        XCTAssertFalse(
            isCloseWorkspacesAlertPresent(app: app),
            "Expected aggregated close-workspaces alert to dismiss after clicking Cancel"
        )
        XCTAssertTrue(
            waitForWorkspaceCount(2, timeout: 5.0),
            "Expected both workspaces to remain after cancelling Cmd+Shift+W multi-close. list=\(socketCommand("list_workspaces") ?? "<nil>")"
        )
    }

    func testCmdShiftWCloseWorkspacesPromptIsWindowModalSheet() {
        let app = XCUIApplication()
        let recorderPath = "/tmp/cmux-ui-test-close-workspaces-presentation-\(UUID().uuidString).json"
        try? FileManager.default.removeItem(atPath: recorderPath)
        configureSocketLaunchEnvironment(app)
        app.launchEnvironment["CMUX_UI_TEST_KEYEQUIV_PATH"] = recorderPath
        app.launchEnvironment["CMUX_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SIDEBAR_SELECTED_WORKSPACE_INDICES"] = "0,1"
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for close-workspaces modal routing test. state=\(app.state.rawValue)"
        )

        app.typeKey("n", modifierFlags: [.command])
        app.typeKey("n", modifierFlags: [.command])
        let sidebarSelection = waitForJSONKey(
            "tabCount",
            equals: "3",
            atPath: recorderPath,
            timeout: 10.0
        )
        XCTAssertEqual(
            sidebarSelection?["sidebarSelectedWorkspaceCount"],
            "2",
            "Expected Cmd+N to create three workspaces and UI-test setup to select two before Cmd+Shift+W. recorder=\(sidebarSelection ?? loadJSON(atPath: recorderPath) ?? [:])"
        )

        app.typeKey("w", modifierFlags: [.command, .shift])
        let closePrompt = waitForJSONKey(
            "closeConfirmationTitle",
            equals: "Close workspaces?",
            atPath: recorderPath,
            timeout: 5.0
        )
        XCTAssertEqual(
            closePrompt?["closeConfirmationTitle"],
            "Close workspaces?",
            "Expected Cmd+Shift+W to use the aggregated close-workspaces alert for sidebar multi-selection. recorder=\(closePrompt ?? loadJSON(atPath: recorderPath) ?? [:])"
        )

        let presentation = waitForJSONKey(
            "closeConfirmationAttachedSheet",
            equals: "1",
            atPath: recorderPath,
            timeout: 5.0
        )
        XCTAssertEqual(
            presentation?["closeConfirmationPresentation"],
            "sheet",
            "Workspace close confirmation should be attached to the cmux window so it cannot get stranded as a separate app-modal alert. recorder=\(presentation ?? loadJSON(atPath: recorderPath) ?? [:])"
        )
        XCTAssertEqual(
            presentation?["closeConfirmationAttachedSheet"],
            "1",
            "Expected the close confirmation to report an attached sheet. recorder=\(presentation ?? loadJSON(atPath: recorderPath) ?? [:])"
        )

        clickCancelOnCloseWorkspacesAlert(app: app)
    }

    private func configureSocketLaunchEnvironment(_ app: XCUIApplication) {
        app.launchArguments += ["-socketControlMode", "allowAll"]
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        app.launchEnvironment["CMUX_TAG"] = launchTag
    }

    private func ensureForegroundAfterLaunch(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if app.wait(for: .runningForeground, timeout: timeout) {
            return true
        }
        if app.state == .runningBackground {
            app.activate()
            return app.wait(for: .runningForeground, timeout: 6.0)
        }
        return false
    }

    private func waitForSocketPong(timeout: TimeInterval) -> Bool {
        var resolvedPath: String?
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
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
            },
            object: NSObject()
        )
        let completed = XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
        if let resolvedPath {
            socketPath = resolvedPath
        }
        return completed
    }

    private func socketCandidates() -> [String] {
        var candidates = [socketPath, taggedSocketPath()]
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

    private func waitForWorkspaceCount(_ expectedCount: Int, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                self.workspaceCount() == expectedCount
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func workspaceCount() -> Int {
        guard let response = socketCommand("list_workspaces") else { return -1 }
        if response == "No workspaces" {
            return 0
        }
        return response
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
    }

    private func waitForJSONKey(_ key: String, equals expected: String, atPath path: String, timeout: TimeInterval) -> [String: String]? {
        var latest: [String: String]?
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                latest = self.loadJSON(atPath: path)
                return latest?[key] == expected
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed ? latest : nil
    }

    private func loadJSON(atPath path: String) -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return json
    }

    private func socketCommand(_ cmd: String, responseTimeout: TimeInterval = 2.0) -> String? {
        if let response = ControlSocketClient(path: socketPath, responseTimeout: responseTimeout).sendLine(cmd) {
            return response
        }
        return socketCommandViaNetcat(cmd, responseTimeout: responseTimeout)
    }

    private func socketCommandViaNetcat(_ cmd: String, responseTimeout: TimeInterval = 2.0) -> String? {
        let nc = "/usr/bin/nc"
        guard FileManager.default.isExecutableFile(atPath: nc) else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        let timeoutSeconds = max(1, Int(ceil(responseTimeout)))
        let script = "printf '%s\\n' \(shellSingleQuote(cmd)) | \(nc) -U \(shellSingleQuote(socketPath)) -w \(timeoutSeconds) 2>/dev/null"
        proc.arguments = ["-lc", script]

        let outPipe = Pipe()
        proc.standardOutput = outPipe

        do {
            try proc.run()
        } catch {
            return nil
        }

        proc.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let outStr = String(data: outData, encoding: .utf8) else { return nil }
        let trimmed = outStr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func shellSingleQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func isCloseWorkspacesAlertPresent(app: XCUIApplication) -> Bool {
        if closeWorkspacesDialog(app: app).exists { return true }
        if closeWorkspacesAlert(app: app).exists { return true }
        return app.staticTexts["Close workspaces?"].exists
    }

    private func waitForCloseWorkspacesAlert(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                self.isCloseWorkspacesAlertPresent(app: app)
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func clickCancelOnCloseWorkspacesAlert(app: XCUIApplication) {
        let dialog = closeWorkspacesDialog(app: app)
        if dialog.exists {
            dialog.buttons["Cancel"].firstMatch.click()
            return
        }
        let alert = closeWorkspacesAlert(app: app)
        if alert.exists {
            alert.buttons["Cancel"].firstMatch.click()
            return
        }
        let anyDialog = app.dialogs.firstMatch
        if anyDialog.exists, anyDialog.buttons["Cancel"].exists {
            anyDialog.buttons["Cancel"].firstMatch.click()
        }
    }

    private func closeWorkspacesDialog(app: XCUIApplication) -> XCUIElement {
        app.dialogs.containing(.staticText, identifier: "Close workspaces?").firstMatch
    }

    private func closeWorkspacesAlert(app: XCUIApplication) -> XCUIElement {
        app.alerts.containing(.staticText, identifier: "Close workspaces?").firstMatch
    }

    private final class ControlSocketClient {
        private let path: String
        private let responseTimeout: TimeInterval

        init(path: String, responseTimeout: TimeInterval = 2.0) {
            self.path = path
            self.responseTimeout = responseTimeout
        }

        func sendLine(_ line: String) -> String? {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }

            var socketTimeout = timeval(
                tv_sec: Int(responseTimeout.rounded(.down)),
                tv_usec: Int32(((responseTimeout - floor(responseTimeout)) * 1_000_000).rounded())
            )

            var noSigPipe: Int32 = 1
            _ = withUnsafePointer(to: &noSigPipe) { ptr in
                setsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    ptr,
                    socklen_t(MemoryLayout<Int32>.size)
                )
            }
            _ = withUnsafePointer(to: &socketTimeout) { ptr in
                setsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_RCVTIMEO,
                    ptr,
                    socklen_t(MemoryLayout<timeval>.size)
                )
            }
            _ = withUnsafePointer(to: &socketTimeout) { ptr in
                setsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_SNDTIMEO,
                    ptr,
                    socklen_t(MemoryLayout<timeval>.size)
                )
            }

            var addr = sockaddr_un()
            memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
            addr.sun_family = sa_family_t(AF_UNIX)

            let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
            let bytes = Array(path.utf8CString)
            guard bytes.count <= maxLen else { return nil }
            withUnsafeMutablePointer(to: &addr.sun_path) { p in
                let raw = UnsafeMutableRawPointer(p).assumingMemoryBound(to: CChar.self)
                memset(raw, 0, maxLen)
                for i in 0..<bytes.count {
                    raw[i] = bytes[i]
                }
            }

            let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
            let addrLen = socklen_t(pathOffset + bytes.count)
            addr.sun_len = UInt8(min(Int(addrLen), 255))

            let connected = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    connect(fd, sa, addrLen)
                }
            }
            guard connected == 0 else { return nil }

            let payload = line + "\n"
            let wrote: Bool = payload.withCString { cstr in
                var remaining = strlen(cstr)
                var p = UnsafeRawPointer(cstr)
                while remaining > 0 {
                    let n = write(fd, p, remaining)
                    if n <= 0 { return false }
                    remaining -= n
                    p = p.advanced(by: n)
                }
                return true
            }
            guard wrote else { return nil }
            _ = shutdown(fd, SHUT_WR)

            var buf = [UInt8](repeating: 0, count: 4096)
            var accum = ""
            while true {
                let n = read(fd, &buf, buf.count)
                if n < 0 {
                    let code = errno
                    if code == EAGAIN || code == EWOULDBLOCK {
                        break
                    }
                    return nil
                }
                if n <= 0 { break }
                if let chunk = String(bytes: buf[0..<n], encoding: .utf8) {
                    accum.append(chunk)
                }
            }
            let trimmed = accum.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}
