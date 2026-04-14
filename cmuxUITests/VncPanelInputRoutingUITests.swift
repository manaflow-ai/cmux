import XCTest
import Foundation
import CoreGraphics
import Darwin

final class VncPanelInputRoutingUITests: XCTestCase {
    private var socketPath = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-ui-test-socket-\(UUID().uuidString).sock"
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    func testVncPanelRoutesKeyboardMultiKeyAndMouseInputInNativeSession() {
        let app = launchWithFakeNativeVncSession()

        XCTAssertTrue(waitForSocketPong(timeout: 12.0), "Expected control socket at \(socketPath)")

        guard let surfaceId = createVncSurface(endpoint: "127.0.0.1:5900") else {
            XCTFail("Expected to create a VNC surface")
            return
        }

        XCTAssertTrue(
            waitForVncState(surfaceId: surfaceId, timeout: 8.0) { state in
                (state["state"] as? String) == "connected" &&
                    (state["renderer"] as? String) == "native"
            },
            "Expected fake-native VNC surface to connect"
        )

        guard let content = focusVncContentElement(app: app, surfaceId: surfaceId) else {
            XCTFail("Expected VNC content view for \(surfaceId)")
            return
        }

        app.typeText("abc")
        app.typeKey("k", modifierFlags: [.control, .option])

        let center = content.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.click()

        let dragStart = content.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.35))
        let dragEnd = content.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.65))
        dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)

        XCTAssertTrue(
            waitForVncState(surfaceId: surfaceId, timeout: 8.0) { state in
                let keyDown = self.intValue(state["input_key_down_count"]) ?? 0
                let modifiedKeyDown = self.intValue(state["input_modified_key_down_count"]) ?? 0
                let mouseDown = self.intValue(state["input_mouse_down_count"]) ?? 0
                let mouseUp = self.intValue(state["input_mouse_up_count"]) ?? 0
                let mouseDragged = self.intValue(state["input_mouse_dragged_count"]) ?? 0
                return keyDown >= 4 &&
                    modifiedKeyDown >= 1 &&
                    mouseDown >= 1 &&
                    mouseUp >= 1 &&
                    mouseDragged >= 1
            },
            "Expected VNC surface to receive keyboard, multi-key, and mouse input. state=\(vncState(surfaceId: surfaceId) ?? [:])"
        )
    }

    func testVncPanelCapturesIMEStyleUnicodeTextInput() {
        let app = launchWithFakeNativeVncSession()

        XCTAssertTrue(waitForSocketPong(timeout: 12.0), "Expected control socket at \(socketPath)")

        guard let surfaceId = createVncSurface(endpoint: "127.0.0.1:5901") else {
            XCTFail("Expected to create a VNC surface")
            return
        }

        XCTAssertTrue(
            waitForVncState(surfaceId: surfaceId, timeout: 8.0) { state in
                (state["state"] as? String) == "connected" &&
                    (state["renderer"] as? String) == "native"
            },
            "Expected fake-native VNC surface to connect"
        )

        guard focusVncContentElement(app: app, surfaceId: surfaceId) != nil else {
            XCTFail("Expected VNC content view for \(surfaceId)")
            return
        }

        app.typeText("にほんご")

        XCTAssertTrue(
            waitForVncState(surfaceId: surfaceId, timeout: 8.0) { state in
                let textEvents = self.intValue(state["input_text_event_count"]) ?? 0
                let lastTextLength = self.intValue(state["input_last_text_length"]) ?? 0
                let hasNonASCII = self.boolValue(state["input_last_text_contains_non_ascii"]) ?? false
                return textEvents >= 1 && lastTextLength > 0 && hasNonASCII
            },
            "Expected VNC surface to capture Unicode/IME-style text input. state=\(vncState(surfaceId: surfaceId) ?? [:])"
        )
    }

    private func launchWithFakeNativeVncSession() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_VNC_FAKE_NATIVE"] = "1"
        app.launch()
        app.activate()

        if app.wait(for: .runningForeground, timeout: 12.0) {
            return app
        }
        if app.state == .runningBackground {
            _ = app.activate()
            _ = app.wait(for: .runningForeground, timeout: 6.0)
        }
        return app
    }

    private func focusVncContentElement(app: XCUIApplication, surfaceId: String) -> XCUIElement? {
        _ = socketJSON(
            method: "surface.focus",
            params: ["surface_id": surfaceId]
        )

        let content = app.otherElements["VNCPanel.Content.\(surfaceId)"].firstMatch
        guard content.waitForExistence(timeout: 8.0) else { return nil }
        content.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        return content
    }

    private func createVncSurface(endpoint: String) -> String? {
        guard let envelope = socketJSON(
            method: "surface.create",
            params: [
                "type": "vnc",
                "endpoint": endpoint,
                "auto_connect": true,
            ]
        ),
        let ok = envelope["ok"] as? Bool,
        ok,
        let result = envelope["result"] as? [String: Any],
        let surfaceId = result["surface_id"] as? String else {
            return nil
        }

        return surfaceId
    }

    private func vncState(surfaceId: String) -> [String: Any]? {
        guard let envelope = socketJSON(
            method: "surface.vnc_state",
            params: ["surface_id": surfaceId]
        ),
        let ok = envelope["ok"] as? Bool,
        ok,
        let result = envelope["result"] as? [String: Any] else {
            return nil
        }
        return result
    }

    private func waitForVncState(
        surfaceId: String,
        timeout: TimeInterval,
        predicate: @escaping ([String: Any]) -> Bool
    ) -> Bool {
        waitForCondition(timeout: timeout) {
            guard let state = self.vncState(surfaceId: surfaceId) else { return false }
            return predicate(state)
        }
    }

    private func waitForSocketPong(timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            self.socketCommand("ping") == "PONG"
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

    private func waitForCondition(timeout: TimeInterval, predicate: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in predicate() },
            object: nil
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func intValue(_ value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        if value is NSNull { return nil }
        return value as? String
    }

    private func boolValue(_ value: Any?) -> Bool? {
        if let boolValue = value as? Bool {
            return boolValue
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            switch string.lowercased() {
            case "1", "true", "yes":
                return true
            case "0", "false", "no":
                return false
            default:
                return nil
            }
        }
        return nil
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
