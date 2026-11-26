import XCTest
import Foundation
import Darwin

/// Regression coverage for https://github.com/manaflow-ai/cmux issue: Cmd+[ /
/// Cmd+] must traverse the GLOBAL workspace focus history (the same
/// `TabManager.navigateBack()/navigateForward()` path as the titlebar arrow
/// buttons), not cycle panes inside the current workspace.
///
/// Ghostty's macOS defaults put `goto_split:previous/next` on ⌘[ / ⌘], the same
/// keys as cmux's Focus Back/Forward defaults. The app-level dispatch mirrors
/// those Ghostty triggers to cycle pane focus and runs that mirror before the
/// focus-history branch, so before the fix the mirror consumed ⌘[ / ⌘]
/// unconditionally: pressing the keys cycled panes within the workspace (or did
/// nothing in a single-pane workspace) while the titlebar arrows navigated
/// across workspaces.
///
/// The tests drive the shortcut through `simulate_shortcut`, which routes
/// through `AppDelegate.debugHandleCustomShortcut` — the exact same matcher and
/// dispatch order as real keystrokes from the app-level event monitor — so the
/// old bug reproduces deterministically on headless CI runners where real
/// keystroke foregrounding is flaky.
final class FocusHistoryShortcutUITests: XCTestCase {
    private var socketPath = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-ui-test-focus-history-\(UUID().uuidString).sock"
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: socketPath)
        super.tearDown()
    }

    func testCmdBracketWalksWorkspaceFocusHistoryBackAndForward() {
        let (_, cleanup) = launchIsolatedApp()
        defer { cleanup() }

        guard let workspaces = createAndVisitWorkspaces(count: 3) else { return }

        XCTAssertTrue(
            waitForCurrentWorkspace(workspaces[2], timeout: 10.0),
            "Expected focus on the last created workspace before navigating"
        )

        // Back: ws3 -> ws2 -> ws1. Before the fix the Ghostty goto_split mirror
        // consumed ⌘[ and the current workspace never changed.
        simulateShortcut("cmd+[")
        XCTAssertTrue(
            waitForCurrentWorkspace(workspaces[1], timeout: 10.0),
            "Cmd+[ should navigate focus history back across workspaces (ws3 -> ws2). current=\(currentWorkspace() ?? "nil")"
        )
        simulateShortcut("cmd+[")
        XCTAssertTrue(
            waitForCurrentWorkspace(workspaces[0], timeout: 10.0),
            "Second Cmd+[ should continue back across workspaces (ws2 -> ws1). current=\(currentWorkspace() ?? "nil")"
        )

        // Forward: ws1 -> ws2 -> ws3, proving the forward stack survives.
        simulateShortcut("cmd+]")
        XCTAssertTrue(
            waitForCurrentWorkspace(workspaces[1], timeout: 10.0),
            "Cmd+] should navigate focus history forward (ws1 -> ws2). current=\(currentWorkspace() ?? "nil")"
        )
        simulateShortcut("cmd+]")
        XCTAssertTrue(
            waitForCurrentWorkspace(workspaces[2], timeout: 10.0),
            "Second Cmd+] should continue forward (ws2 -> ws3). current=\(currentWorkspace() ?? "nil")"
        )
    }

    func testCmdBracketSkipsClosedWorkspacesLikeTheArrowButtons() {
        let (_, cleanup) = launchIsolatedApp()
        defer { cleanup() }

        guard let workspaces = createAndVisitWorkspaces(count: 3) else { return }

        XCTAssertTrue(
            waitForCurrentWorkspace(workspaces[2], timeout: 10.0),
            "Expected focus on the last created workspace before closing ws2"
        )

        let closeReply = socketCommand("close_workspace \(workspaces[1])")
        XCTAssertEqual(closeReply, "OK", "Expected ws2 to close non-interactively, got \(closeReply ?? "nil")")

        // Back from ws3 must skip the closed ws2 and land on ws1, matching the
        // titlebar arrow buttons' closed-workspace pruning.
        simulateShortcut("cmd+[")
        XCTAssertTrue(
            waitForCurrentWorkspace(workspaces[0], timeout: 10.0),
            "Cmd+[ should skip the closed workspace and land on ws1. current=\(currentWorkspace() ?? "nil")"
        )
    }

    // MARK: - Workspace setup over the control socket

    /// Creates `count` workspaces and visits each in creation order so the
    /// focus-history stack ends as [start, ws1, ..., wsN] with wsN current.
    private func createAndVisitWorkspaces(count: Int) -> [String]? {
        var created: [String] = []
        for index in 1...count {
            let reply = socketCommand("new_workspace focus-history-ws\(index)")
            guard let reply,
                  reply.hasPrefix("OK "),
                  let id = reply.split(separator: " ").last.map(String.init),
                  UUID(uuidString: id) != nil else {
                XCTFail("new_workspace #\(index) failed: \(reply ?? "nil")")
                return nil
            }
            created.append(id)
        }
        for id in created {
            guard socketCommand("select_workspace \(id)") == "OK" else {
                XCTFail("select_workspace \(id) failed")
                return nil
            }
            // Selection records focus history synchronously in the
            // selectedTabId didSet; a short settle keeps ordering deterministic.
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        return created
    }

    private func simulateShortcut(_ combo: String) {
        let reply = socketCommand("simulate_shortcut \(combo)", responseTimeout: 30.0)
        XCTAssertEqual(reply, "OK", "simulate_shortcut \(combo) failed: \(reply ?? "nil")")
    }

    private func currentWorkspace() -> String? {
        guard let reply = socketCommand("current_workspace"),
              UUID(uuidString: reply) != nil else { return nil }
        return reply
    }

    private func waitForCurrentWorkspace(_ workspaceId: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if currentWorkspace() == workspaceId { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return currentWorkspace() == workspaceId
    }

    // MARK: - Launch

    private func launchIsolatedApp() -> (XCUIApplication, () -> Void) {
        let fileManager = FileManager.default
        let isolatedHome = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-ui-test-focus-history-\(UUID().uuidString)",
            isDirectory: true
        )
        try? fileManager.createDirectory(at: isolatedHome, withIntermediateDirectories: true)

        let app = XCUIApplication.cmuxTestApplication()
        // Isolated HOME: no user cmux.json shortcut overrides, no user Ghostty
        // keybinds, no restored session — the test exercises factory defaults.
        app.launchEnvironment["HOME"] = isolatedHome.path
        app.launchEnvironment["CFFIXED_USER_HOME"] = isolatedHome.path
        app.launchEnvironment["XDG_CONFIG_HOME"] =
            isolatedHome.appendingPathComponent(".config", isDirectory: true).path
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_TAG"] = "ui-tests-focus-history-\(UUID().uuidString.prefix(8))"
        // Backgrounded apps on CI runners get App Nap throttled and this test
        // drives everything through the control socket, which replies after
        // main-thread hops.
        app.launchArguments += ["-NSAppSleepDisabled", "YES"]

        // The whole flow runs over the control socket, so a backgrounded app is
        // fine; launch() itself raises when activation cannot win on headless
        // CI runners (state stays Running Background), so tolerate that.
        let launchOptions = XCTExpectedFailure.Options()
        launchOptions.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: launchOptions) {
            app.launch()
        }

        let launched = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    app.state == .runningForeground || app.state == .runningBackground
                },
                object: NSObject()
            )],
            timeout: 15.0
        ) == .completed
        XCTAssertTrue(launched, "App failed to start. state=\(app.state.rawValue)")

        let socketReady = waitForControlSocketReady(
            pingTimeout: 20.0,
            socketFileExists: { FileManager.default.fileExists(atPath: self.socketPath) },
            pingReturnsPong: { self.socketCommand("ping") == "PONG" }
        )
        XCTAssertTrue(socketReady, "Control socket never answered ping at \(socketPath)")

        // App-side activation (socket main-hop) so synthetic shortcut events
        // land in a prepared key window even when XCUI activation lost above.
        // Also proves a main-thread hop completes before the interesting
        // commands run (first launch on a clean runner can wedge for a while).
        var mainHopReady = false
        for _ in 0..<12 where !mainHopReady {
            mainHopReady = socketCommand("activate_app", responseTimeout: 10.0) == "OK"
        }
        XCTAssertTrue(mainHopReady, "Main thread never serviced an activate_app socket hop")

        return (app, {
            app.terminate()
            try? fileManager.removeItem(at: isolatedHome)
        })
    }

    // MARK: - Control socket plumbing

    private func socketCommand(_ command: String, responseTimeout: TimeInterval = 10.0) -> String? {
        ControlSocketClient(path: socketPath, responseTimeout: responseTimeout).sendLine(command)
    }

    private final class ControlSocketClient {
        private let path: String
        private let responseTimeout: TimeInterval

        init(path: String, responseTimeout: TimeInterval) {
            self.path = path
            self.responseTimeout = responseTimeout
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
