import Darwin
import Foundation

final class RecordingCodexTeamsCmuxSocket: @unchecked Sendable {
    let path: String

    private let listenerFD: Int32
    private let queue = DispatchQueue(label: "com.cmux.tests.codex-teams-cmux-socket", qos: .userInitiated)
    // Connection handlers must run off `queue`: `acceptLoop()` occupies that serial
    // queue for the listener's whole lifetime, so dispatching `handle(clientFD:)`
    // back onto it would starve every connection. Use a concurrent queue instead.
    private let connectionQueue = DispatchQueue(
        label: "com.cmux.tests.codex-teams-cmux-socket.connections",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let lock = NSLock()
    private var stopped = false
    private var commands: [String] = []

    init() throws {
        path = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-codex-watch-\(UUID().uuidString.prefix(8)).sock", isDirectory: false)
            .path
        listenerFD = try Self.bindUnixSocket(at: path)
        queue.async { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let fd = listenerFD
        let socketPath = path
        lock.unlock()
        Darwin.close(fd)
        unlink(socketPath)
    }

    func commandSnapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return commands
    }

    func waitForMethod(_ method: String, timeout: TimeInterval) -> Bool {
        waitForCommand(matching: { Self.method(in: $0) == method }, timeout: timeout)
    }

    func waitForCommand(containing needle: String, timeout: TimeInterval) -> Bool {
        waitForCommand(matching: { $0.contains(needle) }, timeout: timeout)
    }

    private func waitForCommand(matching predicate: (String) -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if commandSnapshot().contains(where: predicate) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return commandSnapshot().contains(where: predicate)
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func acceptLoop() {
        while !isStopped {
            var address = sockaddr_un()
            var addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
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
            connectionQueue.async { [weak self] in self?.handle(clientFD: clientFD) }
        }
    }

    private func handle(clientFD: Int32) {
        defer { Darwin.close(clientFD) }
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !isStopped {
            let count = Darwin.read(clientFD, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            if count == 0 { return }
            pending.append(buffer, count: count)
            while let newlineRange = pending.firstRange(of: Data([0x0A])) {
                let lineData = pending.subdata(in: 0..<newlineRange.lowerBound)
                pending.removeSubrange(0...newlineRange.lowerBound)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                lock.lock()
                commands.append(line)
                lock.unlock()
                let response = Self.response(for: line) + "\n"
                Self.writeAll(Data(response.utf8), to: clientFD)
                if Self.method(in: line) == "workspace.equalize_splits" {
                    // Simulate the app closing a control connection that idles
                    // between subagent spawns: drop it once a pane-open burst
                    // (split, rename, equalize) completes. The watcher must
                    // reconnect before opening the next subagent pane.
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

    private static func writeAll(_ data: Data, to fd: Int32) {
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

    private static func response(for line: String) -> String {
        guard let object = decodeObject(line), let id = object["id"] as? String else {
            return "OK"
        }
        let result: [String: Any] = (object["method"] as? String) == "surface.split"
            ? ["surface_id": "subagent-surface"]
            : [:]
        let response: [String: Any] = ["id": id, "ok": true, "result": result]
        let data = try? JSONSerialization.data(withJSONObject: response, options: [])
        return String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }

    private static func method(in line: String) -> String? {
        decodeObject(line)?["method"] as? String
    }

    private static func decodeObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }

    private static func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError("socket") }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < maxLength else {
            Darwin.close(fd)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENAMETOOLONG),
                userInfo: [NSLocalizedDescriptionKey: "Unix socket path is too long: \(path)"]
            )
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxLength) { buffer in
                for index in bytes.indices { buffer[index] = CChar(bitPattern: bytes[index]) }
                buffer[bytes.count] = 0
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.bind(fd, socketPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
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
        return fd
    }

    private static func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(errno)))"]
        )
    }
}
