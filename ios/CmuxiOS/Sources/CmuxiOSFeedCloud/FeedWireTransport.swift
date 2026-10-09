public import Foundation

/// Opens WebSocket connections for `CloudFeedSource`. The app uses
/// `URLSessionFeedWireTransport`; tests drive a fake.
public protocol FeedWireTransport: Sendable {
    func connect(_ request: URLRequest) async throws -> any FeedWireConnection
}

/// One open socket. `receive` throws when the socket closes.
public protocol FeedWireConnection: Sendable {
    func receive() async throws -> Data
    func send(_ text: String) async throws
    func close()
}
