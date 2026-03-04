import XCTest
import Foundation
import CoreGraphics

final class MultiWindowNotificationsUITests: XCTestCase {
    private var dataPath = ""
    private var socketPath = ""
    private var launchTag = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        dataPath = "/tmp/cmux-ui-test-multi-window-notifs-\(UUID().uuidString).json"
        socketPath = "/tmp/cmux-ui-test-socket-\(UUID().uuidString).sock"
        launchTag = "ui-tests-multi-window-notifs-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.removeItem(atPath: dataPath)
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dataPath)
        try? FileManager.default.removeItem(atPath: socketPath)
        super.tearDown()
    }

    func testNotificationsRouteToCorrectWindow() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_PATH"] = dataPath
        app.launchEnvironment["CMUX_TAG"] = launchTag
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for multi-window routing test. state=\(app.state.rawValue)"
        )

        XCTAssertTrue(
            waitForData(keys: [
                "window1Id",
                "window2Id",
                "window2InitialSidebarSelection",
                "tabId1",
                "tabId2",
                "notifId1",
                "notifId2",
                "expectedLatestWindowId",
                "expectedLatestTabId",
            ], timeout: 15.0),
            "Expected multi-window notification setup data"
        )

        guard let setup = loadData() else {
            XCTFail("Missing setup data")
            return
        }

        let expectedLatestWindowId = setup["expectedLatestWindowId"] ?? ""
        let expectedLatestTabId = setup["expectedLatestTabId"] ?? ""
        let window2Id = setup["window2Id"] ?? ""
        let window2InitialSidebarSelection = setup["window2InitialSidebarSelection"] ?? ""
        let tabId2 = setup["tabId2"] ?? ""
        let notifId2 = setup["notifId2"] ?? ""

        XCTAssertFalse(expectedLatestWindowId.isEmpty)
        XCTAssertFalse(expectedLatestTabId.isEmpty)
        XCTAssertFalse(window2Id.isEmpty)
        XCTAssertEqual(window2InitialSidebarSelection, "notifications")
        XCTAssertFalse(tabId2.isEmpty)
        XCTAssertFalse(notifId2.isEmpty)

        // Sanity: ensure the second window was actually created.
        XCTAssertTrue(waitForWindowCount(atLeast: 2, app: app, timeout: 6.0))

        // Jump to latest unread (Cmd+Shift+U). This should bring the owning window forward.
        let beforeToken = loadData()?["focusToken"]
        app.typeKey("u", modifierFlags: [.command, .shift])

        XCTAssertTrue(
            waitForFocusChange(from: beforeToken, timeout: 6.0),
            "Expected focus record after jump-to-unread"
        )
        guard let afterJump = loadData() else {
            XCTFail("Missing focus data after jump")
            return
        }
        XCTAssertEqual(afterJump["focusedWindowId"], expectedLatestWindowId)
        XCTAssertEqual(afterJump["focusedTabId"], expectedLatestTabId)

        // Open the notifications popover (Cmd+I) and click the notification belonging to window 2.
        let beforeClickToken = afterJump["focusToken"]
        app.typeKey("i", modifierFlags: [.command])

        let targetButton = app.buttons["NotificationPopoverRow.\(notifId2)"]
        XCTAssertTrue(targetButton.waitForExistence(timeout: 6.0), "Expected notification row button to exist")
        XCTAssertTrue(
            clickNotificationPopoverRowAndWaitForFocusChange(
                button: targetButton,
                app: app,
                from: beforeClickToken,
                timeout: 6.0
            ),
            "Expected focus record after clicking notification"
        )
        guard let afterClick = loadData() else {
            XCTFail("Missing focus data after click")
            return
        }
        XCTAssertEqual(afterClick["focusedWindowId"], window2Id)
        XCTAssertEqual(afterClick["focusedTabId"], tabId2)
        XCTAssertEqual(afterClick["focusedSidebarSelection"], "tabs")
    }

    func testNotificationsPopoverCanCloseViaShortcutAndEscape() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_PATH"] = dataPath
        app.launchEnvironment["CMUX_TAG"] = launchTag
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for notifications popover shortcut test. state=\(app.state.rawValue)"
        )

        XCTAssertTrue(
            waitForData(keys: ["notifId1"], timeout: 15.0),
            "Expected multi-window notification setup data"
        )

        guard let notifId1 = loadData()?["notifId1"], !notifId1.isEmpty else {
            XCTFail("Missing setup notification id")
            return
        }

        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 6.0))

        app.typeKey("i", modifierFlags: [.command])
        let targetButton = app.buttons["NotificationPopoverRow.\(notifId1)"]
        XCTAssertTrue(targetButton.waitForExistence(timeout: 6.0), "Expected popover to open on Show Notifications shortcut")

        app.typeKey("i", modifierFlags: [.command])
        XCTAssertTrue(waitForElementToDisappear(targetButton, timeout: 3.0), "Expected popover to close on repeated Show Notifications shortcut")

        app.typeKey("i", modifierFlags: [.command])
        XCTAssertTrue(targetButton.waitForExistence(timeout: 6.0), "Expected popover to reopen on Show Notifications shortcut")

        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(waitForElementToDisappear(targetButton, timeout: 3.0), "Expected popover to close on Escape")
    }

    func testEmptyNotificationsPopoverBlocksTerminalTyping() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-socketControlMode", "allowAll"]
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_TAG"] = launchTag
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for empty popover blocking test. state=\(app.state.rawValue)"
        )

        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 12.0))
        guard let resolvedPath = resolveSocketPath(timeout: 20.0) else {
            throw XCTSkip("Control socket unavailable in this test environment. requested=\(socketPath)")
        }
        socketPath = resolvedPath
        let pingResponse = waitForSocketPong(timeout: 20.0)
        guard pingResponse == "PONG" else {
            throw XCTSkip("Control socket did not respond in time. path=\(socketPath) response=\(pingResponse ?? "<nil>")")
        }

        _ = socketCommand("clear_notifications")

        app.typeKey("i", modifierFlags: [.command])
        XCTAssertTrue(app.staticTexts["No notifications yet"].waitForExistence(timeout: 6.0), "Expected empty notifications popover state")

        let marker = "cmux_notif_block_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))"
        let before = readCurrentTerminalText() ?? ""
        XCTAssertFalse(before.contains(marker), "Unexpected marker precondition collision")

        app.typeText(marker)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))

        guard let after = readCurrentTerminalText() else {
            XCTFail("Expected terminal text from control socket")
            return
        }
        XCTAssertFalse(after.contains(marker), "Expected typing to be blocked while empty notifications popover is open")
    }

    func testTmuxOSCBridgeRoutesNotificationToMappedSurface() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-socketControlMode", "allowAll"]
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_TAG"] = launchTag
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for tmux OSC bridge test. state=\(app.state.rawValue)"
        )

        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 12.0))
        guard let resolvedPath = resolveSocketPath(timeout: 20.0) else {
            throw XCTSkip("Control socket unavailable in this test environment. requested=\(socketPath)")
        }
        socketPath = resolvedPath
        let pingResponse = waitForSocketPong(timeout: 20.0)
        guard pingResponse == "PONG" else {
            throw XCTSkip("Control socket did not respond in time. path=\(socketPath) response=\(pingResponse ?? "<nil>")")
        }

        guard let workspaceId = currentWorkspaceId() else {
            XCTFail("Expected current workspace ID from control socket")
            return
        }
        guard let surfaceId = currentFocusedSurfaceId() else {
            XCTFail("Expected focused surface ID from control socket")
            return
        }

        guard let tmuxBin = resolveExecutable(
            named: "tmux",
            fallbacks: ["/usr/bin/tmux", "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]
        ) else {
            throw XCTSkip("tmux is not available on this runner")
        }
        guard let cmuxBin = resolveCmuxCLIExecutable() else {
            XCTFail("Unable to resolve cmux CLI executable from test environment")
            return
        }

        _ = socketCommand("clear_notifications")

        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let tmuxSocket = "/tmp/cmux-ui-test-tmux-\(token).sock"
        let bridgeLogPath = "/tmp/cmux-ui-test-tmux-bridge-\(token).log"
        let sessionName = "cmuxui\(String(token.prefix(10)))"
        let notificationTitle = "tmux_bridge_\(String(token.prefix(12)))"
        let notificationBody = "bridge_body_\(String(token.suffix(12)))"
        try? FileManager.default.removeItem(atPath: tmuxSocket)
        try? FileManager.default.removeItem(atPath: bridgeLogPath)
        defer {
            _ = try? runProcess(
                executable: tmuxBin,
                arguments: ["-S", tmuxSocket, "kill-server"]
            )
            try? FileManager.default.removeItem(atPath: tmuxSocket)
            try? FileManager.default.removeItem(atPath: bridgeLogPath)
        }

        let createSession = try runProcess(
            executable: tmuxBin,
            arguments: ["-S", tmuxSocket, "new-session", "-d", "-s", sessionName]
        )
        guard createSession.status == 0 else {
            XCTFail("Failed to create tmux session: \(createSession.stderr)")
            return
        }
        guard let paneId = try firstTmuxPaneId(tmuxBin: tmuxBin, tmuxSocket: tmuxSocket) else {
            XCTFail("Failed to resolve tmux pane ID")
            return
        }

        for (option, value) in [
            ("@cmux_workspace_id", workspaceId),
            ("@cmux_surface_id", surfaceId),
            ("@cmux_socket_path", socketPath),
        ] {
            let setResult = try runProcess(
                executable: tmuxBin,
                arguments: ["-S", tmuxSocket, "set-option", "-p", "-t", paneId, option, value]
            )
            guard setResult.status == 0 else {
                XCTFail("Failed to set tmux pane option \(option): \(setResult.stderr)")
                return
            }
        }

        let bridgeProcess = Process()
        bridgeProcess.executableURL = URL(fileURLWithPath: cmuxBin)
        bridgeProcess.arguments = [
            "--socket",
            socketPath,
            "tmux-osc-bridge",
            "--ensure",
            "--tmux-socket",
            tmuxSocket,
            "--tmux-bin",
            tmuxBin,
            "--debug-log",
            bridgeLogPath,
        ]
        var bridgeEnv = ProcessInfo.processInfo.environment
        if bridgeEnv["PATH"]?.isEmpty ?? true {
            bridgeEnv["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        }
        bridgeProcess.environment = bridgeEnv
        bridgeProcess.standardOutput = Pipe()
        bridgeProcess.standardError = Pipe()
        try bridgeProcess.run()
        defer { terminateProcess(bridgeProcess) }

        XCTAssertTrue(
            waitForBridgeAttach(logPath: bridgeLogPath, timeout: 8.0),
            "Bridge did not report attach in log at \(bridgeLogPath)"
        )
        XCTAssertTrue(bridgeProcess.isRunning, "tmux OSC bridge exited early")

        let oscCommand = "printf '\\033]777;notify;\(notificationTitle);\(notificationBody)\\a'"
        let sendResult = try runProcess(
            executable: tmuxBin,
            arguments: ["-S", tmuxSocket, "send-keys", "-t", paneId, oscCommand, "C-m"]
        )
        guard sendResult.status == 0 else {
            XCTFail("Failed to send OSC payload via tmux: \(sendResult.stderr)")
            return
        }

        guard let bridgedNotification = waitForNotification(
            title: notificationTitle,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            timeout: 10.0
        ) else {
            let debugLog = (try? String(contentsOfFile: bridgeLogPath, encoding: .utf8)) ?? "<missing bridge log>"
            XCTFail("Expected bridged notification for title=\(notificationTitle). bridge log:\n\(debugLog)")
            return
        }
        XCTAssertEqual(bridgedNotification.subtitle, "tmux")
        XCTAssertEqual(bridgedNotification.body, notificationBody)
    }

    private func clickNotificationPopoverRowAndWaitForFocusChange(
        button: XCUIElement,
        app: XCUIApplication,
        from token: String?,
        timeout: TimeInterval
    ) -> Bool {
        // `.click()` on a button inside an NSPopover can be flaky on the VM; prefer a coordinate click
        // within the left side of the row (away from the clear button).
        if button.exists {
            let coord = button.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
            coord.click()
        } else {
            button.click()
        }

        // If the coordinate click was swallowed (popover auto-dismiss, etc), retry with a normal click.
        let firstDeadline = min(1.0, timeout)
        if waitForFocusChange(from: token, timeout: firstDeadline) {
            return true
        }
        button.click()
        return waitForFocusChange(from: token, timeout: max(0.0, timeout - firstDeadline))
    }

    private func waitForWindowCount(atLeast count: Int, app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.windows.count >= count { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return app.windows.count >= count
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

    private func waitForElementToDisappear(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForFocusChange(from token: String?, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = loadData(),
               let current = data["focusToken"],
               !current.isEmpty,
               current != token {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let data = loadData(),
           let current = data["focusToken"],
           !current.isEmpty,
           current != token {
            return true
        }
        return false
    }

    private func waitForData(keys: [String], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = loadData(), keys.allSatisfy({ (data[$0] ?? "").isEmpty == false }) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let data = loadData(), keys.allSatisfy({ (data[$0] ?? "").isEmpty == false }) {
            return true
        }
        return false
    }

    private func waitForSocketPong(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var lastResponse: String?
        while Date() < deadline {
            lastResponse = socketCommand("ping")
            if lastResponse == "PONG" {
                return "PONG"
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return socketCommand("ping") ?? lastResponse
    }

    private func resolveSocketPath(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for candidate in expectedSocketCandidates() {
                guard FileManager.default.fileExists(atPath: candidate) else { continue }
                if socketRespondsToPing(at: candidate) {
                    return candidate
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        for candidate in expectedSocketCandidates() {
            guard FileManager.default.fileExists(atPath: candidate) else { continue }
            if socketRespondsToPing(at: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func expectedSocketCandidates() -> [String] {
        var candidates = [socketPath]
        let taggedDebugSocket = "/tmp/cmux-debug-\(launchTag).sock"
        if taggedDebugSocket != socketPath {
            candidates.append(taggedDebugSocket)
        }
        candidates.append("/tmp/cmux-debug.sock")
        candidates.append("/tmp/cmux.sock")
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: "/tmp") {
            let tagged = entries
                .filter { $0.hasPrefix("cmux-debug-") && $0.hasSuffix(".sock") }
                .map { "/tmp/\($0)" }
                .sorted {
                    let a = ((try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate]) as? Date) ?? .distantPast
                    let b = ((try? FileManager.default.attributesOfItem(atPath: $1)[.modificationDate]) as? Date) ?? .distantPast
                    return a > b
                }
            candidates.append(contentsOf: tagged)
        }
        var seen = Set<String>()
        candidates = candidates.filter { seen.insert($0).inserted }
        return candidates
    }

    private func socketRespondsToPing(at path: String) -> Bool {
        let originalPath = socketPath
        socketPath = path
        defer { socketPath = originalPath }
        return socketCommand("ping") == "PONG"
    }

    private func socketCommand(_ cmd: String) -> String? {
        if let response = ControlSocketClient(path: socketPath).sendLine(cmd) {
            return response
        }
        return socketCommandViaNetcat(cmd)
    }

    private func socketCommandViaNetcat(_ cmd: String) -> String? {
        let nc = "/usr/bin/nc"
        guard FileManager.default.isExecutableFile(atPath: nc) else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        let script = "printf '%s\\n' \(shellSingleQuote(cmd)) | \(nc) -U \(shellSingleQuote(socketPath)) -w 2 2>/dev/null"
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
        if let first = outStr.split(separator: "\n", maxSplits: 1).first {
            return String(first).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let trimmed = outStr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func shellSingleQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private final class ControlSocketClient {
        private let path: String

        init(path: String) {
            self.path = path
        }

        func sendLine(_ line: String) -> String? {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }

#if os(macOS)
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
#endif

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
#if os(macOS)
            addr.sun_len = UInt8(min(Int(addrLen), 255))
#endif

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

            var buf = [UInt8](repeating: 0, count: 4096)
            var accum = ""
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                if let chunk = String(bytes: buf[0..<n], encoding: .utf8) {
                    accum.append(chunk)
                    if let idx = accum.firstIndex(of: "\n") {
                        return String(accum[..<idx])
                    }
                }
            }
            return accum.isEmpty ? nil : accum.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func readCurrentTerminalText() -> String? {
        guard let response = socketCommand("read_terminal_text"), response.hasPrefix("OK ") else {
            return nil
        }
        let encoded = String(response.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private struct SocketNotification {
        let id: String
        let workspaceId: String
        let surfaceId: String?
        let isRead: Bool
        let title: String
        let subtitle: String
        let body: String
    }

    private func currentWorkspaceId() -> String? {
        guard let response = socketCommand("current_workspace") else { return nil }
        let value = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("ERROR") else { return nil }
        return value
    }

    private func currentFocusedSurfaceId() -> String? {
        guard let response = socketCommand("list_surfaces") else { return nil }
        let lines = response
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        for line in lines where line.hasPrefix("*") {
            if let id = parseSurfaceId(from: line) {
                return id
            }
        }
        return parseSurfaceId(from: lines[0])
    }

    private func parseSurfaceId(from line: String) -> String? {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("*") {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        let id = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    private func listNotifications() -> [SocketNotification] {
        guard let response = socketCommand("list_notifications") else { return [] }
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "No notifications" else { return [] }

        var items: [SocketNotification] = []
        for rawLine in trimmed.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let payload = String(line[line.index(after: colon)...])
            let parts = payload.split(separator: "|", maxSplits: 6, omittingEmptySubsequences: false)
            guard parts.count == 7 else { continue }
            let id = String(parts[0])
            let workspaceId = String(parts[1])
            let surfaceRaw = String(parts[2])
            let readRaw = String(parts[3])
            let title = String(parts[4])
            let subtitle = String(parts[5])
            let body = String(parts[6])
            items.append(
                SocketNotification(
                    id: id,
                    workspaceId: workspaceId,
                    surfaceId: surfaceRaw == "none" ? nil : surfaceRaw,
                    isRead: readRaw == "read",
                    title: title,
                    subtitle: subtitle,
                    body: body
                )
            )
        }
        return items
    }

    private func waitForNotification(
        title: String,
        workspaceId: String,
        surfaceId: String,
        timeout: TimeInterval
    ) -> SocketNotification? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let match = listNotifications().first(where: {
                $0.title == title &&
                $0.workspaceId == workspaceId &&
                $0.surfaceId == surfaceId &&
                !$0.isRead
            }) {
                return match
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return listNotifications().first(where: {
            $0.title == title &&
            $0.workspaceId == workspaceId &&
            $0.surfaceId == surfaceId
        })
    }

    private func waitForBridgeAttach(logPath: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let log = try? String(contentsOfFile: logPath, encoding: .utf8),
               log.contains("attach session=") {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let log = try? String(contentsOfFile: logPath, encoding: .utf8),
           log.contains("attach session=") {
            return true
        }
        return false
    }

    private func firstTmuxPaneId(tmuxBin: String, tmuxSocket: String) throws -> String? {
        let result = try runProcess(
            executable: tmuxBin,
            arguments: ["-S", tmuxSocket, "list-panes", "-a", "-F", "#{pane_id}"]
        )
        guard result.status == 0 else { return nil }
        for line in result.stdout.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private func resolveCmuxCLIExecutable() -> String? {
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []

        if let explicit = env["CMUX_UI_TEST_CMUX_CLI_PATH"], !explicit.isEmpty {
            candidates.append(explicit)
        }
        if let builtProducts = env["BUILT_PRODUCTS_DIR"], !builtProducts.isEmpty {
            candidates.append((builtProducts as NSString).appendingPathComponent("cmux"))
        }
        if let targetBuildDir = env["TARGET_BUILD_DIR"], !targetBuildDir.isEmpty {
            candidates.append((targetBuildDir as NSString).appendingPathComponent("cmux"))
            let parent = (targetBuildDir as NSString).deletingLastPathComponent
            candidates.append((parent as NSString).appendingPathComponent("cmux"))
        }

        let testBundlePath = Bundle(for: Self.self).bundleURL.path
        let pathComponents = (testBundlePath as NSString).pathComponents
        if let productsIndex = pathComponents.firstIndex(of: "Products"), productsIndex + 1 < pathComponents.count {
            let prefix = pathComponents.prefix(productsIndex + 2).joined(separator: "/")
            let normalizedPrefix = prefix.hasPrefix("/") ? prefix : "/" + prefix
            candidates.append((normalizedPrefix as NSString).appendingPathComponent("cmux"))
        }

        if let fromPath = resolveExecutable(named: "cmux", fallbacks: ["/usr/local/bin/cmux", "/opt/homebrew/bin/cmux"]) {
            candidates.append(fromPath)
        }

        var seen = Set<String>()
        for candidate in candidates {
            guard !candidate.isEmpty else { continue }
            guard seen.insert(candidate).inserted else { continue }
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func resolveExecutable(named name: String, fallbacks: [String]) -> String? {
        let env = ProcessInfo.processInfo.environment
        let searchPath = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        for entry in searchPath {
            guard !entry.isEmpty else { continue }
            let candidate = (entry as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        for fallback in fallbacks where FileManager.default.isExecutableFile(atPath: fallback) {
            return fallback
        }
        return nil
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    private func terminateProcess(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(2.0)
        while process.isRunning, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if process.isRunning {
            _ = try? runProcess(executable: "/bin/kill", arguments: ["-9", String(process.processIdentifier)])
        }
    }

    private func loadData() -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: dataPath)) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }
}
