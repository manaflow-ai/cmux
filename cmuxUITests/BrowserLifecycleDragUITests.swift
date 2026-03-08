import XCTest
import Foundation
import Darwin

final class BrowserLifecycleDragUITests: XCTestCase {
    private var socketPath = ""
    private var dataPath = ""
    private var launchTag = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        launchTag = "ui-tests-browser-drag-\(UUID().uuidString.prefix(8))"
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

    func testBrowserMoveAcrossWorkspacesPreservesLifecycleBudget() {
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
            "Expected app to launch for browser drag lifecycle test. state=\(app.state.rawValue)"
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
              let originalWorkspaceId = currentResult["workspace_id"] as? String,
              !originalWorkspaceId.isEmpty else {
            XCTFail("Missing current workspace result")
            return
        }

        guard let opened = v2Call(
            "browser.open_split",
            params: ["url": "https://example.com/browser-drag"]
        ),
        let openedResult = opened["result"] as? [String: Any],
        let browserPanelId = openedResult["surface_id"] as? String,
        !browserPanelId.isEmpty else {
            XCTFail("browser.open_split did not return surface_id")
            return
        }

        guard let created = v2Call("workspace.create"),
              let createdResult = created["result"] as? [String: Any],
              let destinationWorkspaceId = createdResult["workspace_id"] as? String,
              !destinationWorkspaceId.isEmpty else {
            XCTFail("workspace.create did not return workspace_id")
            return
        }

        guard v2Call(
            "surface.move",
            params: [
                "surface_id": browserPanelId,
                "workspace_id": destinationWorkspaceId,
                "focus": true,
            ]
        ) != nil else {
            XCTFail("surface.move failed")
            return
        }

        XCTAssertTrue(
            waitForLifecycleSnapshot(timeout: 8.0) { snapshot in
                guard let moved = snapshot.records.first(where: {
                    $0.panelId == browserPanelId && $0.workspaceId == destinationWorkspaceId
                }) else {
                    return false
                }
                return moved.selectedWorkspace &&
                    moved.activeWindowMembership &&
                    moved.desiredVisible &&
                    moved.targetResidency == "visibleInActiveWindow"
            },
            "Expected moved browser to remain visible in the active workspace after cross-workspace move"
        )

        guard let snapshot = latestLifecycleSnapshot(),
              let moved = snapshot.records.first(where: {
                  $0.panelId == browserPanelId && $0.workspaceId == destinationWorkspaceId
              }) else {
            XCTFail("Missing moved browser lifecycle snapshot")
            return
        }

        XCTAssertFalse(
            snapshot.records.contains(where: {
                $0.panelId == browserPanelId &&
                    $0.workspaceId == originalWorkspaceId &&
                    $0.activeWindowMembership
            })
        )
        XCTAssertTrue(moved.selectedWorkspace)
        XCTAssertTrue(moved.activeWindowMembership)
        XCTAssertEqual(moved.targetResidency, "visibleInActiveWindow")
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
        predicate: (BrowserLifecycleSnapshot) -> Bool
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

    private func latestLifecycleSnapshot() -> BrowserLifecycleSnapshot? {
        guard let response = v2Call("debug.panel_lifecycle"),
              let result = response["result"] as? [String: Any] else {
            return nil
        }
        return BrowserLifecycleSnapshot(result: result)
    }

    private func v2Call(_ method: String, params: [String: Any] = [:]) -> [String: Any]? {
        BrowserLifecycleV2SocketClient(path: socketPath).call(method: method, params: params)
    }
}

private struct BrowserLifecycleRecord {
    let panelId: String
    let workspaceId: String
    let selectedWorkspace: Bool
    let activeWindowMembership: Bool
    let desiredVisible: Bool
    let targetResidency: String
}

private struct BrowserLifecycleSnapshot {
    let records: [BrowserLifecycleRecord]

    init?(result: [String: Any]) {
        let rawRecords = result["records"] as? [[String: Any]] ?? []
        let desiredContainer = result["desired"] as? [String: Any] ?? [:]
        let rawDesired = desiredContainer["records"] as? [[String: Any]] ?? []
        let desiredPairs: [(String, (Bool, String))] = rawDesired.compactMap { row -> (String, (Bool, String))? in
            guard let panelId = row["panelId"] as? String else { return nil }
            return (
                panelId,
                (
                    row["targetVisible"] as? Bool ?? false,
                    row["targetResidency"] as? String ?? ""
                )
            )
        }
        let desiredByPanel = Dictionary(uniqueKeysWithValues: desiredPairs)

        records = rawRecords.compactMap { row -> BrowserLifecycleRecord? in
            guard let panelId = row["panelId"] as? String,
                  let workspaceId = row["workspaceId"] as? String else {
                return nil
            }
            let desired = desiredByPanel[panelId] ?? (false, "")
            return BrowserLifecycleRecord(
                panelId: panelId,
                workspaceId: workspaceId,
                selectedWorkspace: row["selectedWorkspace"] as? Bool ?? false,
                activeWindowMembership: row["activeWindowMembership"] as? Bool ?? false,
                desiredVisible: desired.0,
                targetResidency: desired.1
            )
        }
    }
}

private final class BrowserLifecycleV2SocketClient {
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
        guard sent == packet.count else { return nil }

        var buffer = Data()
        var byte: UInt8 = 0
        while recv(fd, &byte, 1, 0) == 1 {
            if byte == 0x0A { break }
            buffer.append(byte)
        }

        guard
            !buffer.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any]
        else {
            return nil
        }
        return object["ok"] as? Bool == true ? object : nil
    }
}
