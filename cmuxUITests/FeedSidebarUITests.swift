import Foundation
import XCTest

/// Exercises the right-sidebar Feed end-to-end: boot the app with a
/// dedicated socket, inject a synthetic permission request over the
/// socket's `feed.push` V2 verb, toggle the sidebar to Feed mode, tap
/// Allow Once, and assert the hook-side socket response carries the
/// resolved decision.
final class FeedSidebarUITests: XCTestCase {
    private var socketPath = ""
    private let modeKey = "socketControlMode"
    private let launchTag = "ui-tests-feed-sidebar"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-debug-\(UUID().uuidString).sock"
        removeSocketFile()
    }

    func testFeedReceivesAndResolvesPermissionRequest() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-\(modeKey)", "cmuxOnly"]
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_TAG"] = launchTag
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "cmux failed to launch for Feed UI test"
        )

        // Wait for the socket to come up.
        let socketExists = expectation(description: "socket exists")
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: self.socketPath) {
                    socketExists.fulfill()
                    return
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        wait(for: [socketExists], timeout: 12)

        // Reveal the right sidebar and toggle to Feed. Uses accessibility
        // identifiers registered on the ModeBarButton row.
        let feedButton = app.buttons["Feed"].firstMatch
        if !feedButton.waitForExistence(timeout: 5) {
            // Fall back: send the right-sidebar toggle shortcut (⌘⌥B).
            app.typeKey("b", modifierFlags: [.command, .option])
            _ = feedButton.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(feedButton.exists, "Feed tab not visible in right sidebar")
        feedButton.click()

        // Push a synthetic permission request via the socket.
        let requestId = "uitest-\(UUID().uuidString)"
        let replyPayload = try sendFeedPush(requestId: requestId, waitSeconds: 30)

        // The reply arrives once the Feed row's Allow Once button is
        // clicked — run that on the UI side while the send is in-flight.
        let allowButton = app.buttons["Once"].firstMatch
        XCTAssertTrue(
            allowButton.waitForExistence(timeout: 10),
            "Allow Once button did not appear in Feed"
        )
        allowButton.click()

        // Await the socket reply from the earlier push.
        let result = try replyPayload.result(timeout: 30)
        XCTAssertEqual(
            result.status, "resolved",
            "Expected feed.push to resolve, got status=\(result.status)"
        )
        XCTAssertEqual(result.mode, "once")

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
                let response = try self.sendLine(line)
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

    private func sendLine(_ line: String) throws -> String {
        let sockFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sockFd != -1 else {
            throw NSError(
                domain: "FeedSidebarUITests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "socket() failed errno=\(errno)"]
            )
        }
        defer { close(sockFd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = socketPath.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                strlcpy(dst.baseAddress!.assumingMemoryBound(to: Int8.self), src, dst.count)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { base in
                connect(sockFd, base, size)
            }
        }
        guard result == 0 else {
            throw NSError(
                domain: "FeedSidebarUITests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "connect() failed errno=\(errno)"]
            )
        }

        let data = line.data(using: .utf8)!
        _ = data.withUnsafeBytes { bytes in
            send(sockFd, bytes.baseAddress, data.count, 0)
        }

        // Read until newline or EOF.
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(sockFd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            buffer.append(chunk, count: n)
            if chunk.prefix(n).contains(0x0A) { break }
        }
        return String(data: buffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func removeSocketFile() {
        try? FileManager.default.removeItem(atPath: socketPath)
    }
}
