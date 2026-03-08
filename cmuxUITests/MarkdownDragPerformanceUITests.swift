import XCTest
import Foundation
import Darwin

final class MarkdownDragPerformanceUITests: XCTestCase {
    private var socketPath = ""
    private var dataPath = ""
    private var launchTag = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        launchTag = "ui-tests-markdown-drag-\(UUID().uuidString.prefix(8))"
        socketPath = "/tmp/cmux-debug-\(launchTag).sock"
        dataPath = "/tmp/cmux-ui-socket-sanity-\(launchTag).json"
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: dataPath)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: dataPath)
        super.tearDown()
    }

    func testMarkdownDragStaysLifecycleVisibleWithinBudget() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-socketControlMode", "allowAll"]
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY_PATH"] = dataPath
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = launchTag
        app.launch()

        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for markdown drag lifecycle test. state=\(app.state.rawValue)"
        )

        guard let socketState = waitForSocketSanity(timeout: 20.0) else {
            XCTFail("Expected control socket sanity data")
            return
        }
        if let expectedSocketPath = socketState["socketExpectedPath"], !expectedSocketPath.isEmpty {
            socketPath = expectedSocketPath
        }
        XCTAssertEqual(socketState["socketReady"], "1", "Expected ready socket. state=\(socketState)")
        XCTAssertEqual(socketState["socketPingResponse"], "PONG", "Expected healthy socket ping. state=\(socketState)")

        guard let workspaceId = waitForCurrentWorkspaceId(timeout: 20.0) else {
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

    private func waitForSocketSanity(timeout: TimeInterval) -> [String: String]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = loadSocketSanityData(),
               data["socketReady"] == "1",
               data["socketPingResponse"] == "PONG" {
                return data
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return loadSocketSanityData()
    }

    private func loadSocketSanityData() -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: dataPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return object
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

    private func latestLifecycleSnapshot() -> MarkdownDragWorkspaceSnapshot? {
        guard let response = v2Call("debug.panel_lifecycle"),
              let result = response["result"] as? [String: Any] else {
            return nil
        }
        return MarkdownDragWorkspaceSnapshot(result: result)
    }

    private func waitForCurrentWorkspaceId(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let response = v2Call("workspace.current"),
               let result = response["result"] as? [String: Any],
               let workspaceId = result["workspace_id"] as? String,
               !workspaceId.isEmpty {
                return workspaceId
            }
            if let response = v2Call("workspace.list"),
               let result = response["result"] as? [String: Any],
               let workspaces = result["workspaces"] as? [[String: Any]],
               let selected = workspaces.first(where: { $0["selected"] as? Bool == true })?["workspace_id"] as? String,
               !selected.isEmpty {
                return selected
            }
            if let response = v2Call("workspace.list"),
               let result = response["result"] as? [String: Any],
               let workspaces = result["workspaces"] as? [[String: Any]],
               let first = workspaces.first?["workspace_id"] as? String,
               !first.isEmpty {
                return first
            }
            if let snapshot = latestLifecycleSnapshot(),
               let selected = snapshot.records.first(where: { $0.selectedWorkspace })?.workspaceId,
               !selected.isEmpty {
                return selected
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return nil
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

private struct MarkdownDragWorkspaceRecord {
    let workspaceId: String
    let selectedWorkspace: Bool
}

private struct MarkdownDragWorkspaceSnapshot {
    let records: [MarkdownDragWorkspaceRecord]

    init?(result: [String: Any]) {
        let rawRecords = result["records"] as? [[String: Any]] ?? []
        records = rawRecords.compactMap { row -> MarkdownDragWorkspaceRecord? in
            guard let workspaceId = row["workspaceId"] as? String else { return nil }
            return MarkdownDragWorkspaceRecord(
                workspaceId: workspaceId,
                selectedWorkspace: row["selectedWorkspace"] as? Bool ?? false
            )
        }
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
            "jsonrpc": "2.0",
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
