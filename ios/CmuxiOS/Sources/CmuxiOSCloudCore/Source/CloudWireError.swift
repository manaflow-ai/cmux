import Foundation

/// Why the Cloud socket session ended.
public enum CloudWireError: Error, Hashable, Sendable {
    /// The owner refused the subscribe or snapshot request.
    case owner(code: String)
    /// A list read failed; the session restarts and reads again.
    case listFailed(code: String)
}
