import Foundation

/// Request/response and event client for the cmux-tui daemon protocol (v12,
/// JSON lines) carried on a link's `daemon` channel.
public actor DaemonClient {
    private let channel: any LinkChannel
    private var nextID = 1
    private var pending: [String: CheckedContinuation<Data, any Error>] = [:]
    private var buffer = Data()
    private var readTask: Task<Void, Never>?
    public nonisolated let events: AsyncStream<Data>
    private let eventContinuation: AsyncStream<Data>.Continuation

    public init(channel: any LinkChannel) {
        self.channel = channel
        (events, eventContinuation) = AsyncStream.makeStream()
    }

    public func start() {
        guard readTask == nil else { return }
        readTask = Task { await self.readLoop() }
    }

    /// Sends `{"id", "cmd", ...params}` and returns the raw JSON reply line.
    public func request(_ cmd: String, params: [String: Any] = [:]) async throws -> Data {
        start()
        let id = "m\(nextID)"
        nextID += 1
        var object = params
        object["id"] = id
        object["cmd"] = cmd
        var line = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        line.append(0x0A)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do { try await channel.send(line) } catch { self.fail(id: id, error: error) }
            }
        }
    }

    private func fail(id: String, error: any Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func readLoop() async {
        do {
            while let chunk = try await channel.receive() {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    route(Data(line))
                }
            }
            finish(LinkError(code: "closed", message: "daemon channel closed"))
        } catch {
            finish(error)
        }
    }

    private func route(_ line: Data) {
        guard !line.isEmpty else { return }
        if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
           let id = object["id"] as? String, let continuation = pending.removeValue(forKey: id) {
            continuation.resume(returning: line)
        } else {
            eventContinuation.yield(line)
        }
    }

    private func finish(_ error: any Error) {
        for (_, continuation) in pending { continuation.resume(throwing: error) }
        pending.removeAll()
        eventContinuation.finish()
    }
}
