import CmuxNativeLink
import Foundation

/// One daemon connection (a `daemon:<uuid>` link channel spliced to the
/// cmux-tui socket on the host). Requests carry integer ids; responses are
/// matched by id, and every line with an `event` key goes to `events`.
actor DaemonClient {
    struct Failure: LocalizedError, Sendable {
        var message: String
        var code: String?
        var errorDescription: String? { message }
    }

    struct Event: Sendable {
        var name: String
        var payload: JSONValue
    }

    private let channel: any LinkChannel
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var reader: Task<Void, Never>?
    private let eventContinuation: AsyncStream<Event>.Continuation
    nonisolated let events: AsyncStream<Event>
    private(set) var closed = false

    init(channel: any LinkChannel) {
        self.channel = channel
        (events, eventContinuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
    }

    func start() {
        guard reader == nil else { return }
        let incoming = channel.incoming
        reader = Task { [weak self] in
            for await line in incoming {
                await self?.handle(line)
            }
            await self?.finish(Failure(message: "The connection to your Mac closed."))
        }
    }

    /// Sends `{"id":N,"cmd":cmd,...params}` and returns `data`.
    @discardableResult
    func request(_ cmd: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        if closed { throw Failure(message: "Not connected.") }
        let id = nextID
        nextID += 1
        var object = params
        object["id"] = .number(Double(id))
        object["cmd"] = .string(cmd)
        var line = try JSONEncoder().encode(JSONValue.object(object))
        line.append(0x0A)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            let channel = channel
            Task {
                do { try await channel.send(line) } catch { self.fail(id, error) }
            }
        }
    }

    func close() {
        channel.close()
        finish(Failure(message: "Closed."))
    }

    private func fail(_ id: Int, _ error: any Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func finish(_ error: any Error) {
        guard !closed else { return }
        closed = true
        for continuation in pending.values { continuation.resume(throwing: error) }
        pending.removeAll()
        eventContinuation.finish()
    }

    private func handle(_ data: Data) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data), let object = value.object else { return }
        if let name = object["event"]?.string {
            eventContinuation.yield(Event(name: name, payload: value))
            return
        }
        guard let id = object["id"]?.int, let continuation = pending.removeValue(forKey: id) else { return }
        if object["ok"]?.bool == true {
            continuation.resume(returning: object["data"] ?? .null)
        } else {
            continuation.resume(throwing: Failure(
                message: object["error"]?.string ?? "The Mac refused the request.",
                code: object["error_code"]?.string
            ))
        }
    }
}

extension DaemonClient {
    func identify() async throws -> JSONValue { try await request("identify") }

    func setClientInfo(deviceID: String, name: String) async throws {
        try await request("set-client-info", [
            "name": .string(name),
            "kind": "iphone",
            "device_kind": "iphone",
            "device_id": .string(deviceID),
            "capabilities": ["shared-sizing-v1", "view-attachment-lease-v1", "view-attachment-detach-v1", "terminal-pending-sequence-v1"],
        ])
    }

    func listWorkspaces() async throws -> DaemonTree {
        try await request("list-workspaces").decode(DaemonTree.self)
    }

    func listAgents() async throws -> [DaemonAgent] {
        struct Agents: Decodable { var agents: [DaemonAgent] }
        return try await request("list-agents").decode(Agents.self).agents
    }

    func listNotifications(limit: Int = 200) async throws -> [DaemonNotification] {
        struct List: Decodable { var notifications: [DaemonNotification] }
        return (try? await request("list-notifications", ["limit": .number(Double(limit))]).decode(List.self).notifications) ?? []
    }

    func subscribe() async throws {
        try await request("subscribe", ["tree_events": "coarse"])
    }

    func send(surface: Int, text: String, paste: Bool = false) async throws {
        var params: [String: JSONValue] = ["surface": .number(Double(surface))]
        if paste {
            params["bytes"] = .string(Data(text.utf8).base64EncodedString())
            params["paste"] = true
        } else {
            params["text"] = .string(text)
        }
        try await request("send", params)
    }

    func sendBytes(surface: Int, _ bytes: Data) async throws {
        try await request("send", ["surface": .number(Double(surface)), "bytes": .string(bytes.base64EncodedString())])
    }

    func sendKeys(surface: Int, _ keys: [String]) async throws {
        try await request("send-key", ["surface": .number(Double(surface)), "keys": .array(keys.map(JSONValue.string))])
    }

    func readScrollback(surface: Int) async throws -> String {
        let data = try await request("copy", ["surface": .number(Double(surface)), "mode": "scrollback"])
        return data["text"]?.string ?? data.string ?? ""
    }

    func newWorkspace(name: String?) async throws -> Int? {
        var params: [String: JSONValue] = [:]
        if let name, !name.isEmpty { params["name"] = .string(name) }
        return try await request("new-workspace", params)["surface"]?.int
    }

    func newTab(pane: Int) async throws -> Int? {
        try await request("new-tab", ["pane": .number(Double(pane))])["surface"]?.int
    }

    func closeSurface(_ surface: Int) async throws {
        try await request("close-surface", ["surface": .number(Double(surface))])
    }

    func acknowledge(surface: Int) async throws {
        try await request("ack-tab-notifications", ["surface": .number(Double(surface))])
    }
}
