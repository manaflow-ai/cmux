import CryptoKit
import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct CodexTeamsWatcherRegressionTests {
    @Test func watcherOpensSubagentAfterOversizedAppServerNotification() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: MockControlSocket.self)
        let controlSocket = try MockControlSocket()
        let appServer = try MockCodexAppServer()
        let homeURL = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-codexw-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: homeURL); appServer.stop(); controlSocket.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["HOME"] = homeURL.path
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = [
            "--socket", controlSocket.path,
            "__codex-teams-watch",
            "--workspace-id", "workspace-root",
            "--surface-id", "surface-root",
            "--app-server-url", appServer.urlString,
            "--codex-path", "/usr/bin/true",
            "--max-auto-depth", "2",
        ]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let didSplit = controlSocket.waitForSurfaceSplit(timeout: 15)
        Self.terminate(process)
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let appServerMethods = appServer.methods

        #expect(didSplit, Comment(rawValue: "appServerMethods: \(appServerMethods)\nstdout:\n\(stdout)\nstderr:\n\(stderr)"))
        #expect(appServerMethods.contains("thread/loaded/list"))
        #expect(controlSocket.methods.contains("surface.split"))
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            exited.signal()
        }
        if exited.wait(timeout: .now() + 1) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 1)
        }
    }
}

// Guards only immutable listener setup plus a tiny request log across handler threads.
private final class MockControlSocket: @unchecked Sendable {
    let path: String

    private let lock = NSLock()
    private let splitSemaphore = DispatchSemaphore(value: 0)
    private var listenerFD: Int32 = -1
    private var stopped = false
    private var requests: [String] = []

    init() throws {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codexw-\(shortID).sock")
            .path
        listenerFD = try Self.bindUnixSocket(at: path)
        let fd = listenerFD
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptLoop(listenerFD: fd)
        }
    }

    var methods: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests.compactMap { line in
            guard let payload = Self.jsonObject(line) else { return nil }
            return payload["method"] as? String
        }
    }

    func waitForSurfaceSplit(timeout: TimeInterval) -> Bool {
        splitSemaphore.wait(timeout: .now() + timeout) == .success
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let fd = listenerFD
        listenerFD = -1
        lock.unlock()

        if fd >= 0 { close(fd) }
        unlink(path)
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func acceptLoop(listenerFD: Int32) {
        while !isStopped {
            let clientFD = accept(listenerFD, nil, nil)
            guard clientFD >= 0 else { continue }
            clientFD.configureNoSigPipe()
            handle(clientFD: clientFD)
        }
    }

    private func handle(clientFD: Int32) {
        defer { close(clientFD) }
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(clientFD, &buffer, buffer.count)
            if count <= 0 { return }
            pending.append(buffer, count: count)
            while let newline = pending.firstIndex(of: 0x0A) {
                let lineData = pending[..<newline]
                pending.removeSubrange(...newline)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                lock.lock()
                requests.append(line)
                lock.unlock()
                let response = responseLine(for: line) + "\n"
                _ = Self.writeAll(Data(response.utf8), to: clientFD)
            }
        }
    }

    private func responseLine(for line: String) -> String {
        guard let payload = Self.jsonObject(line),
              let id = payload["id"] as? String,
              let method = payload["method"] as? String else {
            if line.hasPrefix("auth ") { return "OK" }
            return Self.v2Response(id: "unknown", ok: false, error: ["code": "malformed_request", "message": "invalid payload"])
        }
        switch method {
        case "surface.split":
            splitSemaphore.signal()
            return Self.v2Response(id: id, ok: true, result: ["surface_id": "surface-subagent"])
        case "tab.action", "workspace.equalize_splits":
            return Self.v2Response(id: id, ok: true, result: [:])
        default:
            return Self.v2Response(id: id, ok: false, error: ["code": "unexpected_method", "message": method])
        }
    }

    private static func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = Array(path.utf8)
        guard utf8.count < maxPathLength else {
            close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { buffer in
                for index in 0..<utf8.count { buffer[index] = CChar(bitPattern: utf8[index]) }
                buffer[utf8.count] = 0
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, listen(fd, 1) == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return fd
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func v2Response(id: String, ok: Bool, result: [String: Any]? = nil, error: [String: Any]? = nil) -> String {
        var payload: [String: Any] = ["id": id, "ok": ok]
        if let result { payload["result"] = result }
        if let error { payload["error"] = error }
        let data = try? JSONSerialization.data(withJSONObject: payload)
        return String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }

    fileprivate static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return true }
            var offset = 0
            while offset < data.count {
                let written = write(fd, base.advanced(by: offset), data.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if written == 0 { return false }
                offset += written
            }
            return true
        }
    }
}

// Each accepted WebSocket client is independent; shared state is immutable after init.
private final class MockCodexAppServer: @unchecked Sendable {
    private let rootThread = "019e9b40-4419-7433-80d5-cdb7286a33da"
    private let subagentThread = "019e9b40-b22a-7d02-8b47-e58d40d4a3e6"
    private let oversizedPadding = String(repeating: "x", count: 1_100_000)
    private let lock = NSLock()
    private var listenerFD: Int32 = -1
    private var stopped = false
    private var requests: [String] = []

    let urlString: String

