import XCTest
import Foundation
import Darwin

final class BrowserLifecycleCrossWindowUITests: XCTestCase {
    private var socketPath = ""
    private var launchTag = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-ui-test-browser-cross-window-\(UUID().uuidString).sock"
        launchTag = "ui-tests-browser-cross-window-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: socketPath)
        super.tearDown()
    }

    func testBrowserWorkspaceMoveAcrossWindowsPreservesVisibleResidency() {
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
            "Expected app to launch for browser cross-window lifecycle test. state=\(app.state.rawValue)"
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

        guard let opened = v2Call(
            "browser.open_split",
            params: ["url": "https://example.com/browser-cross-window"]
        ),
        let openedResult = opened["result"] as? [String: Any],
        let browserPanelId = openedResult["surface_id"] as? String,
        !browserPanelId.isEmpty else {
            XCTFail("browser.open_split did not return surface_id")
            return
        }

        guard let currentWindow = v2Call("window.current"),
              let currentWindowResult = currentWindow["result"] as? [String: Any],
              let sourceWindowId = currentWindowResult["window_id"] as? String,
              !sourceWindowId.isEmpty else {
            XCTFail("window.current did not return window_id")
            return
        }

        guard let createdWindow = v2Call("window.create"),
              let createdWindowResult = createdWindow["result"] as? [String: Any],
              let destinationWindowId = createdWindowResult["window_id"] as? String,
              !destinationWindowId.isEmpty else {
            XCTFail("window.create did not return window_id")
            return
        }

        XCTAssertNotEqual(sourceWindowId, destinationWindowId)

        guard v2Call(
            "workspace.move_to_window",
            params: [
                "workspace_id": workspaceId,
                "window_id": destinationWindowId,
                "focus": true,
            ]
        ) != nil else {
            XCTFail("workspace.move_to_window failed")
            return
        }

        XCTAssertTrue(
            waitForLifecycleSnapshot(timeout: 8.0) { snapshot in
                guard let browser = snapshot.records.first(where: { $0.panelId == browserPanelId }) else {
                    return false
                }
                return browser.selectedWorkspace &&
                    browser.activeWindowMembership &&
                    browser.anchorWindowNumber != 0 &&
                    browser.targetResidency == "visibleInActiveWindow"
            },
            "Expected browser to remain visible after cross-window workspace move"
        )

        guard let snapshot = latestLifecycleSnapshot(),
              let browser = snapshot.records.first(where: { $0.panelId == browserPanelId }) else {
            XCTFail("Missing browser lifecycle snapshot after cross-window move")
            return
        }

        XCTAssertTrue(browser.selectedWorkspace)
        XCTAssertTrue(browser.activeWindowMembership)
        XCTAssertEqual(browser.targetResidency, "visibleInActiveWindow")
        XCTAssertNotEqual(browser.anchorWindowNumber, 0)
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
        predicate: (BrowserCrossWindowSnapshot) -> Bool
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

    private func latestLifecycleSnapshot() -> BrowserCrossWindowSnapshot? {
        guard let response = v2Call("debug.panel_lifecycle"),
              let result = response["result"] as? [String: Any] else {
            return nil
        }
        return BrowserCrossWindowSnapshot(result: result)
    }

    private func v2Call(_ method: String, params: [String: Any] = [:]) -> [String: Any]? {
        BrowserCrossWindowV2SocketClient(path: socketPath).call(method: method, params: params)
    }
}

private struct BrowserCrossWindowRecord {
    let panelId: String
    let selectedWorkspace: Bool
    let activeWindowMembership: Bool
    let targetResidency: String
    let anchorWindowNumber: Int
}

private struct BrowserCrossWindowSnapshot {
    let records: [BrowserCrossWindowRecord]

    init?(result: [String: Any]) {
        let rawRecords = result["records"] as? [[String: Any]] ?? []
        let desiredContainer = result["desired"] as? [String: Any] ?? [:]
        let rawDesired = desiredContainer["records"] as? [[String: Any]] ?? []
        let desiredPairs: [(String, String)] = rawDesired.compactMap { row -> (String, String)? in
            guard let panelId = row["panelId"] as? String else { return nil }
            return (panelId, row["targetResidency"] as? String ?? "")
        }
        let desiredByPanel = Dictionary(uniqueKeysWithValues: desiredPairs)

        records = rawRecords.compactMap { row -> BrowserCrossWindowRecord? in
            guard let panelId = row["panelId"] as? String else { return nil }
            let anchor = row["anchor"] as? [String: Any] ?? [:]
            return BrowserCrossWindowRecord(
                panelId: panelId,
                selectedWorkspace: row["selectedWorkspace"] as? Bool ?? false,
                activeWindowMembership: row["activeWindowMembership"] as? Bool ?? false,
                targetResidency: desiredByPanel[panelId] ?? "",
                anchorWindowNumber: anchor["windowNumber"] as? Int ?? 0
            )
        }
    }
}

private final class BrowserCrossWindowV2SocketClient {
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
