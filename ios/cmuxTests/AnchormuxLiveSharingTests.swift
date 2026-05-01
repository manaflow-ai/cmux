import Foundation
import Darwin
import XCTest
@testable import cmux_DEV

final class AnchormuxLiveSharingTests: XCTestCase {
    func testDesktopSessionSharesWithIOSGhosttySurface() async throws {
        guard let config = LiveAnchormuxConfig.resolveForLiveTest() else {
            throw XCTSkip("Live Anchormux env not configured: \(LiveAnchormuxConfig.debugDescription())")
        }
        guard let readyToken = config.readyToken,
              let desktopToken = config.desktopToken else {
            throw XCTSkip("Live Anchormux tokens missing: \(LiveAnchormuxConfig.debugDescription())")
        }

        print("ANCHORMUX_LIVE step=transport-connect host=\(config.host) port=\(config.port)")
        let transport = try await LiveTCPDaemonTransport.connect(
            host: config.host,
            port: config.port
        )
        let client = TerminalRemoteDaemonClient(transport: transport)
        print("ANCHORMUX_LIVE step=hello-start")
        let hello = try await withTimeout("hello", seconds: 3) {
            try await client.sendHello()
        }
        print("ANCHORMUX_LIVE step=hello-done caps=\(hello.capabilities)")
        XCTAssertEqual(hello.name, "cmuxd-remote")
        XCTAssertTrue(hello.capabilities.contains("terminal.stream"))
        let (surfaceView, delegate) = try await MainActor.run {
            let runtime = try GhosttyRuntime.shared()
            let delegate = LiveGhosttySurfaceDelegate()
            let surfaceView = GhosttySurfaceView(runtime: runtime, delegate: delegate)
            surfaceView.frame = CGRect(x: 0, y: 0, width: 640, height: 420)
            surfaceView.layoutIfNeeded()
            return (surfaceView, delegate)
        }
        let initialSize = try await MainActor.run {
            try XCTUnwrap(delegate.lastSize)
        }
        print("ANCHORMUX_LIVE step=surface-ready cols=\(initialSize.columns) rows=\(initialSize.rows)")

        let sessionTransport = TerminalRemoteDaemonSessionTransport(
            client: client,
            command: "printf READY; stty raw -echo -onlcr; exec cat",
            sharedSessionID: config.sessionID,
            readTimeoutMilliseconds: 100
        )

        await MainActor.run {
            delegate.onInput = { data in
                Task {
                    try await sessionTransport.send(data)
                }
            }
        }

        let connectedExpectation = expectation(description: "connected")
        sessionTransport.eventHandler = { event in
            switch event {
            case .connected:
                print("ANCHORMUX_LIVE event=connected")
                connectedExpectation.fulfill()
            case .output(let data):
                print("ANCHORMUX_LIVE event=output bytes=\(data.count)")
                Task { @MainActor in
                    surfaceView.processOutput(data)
                }
            case .disconnected(let error):
                print("ANCHORMUX_LIVE event=disconnected error=\(error ?? "nil")")
            default:
                break
            }
        }

        print("ANCHORMUX_LIVE step=session-connect-start session=\(config.sessionID)")
        do {
            try await withTimeout("sessionTransport.connect", seconds: 5) {
                try await sessionTransport.connect(initialSize: initialSize)
            }
        } catch {
            XCTFail("sessionTransport.connect failed: \(error)")
            await sessionTransport.disconnect()
            await MainActor.run {
                surfaceView.disposeSurface()
            }
            return
        }
        print("ANCHORMUX_LIVE step=session-connect-done")
        await fulfillment(of: [connectedExpectation], timeout: 5.0)

        let desktopText = try await waitForRenderedText(
            in: surfaceView,
            containing: desktopToken,
            timeout: 30.0
        )
        XCTAssertTrue(desktopText.contains(desktopToken))

        await MainActor.run {
            surfaceView.simulateTextInputForTesting("echo \(readyToken)\n")
        }

        let readyText = try await waitForRenderedText(
            in: surfaceView,
            containing: readyToken,
            timeout: 15.0
        )
        XCTAssertTrue(readyText.contains(readyToken))

        await sessionTransport.disconnect()
        await MainActor.run {
            surfaceView.disposeSurface()
        }
    }

