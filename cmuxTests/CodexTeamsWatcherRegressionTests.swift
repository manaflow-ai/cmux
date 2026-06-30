import CryptoKit
import Darwin
import Foundation
import Testing

@Suite(.serialized)
final class CodexTeamsWatcherRegressionTests {
    @Test
    func watcherOpensBackfilledSubagentWithoutSubscribingToThreadStreams() throws {
        let appServer = try FakeCodexTeamsAppServer()
        defer { appServer.stop() }

        let cmuxSocket = try RecordingCodexTeamsCmuxSocket()
        defer { cmuxSocket.stop() }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(
            fileURLWithPath: try BundledCLITestSupport.bundledCLIPath(for: CodexTeamsWatcherRegressionTests.self)
        )
        process.arguments = [
            "--socket",
            cmuxSocket.path,
            "__codex-teams-watch",
            "--workspace-id",
            "workspace-root",
            "--surface-id",
            "surface-root",
            "--app-server-url",
            "ws://127.0.0.1:\(appServer.port)",
            "--codex-path",
            "/usr/bin/codex",
            "--max-auto-depth",
            "2",
            "--owner-pid",
            String(getpid())
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        // The watcher opens a real URLSessionWebSocketTask to the fake app server;
        // its connection timeout is 10s and it retries every 1s. Wait well past
        // that so a slow CI WebSocket connect still completes (and so a genuine
        // connect failure surfaces in stderr) instead of being killed mid-handshake.
        let openedSplit = cmuxSocket.waitForMethod("surface.split", timeout: 25)
        process.terminate()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(
            openedSplit,
            "Expected codex-teams watcher to open a subagent split. stdout=\(stdout) stderr=\(stderr) appServerMethods=\(appServer.methodSnapshot()) cmuxCommands=\(cmuxSocket.commandSnapshot())"
        )
        #expect(!appServer.methodSnapshot().contains("thread/resume"))
    }
}

private final class FakeCodexTeamsAppServer: @unchecked Sendable {
    let port: Int

    private let listenerFD: Int32
    private let queue = DispatchQueue(label: "com.cmux.tests.codex-teams-app-server", qos: .userInitiated)
    // Connection handlers must run off `queue`: `acceptLoop()` occupies that serial
    // queue for the listener's whole lifetime, so dispatching `handle(clientFD:)`
    // back onto it would starve every connection. Use a concurrent queue instead.
    private let connectionQueue = DispatchQueue(
        label: "com.cmux.tests.codex-teams-app-server.connections",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let lock = NSLock()
    private var stopped = false
    private var methods: [String] = []

    init() throws {
        let listener = try Self.bindLoopbackTCP()
        listenerFD = listener.fd
        port = listener.port
        queue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let fd = listenerFD
        lock.unlock()
        Darwin.close(fd)
    }

    func methodSnapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return methods
    }

    private func appendMethod(_ method: String) {
        lock.lock()
        methods.append(method)
        lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func acceptLoop() {
        while !isStopped {
            var address = sockaddr_in()
            var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                    Darwin.accept(listenerFD, socketPointer, &addressLength)
                }
            }
            if clientFD < 0 {
                if isStopped { return }
                if errno == EINTR { continue }
                continue
            }
            connectionQueue.async { [weak self] in
                self?.handle(clientFD: clientFD)
            }
        }
    }

    private func handle(clientFD: Int32) {
        defer { Darwin.close(clientFD) }
        guard let headers = readHTTPHeaders(from: clientFD),
              let key = Self.headerValue("Sec-WebSocket-Key", in: headers) else {
            return
        }
        sendHandshakeResponse(key: key, to: clientFD)

        while !isStopped {
            guard let frame = readFrame(from: clientFD) else { return }
            switch frame.opcode {
            case 0x1:
                guard let text = String(data: frame.payload, encoding: .utf8),
                      let request = Self.decodeObject(text),
                      let method = request["method"] as? String else {
                    continue
                }
                appendMethod(method)
                if method == "thread/resume" {
                    return
                }
                if let response = response(for: request, method: method) {
                    sendText(response, to: clientFD)
                }
            case 0x8:
                return
            case 0x9:
                sendFrame(opcode: 0xA, payload: frame.payload, to: clientFD)
            default:
                continue
            }
        }
    }

    private func response(for request: [String: Any], method: String) -> [String: Any]? {
        guard let id = request["id"] else { return nil }
        switch method {
        case "initialize":
            return ["id": id, "result": [:]]
        case "thread/loaded/list":
            return [
                "id": id,
                "result": [
                    "data": [
                        "root-thread",
                        "subagent-thread"
                    ]
                ]
            ]
        case "thread/read":
            let params = request["params"] as? [String: Any]
            let threadID = params?["threadId"] as? String ?? ""
            return [
                "id": id,
                "result": [
                    "thread": threadObject(id: threadID)
                ]
            ]
        default:
            return ["id": id, "result": [:]]
        }
    }

