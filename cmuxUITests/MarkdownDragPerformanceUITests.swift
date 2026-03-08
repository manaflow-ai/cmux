import XCTest
import Foundation
import Darwin

final class MarkdownDragPerformanceUITests: XCTestCase {
    private var socketPath = ""
    private var launchTag = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-ui-test-markdown-drag-\(UUID().uuidString).sock"
        launchTag = "ui-tests-markdown-drag-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: socketPath)
        super.tearDown()
    }

    func testMarkdownDragStaysLifecycleVisibleWithinBudget() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-socketControlMode", "allowAll"]
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = launchTag
        app.launch()

        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for markdown drag lifecycle test. state=\(app.state.rawValue)"
        )

        guard let resolvedPath = resolveSocketPath(timeout: 8.0) else {
            XCTFail("Expected control socket to exist")
            return
        }
        socketPath = resolvedPath

        XCTAssertTrue(waitForSocketPong(timeout: 8.0), "Expected v2 control socket to respond to system.ping")

        guard let current = v2Call("workspace.current"),
              let currentResult = current["result"] as? [String: Any],
              let workspaceId = currentResult["workspace_id"] as? String,
              !workspaceId.isEmpty else {
            XCTFail("Missing current workspace result")
            return
        }

        let markdownURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ui-markdown-drag-\(UUID().uuidString).md")
        try "# drag budget\n\n" .appending((0..<120).map { "line \($0)" }.joined(separator: "\n"))
            .appending("\n")
            .write(to: markdownURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: markdownURL) }

        guard let open = v2Call(
            "markdown.open",
            params: [
                "path": markdownURL.path,
                "workspace_id": workspaceId,
            ]
        ),
        let openResult = open["result"] as? [String: Any],
        let panelId = openResult["surface_id"] as? String,
        !panelId.isEmpty else {
            XCTFail("markdown.open did not return surface_id")
            return
        }

        XCTAssertTrue(
            waitForVisibleMarkdown(panelId: panelId, timeout: 8.0) != nil,
            "Expected markdown panel to converge to visible residency before dragging"
        )

        for direction in ["right", "down", "left"] {
            let started = Date()
            XCTAssertNotNil(
                v2Call("surface.drag_to_split", params: ["surface_id": panelId, "direction": direction]),
                "surface.drag_to_split failed for direction \(direction)"
            )

            guard let result = waitForVisibleMarkdown(panelId: panelId, timeout: 4.0) else {
                XCTFail("Timed out waiting for visible markdown after drag \(direction)")
                return
            }

            let elapsedMs = Date().timeIntervalSince(started) * 1000.0
            XCTAssertTrue(["showInTree", "noop"].contains(result.plan.action), "Unexpected markdown action after drag \(direction): \(result.plan.action)")
            XCTAssertEqual(result.plan.targetResidency, "visibleInActiveWindow")
            XCTAssertTrue(result.plan.targetVisible)
            XCTAssertLessThan(elapsedMs, 4000.0, "Markdown drag convergence too slow after \(direction): \(elapsedMs)ms")
        }
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

    private func resolveSocketPath(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socketPath) {
                return socketPath
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return FileManager.default.fileExists(atPath: socketPath) ? socketPath : nil
    }

    private func waitForSocketPong(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let response = v2Call("system.ping"),
               let result = response["result"] as? [String: Any],
               result["pong"] as? Bool == true {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }

    private func waitForVisibleMarkdown(panelId: String, timeout: TimeInterval) -> MarkdownDragSnapshot? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let snapshot = latestLifecycleSnapshot(for: panelId),
               snapshot.plan.targetVisible,
               snapshot.plan.targetResidency == "visibleInActiveWindow" {
                return snapshot
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return latestLifecycleSnapshot(for: panelId)
    }

    private func latestLifecycleSnapshot(for panelId: String) -> MarkdownDragSnapshot? {
        guard let response = v2Call("debug.panel_lifecycle"),
              let result = response["result"] as? [String: Any],
              let desired = result["desired"] as? [String: Any],
              let plan = desired["documentExecutorPlan"] as? [String: Any],
              let records = plan["records"] as? [[String: Any]] else {
            return nil
        }
        guard let record = records.first(where: { ($0["panelId"] as? String) == panelId }) else {
            return nil
        }
        return MarkdownDragSnapshot(record)
    }

    private func v2Call(_ method: String, params: [String: Any] = [:]) -> [String: Any]? {
        MarkdownDragV2SocketClient(path: socketPath).call(method: method, params: params)
    }
}

private struct MarkdownDragSnapshot {
    let plan: MarkdownDragPlan

    init?(_ json: [String: Any]) {
        guard let plan = MarkdownDragPlan(json) else { return nil }
        self.plan = plan
    }
}

private struct MarkdownDragPlan {
    let action: String
    let targetResidency: String
    let targetVisible: Bool

    init?(_ json: [String: Any]) {
        action = json["action"] as? String ?? ""
        targetResidency = json["targetResidency"] as? String ?? ""
        targetVisible = json["targetVisible"] as? Bool ?? false
    }
}

private final class MarkdownDragV2SocketClient {
    private let path: String

    init(path: String) {
        self.path = path
    }

    func call(method: String, params: [String: Any] = [:]) -> [String: Any]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

#if os(macOS)
        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) { ptr in
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, ptr, socklen_t(MemoryLayout<Int32>.size))
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
            for (idx, byte) in bytes.enumerated() {
                raw[idx] = byte
            }
        }

        let sunPathOffset = MemoryLayout.offset(of: \sockaddr_un.sun_path) ?? 0
        let addrLen = socklen_t(sunPathOffset + bytes.count)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, addrLen)
            }
        }
        guard connected == 0 else { return nil }

        let payload: [String: Any] = [
            "id": 1,
            "method": method,
            "params": params,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var packet = Data()
        packet.append(data)
        packet.append(0x0A)
        let sent = packet.withUnsafeBytes { rawBuffer in
            send(fd, rawBuffer.baseAddress, rawBuffer.count, 0)
        }
        guard sent == packet.count else { return nil }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            response.append(buffer, count: count)
            if response.contains(0x0A) { break }
        }

        guard let newline = response.firstIndex(of: 0x0A) else { return nil }
        let line = response[..<newline]
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
              let json = object as? [String: Any] else {
            return nil
        }
        return json
    }
}
