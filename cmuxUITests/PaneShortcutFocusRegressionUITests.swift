import XCTest
import Foundation

final class PaneShortcutFocusRegressionUITests: XCTestCase {
    private var socketPath = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-ui-test-socket-\(UUID().uuidString).sock"
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    func testSurfaceShortcutKeepsSelectedPaneWhenResponderIsStale() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        launchAndEnsureForeground(app)

        XCTAssertTrue(waitForSocketPong(timeout: 12.0), "Expected control socket at \(socketPath)")

        guard let initialSurfaceId = currentSurfaceId() else {
            XCTFail("Expected initial surface")
            return
        }
        guard let split = socketJSON(
            method: "surface.split",
            params: ["surface_id": initialSurfaceId, "direction": "right", "focus": true]
        ),
              let splitOK = split["ok"] as? Bool,
              splitOK,
              let splitResult = split["result"] as? [String: Any],
              let workspaceId = splitResult["workspace_id"] as? String,
              let rightSurfaceId = splitResult["surface_id"] as? String else {
            XCTFail("Expected right split to be created. response=\(String(describing: socketJSON(method: "surface.current", params: [:])))")
            return
        }

        guard let panePayload = socketJSON(method: "pane.list", params: [:]),
              let paneOK = panePayload["ok"] as? Bool,
              paneOK,
              let paneResult = panePayload["result"] as? [String: Any],
              let panes = paneResult["panes"] as? [[String: Any]],
              let leftPane = panes.first(where: { pane in
                  (pane["surface_ids"] as? [String])?.contains(initialSurfaceId) == true
              }),
              let leftPaneId = leftPane["id"] as? String else {
            XCTFail("Expected left pane containing initial surface. response=\(String(describing: socketJSON(method: "pane.list", params: [:])))")
            return
        }

        guard let create = socketJSON(
            method: "surface.create",
            params: ["pane_id": leftPaneId, "type": "terminal"]
        ),
              let createOK = create["ok"] as? Bool,
              createOK,
              let createResult = create["result"] as? [String: Any],
              let newLeftSurfaceId = createResult["surface_id"] as? String else {
            XCTFail("Expected second surface in left pane. response=\(String(describing: socketJSON(method: "pane.surfaces", params: ["pane_id": leftPaneId])))")
            return
        }

        guard let focusRight = socketJSON(method: "surface.focus", params: ["surface_id": rightSurfaceId]),
              (focusRight["ok"] as? Bool) == true else {
            XCTFail("Expected surface.focus to succeed for right surface")
            return
        }
        guard let focusLeftPane = socketJSON(method: "pane.focus", params: ["pane_id": leftPaneId]),
              (focusLeftPane["ok"] as? Bool) == true else {
            XCTFail("Expected pane.focus to succeed for left pane")
            return
        }

        guard let leftSurfacesBefore = paneSurfaces(paneId: leftPaneId),
              leftSurfacesBefore.contains(where: { ($0["id"] as? String) == newLeftSurfaceId }),
              let selectedBefore = selectedSurfaceId(in: leftSurfacesBefore) else {
            XCTFail("Expected left pane surfaces before shortcut. response=\(String(describing: socketJSON(method: "pane.surfaces", params: ["pane_id": leftPaneId])))")
            return
        }

        guard let expectedSurfaceId = nextSurfaceId(after: selectedBefore, in: leftSurfacesBefore) else {
            XCTFail("Expected selected surface \(selectedBefore) to exist in left pane surfaces \(leftSurfacesBefore)")
            return
        }
        app.typeKey("]", modifierFlags: [.command, .shift])

        XCTAssertTrue(
            waitForCondition(timeout: 5.0) {
                self.selectedSurfaceId(in: self.paneSurfaces(paneId: leftPaneId) ?? []) == expectedSurfaceId &&
                    self.currentSurfaceId() == expectedSurfaceId
            },
            "Expected Cmd+Shift+] to select \(expectedSurfaceId) in the focused pane instead of returning to stale responder \(rightSurfaceId). current=\(currentSurfaceId() ?? "nil") pane=\(paneSurfaces(paneId: leftPaneId) ?? [])"
        )

        guard let staleFocus = socketJSON(
            method: "debug.terminal.first_responder_focus",
            params: ["workspace_id": workspaceId, "surface_id": rightSurfaceId]
        ),
              let staleFocusOK = staleFocus["ok"] as? Bool,
              staleFocusOK,
              let staleFocusResult = staleFocus["result"] as? [String: Any],
              let staleFocusAccepted = staleFocusResult["accepted"] as? Bool else {
            XCTFail("Expected stale terminal first-responder focus request to return a result. response=\(String(describing: socketJSON(method: "debug.terminals", params: [:])))")
            return
        }
        XCTAssertFalse(
            staleFocusAccepted,
            "Expected stale terminal first-responder focus request to be rejected. response=\(staleFocus)"
        )

