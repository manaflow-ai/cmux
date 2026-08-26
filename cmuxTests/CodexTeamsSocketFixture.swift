import Darwin
import Foundation

/// Minimal cmux v2 Unix-socket fixture that records native split requests.
final class CodexTeamsSocketFixture: @unchecked Sendable {
    private let listenerFD: Int32
    private let queue = DispatchQueue(label: "com.cmux.tests.codex-teams-socket")
    private let stateLock = NSLock()
    private let splitSignal = DispatchSemaphore(value: 0)
    private var clientFD: Int32 = -1
    private var stopped = false
    private var requests: [[String: Any]] = []
    private var splitCount = 0

    let path: String
    let splitFailureMessage: String?

    init(splitFailureMessage: String? = nil) throws {
        self.splitFailureMessage = splitFailureMessage
        path = "/tmp/cmux-codex-backfill-\(UUID().uuidString.prefix(8)).sock"
        unlink(path)
        listenerFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerFD >= 0 else {
            throw Self.posixError("socket")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxLength else {
            Darwin.close(listenerFD)
            throw Self.posixError("socket path")
        }
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
                let destination = UnsafeMutableRawPointer(tuplePointer)
                    .assumingMemoryBound(to: CChar.self)
                strncpy(destination, source, maxLength - 1)
            }
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenerFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(listenerFD, 1) == 0 else {
            let error = Self.posixError("bind/listen")
            Darwin.close(listenerFD)
            throw error
        }

        queue.async { [self] in
            acceptAndServe()
        }
    }

    deinit {
        stop()
    }

    func waitForSurfaceSplits(_ count: Int, timeout: TimeInterval) -> Bool {
        let deadline = DispatchTime.now() + timeout
        for _ in 0..<count where splitSignal.wait(timeout: deadline) != .success {
            return false
        }
        return true
    }

    func requestsSnapshot() -> [[String: Any]] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return requests
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
        unlink(path)
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

        while let request = try? readObject(clientFD: accepted) {
            stateLock.lock()
            requests.append(request)
            stateLock.unlock()
            guard let id = request["id"],
                  let method = request["method"] as? String else {
                continue
            }
            let response: [String: Any]
            if method == "surface.split" {
                stateLock.lock()
                splitCount += 1
                let currentSplitCount = splitCount
                stateLock.unlock()
                if let splitFailureMessage {
                    response = [
                        "id": id,
                        "ok": false,
                        "error": [
                            "code": "fixture_split_failure",
                            "message": splitFailureMessage
                        ]
                    ]
                } else {
                    response = [
                        "id": id,
                        "ok": true,
                        "result": [
                            "surface_id": "fixture-surface-\(currentSplitCount)"
                        ]
                    ]
                }
            } else {
                response = ["id": id, "ok": true, "result": [:]]
            }
            guard (try? writeObject(response, clientFD: accepted)) != nil else {
                return
            }
            if method == "surface.split" {
                splitSignal.signal()
            }
        }
    }

    private func readObject(clientFD: Int32) throws -> [String: Any] {
        var data = Data()
        while true {
            var byte: UInt8 = 0
            let count = Darwin.recv(clientFD, &byte, 1, 0)
            guard count > 0 else {
                throw Self.posixError("recv")
            }
            if byte == 0x0A {
                break
            }
            data.append(byte)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Self.posixError("json")
        }
        return object
    }

    private func writeObject(_ object: [String: Any], clientFD: Int32) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
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
