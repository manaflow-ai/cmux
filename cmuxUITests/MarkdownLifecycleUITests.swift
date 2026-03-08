import XCTest
import Foundation
import Darwin

final class MarkdownLifecycleUITests: XCTestCase {
    private var socketPath = ""
    private var dataPath = ""
    private var launchTag = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        launchTag = "ui-tests-markdown-lifecycle-\(UUID().uuidString.prefix(8))"
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

    func testMarkdownLifecycleDestroysHiddenWorkspaceAndReshowsOnReveal() throws {
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
            "Expected app to launch for markdown lifecycle test. state=\(app.state.rawValue)"
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

        guard let originalWorkspaceId = waitForCurrentWorkspaceId(timeout: 20.0) else {
            XCTFail("Missing current workspace result")
            return
        }

        let markdownURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ui-markdown-\(UUID().uuidString).md")
        try "# lifecycle\n\nhello\n".write(to: markdownURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: markdownURL) }

        guard let open = v2Call(
            "markdown.open",
            params: [
                "path": markdownURL.path,
                "workspace_id": originalWorkspaceId,
            ]
        ),
        let openResult = open["result"] as? [String: Any],
        let panelId = openResult["surface_id"] as? String,
        !panelId.isEmpty else {
            XCTFail("markdown.open did not return surface_id")
            return
        }

        guard let created = v2Call("workspace.create"),
              let createdResult = created["result"] as? [String: Any],
              let hiddenWorkspaceId = createdResult["workspace_id"] as? String,
              !hiddenWorkspaceId.isEmpty else {
            XCTFail("Failed to create hidden workspace")
            return
        }

        guard v2Call("workspace.select", params: ["workspace_id": hiddenWorkspaceId]) != nil else {
            XCTFail("Failed to select hidden workspace")
            return
        }

        XCTAssertTrue(
            waitForDocumentPlan(timeout: 8.0) { plan in
                plan.panelId == panelId && plan.targetResidency == "destroyed"
            },
            "Expected markdown panel to converge to destroyed residency while hidden"
        )

        guard let hiddenPlan = latestDocumentPlan(for: panelId) else {
            XCTFail("Missing hidden markdown document plan")
            return
        }
        XCTAssertTrue(["destroy", "noop"].contains(hiddenPlan.action))

        guard v2Call("workspace.select", params: ["workspace_id": originalWorkspaceId]) != nil else {
            XCTFail("Failed to reselect original workspace")
            return
        }

        XCTAssertTrue(
            waitForDocumentPlan(timeout: 8.0) { plan in
                plan.panelId == panelId && plan.targetResidency == "visibleInActiveWindow"
            },
            "Expected markdown panel to converge back to visible residency on reveal"
        )

        guard let visiblePlan = latestDocumentPlan(for: panelId) else {
            XCTFail("Missing visible markdown document plan")
            return
        }
        XCTAssertTrue(["showInTree", "noop"].contains(visiblePlan.action))
        XCTAssertEqual(visiblePlan.targetResidency, "visibleInActiveWindow")
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

    private func waitForDocumentPlan(
        timeout: TimeInterval,
        predicate: (DocumentPlanRecord) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let plan = latestDocumentPlan(), predicate(plan) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let plan = latestDocumentPlan(), predicate(plan) {
            return true
        }
        return false
    }

    private func latestDocumentPlan(for panelId: String? = nil) -> DocumentPlanRecord? {
        guard let response = v2Call("debug.panel_lifecycle"),
              let result = response["result"] as? [String: Any],
              let desired = result["desired"] as? [String: Any],
              let documentPlan = desired["documentExecutorPlan"] as? [String: Any],
              let records = documentPlan["records"] as? [[String: Any]] else {
            return nil
        }
        let parsed = records.compactMap(DocumentPlanRecord.init)
        if let panelId {
            return parsed.first { $0.panelId == panelId }
        }
        return parsed.first
    }

    private func latestLifecycleSnapshot() -> MarkdownLifecycleWorkspaceSnapshot? {
        guard let response = v2Call("debug.panel_lifecycle"),
              let result = response["result"] as? [String: Any] else {
            return nil
        }
        return MarkdownLifecycleWorkspaceSnapshot(result: result)
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
        return MarkdownV2SocketClient(path: socketPath).call(method: method, params: params)
    }
}

private struct DocumentPlanRecord {
    let panelId: String
    let action: String
    let targetResidency: String

    init?(_ json: [String: Any]) {
        guard let panelId = json["panelId"] as? String else { return nil }
        self.panelId = panelId
        self.action = json["action"] as? String ?? ""
        self.targetResidency = json["targetResidency"] as? String ?? ""
    }
}

private struct MarkdownLifecycleWorkspaceRecord {
    let workspaceId: String
    let selectedWorkspace: Bool
}

private struct MarkdownLifecycleWorkspaceSnapshot {
    let records: [MarkdownLifecycleWorkspaceRecord]

    init?(result: [String: Any]) {
        let rawRecords = result["records"] as? [[String: Any]] ?? []
        records = rawRecords.compactMap { row -> MarkdownLifecycleWorkspaceRecord? in
            guard let workspaceId = row["workspaceId"] as? String else { return nil }
            return MarkdownLifecycleWorkspaceRecord(
                workspaceId: workspaceId,
                selectedWorkspace: row["selectedWorkspace"] as? Bool ?? false
            )
        }
    }
}

private final class MarkdownV2SocketClient {
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
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return nil
        }
        let newline = Data([0x0A])
        var packet = Data()
        packet.append(data)
        packet.append(newline)
        let sent = packet.withUnsafeBytes { rawBuffer in
            send(fd, rawBuffer.baseAddress, rawBuffer.count, 0)
        }
        guard sent >= 0 else { return nil }

        var buffer = Data()
        let deadline = Date().addingTimeInterval(4.0)
        while Date() < deadline {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let readCount = recv(fd, &chunk, chunk.count, 0)
            if readCount <= 0 { break }
            buffer.append(chunk, count: Int(readCount))
            if buffer.contains(0x0A) { break }
        }

        guard let text = String(data: buffer, encoding: .utf8),
              let line = text.split(separator: "\n", maxSplits: 1).first,
              let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              json["ok"] as? Bool == true else {
            return nil
        }
        return json
    }
}