    private func threadObject(id: String) -> [String: Any] {
        if id == "subagent-thread" {
            return [
                "id": "subagent-thread",
                "cwd": "/tmp",
                "status": ["type": "idle"],
                "agentNickname": "Zeno",
                "source": [
                    "subAgent": [
                        "thread_spawn": [
                            "parent_thread_id": "root-thread",
                            "depth": 1,
                            "agent_nickname": "Zeno"
                        ]
                    ]
                ]
            ]
        }
        return [
            "id": "root-thread",
            "cwd": "/tmp",
            "status": ["type": "active"]
        ]
    }

    private func readHTTPHeaders(from fd: Int32) -> String? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < 16 * 1024 {
            let count = Darwin.read(fd, &byte, 1)
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { return nil }
            data.append(byte)
            if data.suffix(4) == Data([13, 10, 13, 10]) {
                return String(data: data, encoding: .utf8)
            }
        }
        return nil
    }

    private func sendHandshakeResponse(key: String, to fd: Int32) {
        let accept = Self.websocketAcceptValue(for: key)
        // The response must terminate with a blank line ("\r\n\r\n"). A Swift
        // multiline string literal drops the final newline before the closing
        // delimiter, which would emit "\r\n\r" and leave the client's WebSocket
        // handshake parser waiting forever. Build the terminator explicitly.
        let response =
            "HTTP/1.1 101 Switching Protocols\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Accept: \(accept)\r\n" +
            "\r\n"
        writeAll(Data(response.utf8), to: fd)
    }

    private func readFrame(from fd: Int32) -> WebSocketFrame? {
        guard let header = readExact(count: 2, from: fd) else { return nil }
        let first = header[0]
        let second = header[1]
        let opcode = first & 0x0F
        let masked = (second & 0x80) != 0
        var length = UInt64(second & 0x7F)
        if length == 126 {
            guard let extended = readExact(count: 2, from: fd) else { return nil }
            length = UInt64(extended[0]) << 8 | UInt64(extended[1])
        } else if length == 127 {
            guard let extended = readExact(count: 8, from: fd) else { return nil }
            length = extended.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
        guard length <= UInt64(Int.max) else { return nil }
        let mask = masked ? readExact(count: 4, from: fd) : nil
        guard !masked || mask != nil else { return nil }
        guard var payload = readExact(count: Int(length), from: fd) else { return nil }
        if let mask {
            for index in payload.indices {
                payload[index] ^= mask[index % 4]
            }
        }
        return WebSocketFrame(opcode: opcode, payload: Data(payload))
    }

    private func sendText(_ object: [String: Any], to fd: Int32) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []) else {
            return
        }
        sendFrame(opcode: 0x1, payload: data, to: fd)
    }

    private func sendFrame(opcode: UInt8, payload: Data, to fd: Int32) {
        var frame = Data()
        frame.append(0x80 | opcode)
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= UInt16.max {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((length >> UInt64(shift)) & 0xFF))
            }
        }
        frame.append(payload)
        writeAll(frame, to: fd)
    }

    private func readExact(count: Int, from fd: Int32) -> [UInt8]? {
        if count == 0 { return [] }
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let readCount = bytes.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(
                    fd,
                    rawBuffer.baseAddress!.advanced(by: offset),
                    count - offset
                )
            }
            if readCount < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if readCount == 0 { return nil }
            offset += readCount
        }
        return bytes
    }

    private func writeAll(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(fd, base.advanced(by: offset), rawBuffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

    private static func bindLoopbackTCP() throws -> (fd: Int32, port: Int) {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError("socket") }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.bind(fd, socketPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw posixError("bind")
        }
        guard Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw posixError("listen")
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.getsockname(fd, socketPointer, &length)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(fd)
            throw posixError("getsockname")
        }
        return (fd, Int(UInt16(bigEndian: boundAddress.sin_port)))
    }

    private static func headerValue(_ name: String, in headers: String) -> String? {
        let prefix = name.lowercased() + ":"
        for line in headers.components(separatedBy: "\r\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func websocketAcceptValue(for key: String) -> String {
        let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((key + guid).utf8))
        return Data(digest).base64EncodedString()
    }

    private static func decodeObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }

    private static func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(errno)))"]
        )
    }

    private struct WebSocketFrame {
        let opcode: UInt8
        let payload: Data
    }
}
