import Darwin
import Foundation

/// One-connection control-socket fixture that answers `workspace.create` with a
/// full identity payload (UUIDs plus refs) and records every request the CLI
/// sends, so tests can assert both the printed output and the follow-up
/// `surface.send_text` routing.
struct CLIWorkspaceCreateIdentityMockServer: Sendable {
    private let socketPath: String
    private let listenerDescriptor: Int32
    private let expectedRequestCount: Int
    /// Simulates an older app that answers `workspace.create` with a ref only.
    private let omitsWorkspaceUUID: Bool

    static let windowID = "11111111-1111-1111-1111-111111111111"
    static let workspaceID = "4B74B022-13FA-4566-84E5-D50E4B7414FE"
    static let surfaceID = "03DF72BC-0608-4ED1-8548-CFDC0D3B7ACA"
    static let workspaceRef = "workspace:39"
    static let surfaceRef = "surface:12"

    init(
        socketPath: String,
        expectedRequestCount: Int,
        omitsWorkspaceUUID: Bool = false
    ) throws {
        self.socketPath = socketPath
        self.expectedRequestCount = expectedRequestCount
        self.omitsWorkspaceUUID = omitsWorkspaceUUID

        unlink(socketPath)
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Self.posixError("socket") }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < pathCapacity else {
            Darwin.close(descriptor)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENAMETOOLONG),
                userInfo: [NSLocalizedDescriptionKey: "Unix socket path is too long"]
            )
        }
        socketPath.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                let buffer = UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self)
                strncpy(buffer, source, pathCapacity - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.bind(descriptor, socketPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(descriptor, 1) == 0 else {
            let error = Self.posixError("bind/listen")
            Darwin.close(descriptor)
            unlink(socketPath)
            throw error
        }

        listenerDescriptor = descriptor
    }

    /// Serves one CLI process and returns the socket request lines it sent.
    func start() -> Task<[String], Never> {
        Task.detached(priority: .userInitiated) { [self] in
            defer {
                Darwin.close(listenerDescriptor)
                unlink(socketPath)
            }

            var readiness = pollfd(fd: listenerDescriptor, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&readiness, 1, 5_000) > 0 else { return [] }

            var clientAddress = sockaddr_un()
            var clientAddressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientDescriptor = withUnsafeMutablePointer(to: &clientAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                    Darwin.accept(listenerDescriptor, socketPointer, &clientAddressLength)
                }
            }
            guard clientDescriptor >= 0 else { return [] }
            defer { Darwin.close(clientDescriptor) }

            var requests: [String] = []
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while requests.count < expectedRequestCount {
                let count = Darwin.read(clientDescriptor, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    return requests
                }
                if count == 0 { return requests }
                pending.append(buffer, count: count)

                while let newline = pending.firstRange(of: Data([0x0A])) {
                    let lineData = pending.subdata(in: 0..<newline.lowerBound)
                    pending.removeSubrange(0...newline.lowerBound)
                    guard let line = String(data: lineData, encoding: .utf8) else { continue }
                    requests.append(line)
                    guard writeResponse(response(for: line), to: clientDescriptor) else {
                        return requests
                    }
                }
            }
            return requests
        }
    }

    private func response(for line: String) -> String {
        guard let data = line.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let requestID = request["id"] as? String,
              let method = request["method"] as? String else {
            return "ERROR: malformed request"
        }

        switch method {
        case "workspace.create":
            var result: [String: Any] = [
                "window_id": Self.windowID,
                "window_ref": "window:1",
                "workspace_ref": Self.workspaceRef,
                "group_id": NSNull(),
                "group_ref": NSNull(),
                "surface_id": Self.surfaceID,
                "surface_ref": Self.surfaceRef,
            ]
            if !omitsWorkspaceUUID {
                result["workspace_id"] = Self.workspaceID
            }
            return encodedResponse(id: requestID, result: result)
        case "surface.send_text":
            return encodedResponse(id: requestID, result: [
                "workspace_id": Self.workspaceID,
                "workspace_ref": Self.workspaceRef,
                "surface_id": Self.surfaceID,
                "surface_ref": Self.surfaceRef,
                "queued": false,
            ])
        default:
            return encodedResponse(id: requestID, error: ["code": "unexpected_method", "message": method])
        }
    }

    private func encodedResponse(
        id: String,
        result: [String: Any]? = nil,
        error: [String: Any]? = nil
    ) -> String {
        var payload: [String: Any] = ["id": id, "ok": error == nil]
        if let result { payload["result"] = result }
        if let error { payload["error"] = error }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func writeResponse(_ response: String, to descriptor: Int32) -> Bool {
        let data = Data((response + "\n").utf8)
        return data.withUnsafeBytes { bytes in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private static func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(errno)))"]
        )
    }
}
