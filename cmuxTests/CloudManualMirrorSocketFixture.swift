import Darwin
import Foundation

/// One command a fixture read from the session, reduced to the fields the
/// handshake tests assert on.
struct CloudManualMirrorFixtureCommand: Sendable {
    let cmd: String
    let id: UInt64
    let surface: UInt64?
    let capabilities: [String]
    let hasInitialSize: Bool

    init?(_ object: [String: Any]) {
        guard let cmd = object["cmd"] as? String else { return nil }
        self.cmd = cmd
        id = (object["id"] as? NSNumber)?.uint64Value ?? 0
        surface = (object["surface"] as? NSNumber)?.uint64Value
        capabilities = object["capabilities"] as? [String] ?? []
        hasInitialSize = object["cols"] != nil || object["rows"] != nil
    }
}

/// A minimal JSON-lines stand-in for the cmux-tui control socket behind a cloud
/// link. It records every command in arrival order and lets a test script the
/// daemon's responses, so handshake ordering is observable as behavior rather
/// than as source text.
// @unchecked Sendable: every mutable field is guarded by `lock`.
final class CloudManualMirrorSocketFixture: @unchecked Sendable {
    let socketPath: String
    private let listenerFD: Int32
    private let lock = NSLock()
    private var clientFD: Int32 = -1
    private var received: [CloudManualMirrorFixtureCommand] = []
    private var cursor = 0

    init() throws {
        let name = "cmux-mm-" + UUID().uuidString.prefix(8).lowercased() + ".sock"
        socketPath = (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
        listenerFD = try Self.listen(at: socketPath)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            acceptAndRead()
        }
    }

    /// The next unread command, or nil when none arrives before `timeout`.
    func nextCommand(timeout: Duration) async -> CloudManualMirrorFixtureCommand? {
        let deadline = ContinuousClock.now + timeout
        while true {
            lock.lock()
            if cursor < received.count {
                let command = received[cursor]
                cursor += 1
                lock.unlock()
                return command
            }
            lock.unlock()
            if ContinuousClock.now >= deadline { return nil }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let line = data + Data([0x0A])
        lock.lock()
        let fd = clientFD
        lock.unlock()
        guard fd >= 0 else { return }
        line.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
    }

    func close() {
        lock.lock()
        if clientFD >= 0 {
            Darwin.close(clientFD)
            clientFD = -1
        }
        lock.unlock()
        Darwin.close(listenerFD)
        unlink(socketPath)
    }

    private func acceptAndRead() {
        var address = sockaddr_un()
        var length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let fd = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.accept(listenerFD, $0, &length)
            }
        }
        guard fd >= 0 else { return }
        lock.lock()
        clientFD = fd
        lock.unlock()
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            if count == 0 { return }
            pending.append(buffer, count: count)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let command = CloudManualMirrorFixtureCommand(object) else { continue }
                lock.lock()
                received.append(command)
                lock.unlock()
            }
        }
    }

    private static func listen(at path: String) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "cmux.tests", code: Int(errno)) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        let utf8 = Array(path.utf8)
        guard utf8.count < maxPathLength else {
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: Int(ENAMETOOLONG))
        }
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { buffer in
                for index in 0..<utf8.count {
                    buffer[index] = CChar(bitPattern: utf8[index])
                }
                buffer[utf8.count] = 0
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: Int(code))
        }
        return fd
    }
}
