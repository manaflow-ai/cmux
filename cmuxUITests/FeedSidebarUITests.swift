import Foundation
import XCTest

/// Exercises the right-sidebar Feed end-to-end: boot the app with a
/// dedicated socket, inject a synthetic permission request over the
/// socket's `feed.push` V2 verb, toggle the sidebar to Dock mode, drive
/// the Feed TUI from the keyboard, and assert the hook-side socket
/// response carries the resolved decision.
final class FeedSidebarUITests: XCTestCase {
    private var socketPath = ""
    private var diagnosticsPath = ""
    private let modeKey = "socketControlMode"
    private let launchTag = "ui-tests-feed-sidebar"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-debug-\(UUID().uuidString).sock"
        diagnosticsPath = "/tmp/cmux-feed-sidebar-\(UUID().uuidString).json"
        removeSocketFile()
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
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
        launchAndEnsureUsable(app)

        XCTAssertTrue(
            waitForSocketPong(timeout: 75),
            "Expected control socket at \(socketPath). diagnostics=\(loadDiagnostics())"
        )

        // Reveal the right sidebar and toggle to Dock. Uses accessibility
        // identifiers registered on the ModeBarButton row.
        let dockButton = app.buttons["Dock"].firstMatch
        if !dockButton.waitForExistence(timeout: 5) {
            // Fall back: send the right-sidebar toggle shortcut (⌘⌥B).
            app.typeKey("b", modifierFlags: [.command, .option])
            _ = dockButton.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(dockButton.exists, "Dock tab not visible in right sidebar")
        dockButton.click()

        let focusButton = app.buttons["Focus Control"].firstMatch
        XCTAssertTrue(
            focusButton.waitForExistence(timeout: 10),
            "Dock Feed focus button did not appear"
        )
        focusButton.click()

        // Push a synthetic permission request via the socket.
        let requestId = "uitest-\(UUID().uuidString)"
        let replyPayload = try sendFeedPush(requestId: requestId, waitSeconds: 30)

        // The TUI blocks on keyboard input. Refresh first so it observes the
        // pending request, then Enter accepts the default "once" action.
        app.typeKey("r", modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])

        // Await the socket reply from the earlier push.
        let result = try replyPayload.result(timeout: 30)
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
                let response = try self.sendLine(line, responseTimeout: waitSeconds + 5)
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
        _ = shutdown(sockFd, SHUT_WR)

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

    private func waitForSocketPong(timeout: TimeInterval) -> Bool {
        var resolvedPath: String?
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let originalPath = self.socketPath
                for candidate in self.socketCandidates() {
                    guard FileManager.default.fileExists(atPath: candidate) else { continue }
                    self.socketPath = candidate
                    if (try? self.sendLine("ping\n")) == "PONG" {
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

    private func waitForDockPortalToLeaveVisibleSidebar(timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard let totals = try? self.portalStatsTotals() else { return false }
                return self.integerValue(in: totals, key: "visible_invalid_anchor_entry_count") == 0 &&
                    self.integerValue(in: totals, key: "visible_orphan_terminal_subview_count") == 0
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func portalStatsTotals() throws -> [String: Any] {
        let frame: [String: Any] = [
            "id": UUID().uuidString,
            "method": "debug.portal.stats",
            "params": [:],
        ]
        let data = try JSONSerialization.data(withJSONObject: frame)
        let line = (String(data: data, encoding: .utf8) ?? "{}") + "\n"
        let response = try sendLine(line)
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

        if app.state == .runningForeground || app.state == .runningBackground {
            return
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
}
