import Darwin
import Foundation

/// One-connection control-socket fixture that serves a remote-tmux workspace.
struct CLIWorkspaceStableIDMockServer: Sendable {
    private let socketPath: String
    private let listenerDescriptor: Int32
    private let windowID: String
    private let workspaceID: String

    init(socketPath: String, windowID: String, workspaceID: String) throws {
        self.socketPath = socketPath
        self.windowID = windowID
        self.workspaceID = workspaceID

        unlink(socketPath)
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw Self.posixError("socket")
        }

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

    /// Serves one CLI process and returns the socket requests it sent.
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
            while true {
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
        case "workspace.list":
            return encodedResponse(
                id: requestID,
                result: [
                    "window_id": windowID,
                    "window_ref": "window:1",
                    "workspaces": [workspaceRow()],
                ]
            )
        case "workspace.current":
            return encodedResponse(
                id: requestID,
                result: [
                    "window_id": windowID,
                    "window_ref": "window:1",
                    "workspace_id": workspaceID,
                    "workspace_ref": "workspace:1",
                    "workspace": workspaceRow(),
                ]
            )
        case "system.tree":
            return encodedResponse(
                id: requestID,
                result: [
                    "active": NSNull(),
                    "caller": NSNull(),
                    "windows": [[
                        "id": windowID,
                        "ref": "window:1",
                        "index": 0,
                        "workspaces": [workspaceRow()],
                    ]],
                ]
            )
        case "system.top":
            return encodedResponse(
                id: requestID,
                result: [
                    "active": NSNull(),
                    "caller": NSNull(),
                    "windows": [[
                        "id": windowID,
                        "ref": "window:1",
                        "index": 0,
                        "workspaces": [workspaceRow(includingTopTag: true)],
                    ]],
                ]
            )
        default:
            return encodedResponse(
                id: requestID,
                error: ["code": "unexpected_method", "message": method]
            )
        }
    }

    private func workspaceRow(includingTopTag: Bool = false) -> [String: Any] {
        var row: [String: Any] = [
            "id": workspaceID,
            "ref": "workspace:1",
            "index": 0,
            "title": "remote",
            "has_custom_title": false,
            "selected": true,
            "workspace_ids": [workspaceID],
            "workspace_refs": ["workspace:1"],
            "panes": [[
                "id": Self.paneID,
                "ref": "pane:1",
                "surfaces": [[
                    "id": Self.surfaceID,
                    "ref": "surface:1",
                    "type": "terminal",
                ]],
            ]],
            "remote": [
                "enabled": true,
                "transport": "remote-tmux",
                "state": "connected",
            ],
        ]
        if includingTopTag {
            row["tags"] = [[
                "kind": "tag",
                "id": "\(workspaceID):tag:agent",
                "ref": "workspace:\(workspaceID):tag:agent",
                "index": 0,
                "key": "agent",
                "value": "running",
            ]]
        }
        return row
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

    private static let paneID = "33333333-3333-3333-3333-333333333333"
    private static let surfaceID = "44444444-4444-4444-4444-444444444444"
}
