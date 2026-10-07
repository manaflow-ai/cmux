import Foundation

/// One open socket. `receive` throws when the socket closes.
public protocol CloudWireConnection: Sendable {
    func receive() async throws -> Data
    func send(_ text: String) async throws
    func close()
}