    func testDesktopCommandBackspaceClearsPromptOnIOS() async throws {
        guard let config = LiveAnchormuxConfig.resolveForLiveTest() else {
            throw XCTSkip("Live Anchormux env not configured: \(LiveAnchormuxConfig.debugDescription())")
        }
        guard let appSocket = LiveDesktopAutomation.socketPath() else {
            throw XCTSkip("Desktop automation socket missing from live Anchormux env")
        }

        let transport = try await LiveTCPDaemonTransport.connect(
            host: config.host,
            port: config.port
        )
        let client = TerminalRemoteDaemonClient(transport: transport)
        let hello = try await withTimeout("hello", seconds: 3) {
            try await client.sendHello()
        }
        XCTAssertEqual(hello.name, "cmuxd-remote")
        XCTAssertTrue(hello.capabilities.contains("terminal.stream"))

        let (surfaceView, delegate) = try await MainActor.run {
            let runtime = try GhosttyRuntime.shared()
            let delegate = LiveGhosttySurfaceDelegate()
            let surfaceView = GhosttySurfaceView(runtime: runtime, delegate: delegate)
            surfaceView.frame = CGRect(x: 0, y: 0, width: 640, height: 420)
            surfaceView.layoutIfNeeded()
            return (surfaceView, delegate)
        }
        let initialSize = try await MainActor.run {
            try XCTUnwrap(delegate.lastSize)
        }

        let sessionTransport = TerminalRemoteDaemonSessionTransport(
            client: client,
            command: "printf READY; stty raw -echo -onlcr; exec cat",
            sharedSessionID: config.sessionID,
            readTimeoutMilliseconds: 100
        )

        await MainActor.run {
            delegate.onInput = { data in
                Task {
                    try await sessionTransport.send(data)
                }
            }
        }

        let connectedExpectation = expectation(description: "connected")
        sessionTransport.eventHandler = { event in
            switch event {
            case .connected:
                connectedExpectation.fulfill()
            case .output(let data):
                Task { @MainActor in
                    surfaceView.processOutput(data)
                }
            default:
                break
            }
        }

        do {
            try await withTimeout("sessionTransport.connect", seconds: 5) {
                try await sessionTransport.connect(initialSize: initialSize)
            }
        } catch {
            await sessionTransport.disconnect()
            await MainActor.run {
                surfaceView.disposeSurface()
            }
            XCTFail("sessionTransport.connect failed: \(error)")
            return
        }

        await fulfillment(of: [connectedExpectation], timeout: 5.0)

        let desktopClient = try DesktopAutomationSocketClient(path: appSocket)
        try desktopClient.activateApp()

        let token = "DELETE_ME_\(Int(Date().timeIntervalSince1970))"
        try desktopClient.type(token)

        let visibleBeforeDelete = try await waitForRenderedText(
            in: surfaceView,
            containing: token,
            timeout: 15.0
        )
        XCTAssertTrue(visibleBeforeDelete.contains(token))

        try desktopClient.simulateShortcut("cmd+backspace")

        let renderedAfterDelete = try await waitForRenderedTextToClear(
            in: surfaceView,
            clearing: token,
            timeout: 15.0
        )
        XCTAssertFalse(renderedAfterDelete.contains(token), "expected iOS surface to clear desktop token after cmd+backspace, got: \(renderedAfterDelete)")

        let desktopAfterDelete = try await waitForDesktopTextToClear(
            client: desktopClient,
            surfaceID: config.sessionID,
            clearing: token,
            timeout: 15.0
        )
        XCTAssertFalse(desktopAfterDelete.contains(token), "expected desktop surface to clear token after cmd+backspace, got: \(desktopAfterDelete)")

        await sessionTransport.disconnect()
        await MainActor.run {
            surfaceView.disposeSurface()
        }
    }

