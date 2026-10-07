public import Foundation

/// Opens the `/v1/wire/cloud` socket. The app uses
/// `URLSessionCloudWireTransport`; tests drive a fake.
public protocol CloudWireTransport: Sendable {
    func connect(_ request: URLRequest) async throws -> any CloudWireConnection
}