        XCTAssertTrue(
            waitForCondition(timeout: 1.0) {
                self.selectedSurfaceId(in: self.paneSurfaces(paneId: leftPaneId) ?? []) == expectedSurfaceId &&
                    self.currentSurfaceId() == expectedSurfaceId
            },
            "Expected selected surface to remain stable after deferred responder callbacks. current=\(currentSurfaceId() ?? "nil") pane=\(paneSurfaces(paneId: leftPaneId) ?? [])"
        )
    }

    private func waitForSocketPong(timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            self.socketCommand("ping") == "pong"
        }
    }

    private func socketCommand(_ command: String) -> String? {
        ControlSocketClient(path: socketPath, responseTimeout: 2.0).sendLine(command)
    }

    private func socketJSON(method: String, params: [String: Any]) -> [String: Any]? {
        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params,
        ]
        return ControlSocketClient(path: socketPath, responseTimeout: 2.0).sendJSON(request)
    }

    private func currentSurfaceId() -> String? {
        guard let envelope = socketJSON(method: "surface.current", params: [:]),
              let ok = envelope["ok"] as? Bool,
              ok,
              let result = envelope["result"] as? [String: Any] else {
            return nil
        }
        return result["surface_id"] as? String
    }

    private func paneSurfaces(paneId: String) -> [[String: Any]]? {
        guard let envelope = socketJSON(method: "pane.surfaces", params: ["pane_id": paneId]),
              let ok = envelope["ok"] as? Bool,
              ok,
              let result = envelope["result"] as? [String: Any] else {
            return nil
        }
        return result["surfaces"] as? [[String: Any]]
    }

    private func selectedSurfaceId(in surfaces: [[String: Any]]) -> String? {
        surfaces.first { ($0["selected"] as? Bool) == true }?["id"] as? String
    }

    private func nextSurfaceId(after selectedSurfaceId: String, in surfaces: [[String: Any]]) -> String? {
        let ids = surfaces.compactMap { $0["id"] as? String }
        guard let index = ids.firstIndex(of: selectedSurfaceId), !ids.isEmpty else {
            return nil
        }
        return ids[(index + 1) % ids.count]
    }

    private func launchAndEnsureForeground(_ app: XCUIApplication) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }

        if app.state != .runningForeground {
            app.activate()
        }

        if waitForCondition(timeout: 3.0, predicate: { app.state == .runningForeground }) {
            return
        }

        XCTFail("App failed to reach foreground. state=\(app.state.rawValue)")
    }

    private func waitForCondition(timeout: TimeInterval, predicate: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in predicate() },
            object: nil
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private final class ControlSocketClient {
        private let path: String
        private let responseTimeout: TimeInterval

        init(path: String, responseTimeout: TimeInterval) {
            self.path = path
            self.responseTimeout = responseTimeout
        }

        func sendJSON(_ object: [String: Any]) -> [String: Any]? {
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  let line = String(data: data, encoding: .utf8),
                  let response = sendLine(line),
                  let responseData = response.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                return nil
            }
            return parsed
        }

        func sendLine(_ line: String) -> String? {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }

#if os(macOS)
            var noSigPipe: Int32 = 1
            _ = withUnsafePointer(to: &noSigPipe) { ptr in
                setsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    ptr,
                    socklen_t(MemoryLayout<Int32>.size)
                )
            }
#endif

            var addr = sockaddr_un()
            memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
            addr.sun_family = sa_family_t(AF_UNIX)

            let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
            let bytes = Array(path.utf8CString)
            guard bytes.count <= maxLen else { return nil }
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                memset(raw, 0, maxLen)
                for index in 0..<bytes.count {
                    raw[index] = bytes[index]
                }
            }

            let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
            let addrLen = socklen_t(pathOffset + bytes.count)
#if os(macOS)
            addr.sun_len = UInt8(min(Int(addrLen), 255))
#endif

            let connected = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    connect(fd, sa, addrLen)
                }
            }
            guard connected == 0 else { return nil }

            let payload = line + "\n"
            let wrote: Bool = payload.withCString { cString in
                var remaining = strlen(cString)
                var pointer = UnsafeRawPointer(cString)
                while remaining > 0 {
                    let written = write(fd, pointer, remaining)
                    if written <= 0 { return false }
                    remaining -= written
                    pointer = pointer.advanced(by: written)
                }
                return true
            }
            guard wrote else { return nil }

            let deadline = Date().addingTimeInterval(responseTimeout)
            var buffer = [UInt8](repeating: 0, count: 4096)
            var accumulator = ""
            while Date() < deadline {
                var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pollDescriptor, 1, 100)
                if ready < 0 {
                    return nil
                }
                if ready == 0 {
                    continue
                }
                let count = read(fd, &buffer, buffer.count)
                if count <= 0 { break }
                if let chunk = String(bytes: buffer[0..<count], encoding: .utf8) {
                    accumulator.append(chunk)
                    if let newline = accumulator.firstIndex(of: "\n") {
                        return String(accumulator[..<newline])
                    }
                }
            }

            return accumulator.isEmpty ? nil : accumulator.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
