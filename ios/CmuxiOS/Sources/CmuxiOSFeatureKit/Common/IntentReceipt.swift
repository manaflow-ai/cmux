import Foundation

/// The owner's answer to an intent: committed at a revision, or refused.
public enum IntentReceipt: Hashable, Sendable {
    /// The mirror is current once it reaches `revision`.
    case committed(key: IntentKey, revision: UInt64)
    case refused(key: IntentKey, reason: String)

    public var key: IntentKey {
        switch self {
        case .committed(let key, _), .refused(let key, _): key
        }
    }
}
