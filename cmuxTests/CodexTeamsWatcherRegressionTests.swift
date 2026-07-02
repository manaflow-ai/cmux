import CryptoKit
import Darwin
import Foundation
import Testing

@Suite(.serialized)
final class CodexTeamsWatcherRegressionTests {
    @Test
    func watcherOpensBackfilledAndLateSpawnedSubagentsWithoutThreadStreamSubscriptions() throws {
        let appServer = try FakeCodexTeamsAppServer()
        defer { appServer.stop() }

        let cmuxSocket = try RecordingCodexTeamsCmuxSocket()
        defer { cmuxSocket.stop() }

        // Point the spawned watcher at a throwaway HOME so any config, cache, or
        // debug-log writes land in a temp directory instead of polluting the real
        // home directory on developer machines and CI.
        let tempHome = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-codex-watch-home-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

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
        environment["HOME"] = tempHome.path
        environment["CFFIXED_USER_HOME"] = tempHome.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        // The watcher opens a real URLSessionWebSocketTask to the fake app
        // server; a cold CI loopback URLSession connect can take ~17s on macOS
        // 15. Wait for every expected split under ONE shared deadline instead of
        // summing four sequential per-assertion timeouts. The app-host harness
        // kills the test host ~45s after the XCTest terminal summary, so
        // sequential waits that sum past that (25+10+10+10) get truncated before
        // a single #expect records pass/fail — silently hiding both the RED
        // failures here and any real regression. A single 30s budget stays
        // inside the window whether the watcher connects slowly, fails the two
        // RED assertions, or never connects at all: a fully-satisfied set
        // returns as soon as the last split lands (GREEN exits in ~20s), while
        // an unsatisfied set records its failures at ~30s, well under the kill.
        //
        // Each split is matched by method (surface.split) plus the thread id it
        // carries in its startup_environment, so a thread counts only when it is
        // actually routed through surface.split — not merely mentioned by some
        // later command such as the tab.action rename.
        //
        // - late-subagent-thread: announced by a bare-threadId notification just
        //   after the backfill reads; one extra thread/read once connected.
        // - late-inflight-subagent-thread (Finding 1): announced by a bare
        //   threadId delivered while a thread/read is in flight, so it lands on
        //   that request's notification handler where re-entrant hydration is
        //   disabled. The watcher must defer and drain it, not drop it.
        // - reloaded-subagent-thread (Finding 2): its first read is still
        //   not_loaded, so it must not be pinned as hydrated forever; when the
        //   app-server re-announces it as loaded the watcher must re-read it.
        let splitResults = cmuxSocket.waitForCommands(
            matchingAll: [
                (method: "surface.split", needle: nil),
                (method: "surface.split", needle: "late-subagent-thread"),
                (method: "surface.split", needle: "late-inflight-subagent-thread"),
                (method: "surface.split", needle: "reloaded-subagent-thread")
            ],
            timeout: 30
        )
        let openedSplit = splitResults[0]
        let openedLateSplit = splitResults[1]
        let openedInflightSplit = splitResults[2]
        let openedReloadedSplit = splitResults[3]
        process.terminate()
        // Don't let a watcher that ignores SIGTERM hang the whole suite: bound the
        // graceful shutdown wait, then SIGKILL and reap so the test always exits.
        let terminationDeadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < terminationDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(
            openedSplit,
            "Expected codex-teams watcher to open a subagent split. stdout=\(stdout) stderr=\(stderr) appServerMethods=\(appServer.methodSnapshot()) cmuxCommands=\(cmuxSocket.commandSnapshot())"
        )
        #expect(
            openedLateSplit,
            "Expected codex-teams watcher to open a split for a late-spawned thread announced only by a bare threadId notification. stdout=\(stdout) stderr=\(stderr) appServerMethods=\(appServer.methodSnapshot()) cmuxCommands=\(cmuxSocket.commandSnapshot())"
        )
        #expect(
            openedInflightSplit,
            "Expected codex-teams watcher to open a split for a thread announced by a bare threadId notification delivered mid-thread/read. stdout=\(stdout) stderr=\(stderr) appServerMethods=\(appServer.methodSnapshot()) cmuxCommands=\(cmuxSocket.commandSnapshot())"
        )
        #expect(
            openedReloadedSplit,
            "Expected codex-teams watcher to re-read and open a split for a thread whose first read was not_loaded and was re-announced once loaded. stdout=\(stdout) stderr=\(stderr) appServerMethods=\(appServer.methodSnapshot()) cmuxCommands=\(cmuxSocket.commandSnapshot())"
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
    private var readCounts: [String: Int] = [:]

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

    private func recordRead(of threadId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let count = (readCounts[threadId] ?? 0) + 1
        readCounts[threadId] = count
        return count
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
            Self.suppressSIGPIPE(on: clientFD)
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
                let params = request["params"] as? [String: Any]
                let readThreadId = method == "thread/read" ? (params?["threadId"] as? String) : nil
                let readCount = readThreadId.map { recordRead(of: $0) } ?? 0
                if readThreadId == "subagent-thread" {
                    // Finding 1: a thread announced by a bare-threadId status
                    // notification delivered *before* the in-flight read's
                    // response, so it lands on that request's notification
                    // handler where re-entrant hydration is disabled. A watcher
                    // that drops such notifications never opens its pane.
                    sendBareThreadNotification("late-inflight-subagent-thread", to: clientFD)
                }
                if readThreadId == "reloaded-subagent-thread", readCount == 1 {
                    // Finding 2 as the tightest race: the thread is still
                    // `not_loaded` on this first read AND its "now loaded"
                    // transition is re-announced *in flight* — before this read's
                    // response — so the bare notification lands on this request's
                    // own handler (re-entrant hydration disabled) and is deferred
                    // onto the very drain that just read this id as not_loaded.
                    // A watcher that reads each deferred id at most once per drain
                    // drops that transition and never opens the pane; a correct
                    // watcher retries the id within the same drain once the
                    // not_loaded read forgets it.
                    sendBareThreadNotification("reloaded-subagent-thread", to: clientFD)
                }
                if let response = response(for: request, method: method, readCount: readCount) {
                    sendText(response, to: clientFD)
                }
                if readThreadId == "subagent-thread" {
                    // Mirror current Codex app-servers: a thread spawned after
                    // the watcher connected is announced only by a bare-threadId
                    // status notification, never by a full thread object.
                    sendBareThreadNotification("late-subagent-thread", to: clientFD)
                    // Finding 2: a thread whose first read is still `not_loaded`.
                    // The watcher must not pin it as hydrated forever.
                    sendBareThreadNotification("reloaded-subagent-thread", to: clientFD)
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

    private func response(for request: [String: Any], method: String, readCount: Int) -> [String: Any]? {
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
                    "thread": threadObject(id: threadID, readCount: readCount)
                ]
            ]
        default:
            return ["id": id, "result": [:]]
        }
    }

    private func threadObject(id: String, readCount: Int) -> [String: Any] {
        let subagentNicknames = [
            "subagent-thread": "Zeno",
            "late-subagent-thread": "Hopper",
            "late-inflight-subagent-thread": "Kepler",
            "reloaded-subagent-thread": "Reloader"
        ]
        if let nickname = subagentNicknames[id] {
            // The reloaded thread reports `not_loaded` on its first read and only
            // becomes attachable once the app-server finishes loading it.
            let statusType = (id == "reloaded-subagent-thread" && readCount <= 1) ? "not_loaded" : "idle"
            return [
                "id": id,
                "cwd": "/tmp",
                "status": ["type": statusType],
                "agentNickname": nickname,
                "source": [
                    "subAgent": [
                        "thread_spawn": [
                            "parent_thread_id": "root-thread",
                            "depth": 1,
                            "agent_nickname": nickname
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

    private func sendBareThreadNotification(_ threadId: String, to fd: Int32) {
        sendText(
            [
                "method": "thread/status/changed",
                "params": [
                    "threadId": threadId,
                    "status": ["type": "active"]
                ]
            ],
            to: fd
        )
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

    private static func suppressSIGPIPE(on fd: Int32) {
        // A peer that closed its end can otherwise raise SIGPIPE on write and
        // terminate the whole test host; make write return EPIPE instead.
        var value: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size))
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
