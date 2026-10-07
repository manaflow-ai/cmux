import Foundation

/// Asks the user about a server identity key. The UI implements it with an
/// alert; the handshake deadline is paused while it waits.
public protocol SSHTrustPrompter: Sendable {
    func decide(_ question: SSHTrustQuestion) async -> SSHTrustDecision
}
