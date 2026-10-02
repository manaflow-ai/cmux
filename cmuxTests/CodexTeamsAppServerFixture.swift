import CryptoKit
import Darwin
import Foundation

/// Minimal WebSocket Codex app-server fixture for bundled-CLI behavior tests.
final class CodexTeamsAppServerFixture: @unchecked Sendable {
    private let listenerFD: Int32
    private let queue = DispatchQueue(label: "com.cmux.tests.codex-teams-app-server")
    private let stateLock = NSLock()
    private let allResumes = DispatchSemaphore(value: 0)
    private var clientFD: Int32 = -1
    private var stopped = false
    private var resumedThreadIds: [String] = []

    let url: String
    let threadIds: [String]

    init(childCount: Int) throws {
        let fixtureThreadIds = ["root-thread"] + (0..<childCount).map { "child-\($0 + 1)" }
        let socketFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw Self.posixError("socket")
        }

        var reuse: Int32 = 1
        setsockopt(
            socketFD,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(socketFD, 4) == 0 else {
            let error = Self.posixError("bind/listen")
            Darwin.close(socketFD)
            throw error
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &boundLength)
            }
        }
        guard nameResult == 0 else {
            let error = Self.posixError("getsockname")
            Darwin.close(socketFD)
            throw error
        }
        listenerFD = socketFD
        threadIds = fixtureThreadIds
        url = "ws://127.0.0.1:\(UInt16(bigEndian: boundAddress.sin_port))"

        queue.async { [self] in
            acceptAndServe()
        }
    }

    deinit {
        stop()
    }

    func waitForAllResumes(timeout: TimeInterval) -> Bool {
        allResumes.wait(timeout: .now() + timeout) == .success
    }

    func resumedThreadIdsSnapshot() -> [String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return resumedThreadIds
    }

    func stop() {
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        stopped = true
        let activeClientFD = clientFD
        clientFD = -1
        stateLock.unlock()

        if activeClientFD >= 0 {
            Darwin.shutdown(activeClientFD, SHUT_RDWR)
            Darwin.close(activeClientFD)
        }
        Darwin.shutdown(listenerFD, SHUT_RDWR)
        Darwin.close(listenerFD)
    }

    private func acceptAndServe() {
        let accepted = Darwin.accept(listenerFD, nil, nil)
        guard accepted >= 0 else { return }
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            Darwin.close(accepted)
            return
        }
        clientFD = accepted
        stateLock.unlock()
        defer {
            stateLock.lock()
            let shouldClose = clientFD == accepted
            if shouldClose {
                clientFD = -1
            }
            stateLock.unlock()
            if shouldClose {
                Darwin.close(accepted)
            }
        }

        do {
            try performHandshake(clientFD: accepted)
            while let request = try receiveObject(clientFD: accepted) {
                try handle(request, clientFD: accepted)
            }
        } catch {
            // The test owns assertions; a closed client ends this disposable fixture.
        }
    }

    private func handle(_ request: [String: Any], clientFD: Int32) throws {
        guard let method = request["method"] as? String else { return }
        guard let id = request["id"] else { return }
        switch method {
        case "initialize":
            try sendObject(["id": id, "result": [:]], clientFD: clientFD)
        case "thread/loaded/list":
            try sendObject([
                "id": id,
                "result": [
                    "data": threadIds,
                    "nextCursor": NSNull()
                ]
            ], clientFD: clientFD)
        case "thread/resume":
            let params = request["params"] as? [String: Any]
            guard let threadId = params?["threadId"] as? String,
                  threadIds.contains(threadId) else {
                try sendObject([
                    "id": id,
                    "error": ["code": -32602, "message": "unknown fixture thread"]
                ], clientFD: clientFD)
                return
            }
            stateLock.lock()
            if !resumedThreadIds.contains(threadId) {
                resumedThreadIds.append(threadId)
            }
            let isLastResume = resumedThreadIds.count == threadIds.count
            stateLock.unlock()
            try sendObject([
                "id": id,
                "result": Self.resumeResult(threadId: threadId)
            ], clientFD: clientFD)
            if isLastResume {
                allResumes.signal()
            }
        default:
            try sendObject([
                "id": id,
                "error": ["code": -32601, "message": "unexpected method \(method)"]
            ], clientFD: clientFD)
        }
    }

    /// Codex CLI 0.146.0 `thread/resume` result shape, sanitized for tests.
    private static func resumeResult(threadId: String) -> [String: Any] {
        let isRoot = threadId == "root-thread"
        let source: Any = isRoot
            ? "cli"
            : [
                "subAgent": [
                    "thread_spawn": [
                        "parent_thread_id": "root-thread",
                        "depth": 1,
                        "agent_path": ["agents", threadId],
                        "agent_nickname": "fixture-\(threadId)",
                        "agent_role": "read-only"
                    ]
                ]
            ]
        let thread: [String: Any] = [
            "id": threadId,
            "sessionId": "fixture-session",
            "forkedFromId": NSNull(),
            "parentThreadId": isRoot ? NSNull() : "root-thread",
            "preview": "",
            "ephemeral": false,
            "isPinned": false,
            "modelProvider": "openai",
            "createdAt": 1,
            "updatedAt": 2,
            "recencyAt": NSNull(),
            "status": ["type": "idle"],
            "path": NSNull(),
            "cwd": "/tmp",
            "cliVersion": "0.146.0",
            "source": source,
            "threadSource": NSNull(),
            "agentNickname": isRoot ? NSNull() : "fixture-\(threadId)",
            "agentRole": isRoot ? NSNull() : "read-only",
            "gitInfo": NSNull(),
            "name": NSNull(),
            "turns": []
        ]
        return [
            "thread": thread,
            "model": "gpt-5",
            "modelProvider": "openai",
            "serviceTier": NSNull(),
            "cwd": "/tmp",
            "instructionSources": [],
            "approvalPolicy": "never",
            "approvalsReviewer": "user",
            "sandbox": ["type": "dangerFullAccess"],
            "reasoningEffort": NSNull()
        ]
    }

    private func performHandshake(clientFD: Int32) throws {
        var request = Data()
        let delimiter = Data("\r\n\r\n".utf8)
        while !request.suffix(delimiter.count).elementsEqual(delimiter) {
            guard let byte = try readExactly(1, clientFD: clientFD).first else {
                throw Self.posixError("websocket handshake read")
            }
            request.append(byte)
        }
        guard let text = String(data: request, encoding: .utf8),
              let keyLine = text
                .split(separator: "\r\n")
                .first(where: { $0.lowercased().hasPrefix("sec-websocket-key:") }),
              let key = keyLine.split(separator: ":", maxSplits: 1).last?
                .trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw Self.posixError("websocket handshake key")
        }
        let acceptInput = Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
        let accept = Data(Insecure.SHA1.hash(data: acceptInput)).base64EncodedString()
        let response = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n"
            + "\r\n"
        try writeAll(Data(response.utf8), clientFD: clientFD)
    }

    private func receiveObject(clientFD: Int32) throws -> [String: Any]? {
        while true {
            let header = try readExactly(2, clientFD: clientFD)
            let opcode = header[0] & 0x0F
            var length = UInt64(header[1] & 0x7F)
            if length == 126 {
                let extended = try readExactly(2, clientFD: clientFD)
                length = UInt64(extended[0]) << 8 | UInt64(extended[1])
            } else if length == 127 {
                length = try readExactly(8, clientFD: clientFD).reduce(0) {
                    ($0 << 8) | UInt64($1)
                }
            }
            let isMasked = header[1] & 0x80 != 0
            let mask = isMasked ? try readExactly(4, clientFD: clientFD) : Data()
            var payload = try readExactly(Int(length), clientFD: clientFD)
            if isMasked {
                for index in payload.indices {
                    payload[index] ^= mask[index % 4]
                }
            }
            switch opcode {
            case 0x1:
                return try JSONSerialization.jsonObject(with: payload) as? [String: Any]
            case 0x8:
                return nil
            case 0x9:
                try sendFrame(payload, opcode: 0xA, clientFD: clientFD)
            default:
                continue
            }
        }
    }

    private func sendObject(_ object: [String: Any], clientFD: Int32) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try sendFrame(data, opcode: 0x1, clientFD: clientFD)
    }

    private func sendFrame(_ payload: Data, opcode: UInt8, clientFD: Int32) throws {
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= Int(UInt16.max) {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            var length = UInt64(payload.count).bigEndian
            withUnsafeBytes(of: &length) {
                frame.append(contentsOf: $0)
            }
        }
        frame.append(payload)
        try writeAll(frame, clientFD: clientFD)
    }

    private func readExactly(_ count: Int, clientFD: Int32) throws -> Data {
        var data = Data()
        while data.count < count {
            var buffer = [UInt8](repeating: 0, count: count - data.count)
            let bytesRead = Darwin.recv(clientFD, &buffer, buffer.count, 0)
            guard bytesRead > 0 else {
                throw Self.posixError("recv")
            }
            data.append(contentsOf: buffer.prefix(bytesRead))
        }
        return data
    }

    private func writeAll(_ data: Data, clientFD: Int32) throws {
        var offset = 0
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            while offset < data.count {
                let written = Darwin.send(
                    clientFD,
                    baseAddress.advanced(by: offset),
                    data.count - offset,
                    0
                )
                guard written > 0 else {
                    throw Self.posixError("send")
                }
                offset += written
            }
        }
    }

    private static func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(errno)))"]
        )
    }
}
