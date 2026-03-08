import XCTest
import Foundation
import Darwin

final class WorkspaceLifecycleMixedDocumentContentUITests: XCTestCase {
    private var socketPath = ""
    private var dataPath = ""
    private var launchTag = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        launchTag = "ui-tests-mixed-document-\(UUID().uuidString.prefix(8))"
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

    func testMixedTerminalAndMarkdownLifecycleBudget() throws {
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
            "Expected app to launch for mixed document lifecycle test. state=\(app.state.rawValue)"
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

        guard let visibleWorkspaceId = waitForCurrentWorkspaceId(timeout: 8.0) else {
            XCTFail("Missing current workspace result")
            return
        }

        let markdownURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ui-mixed-document-\(UUID().uuidString).md")
        try "# mixed\n\nhello\n".write(to: markdownURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: markdownURL) }

        guard let open = v2Call(
            "markdown.open",
            params: [
                "path": markdownURL.path,
                "workspace_id": visibleWorkspaceId,
            ]
        ),
        let openResult = open["result"] as? [String: Any],
        let markdownPanelId = openResult["surface_id"] as? String,
        !markdownPanelId.isEmpty else {
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

        XCTAssertTrue(
            waitForLifecycleSnapshot(timeout: 8.0) { snapshot in
                let visibleTerminal = snapshot.records.first {
                    $0.panelType == "terminal" &&
                        $0.workspaceId == visibleWorkspaceId &&
                        $0.selectedWorkspace &&
                        $0.activeWindowMembership
                }
                let hiddenTerminal = snapshot.records.first {
                    $0.panelType == "terminal" &&
                        $0.workspaceId == hiddenWorkspaceId &&
                        !$0.selectedWorkspace &&
                        !$0.activeWindowMembership
                }
                let visibleMarkdown = snapshot.documentPlans.first {
                    $0.panelId == markdownPanelId &&
                        $0.workspaceId == visibleWorkspaceId &&
                        $0.targetResidency == "visibleInActiveWindow"
                }
                return visibleTerminal != nil &&
                    hiddenTerminal != nil &&
                    visibleMarkdown != nil &&
                    snapshot.visibleInActiveWindowCount >= 1
            },
            "Expected mixed terminal+markdown lifecycle rows and document plan budget"
        )

        guard let snapshot = latestLifecycleSnapshot() else {
            XCTFail("Missing panel lifecycle snapshot")
            return
        }

        let hiddenRecords = snapshot.records.filter {
            $0.workspaceId == hiddenWorkspaceId && !$0.selectedWorkspace
        }
        XCTAssertFalse(hiddenRecords.isEmpty)
        XCTAssertTrue(hiddenRecords.allSatisfy { !$0.activeWindowMembership })
        XCTAssertTrue(hiddenRecords.allSatisfy { !$0.responderEligible })
        XCTAssertTrue(hiddenRecords.allSatisfy { !$0.accessibilityParticipation })

        let visibleMarkdown = snapshot.documentPlans.first {
            $0.panelId == markdownPanelId &&
                $0.workspaceId == visibleWorkspaceId
        }
        XCTAssertNotNil(visibleMarkdown)
        XCTAssertTrue(["showInTree", "noop"].contains(visibleMarkdown?.action ?? ""))
        XCTAssertEqual(visibleMarkdown?.targetResidency, "visibleInActiveWindow")
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

    private func waitForLifecycleSnapshot(
        timeout: TimeInterval,
        predicate: (MixedDocumentSnapshot) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let snapshot = latestLifecycleSnapshot(), predicate(snapshot) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let snapshot = latestLifecycleSnapshot(), predicate(snapshot) {
            return true
        }
        return false
    }

    private func latestLifecycleSnapshot() -> MixedDocumentSnapshot? {
        guard let response = v2Call("debug.panel_lifecycle"),
              let result = response["result"] as? [String: Any] else {
            return nil
        }
        return MixedDocumentSnapshot(result: result)
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
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return nil
    }

    private func v2Call(_ method: String, params: [String: Any] = [:]) -> [String: Any]? {
        return MixedDocumentV2SocketClient(path: socketPath).call(method: method, params: params)
    }
}

private struct MixedDocumentRecord {
    let panelType: String
    let workspaceId: String
    let selectedWorkspace: Bool
    let activeWindowMembership: Bool
    let responderEligible: Bool
    let accessibilityParticipation: Bool
}

private struct MixedDocumentPlan {
    let panelId: String
    let workspaceId: String
    let action: String
    let targetResidency: String
}

private struct MixedDocumentSnapshot {
    let records: [MixedDocumentRecord]
    let documentPlans: [MixedDocumentPlan]
    let visibleInActiveWindowCount: Int

    init?(result: [String: Any]) {
        let rawRecords = result["records"] as? [[String: Any]] ?? []
        let desiredContainer = result["desired"] as? [String: Any] ?? [:]
        let documentPlan = desiredContainer["documentExecutorPlan"] as? [String: Any] ?? [:]
        let rawPlans = documentPlan["records"] as? [[String: Any]] ?? []
        let counts = result["counts"] as? [String: Any] ?? [:]

        records = rawRecords.map {
            MixedDocumentRecord(
                panelType: $0["panelType"] as? String ?? "",
                workspaceId: $0["workspaceId"] as? String ?? "",
                selectedWorkspace: $0["selectedWorkspace"] as? Bool ?? false,
                activeWindowMembership: $0["activeWindowMembership"] as? Bool ?? false,
                responderEligible: $0["responderEligible"] as? Bool ?? false,
                accessibilityParticipation: $0["accessibilityParticipation"] as? Bool ?? false
            )
        }
        documentPlans = rawPlans.compactMap {
            guard let panelId = $0["panelId"] as? String else { return nil }
            return MixedDocumentPlan(
                panelId: panelId,
                workspaceId: $0["workspaceId"] as? String ?? "",
                action: $0["action"] as? String ?? "",
                targetResidency: $0["targetResidency"] as? String ?? ""
            )
        }
        visibleInActiveWindowCount = counts["visibleInActiveWindowCount"] as? Int ?? 0
    }
}

private final class MixedDocumentV2SocketClient {
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
        var packet = Data()
        packet.append(data)
        packet.append(0x0A)
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
