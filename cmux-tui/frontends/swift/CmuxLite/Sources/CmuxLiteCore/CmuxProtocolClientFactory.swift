import Foundation

/// Creates independent protocol clients for disposable surface attachments.
public protocol CmuxProtocolClientFactory: Sendable {
    /// Creates a fresh, disconnected protocol client.
    /// - Returns: A client whose transport has not yet been opened.
    func makeClient() async -> CmuxProtocolClient
}
