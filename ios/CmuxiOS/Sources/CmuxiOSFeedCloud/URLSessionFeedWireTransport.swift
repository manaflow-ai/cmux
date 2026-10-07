public import Foundation

/// `FeedWireTransport` over `URLSessionWebSocketTask`.
public struct URLSessionFeedWireTransport: FeedWireTransport {
    public init() {}

    public func connect(_ request: URLRequest) async throws -> any FeedWireConnection {
        let task = URLSession.shared.webSocketTask(with: request)
        // A full snapshot is up to 1.5 MB (the owner's state bound); the default limit is 1 MiB.
        task.maximumMessageSize = 8 << 20
        task.resume()
        return URLSessionFeedWireConnection(task: task)
    }
}

/// One `URLSessionWebSocketTask` as a `FeedWireConnection`.
struct URLSessionFeedWireConnection: FeedWireConnection {
    let task: URLSessionWebSocketTask

    func receive() async throws -> Data {
        switch try await task.receive() {
        case .string(let text): return Data(text.utf8)
        case .data(let data): return data
        @unknown default: return Data()
        }
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}
