import Darwin
import Foundation

/// One-request control-socket fixture for workspace-group CLI commands.
struct CLIWorkspaceGroupSafetyMockServer: Sendable {
    private let socketPath: String
    private let listenerDescriptor: Int32

    init(socketPath: String) throws {
        self.socketPath = socketPath
        unlink(socketPath)

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Self.posixError("socket") }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < pathCapacity else {
            Darwin.close(descriptor)
            throw Self.posixError("socket path")
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

            var recordedRequests: [String] = []
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                let count = Darwin.read(clientDescriptor, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    return recordedRequests
                }
                if count == 0 { return recordedRequests }
                pending.append(buffer, count: count)
                while let newline = pending.firstRange(of: Data([0x0A])) {
                    let lineData = pending.subdata(in: 0..<newline.lowerBound)
                    pending.removeSubrange(0...newline.lowerBound)
                    guard let line = String(data: lineData, encoding: .utf8) else { continue }
                    recordedRequests.append(line)
                    guard Self.writeResponse(for: line, to: clientDescriptor) else {
                        return recordedRequests
                    }
                }
            }
        }
    }

    private static func writeResponse(for line: String, to descriptor: Int32) -> Bool {
        guard let data = line.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let requestID = request["id"] as? String,
              let method = request["method"] as? String else {
            return false
        }
        let result: [String: Any]
        switch method {
        case "workspace.create":
            result = [
                "workspace_id": "11111111-1111-1111-1111-111111111111",
                "workspace_ref": "workspace:1",
            ]
        case "surface.send_text":
            result = [
                "surface_id": "22222222-2222-2222-2222-222222222222",
                "surface_ref": "surface:1",
            ]
        case "workspace.group.create":
            result = [
                "group": [
                    "id": "11111111-1111-1111-1111-111111111111",
                    "ref": "workspace_group:1",
                ],
            ]
        case "workspace.group.ungroup":
            result = [
                "group_id": "11111111-1111-1111-1111-111111111111",
                "operation": "dissolved",
                "kept_workspace_count": 2,
            ]
        case "workspace.group.delete":
            result = [
                "group_id": "11111111-1111-1111-1111-111111111111",
                "operation": "closed_workspaces",
                "closed_workspace_count": 2,
            ]
        default:
            result = [:]
        }
        let payload: [String: Any] = ["id": requestID, "ok": true, "result": result]
        guard let encoded = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        let response = encoded + Data([0x0A])
        return response.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return false }
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
