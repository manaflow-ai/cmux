import Foundation
import CmuxNativeWire

/// A host-side cmux-tui daemon client: newline JSON requests with integer
/// ids (`{"id","cmd",...}` → `{"id","ok","data"|"error"}`), and every line
/// carrying `event` on `events`.
actor DaemonLineClient {
    struct Failure: Error, CustomStringConvertible, Sendable {
        var description: String
    }

    private let socket: UnixSocketConnection
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var reader: Task<Void, Never>?
    private var closed = false
    nonisolated let events: AsyncStream<JSONValue>
    private let eventSink: AsyncStream<JSONValue>.Continuation

    init(path: String) throws {
        socket = try UnixSocketConnection.connect(path: path)
        (events, eventSink) = AsyncStream.makeStream(of: JSONValue.self, bufferingPolicy: .bufferingNewest(1024))
    }

    func start() {
        guard reader == nil else { return }
        let chunks = socket.chunks
        reader = Task { [weak self] in
            var splitter = ByteStreamLineSplitter(maximumLineBytes: 64 << 20)
            for await chunk in chunks {
                guard let lines = try? splitter.append(chunk) else { break }
                for line in lines { await self?.handle(line) }
            }
            await self?.finish()
        }
    }

    /// Sends a command and returns its `data`.
    @discardableResult
    func request(_ cmd: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        if closed { throw Failure(description: "daemon connection closed") }
        let id = nextID
        nextID += 1
        var object = params
        object["id"] = .number(Double(id))
        object["cmd"] = .string(cmd)
        var line = try JSONEncoder().encode(JSONValue.object(object))
        line.append(0x0A)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            let socket = socket
            Task {
                do { try await socket.write(line) } catch { self.fail(id, error) }
            }
        }
    }

    func close() {
        socket.close()
        finish()
    }

    private func fail(_ id: Int, _ error: any Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        for c in pending.values { c.resume(throwing: Failure(description: "daemon connection closed")) }
        pending.removeAll()
        eventSink.finish()
    }

    private func handle(_ line: Data) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: line), value.objectValue != nil else { return }
        if value["event"]?.stringValue != nil {
            eventSink.yield(value)
            return
        }
        guard let id = value["id"]?.intValue, let c = pending.removeValue(forKey: id) else { return }
        if value["ok"]?.boolValue == true {
            c.resume(returning: value["data"] ?? .null)
        } else {
            c.resume(throwing: Failure(description: value["error"]?.stringValue ?? "daemon refused request \(id)"))
        }
    }
}

extension DaemonLineClient {
    /// `[surface: workspace display name]` from `list-workspaces`.
    func workspaceNames() async -> [Int: String] {
        guard let data = try? await request("list-workspaces") else { return [:] }
        return Self.workspaceNames(in: data)
    }

    static func workspaceNames(in tree: JSONValue) -> [Int: String] {
        var names: [Int: String] = [:]
        for ws in tree["workspaces"]?.arrayValue ?? [] {
            let title = ws["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? ws["name"]?.stringValue ?? ""
            for screen in ws["screens"]?.arrayValue ?? [] {
                for pane in screen["panes"]?.arrayValue ?? [] {
                    for tab in pane["tabs"]?.arrayValue ?? [] {
                        if let surface = tab["surface"]?.intValue, tab["dead"]?.boolValue != true { names[surface] = title }
                    }
                }
            }
        }
        return names
    }

    func agents() async -> [JSONValue] {
        (try? await request("list-agents"))?["agents"]?.arrayValue ?? []
    }

    func scrollback(surface: Int) async -> String {
        guard let data = try? await request("copy", ["surface": .number(Double(surface)), "mode": "scrollback"]) else { return "" }
        return data["text"]?.stringValue ?? data.stringValue ?? ""
    }
}
