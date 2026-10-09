public import CmuxiOSFeatureKit
import Foundation

/// What became of one intent, for haptics and the inline notice.
public enum FeedIntentOutcome: Hashable, Sendable {
    case committed(FeedIntent)
    /// The owner refused it. `closedElsewhere` is `feed.closed`: the request
    /// was answered, declined or expired on another device first.
    case refused(FeedIntent, reason: String, closedElsewhere: Bool)
    /// Not sent: the owner is unreachable (nothing queued) or the send failed.
    case notSent(FeedIntent, offline: Bool)

    public var intent: FeedIntent {
        switch self {
        case .committed(let intent), .refused(let intent, _, _), .notSent(let intent, _): intent
        }
    }

    /// Background reports (seen) never surface to the user.
    public var isSilent: Bool {
        if case .seen = intent { return true }
        return false
    }
}