    private func waitForRenderedText(
        in surfaceView: GhosttySurfaceView,
        containing needle: String,
        timeout: TimeInterval
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var lastText = ""

        while Date() < deadline {
            lastText = await MainActor.run {
                surfaceView.renderedTextForTesting() ?? ""
            }
            if lastText.contains(needle) {
                return lastText
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        XCTFail("Timed out waiting for \(needle) in rendered text: \(lastText)")
        return lastText
    }

    private func waitForRenderedTextToClear(
        in surfaceView: GhosttySurfaceView,
        clearing needle: String,
        timeout: TimeInterval
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var lastText = ""

        while Date() < deadline {
            lastText = await MainActor.run {
                surfaceView.renderedTextForTesting() ?? ""
            }
            if !lastText.contains(needle) {
                return lastText
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTFail("Timed out waiting for \(needle) to clear from rendered text: \(lastText)")
        return lastText
    }

    private func waitForDesktopTextToClear(
        client: DesktopAutomationSocketClient,
        surfaceID: String,
        clearing needle: String,
        timeout: TimeInterval
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var lastText = ""

        while Date() < deadline {
            lastText = try client.readSurfaceText(surfaceID)
            if !lastText.contains(needle) {
                return lastText
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTFail("Timed out waiting for \(needle) to clear from desktop text: \(lastText)")
        return lastText
    }

    private func withTimeout<T: Sendable>(
        _ name: String,
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw LiveAnchormuxTestError.timeout(name)
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

private enum LiveAnchormuxTestError: LocalizedError {
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .timeout(let name):
            return "Timed out waiting for \(name)"
        }
    }
}

@MainActor
private final class LiveGhosttySurfaceDelegate: GhosttySurfaceViewDelegate {
    var lastSize: TerminalGridSize?
    var onInput: ((Data) -> Void)?

    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {
        onInput?(data)
    }

    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize) {
        lastSize = size
    }
}

private enum LiveDesktopAutomation {
    static func socketPath(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let raw = env["CMUX_LIVE_ANCHORMUX_APP_SOCKET"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty else {
            return nil
        }
        return raw
    }
}

private struct DesktopAutomationSocketError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

private final class DesktopAutomationSocketClient {
    private let path: String
    private let responseTimeout: TimeInterval
    private var nextID: Int = 1

    init(path: String, responseTimeout: TimeInterval = 5.0) throws {
        guard !path.isEmpty else {
            throw DesktopAutomationSocketError(message: "Desktop automation socket path is empty")
        }
        self.path = path
        self.responseTimeout = responseTimeout
    }

    func activateApp() throws {
        _ = try call("debug.app.activate")
    }

    func type(_ text: String) throws {
        _ = try call("debug.type", params: ["text": text])
    }

    func simulateShortcut(_ combo: String) throws {
        _ = try call("debug.shortcut.simulate", params: ["combo": combo])
    }

    func readSurfaceText(_ surfaceID: String) throws -> String {
        let result = try call("surface.read_text", params: ["surface_id": surfaceID])
        if let text = result["text"] as? String {
            return text
        }
        if let base64 = result["base64"] as? String,
           let data = Data(base64Encoded: base64) {
            return String(decoding: data, as: UTF8.self)
        }
        return ""
    }

    private func call(_ method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        let requestID = nextID
        nextID += 1

        let object: [String: Any] = [
            "id": requestID,
            "method": method,
            "params": params,
        ]
        let response = try sendJSON(object)

        guard let ok = response["ok"] as? Bool, ok else {
            let error = response["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "unknown error"
            throw DesktopAutomationSocketError(message: "desktop automation call failed for \(method): \(message)")
        }

        return response["result"] as? [String: Any] ?? [:]
    }

    private func sendJSON(_ object: [String: Any]) throws -> [String: Any] {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw DesktopAutomationSocketError(message: "invalid desktop automation JSON object")
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let line = String(data: data, encoding: .utf8) else {
            throw DesktopAutomationSocketError(message: "failed to encode desktop automation request")
        }
        guard let response = try sendLine(line),
              let responseData = response.data(using: .utf8),
              let parsed = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw DesktopAutomationSocketError(message: "failed to decode desktop automation response")
        }
        return parsed
    }

    private func sendLine(_ line: String) throws -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw DesktopAutomationSocketError(message: "failed to create desktop automation socket")
        }
        defer { close(fd) }

#if os(macOS) || os(iOS)
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
        guard bytes.count <= maxLen else {
            throw DesktopAutomationSocketError(message: "desktop automation socket path is too long")
        }
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
        guard connected == 0 else {
            throw DesktopAutomationSocketError(message: "failed to connect to desktop automation socket at \(path)")
        }

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
        guard wrote else {
            throw DesktopAutomationSocketError(message: "failed to write desktop automation request")
        }

        let deadline = Date().addingTimeInterval(responseTimeout)
        var buffer = [UInt8](repeating: 0, count: 4096)
        var accumulator = ""
        while Date() < deadline {
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollDescriptor, 1, 100)
            if ready < 0 {
                throw DesktopAutomationSocketError(message: "poll failed while waiting for desktop automation response")
            }
            if ready == 0 {
                continue
            }
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 {
                break
            }
            if let chunk = String(bytes: buffer[0..<count], encoding: .utf8) {
                accumulator.append(chunk)
                if let newline = accumulator.firstIndex(of: "\n") {
                    return String(accumulator[..<newline])
                }
            }
        }

        if accumulator.isEmpty {
            throw DesktopAutomationSocketError(message: "timed out waiting for desktop automation response")
        }
        return accumulator.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
