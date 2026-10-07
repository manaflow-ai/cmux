import Foundation

/// Why `CloudFeedSource` ended a session on an open socket.
enum FeedWireError: Error, Hashable, Sendable {
    /// The owner answered a subscribe or snapshot request with an error.
    case owner(code: String)
}
