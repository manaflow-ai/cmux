import Darwin
import Foundation

// The socket loop runs on a private queue; the lock protects captures and descriptor lifecycle state.
final class CLIWindowCommandMockServer: @unchecked Sendable {
    private let socketPath: String
    private let targetWindowID: String
    private let targetWindowRef: String
    private let queue = DispatchQueue(label: "com.cmux.tests.cli-window-command-server")
    private let finished = DispatchGroup()
    private let lock = NSLock()
    private var listenerFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var started = false
    private var stopping = false
    private var receivedLines: [String] = []

    init(socketPath: String, targetWindowID: String, targetWindowRef: String) throws {
        self.socketPath = socketPath
        self.targetWindowID = targetWindowID
        self.targetWindowRef = targetWindowRef

        unlink(socketPath)
        listenerFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerFD >= 0 else {
            throw Self.posixError("socket")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < maxPathLength else {
            stop()
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENAMETOOLONG),
                userInfo: [NSLocalizedDescriptionKey: "Unix socket path is too long: \(socketPath)"]
            )
        }
        socketPath.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                let buffer = UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self)
                strncpy(buffer, source, maxPathLength - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.bind(listenerFD, socketPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let error = Self.posixError("bind")
            stop()
            throw error
        }
        guard Darwin.listen(listenerFD, 1) == 0 else {
            let error = Self.posixError("listen")
            stop()
            throw error
        }
    }

    deinit {
        stop()
    }

    func start() {
        lock.lock()
        guard !started, !stopping else {
            lock.unlock()
            return
        }
        started = true
        finished.enter()
        lock.unlock()

        queue.async { [self] in
            serveOneConnection()
        }
    }

    func waitUntilFinished(timeout: TimeInterval) -> Bool {
        finished.wait(timeout: .now() + timeout) == .success
    }

    func receivedLinesSnapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return receivedLines
    }

    func requestObjects() throws -> [[String: Any]] {
        receivedLinesSnapshot().compactMap { line in
            guard let data = line.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data),
                  let object = value as? [String: Any] else {
                return nil
            }
            return object
        }
    }

    func stop() {
        var listenerToClose: Int32 = -1
        var shouldWakeListener = false
        var shouldWait = false

        lock.lock()
        guard !stopping else {
            lock.unlock()
            return
        }
        stopping = true
        shouldWait = started
        if !started {
            listenerToClose = listenerFD
            listenerFD = -1
        } else if clientFD >= 0 {
            _ = Darwin.shutdown(clientFD, SHUT_RDWR)
        } else {
            shouldWakeListener = listenerFD >= 0
        }
        lock.unlock()

        if listenerToClose >= 0 {
            Darwin.close(listenerToClose)
        }
        if shouldWakeListener {
            wakeListener()
        }
        if shouldWait {
            finished.wait()
        }
        unlink(socketPath)
    }

    private func serveOneConnection() {
        defer {
            closeListener()
            finished.leave()
        }

        lock.lock()
        let listenerFD = self.listenerFD
        lock.unlock()
        guard listenerFD >= 0 else { return }

        var clientAddress = sockaddr_un()
        var clientAddressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.accept(listenerFD, socketPointer, &clientAddressLength)
            }
        }
        guard clientFD >= 0 else { return }
        lock.lock()
        guard !stopping else {
            lock.unlock()
            Darwin.close(clientFD)
            return
        }
        self.clientFD = clientFD
        lock.unlock()
        defer { closeClient(clientFD) }

        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(clientFD, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            if count == 0 { return }
            pending.append(buffer, count: count)

            while let newline = pending.firstRange(of: Data([0x0A])) {
                let lineData = pending.subdata(in: 0..<newline.lowerBound)
                pending.removeSubrange(0...newline.lowerBound)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                let response: String
                if line.hasPrefix("auth ") {
                    response = "OK: Authenticated"
                } else {
                    record(line)
                    response = self.response(for: line)
                }
                let responseLine = response + "\n"
                _ = responseLine.withCString { pointer in
                    Darwin.write(clientFD, pointer, strlen(pointer))
                }
            }
        }
    }

    private func closeClient(_ descriptor: Int32) {
        lock.lock()
        if clientFD == descriptor {
            clientFD = -1
        }
        lock.unlock()
        Darwin.close(descriptor)
    }

    private func closeListener() {
        lock.lock()
        let descriptor = listenerFD
        listenerFD = -1
        lock.unlock()
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    private func wakeListener() {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        socketPath.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                let buffer = UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self)
                strncpy(buffer, source, maxPathLength - 1)
            }
        }
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.connect(descriptor, socketPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    private func record(_ line: String) {
        lock.lock()
        receivedLines.append(line)
        lock.unlock()
    }

    private func response(for line: String) -> String {
        if line == "focus_window \(targetWindowID)" || line == "close_window \(targetWindowID)" {
            return "OK"
        }
        if line.hasPrefix("close_window ") {
            return "ERROR: Window not found"
        }

        guard let data = line.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = request["id"] as? String,
              let method = request["method"] as? String else {
            return "ERROR: Invalid window id"
        }

        switch method {
        case "window.list":
            return v2Response(
                id: id,
                ok: true,
                result: [
                    "windows": [[
                        "id": targetWindowID,
                        "ref": targetWindowRef,
                        "index": 2,
                    ]],
                ]
            )
        default:
            return v2Response(
                id: id,
                ok: false,
                error: ["code": "unexpected_method", "message": method]
            )
        }
    }

    private func v2Response(
        id: String,
        ok: Bool,
        result: [String: Any]? = nil,
        error: [String: Any]? = nil
    ) -> String {
        var payload: [String: Any] = ["id": id, "ok": ok]
        if let result { payload["result"] = result }
        if let error { payload["error"] = error }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let response = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return response
    }

    private static func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(errno)))"]
        )
    }
}
