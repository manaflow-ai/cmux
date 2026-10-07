import Foundation

/// One `URLSessionWebSocketTask` as a `CloudWireConnection`.
struct URLSessionCloudWireConnection: CloudWireConnection {
    let task: URLSessionWebSocketTask

    func receive() async throws -> Data {
        switch try await task.receive() {
        case .string(let text): return Data(text.utf8)
        case .data(let data): return data
        @unknown default: return Data()
        }
    }

    func send(_ text: String) async throws { try await task.send(.string(text)) }

    func close() { task.cancel(with: .goingAway, reason: nil) }
}