    init() throws {
        listenerFD = try Self.bindTCPListener()
        urlString = "ws://127.0.0.1:\(try Self.port(for: listenerFD))"
        let fd = listenerFD
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptLoop(listenerFD: fd)
        }
    }

    var methods: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let fd = listenerFD
        listenerFD = -1
        lock.unlock()
        if fd >= 0 { close(fd) }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func acceptLoop(listenerFD: Int32) {
        while !isStopped {
            let clientFD = accept(listenerFD, nil, nil)
            guard clientFD >= 0 else { continue }
            clientFD.configureNoSigPipe()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handle(clientFD: clientFD)
            }
        }
    }

    private func handle(clientFD: Int32) {
        defer { close(clientFD) }
        guard performHandshake(clientFD: clientFD) else { return }
        while let text = Self.readFrame(from: clientFD),
              let message = Self.jsonObject(text) {
            guard let id = message["id"], let method = message["method"] as? String else {
                continue
            }
            lock.lock(); requests.append(method); lock.unlock()
            switch method {
            case "initialize":
                sendJSON(["id": id, "result": ["userAgent": "mock-codex"]], to: clientFD)
            case "thread/loaded/list":
                sendJSON(oversizedThreadStatusNotification(), to: clientFD)
                sendJSON(["id": id, "result": ["data": [rootThread, subagentThread]]], to: clientFD)
            case "thread/resume":
                let params = message["params"] as? [String: Any]
                let threadId = params?["threadId"] as? String
                sendJSON(["id": id, "result": ["thread": threadObject(id: threadId ?? rootThread)]], to: clientFD)
            default:
                sendJSON(["id": id, "result": [:]], to: clientFD)
            }
        }
    }

    private func oversizedThreadStatusNotification() -> [String: Any] {
        [
            "method": "thread/status/changed",
            "params": [
                "thread": threadObject(id: rootThread).merging(["debugPadding": oversizedPadding]) { current, _ in current },
            ],
        ]
    }

    private func threadObject(id: String) -> [String: Any] {
        if id == subagentThread {
            return [
                "id": subagentThread,
                "cwd": "/tmp",
                "status": ["type": "idle"],
                "agentNickname": "Zeno",
                "source": [
                    "subAgent": [
                        "thread_spawn": [
                            "parent_thread_id": rootThread,
                            "depth": 1,
                            "agent_nickname": "Zeno",
                            "agent_role": "Researcher",
                        ],
                    ],
                ],
            ]
        }
        return ["id": rootThread, "cwd": "/tmp", "status": ["type": "active"]]
    }

    private func performHandshake(clientFD: Int32) -> Bool {
        guard let request = Self.readHTTPHeader(from: clientFD),
              let keyLine = request
                .components(separatedBy: "\r\n")
                .first(where: { $0.lowercased().hasPrefix("sec-websocket-key:") }) else {
            return false
        }
        let key = keyLine.split(separator: ":", maxSplits: 1).last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let acceptSource = Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
        let accept = Data(Insecure.SHA1.hash(data: acceptSource)).base64EncodedString()
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        return MockControlSocket.writeAll(Data(response.utf8), to: clientFD)
    }

    private func sendJSON(_ object: [String: Any], to fd: Int32) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        _ = Self.sendText(text, to: fd)
    }

    private static func bindTCPListener() throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        guard bindResult == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return fd
    }

    private static func port(for fd: Int32) throws -> UInt16 {
        var addr = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.stride)
        let result = withUnsafeMutablePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                getsockname(fd, sockaddrPtr, &length)
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return UInt16(bigEndian: addr.sin_port)
    }

    private static func readHTTPHeader(from fd: Int32) -> String? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < 16 * 1024 {
            let count = read(fd, &byte, 1)
            if count <= 0 { return nil }
            data.append(byte)
            if data.suffix(4) == Data([13, 10, 13, 10]) {
                return String(data: data, encoding: .utf8)
            }
        }
        return nil
    }

    private static func readFrame(from fd: Int32) -> String? {
        guard let header = readExact(2, from: fd), header.count == 2 else { return nil }
        let opcode = header[0] & 0x0F
        if opcode == 0x8 { return nil }
        var length = Int(header[1] & 0x7F)
        if length == 126 {
            guard let extended = readExact(2, from: fd) else { return nil }
            length = Int(UInt16(extended[0]) << 8 | UInt16(extended[1]))
        } else if length == 127 {
            guard let extended = readExact(8, from: fd) else { return nil }
            length = extended.reduce(0) { ($0 << 8) | Int($1) }
        }
        let masked = (header[1] & 0x80) != 0
        let mask = masked ? readExact(4, from: fd) : nil
        guard var payload = readExact(length, from: fd) else { return nil }
        if let mask {
            for index in payload.indices {
                payload[index] ^= mask[index % 4]
            }
        }
        return String(data: payload, encoding: .utf8)
    }

    private static func readExact(_ count: Int, from fd: Int32) -> Data? {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let readCount = buffer.withUnsafeMutableBufferPointer { pointer -> Int in
                guard let base = pointer.baseAddress else { return 0 }
                return read(fd, base.advanced(by: offset), count - offset)
            }
            if readCount < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if readCount == 0 { return nil }
            offset += readCount
        }
        return Data(buffer)
    }

    private static func sendText(_ text: String, to fd: Int32) -> Bool {
        let payload = Data(text.utf8)
        var frame = Data([0x81])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= Int(UInt16.max) {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((UInt64(payload.count) >> UInt64(shift)) & 0xFF))
            }
        }
        frame.append(payload)
        return MockControlSocket.writeAll(frame, to: fd)
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

private extension Int32 {
    func configureNoSigPipe() {
#if os(macOS)
        var noSigPipe: Int32 = 1
        setsockopt(self, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
#endif
    }
}
