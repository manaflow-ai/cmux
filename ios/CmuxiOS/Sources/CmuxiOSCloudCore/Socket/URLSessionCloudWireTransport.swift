public import Foundation

/// `CloudWireTransport` over `URLSessionWebSocketTask`.
public struct URLSessionCloudWireTransport: CloudWireTransport {
    public init() {}

    public func connect(_ request: URLRequest) async throws -> any CloudWireConnection {
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        return URLSessionCloudWireConnection(task: task)
    }
}
