import XCTest
import Foundation
import Darwin

final class WorkspaceLifecycleTerminalUITests: XCTestCase {
    private var socketPath = ""
    private var dataPath = ""
    private var launchTag = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        launchTag = "ui-tests-workspace-lifecycle-\(UUID().uuidString.prefix(8))"
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

    func testTerminalLifecycleDistinguishesVisibleAndHiddenWorkspaces() {
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
            "Expected app to launch for workspace lifecycle test. state=\(app.state.rawValue)"
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

        guard let current = v2Call("workspace.current"),
              let currentResult = current["result"] as? [String: Any],
              let visibleWorkspaceId = currentResult["workspace_id"] as? String,
              !visibleWorkspaceId.isEmpty else {
            XCTFail("Missing current workspace result")
            return
        }

        guard let created = v2Call("workspace.create"),
              let createdResult = created["result"] as? [String: Any],
              let hiddenWorkspaceId = createdResult["workspace_id"] as? String,
              !hiddenWorkspaceId.isEmpty else {
            XCTFail("Failed to create hidden workspace")
            return
        }

        XCTAssertNotEqual(visibleWorkspaceId, hiddenWorkspaceId, "Expected hidden workspace to differ from current workspace")

        let snapshotReady = waitForLifecycleSnapshot(timeout: 8.0) { snapshot in
            let records = snapshot.records
            let desired = snapshot.desiredRecords
            let visibleCurrent = records.first {
                $0.panelType == "terminal" &&
                    $0.workspaceId == visibleWorkspaceId &&
                    $0.selectedWorkspace &&
                    $0.activeWindowMembership
            }
            let hiddenCurrent = records.first {
                $0.panelType == "terminal" &&
                    $0.workspaceId == hiddenWorkspaceId &&
                    !$0.selectedWorkspace &&
                    !$0.activeWindowMembership
            }
            let visibleDesired = desired.first {
                $0.panelType == "terminal" &&
                    $0.workspaceId == visibleWorkspaceId &&
                    $0.targetVisible
            }
            let hiddenDesired = desired.first {
                $0.panelType == "terminal" &&
                    $0.workspaceId == hiddenWorkspaceId &&
                    !$0.targetVisible
            }
            return visibleCurrent != nil && hiddenCurrent != nil && visibleDesired != nil && hiddenDesired != nil
        }
        XCTAssertTrue(snapshotReady, "Expected lifecycle snapshot to contain visible and hidden terminal rows")

        guard let snapshot = latestLifecycleSnapshot() else {
            XCTFail("Missing panel lifecycle snapshot")
            return
        }

        let visibleCurrent = snapshot.records.first {
            $0.panelType == "terminal" &&
                $0.workspaceId == visibleWorkspaceId &&
                $0.selectedWorkspace &&
                $0.activeWindowMembership
        }
        let hiddenCurrent = snapshot.records.first {
            $0.panelType == "terminal" &&
                $0.workspaceId == hiddenWorkspaceId &&
                !$0.selectedWorkspace &&
                !$0.activeWindowMembership
        }
        let visibleDesired = snapshot.desiredRecords.first {
            $0.panelType == "terminal" &&
                $0.workspaceId == visibleWorkspaceId &&
                $0.targetVisible
        }
        let hiddenDesired = snapshot.desiredRecords.first {
            $0.panelType == "terminal" &&
                $0.workspaceId == hiddenWorkspaceId &&
                !$0.targetVisible
        }

        XCTAssertNotNil(visibleCurrent, "Expected visible terminal lifecycle row")
        XCTAssertNotNil(hiddenCurrent, "Expected hidden terminal lifecycle row")
        XCTAssertNotNil(visibleDesired, "Expected visible desired terminal row")
        XCTAssertNotNil(hiddenDesired, "Expected hidden desired terminal row")

        XCTAssertEqual(visibleDesired?.targetResidency, "visibleInActiveWindow")
        XCTAssertEqual(visibleDesired?.requiresCurrentGenerationAnchor, true)
        XCTAssertEqual(hiddenCurrent?.activeWindowMembership, false)
        XCTAssertEqual(hiddenCurrent?.responderEligible, false)
        XCTAssertEqual(hiddenCurrent?.accessibilityParticipation, false)
        XCTAssertNotEqual(hiddenDesired?.targetResidency, "visibleInActiveWindow")

        XCTAssertGreaterThanOrEqual(snapshot.visibleInActiveWindowCount, 1)
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
        predicate: (LifecycleSnapshot) -> Bool
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

    private func latestLifecycleSnapshot() -> LifecycleSnapshot? {
        guard let response = v2Call("debug.panel_lifecycle"),
              let result = response["result"] as? [String: Any] else {
            return nil
        }
        return LifecycleSnapshot(result: result)
    }

    private func v2Call(_ method: String, params: [String: Any] = [:]) -> [String: Any]? {
        return V2SocketClient(path: socketPath).call(method: method, params: params)
    }
}

private struct LifecycleRecord {
    let panelType: String
    let workspaceId: String
    let selectedWorkspace: Bool
    let activeWindowMembership: Bool
    let responderEligible: Bool
    let accessibilityParticipation: Bool
}

private struct DesiredLifecycleRecord {
    let panelType: String
    let workspaceId: String
    let targetVisible: Bool
    let targetResidency: String
    let requiresCurrentGenerationAnchor: Bool
}

private struct LifecycleSnapshot {
    let records: [LifecycleRecord]
    let desiredRecords: [DesiredLifecycleRecord]
    let visibleInActiveWindowCount: Int

    init?(result: [String: Any]) {
        let rawRecords = result["records"] as? [[String: Any]] ?? []
        let desiredContainer = result["desired"] as? [String: Any] ?? [:]
        let rawDesired = desiredContainer["records"] as? [[String: Any]] ?? []
        let counts = result["counts"] as? [String: Any] ?? [:]

        records = rawRecords.map {
            LifecycleRecord(
                panelType: $0["panelType"] as? String ?? "",
                workspaceId: $0["workspaceId"] as? String ?? "",
                selectedWorkspace: $0["selectedWorkspace"] as? Bool ?? false,
                activeWindowMembership: $0["activeWindowMembership"] as? Bool ?? false,
                responderEligible: $0["responderEligible"] as? Bool ?? false,
                accessibilityParticipation: $0["accessibilityParticipation"] as? Bool ?? false
            )
        }
        desiredRecords = rawDesired.map {
            DesiredLifecycleRecord(
                panelType: $0["panelType"] as? String ?? "",
                workspaceId: $0["workspaceId"] as? String ?? "",
                targetVisible: $0["targetVisible"] as? Bool ?? false,
                targetResidency: $0["targetResidency"] as? String ?? "",
                requiresCurrentGenerationAnchor: $0["requiresCurrentGenerationAnchor"] as? Bool ?? false
            )
        }
        visibleInActiveWindowCount = counts["visibleInActiveWindowCount"] as? Int ?? 0
    }
}

private final class V2SocketClient {
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
            "params": params
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: data, encoding: .utf8)?.appending("\n"),
              send(fd, line, line.utf8.count, 0) >= 0 else {
            return nil
        }

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
