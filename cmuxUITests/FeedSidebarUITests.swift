import Foundation
import XCTest

/// Exercises the right-sidebar Feed end-to-end: boot the app with a
/// dedicated socket, inject a synthetic permission request in-process,
/// toggle the sidebar to Dock mode, drive the Feed TUI from the keyboard,
/// and assert the hook-side response carries the resolved decision.
final class FeedSidebarUITests: XCTestCase {
    private var socketPath = ""
    private var diagnosticsPath = ""
    private var feedResultPath = ""
    private var requestId = ""
    private var lastSocketProbe = ""
    private let modeKey = "socketControlMode"
    private let launchTag = "ui-tests-feed-sidebar"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-debug-\(UUID().uuidString).sock"
        diagnosticsPath = "/tmp/cmux-feed-sidebar-\(UUID().uuidString).json"
        feedResultPath = "/tmp/cmux-feed-sidebar-result-\(UUID().uuidString).json"
        requestId = "uitest-\(UUID().uuidString)"
        removeSocketFile()
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
        try? FileManager.default.removeItem(atPath: feedResultPath)
    }

    func testFeedReceivesAndResolvesPermissionRequest() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-\(modeKey)", "allowAll",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = launchTag
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        app.launchEnvironment["CMUX_UI_TEST_PORTAL_STATS"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_FEED_SIDEBAR_RESULT_PATH"] = feedResultPath
        app.launchEnvironment["CMUX_UI_TEST_FEED_SIDEBAR_REQUEST_ID"] = requestId
        launchAndEnsureUsable(app)

        XCTAssertTrue(
            waitForInAppSocketReady(timeout: 75),
            "Expected app-side control socket readiness at \(socketPath). diagnostics=\(loadDiagnostics())"
        )
        XCTAssertTrue(
            waitForFeedBridgeStarted(timeout: 10),
            "Synthetic feed.push did not start. result=\(loadFeedResult())"
        )

        XCTAssertTrue(
            revealDockMode(in: app),
            "Dock mode did not open in the right sidebar. diagnostics=\(loadDiagnostics())"
        )

        let focusButton = app.buttons["Focus Control"].firstMatch
        XCTAssertTrue(
            focusButton.waitForExistence(timeout: 10),
            "Dock Feed focus button did not appear"
        )
        focusButton.click()
        XCTAssertTrue(
            waitForOpenTUIFeedAppPrepared(timeout: 45),
            "OpenTUI Feed app was not prepared"
        )

        // The TUI blocks on keyboard input. Refresh first so it observes the
        // pending request, then Enter accepts the default "once" action.
        app.typeKey("r", modifierFlags: [])
        Thread.sleep(forTimeInterval: 1.0)
        app.typeKey(.return, modifierFlags: [])

        // Await the hook-side reply from the earlier in-app feed.push.
        let result = try waitForFeedBridgeResult(timeout: 35)
        XCTAssertEqual(
            result.status, "resolved",
            "Expected feed.push to resolve, got status=\(result.status)"
        )
        XCTAssertEqual(result.mode, "once")

        app.typeKey("3", modifierFlags: [.control])
        XCTAssertTrue(
            app.buttons["RightSidebarModeButton.sessions"].firstMatch.waitForExistence(timeout: 5),
            "Sessions mode button disappeared after Ctrl-3"
        )
        XCTAssertTrue(
            waitForDockPortalToLeaveVisibleSidebar(timeout: 5),
            "Dock terminal portal stayed visible after switching from Ctrl-4 Dock to Ctrl-3 Sessions"
        )

        app.terminate()
    }

    // MARK: - Socket helpers

    private struct FeedPushResult {
        let status: String
        let mode: String
    }

    private func waitForInAppSocketReady(timeout: TimeInterval) -> Bool {
        pollUntil(timeout: timeout) {
            let diagnostics = loadDiagnostics()
            return diagnostics["socketReady"] == "1" &&
                diagnostics["socketPingResponse"] == "PONG"
        }
    }

    private func waitForFeedBridgeStarted(timeout: TimeInterval) -> Bool {
        pollUntil(timeout: timeout) {
            let stage = loadFeedResult()["stage"]
            return stage == "feedPushStarting" || stage == "feedPushReturned"
        }
    }

    private func waitForFeedBridgeResult(timeout: TimeInterval) throws -> FeedPushResult {
        var payload: [String: String] = [:]
        let completed = pollUntil(timeout: timeout) {
            payload = loadFeedResult()
            return payload["stage"] == "feedPushReturned"
        }
        guard completed else {
            throw NSError(
                domain: "FeedPush",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "feed.push never returned. result=\(loadFeedResult())"]
            )
        }
        guard payload["ok"] == "1" else {
            throw NSError(
                domain: "FeedPush",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "feed.push failed. result=\(payload)"]
            )
        }
        return FeedPushResult(
            status: payload["status"] ?? "",
            mode: payload["mode"] ?? ""
        )
    }

    private final class FeedPushFuture {
        private let semaphore = DispatchSemaphore(value: 0)
        private var outcome: Result<FeedPushResult, Error>?

        func resolve(_ outcome: Result<FeedPushResult, Error>) {
            self.outcome = outcome
            semaphore.signal()
        }

        func result(timeout: TimeInterval) throws -> FeedPushResult {
            let deadline: DispatchTime = .now() + timeout
            if semaphore.wait(timeout: deadline) == .timedOut {
                throw NSError(domain: "FeedPush", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "feed.push never returned"])
            }
            return try outcome!.get()
        }
    }

    private func sendFeedPush(requestId: String, waitSeconds: Double) throws -> FeedPushFuture {
        let future = FeedPushFuture()
        DispatchQueue.global().async {
            do {
                let params: [String: Any] = [
                    "event": [
                        "session_id": "uitest-\(requestId)",
                        "hook_event_name": "PermissionRequest",
                        "_source": "claude",
                        "tool_name": "Write",
                        "tool_input": ["file_path": "/tmp/feeduitest"],
                        "_opencode_request_id": requestId,
                    ],
                    "wait_timeout_seconds": waitSeconds,
                ]
                let frame: [String: Any] = [
                    "id": UUID().uuidString,
                    "method": "feed.push",
                    "params": params,
                ]
                let data = try JSONSerialization.data(withJSONObject: frame)
                let line = (String(data: data, encoding: .utf8) ?? "{}") + "\n"
                let response = try self.sendSocketLine(line, responseTimeout: waitSeconds + 5)
                guard let respData = response.data(using: .utf8),
                      let respObj = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
                      (respObj["ok"] as? Bool) == true,
                      let result = respObj["result"] as? [String: Any],
                      let status = result["status"] as? String
                else {
                    future.resolve(.failure(NSError(
                        domain: "FeedPush", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "invalid response: \(response)"]
                    )))
                    return
                }
                let mode = (result["decision"] as? [String: Any])?["mode"] as? String ?? ""
                future.resolve(.success(FeedPushResult(status: status, mode: mode)))
            } catch {
                future.resolve(.failure(error))
            }
        }
        return future
    }

    private func sendLine(_ line: String, responseTimeout: TimeInterval = 2.0) throws -> String {
        let sockFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sockFd != -1 else {
            throw NSError(
                domain: "FeedSidebarUITests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "socket() failed errno=\(errno)"]
            )
        }
        defer { close(sockFd) }

        var socketTimeout = timeval(
            tv_sec: Int(responseTimeout.rounded(.down)),
            tv_usec: Int32(((responseTimeout - floor(responseTimeout)) * 1_000_000).rounded())
        )
        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) { ptr in
            setsockopt(
                sockFd,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                ptr,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        _ = withUnsafePointer(to: &socketTimeout) { ptr in
            setsockopt(
                sockFd,
                SOL_SOCKET,
                SO_RCVTIMEO,
                ptr,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        _ = withUnsafePointer(to: &socketTimeout) { ptr in
            setsockopt(
                sockFd,
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
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= maxLen else {
            throw NSError(
                domain: "FeedSidebarUITests",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "socket path too long: \(socketPath)"]
            )
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            memset(raw, 0, maxLen)
            for index in 0..<pathBytes.count {
                raw[index] = pathBytes[index]
            }
        }

        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        let addrLen = socklen_t(pathOffset + pathBytes.count)
        addr.sun_len = UInt8(min(Int(addrLen), 255))
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { base in
                connect(sockFd, base, addrLen)
            }
        }
        guard result == 0 else {
            throw NSError(
                domain: "FeedSidebarUITests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "connect() failed errno=\(errno)"]
            )
        }

        let payload = line.hasSuffix("\n") ? line : "\(line)\n"
        let wrote = payload.withCString { cString in
            var remaining = strlen(cString)
            var pointer = UnsafeRawPointer(cString)
            while remaining > 0 {
                let written = write(sockFd, pointer, remaining)
                if written <= 0 { return false }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
            return true
        }
        guard wrote else {
            throw NSError(
                domain: "FeedSidebarUITests",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "write() failed errno=\(errno)"]
            )
        }

        // Read until newline or EOF.
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(sockFd, &chunk, chunk.count, 0)
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                throw NSError(
                    domain: "FeedSidebarUITests",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "recv() failed errno=\(errno)"]
                )
            }
            if n <= 0 { break }
            buffer.append(chunk, count: n)
            if chunk.prefix(n).contains(0x0A) { break }
        }
        return String(data: buffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func sendSocketLine(_ line: String, responseTimeout: TimeInterval = 2.0) throws -> String {
        do {
            return try sendLine(line, responseTimeout: responseTimeout)
        } catch {
            if let response = socketCommandViaNetcat(line, responseTimeout: responseTimeout) {
                return response
            }
            throw NSError(
                domain: "FeedSidebarUITests",
                code: 7,
                userInfo: [
                    NSLocalizedDescriptionKey: "socket command failed at \(socketPath): \(error.localizedDescription)"
                ]
            )
        }
    }

    private func waitForSocketPong(timeout: TimeInterval) -> Bool {
        var resolvedPath: String?
        let completed = pollUntil(timeout: timeout) {
            let originalPath = self.socketPath
            for candidate in self.socketCandidates() {
                guard FileManager.default.fileExists(atPath: candidate) else { continue }
                self.socketPath = candidate
                let response = try? self.sendSocketLine("ping", responseTimeout: 2)
                self.lastSocketProbe = "candidate=\(candidate) response=\(response ?? "nil")"
                if response == "PONG" {
                    resolvedPath = candidate
                    return true
                }
                self.socketPath = originalPath
            }
            return false
        }
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

    private func socketCommandViaNetcat(_ line: String, responseTimeout: TimeInterval = 2.0) -> String? {
        let nc = "/usr/bin/nc"
        guard FileManager.default.isExecutableFile(atPath: nc) else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        let timeoutSeconds = max(1, Int(ceil(responseTimeout)))
        let payload = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        let script = "printf '%s\\n' \(shellSingleQuote(payload)) | \(nc) -U \(shellSingleQuote(socketPath)) -w \(timeoutSeconds) 2>/dev/null"
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

    private func waitForOpenTUIFeedAppPrepared(timeout: TimeInterval) -> Bool {
        let homePath = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let markerPath = URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("feed-tui-opentui", isDirectory: true)
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent("@opentui", isDirectory: true)
            .appendingPathComponent("core", isDirectory: true)
            .appendingPathComponent("package.json", isDirectory: false)
            .path
        return pollUntil(timeout: timeout, interval: 0.5) {
            FileManager.default.fileExists(atPath: markerPath)
        }
    }

    private func waitForDockPortalToLeaveVisibleSidebar(timeout: TimeInterval) -> Bool {
        pollUntil(timeout: timeout) {
            let diagnostics = self.loadDiagnostics()
            return (Int(diagnostics["portal_visible_invalid_anchor_entry_count"] ?? "") ?? 0) == 0 &&
                (Int(diagnostics["portal_visible_orphan_terminal_subview_count"] ?? "") ?? 0) == 0
        }
    }

    private func revealDockMode(in app: XCUIApplication) -> Bool {
        let dockButton = app.buttons["RightSidebarModeButton.feed"].firstMatch
        if waitForHittable(dockButton, timeout: 5) {
            dockButton.click()
            return true
        }

        app.activate()
        if focusDockModeViaSocket() {
            return true
        }

        app.typeKey("e", modifierFlags: [.command, .shift])
        if waitForHittable(dockButton, timeout: 5) {
            dockButton.click()
            return true
        }

        app.typeKey("b", modifierFlags: [.command, .option])
        if waitForHittable(dockButton, timeout: 5) {
            dockButton.click()
            return true
        }

        app.typeKey("4", modifierFlags: [.control])
        if waitForHittable(dockButton, timeout: 5) {
            dockButton.click()
            return true
        }
        return false
    }

    private func focusDockModeViaSocket() -> Bool {
        let frame: [String: Any] = [
            "id": UUID().uuidString,
            "method": "debug.right_sidebar.focus",
            "params": [
                "mode": "feed",
                "focus_first_item": false,
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let line = String(data: data, encoding: .utf8),
              let response = try? sendSocketLine("\(line)\n", responseTimeout: 3),
              let responseData = response.data(using: .utf8),
              let responseObject = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        else {
            return false
        }
        guard responseObject["ok"] as? Bool == true else {
            return false
        }
        if let result = responseObject["result"] as? [String: Any] {
            return result["focused"] as? Bool == true
        }
        return false
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        pollUntil(timeout: timeout) {
            element.exists && element.isHittable
        }
    }

    private func portalStatsTotals() throws -> [String: Any] {
        let frame: [String: Any] = [
            "id": UUID().uuidString,
            "method": "debug.portal.stats",
            "params": [:],
        ]
        let data = try JSONSerialization.data(withJSONObject: frame)
        let line = (String(data: data, encoding: .utf8) ?? "{}") + "\n"
        let response = try sendSocketLine(line)
        guard let respData = response.data(using: .utf8),
              let respObj = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
              (respObj["ok"] as? Bool) == true,
              let result = respObj["result"] as? [String: Any],
              let totals = result["totals"] as? [String: Any] else {
            throw NSError(
                domain: "FeedSidebarUITests",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "invalid portal stats response: \(response)"]
            )
        }
        return totals
    }

    private func integerValue(in dictionary: [String: Any], key: String) -> Int {
        if let value = dictionary[key] as? Int {
            return value
        }
        if let value = dictionary[key] as? NSNumber {
            return value.intValue
        }
        return Int(dictionary[key] as? String ?? "") ?? 0
    }

    private func launchAndEnsureUsable(_ app: XCUIApplication) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }

        if app.state == .runningForeground {
            return
        }
        if app.state == .runningBackground {
            app.activate()
        }
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "cmux failed to launch for Feed UI test. state=\(app.state.rawValue)"
        )
    }

    private func removeSocketFile() {
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: taggedSocketPath())
    }

    private func loadDiagnostics() -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: diagnosticsPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    private func loadFeedResult() -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: feedResultPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    private func pollUntil(timeout: TimeInterval, interval: TimeInterval = 0.1, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() {
                return true
            }
            Thread.sleep(forTimeInterval: interval)
        }
        return predicate()
    }
}
