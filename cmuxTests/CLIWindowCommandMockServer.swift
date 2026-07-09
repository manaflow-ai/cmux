import Darwin
import Foundation

// The socket loop runs on a private queue; the lock only protects test captures read by the test thread.
final class CLIWindowCommandMockServer: @unchecked Sendable {
    private let socketPath: String
    private let targetWindowID: String
    private let targetWindowRef: String
    private let queue = DispatchQueue(label: "com.cmux.tests.cli-window-command-server")
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var listenerFD: Int32 = -1
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
        try receivedLinesSnapshot().compactMap { line in
            guard let data = line.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return object
        }
    }

    func stop() {
        if listenerFD >= 0 {
            Darwin.close(listenerFD)
            listenerFD = -1
        }
        unlink(socketPath)
    }

    private func serveOneConnection() {
        defer { finished.signal() }

        var clientAddress = sockaddr_un()
        var clientAddressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.accept(listenerFD, socketPointer, &clientAddressLength)
            }
        }
        guard clientFD >= 0 else { return }
        defer { Darwin.close(clientFD) }

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
                record(line)
                let response = response(for: line) + "\n"
                _ = response.withCString { pointer in
                    Darwin.write(clientFD, pointer, strlen(pointer))
                }
            }
        }
    }

    private func record(_ line: String) {
        lock.lock()
        receivedLines.append(line)
        lock.unlock()
    }

    private func response(for line: String) -> String {
        if line == "focus_window \(targetWindowID)" {
            return "OK"
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
        case "window.close":
            return v2Response(
                id: id,
                ok: true,
                result: [
                    "window_id": targetWindowID,
                    "window_ref": targetWindowRef,
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
