import XCTest
import Foundation
import Darwin

final class WorkspaceLifecycleMixedContentUITests: XCTestCase {
    private var socketPath = ""
    private var launchTag = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-ui-test-mixed-lifecycle-\(UUID().uuidString).sock"
        launchTag = "ui-tests-mixed-lifecycle-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: socketPath)
        super.tearDown()
    }

    func testMixedBrowserAndTerminalLifecycleBudget() {
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
            "Expected app to launch for mixed lifecycle test. state=\(app.state.rawValue)"
        )

        guard let resolvedPath = resolveSocketPath(timeout: 8.0) else {
            XCTFail("Expected control socket to exist")
            return
        }
        socketPath = resolvedPath

        XCTAssertTrue(waitForSocketPong(timeout: 8.0), "Expected v2 control socket to respond to system.ping")

        guard let current = v2Call("workspace.current"),
              let currentResult = current["result"] as? [String: Any],
              let visibleWorkspaceId = currentResult["workspace_id"] as? String,
              !visibleWorkspaceId.isEmpty else {
            XCTFail("Missing current workspace result")
            return
        }

        guard let browser = v2Call(
            "browser.open_split",
            params: ["url": "https://example.com"]
        ),
        let browserResult = browser["result"] as? [String: Any],
        let browserPanelId = browserResult["surface_id"] as? String,
        !browserPanelId.isEmpty else {
            XCTFail("browser.open_split did not return surface_id")
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
                let visibleBrowser = snapshot.records.first {
                    $0.panelType == "browser" &&
                        $0.workspaceId == visibleWorkspaceId &&
                        $0.panelId == browserPanelId &&
                        $0.selectedWorkspace &&
                        $0.activeWindowMembership
                }
                let hiddenTerminal = snapshot.records.first {
                    $0.panelType == "terminal" &&
                        $0.workspaceId == hiddenWorkspaceId &&
                        !$0.selectedWorkspace &&
                        !$0.activeWindowMembership
                }
                let visibleTerminalDesired = snapshot.desiredRecords.first {
                    $0.panelType == "terminal" &&
                        $0.workspaceId == visibleWorkspaceId &&
                        $0.targetVisible
                }
                let visibleBrowserDesired = snapshot.desiredRecords.first {
                    $0.panelType == "browser" &&
                        $0.workspaceId == visibleWorkspaceId &&
                        $0.panelId == browserPanelId &&
                        $0.targetVisible
                }
                return visibleTerminal != nil &&
                    visibleBrowser != nil &&
                    hiddenTerminal != nil &&
                    visibleTerminalDesired != nil &&
                    visibleBrowserDesired != nil &&
                    snapshot.visibleInActiveWindowCount >= 2
            },
            "Expected mixed browser+terminal lifecycle rows and visible pane budget"
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

        let visibleDesired = snapshot.desiredRecords.filter {
            $0.workspaceId == visibleWorkspaceId && $0.targetVisible
        }
        XCTAssertTrue(visibleDesired.contains { $0.panelType == "terminal" && $0.targetResidency == "visibleInActiveWindow" })
        XCTAssertTrue(visibleDesired.contains { $0.panelType == "browser" && $0.panelId == browserPanelId && $0.targetResidency == "visibleInActiveWindow" })
        XCTAssertGreaterThanOrEqual(snapshot.visibleInActiveWindowCount, 2)
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

    private func waitForLifecycleSnapshot(
        timeout: TimeInterval,
        predicate: (MixedLifecycleSnapshot) -> Bool
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

    private func latestLifecycleSnapshot() -> MixedLifecycleSnapshot? {
        guard let response = v2Call("debug.panel_lifecycle"),
              let result = response["result"] as? [String: Any] else {
            return nil
        }
        return MixedLifecycleSnapshot(result: result)
    }

    private func v2Call(_ method: String, params: [String: Any] = [:]) -> [String: Any]? {
        return MixedV2SocketClient(path: socketPath).call(method: method, params: params)
    }
}

private struct MixedLifecycleRecord {
    let panelId: String
    let panelType: String
    let workspaceId: String
    let selectedWorkspace: Bool
    let activeWindowMembership: Bool
    let responderEligible: Bool
    let accessibilityParticipation: Bool
}

private struct MixedDesiredLifecycleRecord {
    let panelId: String
    let panelType: String
    let workspaceId: String
    let targetVisible: Bool
    let targetResidency: String
}

private struct MixedLifecycleSnapshot {
    let records: [MixedLifecycleRecord]
    let desiredRecords: [MixedDesiredLifecycleRecord]
    let visibleInActiveWindowCount: Int

    init?(result: [String: Any]) {
        let rawRecords = result["records"] as? [[String: Any]] ?? []
        let desiredContainer = result["desired"] as? [String: Any] ?? [:]
        let rawDesired = desiredContainer["records"] as? [[String: Any]] ?? []
        let counts = result["counts"] as? [String: Any] ?? [:]

        records = rawRecords.map {
            MixedLifecycleRecord(
                panelId: $0["panelId"] as? String ?? "",
                panelType: $0["panelType"] as? String ?? "",
                workspaceId: $0["workspaceId"] as? String ?? "",
                selectedWorkspace: $0["selectedWorkspace"] as? Bool ?? false,
                activeWindowMembership: $0["activeWindowMembership"] as? Bool ?? false,
                responderEligible: $0["responderEligible"] as? Bool ?? false,
                accessibilityParticipation: $0["accessibilityParticipation"] as? Bool ?? false
            )
        }
        desiredRecords = rawDesired.map {
            MixedDesiredLifecycleRecord(
                panelId: $0["panelId"] as? String ?? "",
                panelType: $0["panelType"] as? String ?? "",
                workspaceId: $0["workspaceId"] as? String ?? "",
                targetVisible: $0["targetVisible"] as? Bool ?? false,
                targetResidency: $0["targetResidency"] as? String ?? ""
            )
        }
        visibleInActiveWindowCount = counts["visibleInActiveWindowCount"] as? Int ?? 0
    }
}

private final class MixedV2SocketClient {
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
