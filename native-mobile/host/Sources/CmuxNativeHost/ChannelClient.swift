import Foundation
public import CmuxNativeLink
public import CmuxNativeWire

/// Request/response helper over a `LinkChannel` carrying JSON lines with an
/// `id` (daemon protocol or `svc`). Lines without a matching waiter are kept
/// for `waitFor`. Used by the e2e self-test and tests.
public actor ChannelClient {
    public let channel: any LinkChannel
    private var buffered: [JSONValue] = []
    private var waiters: [(id: UInt64, match: @Sendable (JSONValue) -> Bool, continuation: CheckedContinuation<JSONValue, any Error>)] = []
    private var nextWaiter: UInt64 = 0
    private var nextID = 1
    private var finished = false
    private var reader: Task<Void, Never>?

    public init(channel: any LinkChannel) {
        self.channel = channel
    }

    private func startIfNeeded() {
        guard reader == nil else { return }
        let incoming = channel.incoming
        reader = Task { [weak self] in
            for await line in incoming {
                guard let value = try? JSONDecoder().decode(JSONValue.self, from: line) else { continue }
                await self?.receive(value)
            }
            await self?.finish()
        }
    }

    private func receive(_ value: JSONValue) {
        if let index = waiters.firstIndex(where: { $0.match(value) }) {
            waiters.remove(at: index).continuation.resume(returning: value)
        } else {
            buffered.append(value)
            if buffered.count > 10_000 { buffered.removeFirst(buffered.count - 10_000) }
        }
    }

    private func finish() {
        finished = true
        let all = waiters
        waiters = []
        for w in all { w.continuation.resume(throwing: LinkError.channelClosed) }
    }

    /// Sends `object` with a fresh numeric `id` and waits for the response
    /// carrying that id.
    public func request(_ object: [String: JSONValue], timeout: Duration = .seconds(20)) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        var body = object
        body["id"] = .number(Double(id))
        try await sendRaw(.object(body))
        return try await waitFor(timeout: timeout) { $0["id"]?.intValue == id && $0["event"] == nil }
    }

    public func sendRaw(_ value: JSONValue) async throws {
        startIfNeeded()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(value)
        line.append(0x0A)
        try await channel.send(line)
    }

    /// Returns the first buffered or future line matching `match`.
    public func waitFor(timeout: Duration = .seconds(20), _ match: @escaping @Sendable (JSONValue) -> Bool) async throws -> JSONValue {
        startIfNeeded()
        if let index = buffered.firstIndex(where: match) { return buffered.remove(at: index) }
        if finished { throw LinkError.channelClosed }
        let waiterID = nextWaiter
        nextWaiter += 1
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { await self?.expire(waiterID) }
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append((waiterID, match, continuation))
        }
    }

    private func expire(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: LinkError.timeout("response"))
    }

    public func close() {
        reader?.cancel()
        channel.close()
    }
}
