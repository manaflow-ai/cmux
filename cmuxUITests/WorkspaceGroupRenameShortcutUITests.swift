import XCTest
import Foundation
import Darwin

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/9199.
///
/// A workspace group's header row is backed by an anchor workspace whose own
/// title is never displayed — the row renders the group name, and the anchor
/// title keeps whatever the group was called at creation. With the anchor
/// focused, ⌘⇧R must rename the group (what that row shows), not the invisible
/// anchor title.
///
/// Setup and assertions go through the control socket so the check is on real
/// model state rather than an accessibility label that both behaviors could
/// satisfy.
final class WorkspaceGroupRenameShortcutUITests: XCTestCase {
    private var socketPath = ""
    private var launchTag = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-debug-\(UUID().uuidString).sock"
        launchTag = "ui-tests-group-rename-\(UUID().uuidString.lowercased())"
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: socketPath)
        super.tearDown()
    }

    func testRenameShortcutRenamesFocusedWorkspaceGroup() {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchArguments += ["-socketControlMode", "allowAll"]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = launchTag
        launchAndActivate(app)

        let client = SocketClient(path: socketPath)
        XCTAssertTrue(
            pollUntil(timeout: 30.0) { FileManager.default.fileExists(atPath: self.socketPath) },
            "Control socket never bound at \(socketPath)"
        )
        XCTAssertTrue(
            pollUntil(timeout: 20.0) { client.call("workspace.group.list", [:]) != nil },
            "Control socket never answered"
        )

        // Create a group, then rename the group only. The anchor workspace keeps
        // the creation-time title, which is the divergence the bug rides on.
        guard let created = client.call("workspace.group.create", ["name": "Group Under Test"]),
              let group = (created["result"] as? [String: Any])?["group"] as? [String: Any],
              let groupId = group["id"] as? String,
              let anchorId = group["anchor_workspace_id"] as? String else {
            XCTFail("Could not create a workspace group over the control socket")
            return
        }
        XCTAssertNotNil(
            client.call("workspace.group.rename", ["group_id": groupId, "name": "Swappa"]),
            "Could not rename the group over the control socket"
        )
        XCTAssertNotNil(
            client.call("workspace.select", ["workspace_id": anchorId]),
            "Could not focus the group's anchor workspace"
        )
        XCTAssertTrue(
            pollUntil(timeout: 10.0) { self.groupName(client, groupId: groupId) == "Swappa" },
            "Group rename did not land before exercising the shortcut"
        )

        let newName = "Renamed \(String(UUID().uuidString.prefix(6)))"
        app.typeKey("r", modifierFlags: [.command, .shift])

        let renameField = app.textFields["CommandPaletteRenameField"].firstMatch
        XCTAssertTrue(
            renameField.waitForExistence(timeout: 15.0),
            "Expected Cmd+Shift+R to open the palette rename editor"
        )
        app.typeKey("a", modifierFlags: [.command])
        app.typeText(newName)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        XCTAssertTrue(
            pollUntil(timeout: 15.0) { self.groupName(client, groupId: groupId) == newName },
            """
            Expected Cmd+Shift+R on the focused group anchor to rename the group. \
            group name is still \(self.groupName(client, groupId: groupId) ?? "nil")
            """
        )
    }

    private func groupName(_ client: SocketClient, groupId: String) -> String? {
        guard let response = client.call("workspace.group.list", [:]),
              let result = response["result"] as? [String: Any],
              let groups = result["groups"] as? [[String: Any]] else {
            return nil
        }
        return groups.first(where: { $0["id"] as? String == groupId })?["name"] as? String
    }

    /// Launches and brings the app forward. Deliberately does NOT wrap
    /// `launch()` in `XCTExpectFailure`: a non-strict expectation there
    /// swallows the launch failure and, with `continueAfterFailure = false`,
    /// silently abandons the rest of the test body — the test then passes
    /// without running a single assertion.
    private func launchAndActivate(_ app: XCUIApplication, timeout: TimeInterval = 30.0) {
        app.launch()
        if !app.wait(for: .runningForeground, timeout: timeout), app.state == .runningBackground {
            app.activate()
            _ = app.wait(for: .runningForeground, timeout: 10.0)
        }
        XCTAssertEqual(app.state, .runningForeground, "App never reached the foreground")
    }

    private func pollUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        while true {
            if condition() { return true }
            if (ProcessInfo.processInfo.systemUptime - start) >= timeout { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
    }
}

/// Minimal line-protocol client for the app's control socket.
private final class SocketClient {
    private let path: String
    private let responseTimeout: TimeInterval = 5.0
    private var nextId = 0

    init(path: String) {
        self.path = path
    }

    func call(_ method: String, _ params: [String: Any]) -> [String: Any]? {
        nextId += 1
        let request: [String: Any] = ["id": "\(nextId)", "method": method, "params": params]
        guard JSONSerialization.isValidJSONObject(request),
              let data = try? JSONSerialization.data(withJSONObject: request),
              let line = String(data: data, encoding: .utf8),
              let response = send(line),
              let responseData = response.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any],
              object["ok"] as? Bool == true else {
            return nil
        }
        return object
    }

    private func send(_ line: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var timeout = timeval(tv_sec: Int(responseTimeout), tv_usec: 0)
        withUnsafePointer(to: &timeout) { ptr in
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }

        var addr = sockaddr_un()
        memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            for index in 0..<pathBytes.count {
                raw[index] = pathBytes[index]
            }
        }
        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        let addrLen = socklen_t(pathOffset + pathBytes.count)
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, addrLen)
            }
        }
        guard connected == 0 else { return nil }

        let payload = Array((line + "\n").utf8)
        let wrote = payload.withUnsafeBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            return Darwin.write(fd, baseAddress, rawBuffer.count) == rawBuffer.count
        }
        guard wrote else { return nil }

        var buffer = [UInt8](repeating: 0, count: 8192)
        var accumulator = ""
        let deadline = Date().addingTimeInterval(responseTimeout)
        while Date() < deadline {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            if let chunk = String(bytes: buffer[0..<count], encoding: .utf8) {
                accumulator.append(chunk)
                if let newline = accumulator.firstIndex(of: "\n") {
                    return String(accumulator[accumulator.startIndex..<newline])
                }
            }
        }
        return accumulator.isEmpty ? nil : accumulator
    }
}
